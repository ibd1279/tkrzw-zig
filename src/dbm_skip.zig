// Zig 0.15.2 port of tkrzw SkipDBM — file-backed static skip list database.
//
// Architecture notes:
//   - Records are appended to a flat file starting at byte 128 (METADATA_SIZE).
//   - Skip level is deterministic: computeLevel(index, step_unit, max_level).
//   - Skip pointers are written as zeros, then back-patched into prior records
//     after each new record is appended (in-order append with back-patching).
//   - For random-order inserts, RecordSorter buffers in-memory entries, flushes
//     to tmp files, then merges all sources (existing skip records, flat tmp files)
//     via a priority-queue heap during finishStorage.
//   - Thread safety: std.Io.RwLock protects file access; atomics for record_count.
//   - File header (128 bytes): magic, version, params, metadata, dirty-close markers.

const std = @import("std");
const lib_common = @import("lib_common.zig");
const thread_util = @import("thread_util.zig");
const file_mod = @import("file.zig");
const file_util = @import("file_util.zig");
const str_util = @import("str_util.zig");
const varint = @import("varint.zig");
const time_util = @import("time_util.zig");
const dbm_mod = @import("dbm.zig");

pub const Status = lib_common.Status;
pub const Code = lib_common.Code;
pub const KeyComparator = lib_common.KeyComparator;
pub const lexicalKeyComparator = lib_common.lexicalKeyComparator;
pub const RecordAction = dbm_mod.RecordAction;
pub const UpdateLogger = dbm_mod.UpdateLogger;
pub const File = file_mod.File;
pub const OpenOptions = file_mod.OpenOptions;
pub const StdFile = file_mod.StdFile;
pub const FlatRecord = file_util.FlatRecord;
pub const FlatRecordReader = file_util.FlatRecordReader;
pub const RecordType = file_util.RecordType;

// ---------------------------------------------------------------------------
// Constants (Phase 1)
// ---------------------------------------------------------------------------

const METADATA_SIZE: i64 = 128;
const META_MAGIC_DATA: []const u8 = "TkrzwSDB\n";
const RECORD_MAGIC: u8 = 0xFF;
const CLOSURE_FLAG_CLOSE: u8 = 0x01;
const REMOVING_VALUE: []const u8 = &[_]u8{ 0xDE, 0xAD, 0x00, 0x19, 0x78, 0x02, 0x11 };
const PKG_MAJOR_VERSION: u8 = 1;
const PKG_MINOR_VERSION: u8 = 0;
pub const DEFAULT_OFFSET_WIDTH: u8 = 4;
pub const DEFAULT_STEP_UNIT: u8 = 4;
pub const DEFAULT_MAX_LEVEL: u8 = 14;
pub const DEFAULT_SORT_MEM_SIZE: i64 = 256 * 1024 * 1024;
pub const DEFAULT_MAX_CACHED_RECORDS: i32 = 65536;
const MIN_OFFSET_WIDTH: u8 = 3;
const MAX_OFFSET_WIDTH: u8 = 6;
const MIN_STEP_UNIT: u8 = 2;
const MAX_STEP_UNIT: u8 = 64;
const MIN_MAX_LEVEL: u8 = 1;
const MAX_MAX_LEVEL: u8 = 32;
const MIN_SORT_MEM_SIZE: i64 = 1024;
const MAX_SORT_MEM_SIZE: i64 = 8 * 1024 * 1024 * 1024;
const MIN_MAX_CACHED_RECORDS: i32 = 1;
const MAX_MAX_CACHED_RECORDS: i32 = 16 * 1024 * 1024;
const SKIP_RECORD_READ_BUFFER_SIZE: usize = 256;
const SKIP_RECORD_READ_DATA_SIZE: usize = 32;
pub const OPAQUE_METADATA_SIZE: usize = 64;
const REC_MEM_FOOT: usize = 8;

// ---------------------------------------------------------------------------
// Enums and Type Aliases (Phase 1)
// ---------------------------------------------------------------------------

pub const RestoreMode = enum(i32) {
    restore_default   = 0,
    restore_sync      = 1,
    restore_read_only = 2,
    restore_noop      = 3,
};
/// OR-able modifier: skip shortcut records during restore. Matches C++ RESTORE_NO_SHORTCUTS.
pub const RESTORE_NO_SHORTCUTS: i32 = 1 << 16;
/// OR-able modifier: use hard sync during restore. Matches C++ RESTORE_WITH_HARDSYNC.
pub const RESTORE_WITH_HARDSYNC: i32 = 1 << 17;

pub const TuningParameters = struct {
    offset_width: i32 = DEFAULT_OFFSET_WIDTH,
    step_unit: i32 = DEFAULT_STEP_UNIT,
    max_level: i32 = DEFAULT_MAX_LEVEL,
    restore_mode: i32 = 0,
    sort_mem_size: i64 = DEFAULT_SORT_MEM_SIZE,
    insert_in_order: bool = false,
    max_cached_records: i32 = DEFAULT_MAX_CACHED_RECORDS,
};

pub const ReducerType = *const fn (key: []const u8, values: []const []const u8, allocator: std.mem.Allocator) std.mem.Allocator.Error![][]const u8;

// ---------------------------------------------------------------------------
// Helper Functions
// ---------------------------------------------------------------------------

fn currentTimeMicros(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toMicroseconds();
}

fn powI64(base: i64, exp: u8) i64 {
    var result: i64 = 1;
    var i: u8 = 0;
    while (i < exp) : (i += 1) {
        result *= base;
    }
    return result;
}

fn computeLevel(index: i64, step_unit: u8, max_level: u8) u8 {
    var level: u8 = 0;
    var idx = index;
    while (level < max_level and @mod(idx, @as(i64, step_unit)) == 0) {
        idx = @divTrunc(idx, @as(i64, step_unit));
        level += 1;
    }
    return level;
}

fn saveMetadata(impl: *SkipDBMImpl, io: std.Io, file: File, finish: bool) Status {
    impl.cyclic_magic +%= 1;

    var buf: [METADATA_SIZE]u8 = undefined;
    @memset(&buf, 0);

    @memcpy(buf[0..9], META_MAGIC_DATA);
    buf[9] = impl.cyclic_magic;
    buf[10] = impl.pkg_major_version;
    buf[11] = impl.pkg_minor_version;
    buf[12] = impl.offset_width;
    buf[13] = impl.step_unit;
    buf[14] = impl.max_level;

    if (finish) {
        buf[15] = impl.closure_flags | CLOSURE_FLAG_CLOSE;
    } else {
        buf[15] = 0; // CLOSURE_FLAG_NONE — file is open, not cleanly closed
    }

    var tmp_buf: [8]u8 = undefined;
    const num_rec_bytes = str_util.intToStrBigEndian(@as(u64, @bitCast(impl.num_records)), 8, &tmp_buf);
    @memcpy(buf[24..32], num_rec_bytes);
    const eff_bytes = str_util.intToStrBigEndian(@as(u64, @bitCast(impl.eff_data_size)), 8, &tmp_buf);
    @memcpy(buf[32..40], eff_bytes);
    const file_bytes = str_util.intToStrBigEndian(@as(u64, @bitCast(impl.file_size)), 8, &tmp_buf);
    @memcpy(buf[40..48], file_bytes);
    const ts_bytes = str_util.intToStrBigEndian(@as(u64, @bitCast(impl.timestamp)), 8, &tmp_buf);
    @memcpy(buf[48..56], ts_bytes);
    const db_bytes = str_util.intToStrBigEndian(@as(u64, impl.db_type), 4, &tmp_buf);
    @memcpy(buf[56..60], db_bytes[0..4]);

    @memcpy(buf[62..126], &impl.opaque_metadata);

    buf[127] = impl.cyclic_magic;

    const status = file.write(io, 0, &buf);
    return status;
}

fn loadMetadata(impl: *SkipDBMImpl, io: std.Io, file: File) Status {
    var buf: [METADATA_SIZE]u8 = undefined;
    const read_status = file.read(io, 0, &buf);
    if (!read_status.isOk()) {
        return read_status;
    }

    if (!std.mem.eql(u8, buf[0..9], META_MAGIC_DATA)) {
        return Status.init(.BROKEN_DATA_ERROR);
    }

    const cyclic_front = buf[9];
    const cyclic_back = buf[127];
    impl.dirty_close = (cyclic_front != cyclic_back);
    impl.cyclic_magic = cyclic_front;

    impl.pkg_major_version = buf[10];
    impl.pkg_minor_version = buf[11];
    impl.offset_width = buf[12];
    impl.step_unit = buf[13];
    impl.max_level = buf[14];
    impl.closure_flags = buf[15];

    if (impl.offset_width < MIN_OFFSET_WIDTH or impl.offset_width > MAX_OFFSET_WIDTH) {
        return Status.init(.BROKEN_DATA_ERROR);
    }
    if (impl.step_unit < MIN_STEP_UNIT or impl.step_unit > MAX_STEP_UNIT) {
        return Status.init(.BROKEN_DATA_ERROR);
    }
    if (impl.max_level < MIN_MAX_LEVEL or impl.max_level > MAX_MAX_LEVEL) {
        return Status.init(.BROKEN_DATA_ERROR);
    }

    impl.num_records = @as(i64, @bitCast(str_util.strToIntBigEndian(buf[24..32])));
    impl.eff_data_size = @as(i64, @bitCast(str_util.strToIntBigEndian(buf[32..40])));
    impl.file_size = @as(i64, @bitCast(str_util.strToIntBigEndian(buf[40..48])));
    impl.timestamp = @as(i64, @bitCast(str_util.strToIntBigEndian(buf[48..56])));
    impl.db_type = @as(u32, @intCast(str_util.strToIntBigEndian(buf[56..60])));

    @memcpy(&impl.opaque_metadata, buf[62..126]);

    return Status.init(.SUCCESS);
}

// ---------------------------------------------------------------------------
// CachedBlob
// ---------------------------------------------------------------------------

const CachedBlob = struct {
    data: []u8,
};

// ---------------------------------------------------------------------------
// SkipRecord (Phase 2)
// ---------------------------------------------------------------------------

const SkipRecord = struct {
    file: File,
    offset_width: u8,
    step_unit: u8,
    max_level: u8,
    level: u8,
    offset: i64,
    index: i64,
    whole_size: usize,
    key_size: usize,
    value_size: usize,
    skip_offsets: [MAX_MAX_LEVEL]i64,
    key_ptr: []const u8,
    value_ptr: ?[]const u8,
    body_offset: i64,
    buf: [SKIP_RECORD_READ_BUFFER_SIZE]u8,
    body_buf: ?[]u8,
    allocator: std.mem.Allocator,

    fn init(file: File, offset_width: u8, step_unit: u8, max_level: u8, allocator: std.mem.Allocator) SkipRecord {
        var skip_offsets: [MAX_MAX_LEVEL]i64 = undefined;
        for (0..MAX_MAX_LEVEL) |i| {
            skip_offsets[i] = 0;
        }
        return .{
            .file = file,
            .offset_width = offset_width,
            .step_unit = step_unit,
            .max_level = max_level,
            .level = 0,
            .offset = 0,
            .index = 0,
            .whole_size = 0,
            .key_size = 0,
            .value_size = 0,
            .skip_offsets = skip_offsets,
            .key_ptr = &.{},
            .value_ptr = null,
            .body_offset = 0,
            .buf = undefined,
            .body_buf = null,
            .allocator = allocator,
        };
    }

    fn deinit(self: *SkipRecord) void {
        if (self.body_buf) |buf| {
            self.allocator.free(buf);
        }
    }

    fn setData(self: *SkipRecord, index: i64, key: []const u8, value: []const u8) void {
        self.level = computeLevel(index, self.step_unit, self.max_level);
        self.index = index;
        self.key_ptr = key;
        self.key_size = key.len;
        self.value_ptr = value;
        self.value_size = value.len;

        const key_size_varint = varint.sizeVarNum(@as(u64, key.len));
        const value_size_varint = varint.sizeVarNum(@as(u64, value.len));
        self.whole_size = 1 + self.offset_width * self.level + key_size_varint + value_size_varint + key.len + value.len;
    }

    fn write(self: *SkipRecord, io: std.Io) Status {
        var stack_buf: [4096]u8 = undefined;
        const write_buf = if (self.whole_size <= 4096)
            stack_buf[0..self.whole_size]
        else
            self.allocator.alloc(u8, self.whole_size) catch {
                return Status.init(.SYSTEM_ERROR);
            };
        defer if (self.whole_size > 4096) self.allocator.free(write_buf);

        write_buf[0] = RECORD_MAGIC;

        var offset: usize = 1;
        for (0..self.level) |_| {
            for (0..self.offset_width) |_| {
                write_buf[offset] = 0;
                offset += 1;
            }
        }

        offset += varint.writeVarNum(write_buf[offset..], @as(u64, self.key_size));

        offset += varint.writeVarNum(write_buf[offset..], @as(u64, self.value_size));

        @memcpy(write_buf[offset .. offset + self.key_size], self.key_ptr);
        offset += self.key_size;

        @memcpy(write_buf[offset .. offset + self.value_size], self.value_ptr.?);
        offset += self.value_size;

        var append_offset: i64 = 0;
        if (!self.file.append(io, write_buf, &append_offset).isOk()) {
            return Status.init(.SYSTEM_ERROR);
        }
        self.offset = append_offset;
        return Status.init(.SUCCESS);
    }

    fn readMetadataKey(self: *SkipRecord, io: std.Io, offset: i64, index: i64) Status {
        self.level = computeLevel(index, self.step_unit, self.max_level);
        self.index = index;
        self.offset = offset;

        const min_record_size = 1 + self.offset_width * self.level + 2;
        const read_size = min_record_size + SKIP_RECORD_READ_DATA_SIZE;
        const file_size = self.file.getSizeSimple();

        if (file_size < offset) {
            return Status.init(.BROKEN_DATA_ERROR);
        }

        const record_size = @min(read_size, @as(usize, @intCast(file_size - offset)));
        if (record_size < min_record_size) {
            return Status.init(.BROKEN_DATA_ERROR);
        }

        const read_status = self.file.read(io, offset, self.buf[0..record_size]);
        if (!read_status.isOk()) {
            return read_status;
        }

        if (self.buf[0] != RECORD_MAGIC) {
            return Status.init(.BROKEN_DATA_ERROR);
        }

        for (0..self.level) |i| {
            const slice_start = 1 + i * self.offset_width;
            const slice_end = slice_start + self.offset_width;
            self.skip_offsets[i] = @as(i64, @intCast(str_util.strToIntBigEndian(self.buf[slice_start..slice_end])));
        }

        for (self.level..MAX_MAX_LEVEL) |i| {
            self.skip_offsets[i] = 0;
        }

        var varint_offset: usize = 1 + self.offset_width * self.level;
        var key_size_u64: u64 = 0;
        const ks = varint.readVarNum(self.buf[varint_offset..record_size], &key_size_u64);
        const key_size = key_size_u64;
        if (ks == 0) {
            return Status.init(.BROKEN_DATA_ERROR);
        }

        varint_offset += ks;
        if (varint_offset >= record_size) {
            return Status.init(.BROKEN_DATA_ERROR);
        }

        var value_size_u64: u64 = 0;
        const vs = varint.readVarNum(self.buf[varint_offset..record_size], &value_size_u64);
        const value_size = value_size_u64;
        if (vs == 0) {
            return Status.init(.BROKEN_DATA_ERROR);
        }

        varint_offset += vs;

        const header_size = 1 + self.offset_width * self.level + ks + vs;
        self.whole_size = header_size + key_size + value_size;
        self.body_offset = offset + @as(i64, @intCast(header_size));

        self.key_size = key_size;
        self.value_size = value_size;
        self.value_ptr = null;

        const remaining = record_size - header_size;
        if (remaining >= key_size + value_size) {
            self.key_ptr = self.buf[header_size .. header_size + key_size];
            self.value_ptr = self.buf[header_size + key_size .. header_size + key_size + value_size];
        } else {
            self.key_ptr = &.{};
        }

        if (@as(i64, @intCast(offset + @as(i64, @intCast(self.whole_size)))) > file_size) {
            return Status.init(.BROKEN_DATA_ERROR);
        }

        return Status.init(.SUCCESS);
    }

    fn readBody(self: *SkipRecord, io: std.Io) Status {
        const needed_size = self.key_size + self.value_size;

        if (self.body_buf != null and self.body_buf.?.len >= needed_size) {
            // Reuse existing buffer
        } else {
            if (self.body_buf) |buf| {
                self.allocator.free(buf);
            }
            const buf_alloc = self.allocator.alloc(u8, needed_size) catch {
                return Status.init(.SYSTEM_ERROR);
            };
            self.body_buf = buf_alloc;
        }

        const read_status = self.file.read(io, self.body_offset, self.body_buf.?);
        if (!read_status.isOk()) {
            return read_status;
        }

        self.key_ptr = self.body_buf.?[0..self.key_size];
        self.value_ptr = self.body_buf.?[self.key_size .. self.key_size + self.value_size];

        return Status.init(.SUCCESS);
    }

    fn updatePastRecords(self: *SkipRecord, io: std.Io, _index: i64, rec_offset: i64, past_offsets: *[MAX_MAX_LEVEL]i64) Status {
        var past_index_diff: i64 = 1;
        for (0..self.level) |i| {
            past_index_diff *= @as(i64, self.step_unit);
            const past_offset = past_offsets[i];
            if (past_offset <= 0) continue;

            // Verify the past record actually has a skip slot at level i.
            // The past record is at ordinal (index - past_index_diff); its level is
            // determined by how many times step_unit divides that index.
            var past_index = _index - past_index_diff;
            var past_level: usize = 0;
            while (past_level < self.max_level and @mod(past_index, @as(i64, self.step_unit)) == 0) {
                past_index = @divTrunc(past_index, @as(i64, self.step_unit));
                past_level += 1;
            }
            if (i > past_level) break; // past record doesn't have this level; stop here

            var patch_buf: [8]u8 = undefined;
            _ = str_util.intToStrBigEndian(@as(u64, @intCast(rec_offset)), self.offset_width, &patch_buf);

            const write_offset = past_offset + 1 + @as(i64, @intCast(i)) * @as(i64, self.offset_width);
            const write_status = self.file.write(io, write_offset, patch_buf[0..self.offset_width]);
            if (!write_status.isOk()) {
                return write_status;
            }
        }

        for (0..self.level) |i| {
            past_offsets[i] = rec_offset;
        }

        return Status.init(.SUCCESS);
    }

    fn serialize(self: *SkipRecord, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        const offset_size = self.offset_width;
        const level_size = varint.sizeVarNum(@as(u64, self.level));
        const skip_offsets_size = @as(usize, self.level) * 8;
        const key_size_size = varint.sizeVarNum(@as(u64, self.key_size));
        const value_size_size = varint.sizeVarNum(@as(u64, self.value_size));
        const has_value_size: usize = 1;

        const total_size = offset_size + level_size + skip_offsets_size + key_size_size + value_size_size + has_value_size + self.key_size + (if (self.value_ptr != null) self.value_size else 0);

        var blob = try allocator.alloc(u8, total_size);
        var pos: usize = 0;

        _ = str_util.intToStrBigEndian(@as(u64, @intCast(self.offset)), self.offset_width, &blob[pos .. pos + self.offset_width]);
        pos += self.offset_width;

        pos += varint.writeVarNum(blob[pos..], @as(u64, self.level));

        for (0..self.level) |i| {
            _ = str_util.intToStrBigEndian(@as(u64, @intCast(self.skip_offsets[i])), 8, &blob[pos .. pos + 8]);
            pos += 8;
        }

        pos += varint.writeVarNum(blob[pos..], @as(u64, self.key_size));
        pos += varint.writeVarNum(blob[pos..], @as(u64, self.value_size));

        blob[pos] = if (self.value_ptr != null) 1 else 0;
        pos += 1;

        @memcpy(blob[pos .. pos + self.key_size], self.key_ptr);
        pos += self.key_size;

        if (self.value_ptr) |val| {
            @memcpy(blob[pos .. pos + val.len], val);
            pos += val.len;
        }

        return blob;
    }

    fn deserialize(self: *SkipRecord, index: i64, blob: []const u8) Status {
        self.index = index;
        var pos: usize = 0;

        if (blob.len < self.offset_width) {
            return Status.init(.BROKEN_DATA_ERROR);
        }

        self.offset = @as(i64, @intCast(str_util.strToIntBigEndian(blob[pos .. pos + self.offset_width])));
        pos += self.offset_width;

        var level_u64: u64 = 0;
        const level_size = varint.readVarNum(blob[pos..], &level_u64);
        if (level_size == 0) {
            return Status.init(.BROKEN_DATA_ERROR);
        }
        self.level = @as(u8, @intCast(level_u64));
        pos += level_size;

        if (self.level >= MAX_MAX_LEVEL) {
            return Status.init(.BROKEN_DATA_ERROR);
        }

        for (0..self.level) |i| {
            if (pos + 8 > blob.len) {
                return Status.init(.BROKEN_DATA_ERROR);
            }
            self.skip_offsets[i] = @as(i64, @intCast(str_util.strToIntBigEndian(blob[pos .. pos + 8])));
            pos += 8;
        }

        for (self.level..MAX_MAX_LEVEL) |i| {
            self.skip_offsets[i] = 0;
        }

        var key_size_u64: u64 = 0;
        const key_size_bytes = varint.readVarNum(blob[pos..], &key_size_u64);
        if (key_size_bytes == 0) {
            return Status.init(.BROKEN_DATA_ERROR);
        }
        self.key_size = key_size_u64;
        pos += key_size_bytes;

        var value_size_u64: u64 = 0;
        const value_size_bytes = varint.readVarNum(blob[pos..], &value_size_u64);
        if (value_size_bytes == 0) {
            return Status.init(.BROKEN_DATA_ERROR);
        }
        self.value_size = value_size_u64;
        pos += value_size_bytes;

        if (pos >= blob.len) {
            return Status.init(.BROKEN_DATA_ERROR);
        }
        const has_value = blob[pos] != 0;
        pos += 1;

        const total_body_size = if (has_value) self.key_size + self.value_size else self.key_size;

        // Bug 4 Fix: Check buffer space with correct ordering to prevent overflow
        if (pos + total_body_size <= SKIP_RECORD_READ_BUFFER_SIZE) {
            if (pos + total_body_size > blob.len) {
                return Status.init(.BROKEN_DATA_ERROR);
            }
            @memcpy(self.buf[pos .. pos + total_body_size], blob[pos .. pos + total_body_size]);
            self.key_ptr = self.buf[pos .. pos + self.key_size];
            if (has_value) {
                self.value_ptr = self.buf[pos + self.key_size .. pos + total_body_size];
            } else {
                self.value_ptr = null;
            }
        } else {
            if (self.body_buf) |buf| {
                self.allocator.free(buf);
            }
            const new_buf = self.allocator.alloc(u8, total_body_size) catch {
                return Status.init(.SYSTEM_ERROR);
            };
            if (pos + total_body_size > blob.len) {
                self.allocator.free(new_buf);
                return Status.init(.BROKEN_DATA_ERROR);
            }
            @memcpy(new_buf, blob[pos .. pos + total_body_size]);
            self.body_buf = new_buf;
            self.key_ptr = new_buf[0..self.key_size];
            if (has_value) {
                self.value_ptr = new_buf[self.key_size .. total_body_size];
            } else {
                self.value_ptr = null;
            }
        }

        // Bug 1 Fix: Reconstruct header_size by tracking actual bytes written for each varint field
        // Re-read from start to compute exact header size
        var header_pos: usize = 0;

        // offset_width bytes for offset (already accounted in pos initialization)
        header_pos = self.offset_width;

        // level varint bytes
        var level_u64_verify: u64 = 0;
        const level_bytes_verify = varint.readVarNum(blob[header_pos..], &level_u64_verify);
        header_pos += level_bytes_verify;

        // skip_offsets (8 bytes per level)
        header_pos += 8 * self.level;

        // key_size varint bytes
        var key_size_u64_verify: u64 = 0;
        const key_size_bytes_verify = varint.readVarNum(blob[header_pos..], &key_size_u64_verify);
        header_pos += key_size_bytes_verify;

        // value_size varint bytes
        var value_size_u64_verify: u64 = 0;
        const value_size_bytes_verify = varint.readVarNum(blob[header_pos..], &value_size_u64_verify);
        header_pos += value_size_bytes_verify;

        // has_value flag (1 byte)
        header_pos += 1;

        const header_size = header_pos;
        self.body_offset = self.offset + @as(i64, @intCast(header_size));
        self.whole_size = header_size + self.key_size + self.value_size;

        return Status.init(.SUCCESS);
    }

    fn search(self: *SkipRecord, io: std.Io, record_base: i64, cache: ?*SkipRecordCache, key: []const u8, upper: bool) Status {
        var offset = record_base;
        var cur_idx: i64 = 0;
        var end_offset = self.file.getSizeSimple();

        while (offset < end_offset) {
            var load_status: Status = undefined;

            if (cache) |c| {
                if (c.prepare(cur_idx, self)) {
                    load_status = Status.init(.SUCCESS);
                } else {
                    load_status = self.readMetadataKey(io, offset, cur_idx);
                }
            } else {
                load_status = self.readMetadataKey(io, offset, cur_idx);
            }

            if (!load_status.isOk()) {
                return load_status;
            }

            if (self.key_ptr.len == 0) {
                const body_status = self.readBody(io);
                if (!body_status.isOk()) {
                    return body_status;
                }
            }

            const cmp = std.mem.order(u8, key, self.key_ptr);

            if (cmp == .eq) {
                return Status.init(.SUCCESS);
            } else if (cmp == .lt) {
                break;
            } else {
                var jumped = false;
                var lv: i8 = @as(i8, @intCast(self.level)) - 1;
                while (lv >= 0) {
                    const lv_u = @as(usize, @intCast(lv));
                    const next_off = self.skip_offsets[lv_u];

                    if (next_off == 0 or next_off >= end_offset) {
                        lv -= 1;
                        continue;
                    }

                    var next_rec = SkipRecord.init(self.file, self.offset_width, self.step_unit, self.max_level, self.allocator);
                    defer next_rec.deinit();

                    const next_status = next_rec.readMetadataKey(io, next_off, cur_idx + powI64(@as(i64, self.step_unit), @as(u8, @intCast(lv_u + 1))));
                    if (!next_status.isOk()) {
                        lv -= 1;
                        continue;
                    }

                    if (next_rec.key_ptr.len == 0) {
                        const body_status = next_rec.readBody(io);
                        if (!body_status.isOk()) {
                            lv -= 1;
                            continue;
                        }
                    }

                    const cmp2 = std.mem.order(u8, key, next_rec.key_ptr);
                    if (cmp2 == .gt or cmp2 == .eq) {
                        offset = next_off;
                        cur_idx += powI64(@as(i64, self.step_unit), @as(u8, @intCast(lv_u + 1)));
                        self.* = next_rec;
                        jumped = true;
                        break;
                    } else {
                        end_offset = next_off;
                    }

                    lv -= 1;
                }

                if (!jumped) {
                    offset += @as(i64, @intCast(self.whole_size));
                    cur_idx += 1;
                }
            }
        }

        if (upper and offset < self.file.getSizeSimple()) {
            const load_status = self.readMetadataKey(io, offset, cur_idx);
            if (load_status.isOk()) {
                return Status.init(.SUCCESS);
            }
            return load_status;
        }

        return Status.init(.NOT_FOUND_ERROR);
    }

    fn searchByIndex(self: *SkipRecord, io: std.Io, record_base: i64, cache: ?*SkipRecordCache, target_index: i64) Status {
        var offset = record_base;
        var cur_idx: i64 = 0;
        var end_offset = self.file.getSizeSimple();

        while (cur_idx < target_index and offset < end_offset) {
            var load_status: Status = undefined;

            if (cache) |c| {
                if (c.prepare(cur_idx, self)) {
                    load_status = Status.init(.SUCCESS);
                } else {
                    load_status = self.readMetadataKey(io, offset, cur_idx);
                }
            } else {
                load_status = self.readMetadataKey(io, offset, cur_idx);
            }

            if (!load_status.isOk()) {
                return load_status;
            }

            var jumped = false;
            var lv: i8 = @as(i8, @intCast(self.level)) - 1;
            while (lv >= 0) {
                const lv_u = @as(usize, @intCast(lv));
                const step = powI64(@as(i64, self.step_unit), @as(u8, @intCast(lv_u + 1)));
                const next_off = self.skip_offsets[lv_u];

                if (next_off != 0 and next_off < end_offset and cur_idx + step <= target_index) {
                    offset = next_off;
                    cur_idx += step;
                    jumped = true;
                    break;
                } else if (next_off != 0 and next_off < end_offset and cur_idx + step > target_index) {
                    end_offset = next_off;
                }

                lv -= 1;
            }

            if (!jumped) {
                offset += @as(i64, @intCast(self.whole_size));
                cur_idx += 1;
            }
        }

        return self.readMetadataKey(io, offset, cur_idx);
    }
};

// ---------------------------------------------------------------------------
// SkipRecordCache (stub for Phase 5)
// ---------------------------------------------------------------------------

const SkipRecordCache = struct {
    cache_unit: i64,
    records: []std.atomic.Value(?*CachedBlob),
    allocator: std.mem.Allocator,

    fn init(step_unit: u8, capacity: i32, num_records: i64, allocator: std.mem.Allocator) !*SkipRecordCache {
        var cache_unit: i64 = 1;
        while (@divTrunc(num_records, cache_unit) > @as(i64, capacity)) {
            cache_unit *= @as(i64, step_unit);
        }

        const size = @max(@divTrunc(num_records, cache_unit), 1);
        const records_arr = try allocator.alloc(std.atomic.Value(?*CachedBlob), @intCast(size));

        for (records_arr) |*slot| {
            slot.* = std.atomic.Value(?*CachedBlob).init(null);
        }

        const self = try allocator.create(SkipRecordCache);
        self.* = .{
            .cache_unit = cache_unit,
            .records = records_arr,
            .allocator = allocator,
        };
        return self;
    }

    fn deinit(self: *SkipRecordCache) void {
        for (self.records) |*slot| {
            const blob = slot.load(.acquire);
            if (blob) |b| {
                self.allocator.free(b.data);
                self.allocator.destroy(b);
            }
        }
        self.allocator.free(self.records);
        self.allocator.destroy(self);
    }

    fn prepare(self: *SkipRecordCache, index: i64, rec: *SkipRecord) bool {
        if (@mod(index, self.cache_unit) != 0) {
            return false;
        }

        const slot_idx = @divTrunc(index, self.cache_unit);
        if (slot_idx >= @as(i64, @intCast(self.records.len))) {
            return false;
        }

        const blob = self.records[@intCast(slot_idx)].load(.acquire);
        if (blob == null) {
            return false;
        }

        const status = rec.deserialize(index, blob.?.data);
        return status.isOk();
    }

    fn add(self: *SkipRecordCache, rec: *SkipRecord) void {
        if (@mod(rec.index, self.cache_unit) != 0) {
            return;
        }

        const slot_idx = @divTrunc(rec.index, self.cache_unit);
        if (slot_idx >= @as(i64, @intCast(self.records.len))) {
            return;
        }

        const blob = self.allocator.create(CachedBlob) catch {
            return;
        };

        blob.data = rec.serialize(self.allocator) catch {
            self.allocator.destroy(blob);
            return;
        };

        const expected: ?*CachedBlob = null;
        const result = self.records[@intCast(slot_idx)].compareAndSwap(expected, blob, .acq_rel, .acquire);

        if (result != null) {
            self.allocator.free(blob.data);
            self.allocator.destroy(blob);
        }
    }
};

// ---------------------------------------------------------------------------
// SortEntry and SortSlot
// ---------------------------------------------------------------------------

const SortEntry = struct {
    key: []u8,
    value: []u8,
};

fn sortEntryCmp(_ctx: void, a: SortEntry, b: SortEntry) bool {
    _ = _ctx;
    return std.mem.order(u8, a.key, b.key) == .lt;
}

const SortSlot = struct {
    id: usize,
    key: []u8,
    value: []u8,
    flat_reader: ?*FlatRecordReader,
    flat_file: ?File,
    skip_record: ?*SkipRecord,
    offset: i64,
    end_offset: i64,
    allocator: std.mem.Allocator,
};

fn sortSlotLessThan(_ctx: void, a: *SortSlot, b: *SortSlot) std.math.Order {
    _ = _ctx;
    const cmp = std.mem.order(u8, a.key, b.key);
    if (cmp != .eq) return cmp;
    if (a.id < b.id) return .lt;
    if (a.id > b.id) return .gt;
    return .eq;
}

// ---------------------------------------------------------------------------
// RecordSorter (stub for Phase 6)
// ---------------------------------------------------------------------------

const RecordSorter = struct {
    base_path: []const u8,
    max_mem_size: i64,
    current_entries: std.ArrayListUnmanaged(SortEntry) = .empty,
    current_mem_size: i64,
    tmp_paths: std.ArrayListUnmanaged([]u8) = .empty,
    tmp_file_owners: std.ArrayListUnmanaged(File) = .empty,
    slots: std.ArrayListUnmanaged(SortSlot) = .empty,
    heap: std.PriorityQueue(*SortSlot, void, sortSlotLessThan) = .empty,
    finished: bool,
    tmp_file_counter: u32 = 0,
    allocator: std.mem.Allocator,

    fn init(base_path: []const u8, max_mem_size: i64, allocator: std.mem.Allocator) !*RecordSorter {
        const self = try allocator.create(RecordSorter);
        self.* = .{
            .base_path = base_path,
            .max_mem_size = max_mem_size,
            .current_mem_size = 0,
            .finished = false,
            .allocator = allocator,
        };
        return self;
    }

    fn deinit(self: *RecordSorter, io: std.Io) void {
        const allocator = self.allocator;

        for (self.current_entries.items) |entry| {
            allocator.free(entry.key);
            allocator.free(entry.value);
        }
        self.current_entries.deinit(allocator);

        for (self.slots.items) |slot| {
            allocator.free(slot.key);
            allocator.free(slot.value);
            if (slot.skip_record) |rec| {
                rec.deinit();
                allocator.destroy(rec);
            }
            if (slot.flat_reader) |reader| {
                reader.deinit();
                allocator.destroy(reader);
            }
        }
        self.slots.deinit(allocator);

        for (self.tmp_file_owners.items) |file| {
            _ = file.close(io);
        }
        self.tmp_file_owners.deinit(allocator);

        for (self.tmp_paths.items) |path| {
            _ = file_mod.removeFile(path);
            allocator.free(path);
        }
        self.tmp_paths.deinit(allocator);

        self.heap.deinit(self.allocator);
        allocator.destroy(self);
    }

    fn add(self: *RecordSorter, io: std.Io, key: []const u8, value: []const u8) !void {
        const key_dup = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_dup);

        const value_dup = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_dup);

        try self.current_entries.append(self.allocator, .{
            .key = key_dup,
            .value = value_dup,
        });

        self.current_mem_size += @as(i64, @intCast(key.len + value.len + REC_MEM_FOOT));

        if (self.current_mem_size >= self.max_mem_size) {
            try self.flush(io);
        }
    }

    fn flush(self: *RecordSorter, io: std.Io) !void {
        if (self.current_entries.items.len == 0) {
            return;
        }

        std.sort.heap(SortEntry, self.current_entries.items, {}, sortEntryCmp);

        var tmp_path_buf: [256]u8 = undefined;
        const tmp_path = try std.fmt.bufPrint(&tmp_path_buf, "{s}.tmp.sorter.{d}", .{ self.base_path, self.tmp_file_counter });
        self.tmp_file_counter += 1;

        const tmp_path_owned = try self.allocator.dupe(u8, tmp_path);
        errdefer self.allocator.free(tmp_path_owned);

        const std_file_ptr = try StdFile.create(self.allocator);
        const tmp_file = std_file_ptr.asFile();
        errdefer _ = tmp_file.close(io);

        const open_status = tmp_file.open(io, tmp_path_owned, true, .{ .truncate = true, .no_lock = true }); // process-private temp file
        if (!open_status.isOk()) {
            _ = tmp_file.close(io);
            self.allocator.destroy(std_file_ptr);
            self.allocator.free(tmp_path_owned);
            return error.OutOfMemory;
        }

        try self.tmp_paths.append(self.allocator, tmp_path_owned);
        try self.tmp_file_owners.append(self.allocator, tmp_file);

        for (self.current_entries.items) |entry| {
            var flat_key: FlatRecord = .{ .file = tmp_file, .allocator = self.allocator };
            const key_status = flat_key.write(io, entry.key, .normal);
            if (!key_status.isOk()) {
                return error.WriteFailed;
            }

            var flat_value: FlatRecord = .{ .file = tmp_file, .allocator = self.allocator };
            const value_status = flat_value.write(io, entry.value, .normal);
            if (!value_status.isOk()) {
                return error.WriteFailed;
            }
        }

        for (self.current_entries.items) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
        self.current_entries.clearRetainingCapacity();
        self.current_mem_size = 0;
    }

    fn addSkipRecord(self: *RecordSorter, io: std.Io, rec: *SkipRecord, record_base: i64) !void {
        // Store skip record source for merge; will be processed in finish()
        // Note: rec is a temporary stack object; we extract its data and file reference

        // Read first record to initialize the slot
        const meta_status = rec.readMetadataKey(io, record_base, 0);
        if (!meta_status.isOk()) {
            return;
        }

        const body_status = rec.readBody(io);
        if (!body_status.isOk()) {
            return;
        }

        // Create a new SkipRecord allocated on heap to persist beyond this function
        const new_rec = try self.allocator.create(SkipRecord);
        new_rec.* = rec.*;  // Copy all fields including file reference

        const slot = SortSlot{
            .id = self.slots.items.len,
            .key = try self.allocator.dupe(u8, rec.key_ptr),
            .value = try self.allocator.dupe(u8, rec.value_ptr orelse ""),
            .flat_reader = null,
            .flat_file = null,
            .skip_record = new_rec,
            .offset = record_base + @as(i64, @intCast(rec.whole_size)),
            .end_offset = rec.file.getSizeSimple(),
            .allocator = self.allocator,
        };

        try self.slots.append(self.allocator, slot);
    }

    fn finish(self: *RecordSorter, io: std.Io) !void {
        try self.flush(io);

        // Build the merge heap from all sources
        var id_counter: usize = 0;

        // Add skip record sources to heap
        for (self.slots.items) |*slot| {
            if (slot.skip_record != null) {
                slot.id = id_counter;
                id_counter += 1;
                try self.heap.push(self.allocator, slot);
            }
        }

        // Add flat file sources to heap
        for (self.tmp_paths.items, 0..) |_, i| {
            const tmp_file = self.tmp_file_owners.items[i];
            var reader = try FlatRecordReader.init(tmp_file, self.allocator, 4096);

            // Read first key record
            var first_key: []const u8 = undefined;
            var read_status = reader.read(io, &first_key, null);
            if (!read_status.isOk()) {
                reader.deinit();
                continue;
            }

            // Read first value record
            var first_value: []const u8 = undefined;
            read_status = reader.read(io, &first_value, null);
            if (!read_status.isOk()) {
                reader.deinit();
                self.allocator.free(first_key);
                continue;
            }

            const slot = SortSlot{
                .id = id_counter,
                .key = try self.allocator.dupe(u8, first_key),
                .value = try self.allocator.dupe(u8, first_value),
                .flat_reader = try self.allocator.create(FlatRecordReader),
                .flat_file = null,
                .skip_record = null,
                .offset = 0,
                .end_offset = 0,
                .allocator = self.allocator,
            };
            slot.flat_reader.?.* = reader;

            try self.slots.append(self.allocator, slot);
            try self.heap.push(self.allocator, &self.slots.items[self.slots.items.len - 1]);

            id_counter += 1;
            self.allocator.free(first_key);
            self.allocator.free(first_value);
        }

        self.finished = true;
    }

    fn get(self: *RecordSorter, io: std.Io, key_out: *[]u8, value_out: *[]u8) !void {
        if (self.heap.count() == 0) {
            return error.NotFound;
        }

        const slot = self.heap.pop().?;
        // Transfer ownership of current key/value to callers before overwriting slot fields.
        key_out.* = slot.key;
        value_out.* = slot.value;

        var found_next = false;

        if (slot.flat_reader) |reader| {
            var next_data: []const u8 = undefined;
            const read_status = reader.read(io, &next_data, null);
            if (read_status.isOk()) {
                const new_key = try self.allocator.dupe(u8, next_data);
                var value_data: []const u8 = undefined;
                const value_status = reader.read(io, &value_data, null);
                if (value_status.isOk()) {
                    // Overwrite slot fields in-place, then push the same pointer back.
                    slot.key = new_key;
                    slot.value = try self.allocator.dupe(u8, value_data);
                    found_next = true;
                } else {
                    self.allocator.free(new_key);
                }
            }
        } else if (slot.skip_record) |rec| {
            if (slot.offset < slot.end_offset) {
                // Read the next record in-place. rec IS slot.skip_record — mutated in-place.
                const meta_status = rec.readMetadataKey(io, slot.offset, rec.index + 1);
                if (meta_status.isOk()) {
                    const body_status = rec.readBody(io);
                    if (body_status.isOk()) {
                        const new_key = try self.allocator.dupe(u8, rec.key_ptr);
                        const new_value = if (rec.value_ptr) |vp|
                            try self.allocator.dupe(u8, vp)
                        else
                            try self.allocator.dupe(u8, "");
                        slot.key = new_key;
                        slot.value = new_value;
                        slot.offset += @as(i64, @intCast(rec.whole_size));
                        found_next = true;
                    }
                }
            }
        }

        if (found_next) {
            // Push the same pointer we removed — no dangling stack address.
            try self.heap.push(self.allocator, slot);
        } else {
            // Ownership of key/value transferred to caller; zero lengths so deinit
            // calls allocator.free on a zero-length slice (which is a safe no-op).
            slot.key = slot.key[0..0];
            slot.value = slot.value[0..0];
        }
    }

    fn isUpdated(self: *RecordSorter) bool {
        return self.current_entries.items.len > 0 or self.tmp_paths.items.len > 0;
    }
};

// ---------------------------------------------------------------------------
// SkipDBMIteratorImpl (stub for Phase 10)
// ---------------------------------------------------------------------------

const SkipDBMIteratorImpl = struct {
    dbm: ?*SkipDBMImpl,
    record_offset: i64,
    record_index: i64,
    record_size: usize,
    allocator: std.mem.Allocator,

    fn init(dbm: *SkipDBMImpl, io: std.Io, allocator: std.mem.Allocator) !*SkipDBMIteratorImpl {
        const self = try allocator.create(SkipDBMIteratorImpl);
        self.* = .{
            .dbm = dbm,
            .record_offset = -1,
            .record_index = -1,
            .record_size = 0,
            .allocator = allocator,
        };

        dbm.mutex.lockUncancelable(io);
        dbm.iterators.append(allocator, self) catch {
            dbm.mutex.unlock(io);
            return error.OutOfMemory;
        };
        dbm.mutex.unlock(io);

        return self;
    }

    fn deinit(self: *SkipDBMIteratorImpl, io: std.Io) void {
        if (self.dbm) |dbm| {
            dbm.mutex.lockUncancelable(io);
            defer dbm.mutex.unlock(io);
            for (dbm.iterators.items, 0..) |iter, i| {
                if (iter == self) {
                    _ = dbm.iterators.orderedRemove(i);
                    break;
                }
            }
        }

        self.allocator.destroy(self);
    }

    // C++ SkipDBMIteratorImpl methods take shared_lock on the outer mutex.
    // In Zig, the lock is provided by the caller: either by SkipDBM.Iterator public
    // wrappers (for direct user access) or by processFirst/processEach
    // (which hold the outer mutex before calling these methods). Do not add locking
    // here — it would deadlock the process* methods.
    fn first(self: *SkipDBMIteratorImpl) Status {
        if (self.dbm == null or !self.dbm.?.open) {
            return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        }

        self.record_offset = METADATA_SIZE;
        self.record_index = 0;
        self.record_size = 0;

        const file_size = self.dbm.?.file.getSizeSimple();
        if (file_size > METADATA_SIZE) {
            return Status.init(.SUCCESS);
        } else {
            return Status.init(.NOT_FOUND_ERROR);
        }
    }

    fn last(self: *SkipDBMIteratorImpl, io: std.Io) Status {
        if (self.dbm == null or !self.dbm.?.open) {
            return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        }

        if (self.dbm.?.num_records == 0) {
            return Status.init(.NOT_FOUND_ERROR);
        }

        var rec = SkipRecord.init(self.dbm.?.file, self.dbm.?.offset_width, self.dbm.?.step_unit, self.dbm.?.max_level, self.allocator);
        defer rec.deinit();

        const status = rec.searchByIndex(io, METADATA_SIZE, self.dbm.?.cache, self.dbm.?.num_records - 1);
        if (!status.isOk()) {
            return status;
        }

        self.record_offset = rec.offset;
        self.record_index = self.dbm.?.num_records - 1;
        self.record_size = 0;

        return Status.init(.SUCCESS);
    }

    fn jump(self: *SkipDBMIteratorImpl, io: std.Io, key: []const u8) Status {
        if (self.dbm == null or !self.dbm.?.open) {
            return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        }

        var rec = SkipRecord.init(self.dbm.?.file, self.dbm.?.offset_width, self.dbm.?.step_unit, self.dbm.?.max_level, self.allocator);
        defer rec.deinit();

        const status = rec.search(io, METADATA_SIZE, self.dbm.?.cache, key, true);
        if (status.isOk()) {
            self.record_offset = rec.offset;
            self.record_index = rec.index;
            self.record_size = 0;
            return Status.init(.SUCCESS);
        }

        self.record_offset = -1;
        self.record_index = -1;
        return status;
    }

    fn jumpLower(self: *SkipDBMIteratorImpl, io: std.Io, key: []const u8, inclusive: bool) Status {
        if (self.dbm == null or !self.dbm.?.open) {
            return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        }

        var rec = SkipRecord.init(self.dbm.?.file, self.dbm.?.offset_width, self.dbm.?.step_unit, self.dbm.?.max_level, self.allocator);
        defer rec.deinit();

        const status = rec.search(io, METADATA_SIZE, self.dbm.?.cache, key, true);
        if (!status.isOk()) {
            return status;
        }

        // Always set iterator position to the found record first.
        // previous() uses self.record_index to step back one position.
        self.record_offset = rec.offset;
        self.record_index = rec.index;
        self.record_size = 0;

        if (inclusive and std.mem.eql(u8, rec.key_ptr, key)) {
            return Status.init(.SUCCESS);
        }

        return self.previous(io);
    }

    fn jumpUpper(self: *SkipDBMIteratorImpl, io: std.Io, key: []const u8, inclusive: bool) Status {
        if (self.dbm == null or !self.dbm.?.open) {
            return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        }

        var rec = SkipRecord.init(self.dbm.?.file, self.dbm.?.offset_width, self.dbm.?.step_unit, self.dbm.?.max_level, self.allocator);
        defer rec.deinit();

        const status = rec.search(io, METADATA_SIZE, self.dbm.?.cache, key, true);
        if (!status.isOk()) {
            return status;
        }

        // Always set iterator position to the found record first.
        // next() uses self.record_offset / self.record_index to advance.
        self.record_offset = rec.offset;
        self.record_index = rec.index;
        self.record_size = 0;

        if (!inclusive and std.mem.eql(u8, rec.key_ptr, key)) {
            return self.next(io);
        }

        return Status.init(.SUCCESS);
    }

    fn next(self: *SkipDBMIteratorImpl, io: std.Io) Status {
        if (self.record_offset < 0 or self.record_index < 0) {
            return Status.init(.NOT_FOUND_ERROR);
        }

        if (self.record_size == 0) {
            var rec = SkipRecord.init(self.dbm.?.file, self.dbm.?.offset_width, self.dbm.?.step_unit, self.dbm.?.max_level, self.allocator);
            defer rec.deinit();

            const status = rec.readMetadataKey(io, self.record_offset, self.record_index);
            if (!status.isOk()) {
                return status;
            }

            self.record_size = rec.whole_size;
        }

        self.record_offset += @as(i64, @intCast(self.record_size));
        self.record_index += 1;
        self.record_size = 0;

        if (self.record_offset >= self.dbm.?.file.getSizeSimple()) {
            self.record_offset = -1;
            self.record_index = -1;
            return Status.init(.NOT_FOUND_ERROR);
        }

        return Status.init(.SUCCESS);
    }

    fn previous(self: *SkipDBMIteratorImpl, io: std.Io) Status {
        if (self.record_index <= 0) {
            self.record_offset = -1;
            self.record_index = -1;
            return Status.init(.NOT_FOUND_ERROR);
        }

        var rec = SkipRecord.init(self.dbm.?.file, self.dbm.?.offset_width, self.dbm.?.step_unit, self.dbm.?.max_level, self.allocator);
        defer rec.deinit();

        const status = rec.searchByIndex(io, METADATA_SIZE, self.dbm.?.cache, self.record_index - 1);
        if (!status.isOk()) {
            return status;
        }

        self.record_offset = rec.offset;
        self.record_index = self.record_index - 1;
        self.record_size = 0;

        return Status.init(.SUCCESS);
    }

    fn get(self: *SkipDBMIteratorImpl, io: std.Io, key_out: ?*std.ArrayList(u8), value_out: ?*std.ArrayList(u8)) Status {
        if (self.record_offset < 0 or self.record_index < 0) {
            return Status.init(.NOT_FOUND_ERROR);
        }

        var rec = SkipRecord.init(self.dbm.?.file, self.dbm.?.offset_width, self.dbm.?.step_unit, self.dbm.?.max_level, self.allocator);
        defer rec.deinit();

        var status = rec.readMetadataKey(io, self.record_offset, self.record_index);
        if (!status.isOk()) {
            return status;
        }

        status = rec.readBody(io);
        if (!status.isOk()) {
            return status;
        }

        if (key_out) |k| {
            k.clearRetainingCapacity();
            k.appendSlice(self.allocator, rec.key_ptr) catch {
                return Status.init(.SYSTEM_ERROR);
            };
        }

        if (value_out) |v| {
            v.clearRetainingCapacity();
            if (rec.value_ptr) |vp| {
                v.appendSlice(self.allocator, vp) catch {
                    return Status.init(.SYSTEM_ERROR);
                };
            }
        }

        return Status.init(.SUCCESS);
    }

    fn process(self: *SkipDBMIteratorImpl, io: std.Io, comptime P: type, proc: *P, writable: bool) Status {
        const dbm = self.dbm.?;
        if (self.record_offset < 0 or self.record_offset >= dbm.file.getSizeSimple()) {
            return Status.init(.NOT_FOUND_ERROR);
        }

        var rec = SkipRecord.init(dbm.file, dbm.offset_width, dbm.step_unit, dbm.max_level, self.allocator);
        defer rec.deinit();

        var status = rec.readMetadataKey(io, self.record_offset, self.record_index);
        if (!status.isOk()) return status;

        if (rec.value_ptr == null) {
            status = rec.readBody(io);
            if (!status.isOk()) return status;
        }

        self.record_size = rec.whole_size;

        const key = rec.key_ptr;
        const value = rec.value_ptr orelse &[_]u8{};
        const action = proc.processFull(key, value);

        if (writable) {
            switch (action) {
                .noop => {},
                .set => |new_value| {
                    const update_status = updateRecordImpl(dbm, io, key, new_value);
                    if (!update_status.isOk()) return update_status;
                    if (dbm.update_logger) |ul| _ = ul.writeSet(key, new_value);
                },
                .remove => {
                    const update_status = updateRecordImpl(dbm, io, key, REMOVING_VALUE);
                    if (!update_status.isOk()) return update_status;
                    if (dbm.update_logger) |ul| _ = ul.writeRemove(key);
                    self.record_offset += @as(i64, @intCast(self.record_size));
                    self.record_index += 1;
                    self.record_size = 0;
                },
            }
        }

        return Status.init(.SUCCESS);
    }

    fn iterSet(self: *SkipDBMIteratorImpl, io: std.Io, value: []const u8, old_key_out: ?*std.ArrayList(u8), old_value_out: ?*std.ArrayList(u8)) Status {
        const dbm = self.dbm.?;
        if (self.record_offset < 0 or self.record_offset >= dbm.file.getSizeSimple()) {
            return Status.init(.NOT_FOUND_ERROR);
        }

        var rec = SkipRecord.init(dbm.file, dbm.offset_width, dbm.step_unit, dbm.max_level, self.allocator);
        defer rec.deinit();

        var status = rec.readMetadataKey(io, self.record_offset, self.record_index);
        if (!status.isOk()) return status;

        if (old_key_out != null or old_value_out != null) {
            status = rec.readBody(io);
            if (!status.isOk()) return status;
        }

        if (old_key_out) |k| {
            k.clearRetainingCapacity();
            k.appendSlice(self.allocator, rec.key_ptr) catch return Status.init(.SYSTEM_ERROR);
        }
        if (old_value_out) |v| {
            v.clearRetainingCapacity();
            if (rec.value_ptr) |vp| v.appendSlice(self.allocator, vp) catch return Status.init(.SYSTEM_ERROR);
        }

        const key = if (rec.key_ptr.len > 0) rec.key_ptr else blk: {
            status = rec.readBody(io);
            if (!status.isOk()) return status;
            break :blk rec.key_ptr;
        };

        const update_status = updateRecordImpl(dbm, io, key, value);
        if (!update_status.isOk()) return update_status;
        if (dbm.update_logger) |ul| _ = ul.writeSet(key, value);
        return Status.init(.SUCCESS);
    }

    fn iterRemove(self: *SkipDBMIteratorImpl, io: std.Io, old_key_out: ?*std.ArrayList(u8), old_value_out: ?*std.ArrayList(u8)) Status {
        const dbm = self.dbm.?;
        if (self.record_offset < 0 or self.record_offset >= dbm.file.getSizeSimple()) {
            return Status.init(.NOT_FOUND_ERROR);
        }

        var rec = SkipRecord.init(dbm.file, dbm.offset_width, dbm.step_unit, dbm.max_level, self.allocator);
        defer rec.deinit();

        var status = rec.readMetadataKey(io, self.record_offset, self.record_index);
        if (!status.isOk()) return status;

        if (old_key_out != null or old_value_out != null) {
            status = rec.readBody(io);
            if (!status.isOk()) return status;
        }

        if (old_key_out) |k| {
            k.clearRetainingCapacity();
            k.appendSlice(self.allocator, rec.key_ptr) catch return Status.init(.SYSTEM_ERROR);
        }
        if (old_value_out) |v| {
            v.clearRetainingCapacity();
            if (rec.value_ptr) |vp| v.appendSlice(self.allocator, vp) catch return Status.init(.SYSTEM_ERROR);
        }

        const key = if (rec.key_ptr.len > 0) rec.key_ptr else blk: {
            status = rec.readBody(io);
            if (!status.isOk()) return status;
            break :blk rec.key_ptr;
        };

        self.record_size = rec.whole_size;

        const update_status = updateRecordImpl(dbm, io, key, REMOVING_VALUE);
        if (!update_status.isOk()) return update_status;
        if (dbm.update_logger) |ul| _ = ul.writeRemove(key);
        self.record_offset += @as(i64, @intCast(self.record_size));
        self.record_index += 1;
        self.record_size = 0;
        return Status.init(.SUCCESS);
    }
};

// ---------------------------------------------------------------------------
// SkipDBMImpl (stub for Phase 7)
// ---------------------------------------------------------------------------

const SkipDBMImpl = struct {
    open: bool,
    writable: bool,
    healthy: bool,
    auto_restored: bool,
    updated: bool,
    removed: bool,
    dirty_close: bool = false,
    path: std.ArrayListUnmanaged(u8) = .empty,
    cyclic_magic: u8,
    pkg_major_version: u8,
    pkg_minor_version: u8,
    offset_width: u8,
    step_unit: u8,
    max_level: u8,
    closure_flags: u8,
    num_records: i64,
    eff_data_size: i64,
    file_size: i64,
    timestamp: i64,
    db_type: u32,
    opaque_metadata: [OPAQUE_METADATA_SIZE]u8,
    file: File,
    sorted_file: ?File,
    sorted_path: std.ArrayListUnmanaged(u8) = .empty,
    sorter: ?*RecordSorter,
    past_offsets: [MAX_MAX_LEVEL]i64,
    insert_in_order: bool,
    sort_mem_size: i64,
    max_cached_records: i32,
    cache: ?*SkipRecordCache,
    record_index: i64,
    old_num_records: i64,
    old_eff_data_size: i64,
    iterators: std.ArrayListUnmanaged(*SkipDBMIteratorImpl) = .empty,
    mutex: std.Io.RwLock = .init,
    update_logger: ?*UpdateLogger,
    allocator: std.mem.Allocator,
};

// ---------------------------------------------------------------------------
// SkipDBMImpl Helper Functions (Phases 7-9)
// ---------------------------------------------------------------------------

fn openAdvancedImpl(impl: *SkipDBMImpl, io: std.Io, path: []const u8, writable: bool, options: OpenOptions, params: TuningParameters) Status {
    impl.mutex.lockUncancelable(io);
    defer impl.mutex.unlock(io);

    if (impl.open) {
        return Status.initMsg(.PRECONDITION_ERROR, "already open");
    }

    impl.offset_width = @intCast(std.math.clamp(params.offset_width, @as(i32, MIN_OFFSET_WIDTH), @as(i32, MAX_OFFSET_WIDTH)));
    impl.step_unit = @intCast(std.math.clamp(params.step_unit, @as(i32, MIN_STEP_UNIT), @as(i32, MAX_STEP_UNIT)));
    impl.max_level = @intCast(std.math.clamp(params.max_level, @as(i32, MIN_MAX_LEVEL), @as(i32, MAX_MAX_LEVEL)));
    impl.sort_mem_size = std.math.clamp(params.sort_mem_size, MIN_SORT_MEM_SIZE, MAX_SORT_MEM_SIZE);
    impl.max_cached_records = std.math.clamp(params.max_cached_records, MIN_MAX_CACHED_RECORDS, MAX_MAX_CACHED_RECORDS);
    impl.insert_in_order = params.insert_in_order;

    impl.path.clearRetainingCapacity();
    impl.path.appendSlice(impl.allocator, path) catch {
        return Status.init(.SYSTEM_ERROR);
    };

    const open_status = impl.file.open(io, path, writable, options);
    if (!open_status.isOk()) {
        return open_status;
    }
    // From this point forward, all error return sites must explicitly close the file.

    const file_size = impl.file.getSizeSimple();

    if (file_size == 0 and writable) {
        impl.pkg_major_version = PKG_MAJOR_VERSION;
        impl.pkg_minor_version = PKG_MINOR_VERSION;
        impl.closure_flags = CLOSURE_FLAG_CLOSE;
        impl.file_size = METADATA_SIZE;
        impl.timestamp = currentTimeMicros(io);
        impl.num_records = 0;
        impl.eff_data_size = 0;

        const truncate_status = impl.file.truncate(io, @as(i64, METADATA_SIZE));
        if (!truncate_status.isOk()) {
            _ = impl.file.close(io);
            return truncate_status;
        }

        const save_status = saveMetadata(impl, io, impl.file, true);
        if (!save_status.isOk()) {
            _ = impl.file.close(io);
            return save_status;
        }
    }

    const load_status = loadMetadata(impl, io, impl.file);
    if (!load_status.isOk()) {
        _ = impl.file.close(io);
        return load_status;
    }

    const is_dirty = impl.dirty_close;
    if (is_dirty) {
        impl.file_size = std.math.maxInt(i64);
    }

    impl.healthy = (impl.closure_flags & CLOSURE_FLAG_CLOSE) != 0;
    const actual_size = impl.file.getSizeSimple();

    if (actual_size > impl.file_size) {
        impl.healthy = false;
    } else if (actual_size < impl.file_size) {
        if (actual_size >= 0) {
            const padding_start = actual_size;
            const padding_len = impl.file_size - actual_size;
            if (padding_len > 1048576) {
                impl.healthy = false;
            } else {
                var padding_buf: [1048576]u8 = undefined;
                const read_status = impl.file.read(io, padding_start, padding_buf[0..@as(usize, @intCast(padding_len))]);
                if (read_status.isOk()) {
                    for (padding_buf[0..@as(usize, @intCast(padding_len))]) |byte| {
                        if (byte != 0) {
                            impl.healthy = false;
                            break;
                        }
                    }
                }
            }

            if (impl.healthy) {
                const trunc_status = impl.file.truncate(io, actual_size);
                if (!trunc_status.isOk()) {
                    impl.healthy = false;
                }
            }
        }
    }

    if (!impl.healthy and writable and params.restore_mode != @intFromEnum(RestoreMode.restore_read_only) and params.restore_mode != @intFromEnum(RestoreMode.restore_noop)) {
        var restore_path_buf: [512]u8 = undefined;
        const restore_path = std.fmt.bufPrint(&restore_path_buf, "{s}.tmp.restore", .{path}) catch {
            _ = impl.file.close(io);
            return Status.init(.SYSTEM_ERROR);
        };

        const restore_status = restoreDatabaseImpl( impl.allocator, io,path, restore_path);
        if (restore_status.isOk()) {
            const rename_status = file_mod.renameFile(restore_path, path);
            if (rename_status.isOk()) {
                _ = impl.file.close(io);
                const reopen_status = impl.file.open(io, path, writable, options);
                if (reopen_status.isOk()) {
                    const reload_status = loadMetadata(impl, io, impl.file);
                    if (reload_status.isOk()) {
                        impl.healthy = true;
                        impl.auto_restored = true;
                    }
                }
            }
        }
    }

    if (impl.healthy and writable) {
        const save_status = saveMetadata(impl, io, impl.file, false);
        if (!save_status.isOk()) {
            impl.healthy = false;
        }
    }

    const prep_status = prepareStorageImpl(impl, io);
    if (!prep_status.isOk()) {
        _ = impl.file.close(io);
        return prep_status;
    }

    if (impl.max_cached_records > 0) {
        impl.cache = SkipRecordCache.init(impl.step_unit, impl.max_cached_records, impl.num_records, impl.allocator) catch null;
    }

    impl.open = true;
    impl.writable = writable;

    return Status.init(.SUCCESS);
}

fn closeImplImpl(impl: *SkipDBMImpl, io: std.Io) Status {
    impl.mutex.lockUncancelable(io);
    defer impl.mutex.unlock(io);

    if (!impl.open) {
        return Status.initMsg(.PRECONDITION_ERROR, "not opened");
    }

    cancelIteratorsImpl(impl);

    if (impl.writable and impl.healthy) {
        if (impl.updated) {
            const finish_status = finishStorageImpl(impl, io, null);
            if (!finish_status.isOk()) {
                impl.healthy = false;
            }
        } else {
            discardStorageImpl(impl, io);
            impl.file_size = impl.file.getSizeSimple();
            impl.timestamp = currentTimeMicros(io);
            const save_status = saveMetadata(impl, io, impl.file, true);
            if (!save_status.isOk()) {
                impl.healthy = false;
            }
        }
    }

    _ = impl.file.close(io);

    impl.open = false;
    impl.writable = false;
    impl.updated = false;
    impl.removed = false;

    return Status.init(.SUCCESS);
}

fn prepareStorageImpl(impl: *SkipDBMImpl, io: std.Io) Status {
    var sorter_path_buf: [512]u8 = undefined;
    const sorter_path = std.fmt.bufPrint(&sorter_path_buf, "{s}.tmp.sorter_base", .{impl.path.items}) catch {
        return Status.init(.SYSTEM_ERROR);
    };

    impl.sorter = RecordSorter.init(sorter_path, impl.sort_mem_size, impl.allocator) catch {
        return Status.init(.SYSTEM_ERROR);
    };

    if (impl.insert_in_order) {
        var sorted_path_buf: [512]u8 = undefined;
        const sorted_path = std.fmt.bufPrint(&sorted_path_buf, "{s}.tmp.sorted", .{impl.path.items}) catch {
            return Status.init(.SYSTEM_ERROR);
        };

        impl.sorted_path.clearRetainingCapacity();
        impl.sorted_path.appendSlice(impl.allocator, sorted_path) catch {
            return Status.init(.SYSTEM_ERROR);
        };

        const std_file_ptr = StdFile.create(impl.allocator) catch {
            return Status.init(.SYSTEM_ERROR);
        };

        const sorted_file = std_file_ptr.asFile();
        const open_status = sorted_file.open(io, impl.sorted_path.items, true, .{ .truncate = true, .no_lock = true }); // process-private auxiliary sort file
        if (!open_status.isOk()) {
            _ = sorted_file.close(io);
            impl.allocator.destroy(std_file_ptr);
            return Status.init(.SYSTEM_ERROR);
        }

        impl.sorted_file = sorted_file;

        const trunc_status = impl.sorted_file.?.truncate(io, METADATA_SIZE);
        if (!trunc_status.isOk()) {
            return Status.init(.SYSTEM_ERROR);
        }

        for (0..MAX_MAX_LEVEL) |i| {
            impl.past_offsets[i] = 0;
        }
        impl.record_index = 0;
    }

    impl.old_num_records = impl.num_records;
    impl.old_eff_data_size = impl.eff_data_size;

    return Status.init(.SUCCESS);
}

fn discardStorageImpl(impl: *SkipDBMImpl, io: std.Io) void {
    if (impl.sorted_file) |file| {
        _ = file.close(io);
        _ = file_mod.removeFile(impl.sorted_path.items);
        file.deinit(impl.allocator);
        impl.sorted_file = null;
    }

    if (impl.sorter) |sorter| {
        sorter.deinit(io);
        impl.sorter = null;
    }

    impl.num_records = impl.old_num_records;
    impl.eff_data_size = impl.old_eff_data_size;
    impl.updated = false;
    impl.removed = false;
}

fn finishStorageImpl(impl: *SkipDBMImpl, io: std.Io, reducer: ?ReducerType) Status {
    // Build merged_path = path + ".tmp.merged"
    var merged_path_buf: [512]u8 = undefined;
    const merged_path = std.fmt.bufPrint(&merged_path_buf, "{s}.tmp.merged", .{impl.path.items}) catch {
        return Status.init(.SYSTEM_ERROR);
    };

    const sorted_path_items = impl.sorted_path.items;

    // Fast path: no deletes, no reducer, sorted_file exists, main file is empty, sorter is empty
    if (reducer == null and !impl.removed and impl.sorted_file != null and
        impl.file.getSizeSimple() == METADATA_SIZE and !impl.sorter.?.isUpdated()) {
        impl.sorted_file.?.deinit(impl.allocator);
        impl.sorted_file = null;

        const rename_status = file_mod.renameFile(sorted_path_items, impl.path.items);
        if (!rename_status.isOk()) {
            return rename_status;
        }

        // Close the empty main file before reopening (it now points to the renamed sorted_file).
        _ = impl.file.close(io);

        // Reopen main file. Use no_lock because sorted_file still holds LOCK_EX on this
        // inode (it was renamed here but not yet closed); relocking would deadlock.
        const reopen_status = impl.file.open(io, impl.path.items, true, .{ .no_lock = true });
        if (!reopen_status.isOk()) {
            return reopen_status;
        }

        // Update file_size to the actual size of the renamed sorted_file.
        impl.file_size = impl.file.getSizeSimple();
        impl.timestamp = currentTimeMicros(io);

        const meta_status = saveMetadata(impl, io, impl.file, true);
        if (!meta_status.isOk()) {
            return meta_status;
        }

        // Free old sorter before recreating for the next write cycle.
        if (impl.sorter) |s| { s.deinit(io); impl.sorter = null; }
        _ = prepareStorageImpl(impl, io);
        return Status.init(.SUCCESS);
    }

    // Add existing file to sorter (if non-empty)
    if (impl.file.getSizeSimple() > METADATA_SIZE) {
        var src_rec = SkipRecord.init(impl.file, impl.offset_width, impl.step_unit, impl.max_level, impl.allocator);
        impl.sorter.?.addSkipRecord(io, &src_rec, METADATA_SIZE) catch {
            return Status.init(.SYSTEM_ERROR);
        };
    }

    // Add sorted_file to sorter (if exists and non-empty)
    if (impl.sorted_file != null and impl.sorted_path.items.len > 0) {
        if (impl.sorted_file.?.getSizeSimple() > METADATA_SIZE) {
            var src_rec = SkipRecord.init(impl.sorted_file.?, impl.offset_width, impl.step_unit, impl.max_level, impl.allocator);
            impl.sorter.?.addSkipRecord(io, &src_rec, METADATA_SIZE) catch {
                return Status.init(.SYSTEM_ERROR);
            };
        }
    }

    // Call sorter.finish() to build merge heap
    impl.sorter.?.finish(io) catch {
        return Status.init(.SYSTEM_ERROR);
    };

    // Create and open merged_file
    const merged_file_ptr = StdFile.create(impl.allocator) catch {
        return Status.init(.SYSTEM_ERROR);
    };
    var merged_file = merged_file_ptr.asFile();
    defer merged_file.deinit(impl.allocator);

    const merged_open_status = merged_file.open(io, merged_path, true, .{ .truncate = true, .no_lock = true }); // process-private merge staging file
    if (!merged_open_status.isOk()) {
        return merged_open_status;
    }
    defer _ = merged_file.close(io);

    // Truncate merged_file to METADATA_SIZE
    const truncate_status = merged_file.truncate(io, METADATA_SIZE);
    if (!truncate_status.isOk()) {
        return truncate_status;
    }

    // Reset write state
    impl.num_records = 0;
    impl.eff_data_size = 0;
    impl.record_index = 0;
    @memset(&impl.past_offsets, 0);

    // Merge loop (apply reducer if needed)
    var current_key: ?[]u8 = null;
    var values: std.ArrayList([]u8) = .empty;
    defer {
        if (current_key) |k| impl.allocator.free(k);
        for (values.items) |v| impl.allocator.free(v);
        values.deinit(impl.allocator);
    }

    while (true) {
        var key: []u8 = undefined;
        var value: []u8 = undefined;

        // Try to get next record from sorter
        impl.sorter.?.get(io, &key, &value) catch {
            // No more records; apply final reducer if needed
            if (current_key != null and values.items.len > 0) {
                if (reducer != null) {
                    const reduced = reducer.?(current_key.?, values.items, impl.allocator) catch {
                        return Status.init(.SYSTEM_ERROR);
                    };
                    defer {
                        for (reduced) |v| impl.allocator.free(v);
                        impl.allocator.free(reduced);
                    }

                    for (reduced) |rv| {
                        const write_status = writeRecordImpl(impl, io, merged_file, current_key.?, rv);
                        if (!write_status.isOk()) {
                            return write_status;
                        }
                    }
                } else {
                    // No explicit reducer: last write wins; skip if the last value is a tombstone.
                    if (values.items.len > 0) {
                        const last_val = values.items[values.items.len - 1];
                        if (!std.mem.eql(u8, last_val, REMOVING_VALUE)) {
                            const write_status = writeRecordImpl(impl, io, merged_file, current_key.?, last_val);
                            if (!write_status.isOk()) {
                                return write_status;
                            }
                        }
                    }
                }
            }
            break;
        };

        // Check if key changed
        if (current_key == null or std.mem.order(u8, current_key.?, key) != .eq) {
            // Key changed: apply reducer to accumulated values
            if (current_key != null and values.items.len > 0) {
                if (reducer != null) {
                    const reduced = reducer.?(current_key.?, values.items, impl.allocator) catch {
                        impl.allocator.free(key);
                        impl.allocator.free(value);
                        return Status.init(.SYSTEM_ERROR);
                    };
                    defer {
                        for (reduced) |v| impl.allocator.free(v);
                        impl.allocator.free(reduced);
                    }

                    for (reduced) |rv| {
                        const write_status = writeRecordImpl(impl, io, merged_file, current_key.?, rv);
                        if (!write_status.isOk()) {
                            impl.allocator.free(key);
                            impl.allocator.free(value);
                            return write_status;
                        }
                    }
                } else {
                    // No explicit reducer: last write wins; skip if the last value is a tombstone.
                    if (values.items.len > 0) {
                        const last_val = values.items[values.items.len - 1];
                        if (!std.mem.eql(u8, last_val, REMOVING_VALUE)) {
                            const write_status = writeRecordImpl(impl, io, merged_file, current_key.?, last_val);
                            if (!write_status.isOk()) {
                                impl.allocator.free(key);
                                impl.allocator.free(value);
                                return write_status;
                            }
                        }
                    }
                }
            }

            // Clear old values and start new accumulation
            for (values.items) |v| impl.allocator.free(v);
            values.clearRetainingCapacity();

            if (current_key != null) {
                impl.allocator.free(current_key.?);
            }
            current_key = impl.allocator.dupe(u8, key) catch {
                impl.allocator.free(key);
                return Status.init(.SYSTEM_ERROR);
            };
            impl.allocator.free(key);
        } else {
            impl.allocator.free(key);
        }

        // Add value to accumulator
        values.append(impl.allocator, value) catch {
            return Status.init(.SYSTEM_ERROR);
        };
    }

    // Save metadata to merged_file
    impl.file_size = merged_file.getSizeSimple();
    impl.timestamp = currentTimeMicros(io);
    const meta_status = saveMetadata(impl, io, merged_file, true);
    if (!meta_status.isOk()) {
        return meta_status;
    }

    // Close and free sorted_file if exists
    if (impl.sorted_file != null) {
        impl.sorted_file.?.deinit(impl.allocator);
        impl.sorted_file = null;
    }

    // Close the main file before renaming over it and reopening.
    _ = impl.file.close(io);

    // Rename merged_file → main file
    const rename_status = file_mod.renameFile(merged_path, impl.path.items);
    if (!rename_status.isOk()) {
        return rename_status;
    }

    // Remove sorted_path if exists
    if (sorted_path_items.len > 0) {
        _ = file_mod.removeFile(sorted_path_items);
    }

    // Reopen main file. Use no_lock: the merge temp file still holds LOCK_EX on
    // the renamed inode (not yet closed); relocking would deadlock.
    const reopen_status = impl.file.open(io, impl.path.items, true, .{ .no_lock = true });
    if (!reopen_status.isOk()) {
        return reopen_status;
    }

    // Free old sorter before rebuilding for the next write cycle.
    if (impl.sorter) |s| { s.deinit(io); impl.sorter = null; }
    _ = prepareStorageImpl(impl, io);

    impl.updated = false;
    impl.removed = false;

    return Status.init(.SUCCESS);
}

fn cancelIteratorsImpl(impl: *SkipDBMImpl) void {
    for (impl.iterators.items) |iter| {
        iter.record_offset = -1;
        iter.record_index = -1;
    }
}

fn restoreDatabaseImpl( allocator: std.mem.Allocator, io: std.Io,old_path: []const u8, new_path: []const u8) Status {
    const old_file_ptr = StdFile.create(allocator) catch {
        return Status.init(.SYSTEM_ERROR);
    };
    var old_file = old_file_ptr.asFile();
    defer old_file.deinit(allocator);

    const old_open_status = old_file.open(io, old_path, false, .{ .no_lock = true }); // restore source; may be broken/unlocked
    if (!old_open_status.isOk()) {
        return old_open_status;
    }
    defer _ = old_file.close(io);

    const new_file_ptr = StdFile.create(allocator) catch {
        return Status.init(.SYSTEM_ERROR);
    };
    var new_file = new_file_ptr.asFile();
    defer new_file.deinit(allocator);

    const new_open_status = new_file.open(io, new_path, true, .{ .truncate = true, .no_lock = true }); // fresh restore output file
    if (!new_open_status.isOk()) {
        _ = new_file.close(io);
        return new_open_status;
    }
    defer _ = new_file.close(io);

    // Copy metadata from old to new
    var metadata_buf: [METADATA_SIZE]u8 = undefined;
    const read_status = old_file.read(io, 0, &metadata_buf);
    if (!read_status.isOk()) return read_status;
    const write_status = new_file.write(io, 0, &metadata_buf);
    if (!write_status.isOk()) return write_status;

    // Read parameters from old file's metadata; fall back to defaults if broken.
    var scan_offset_width: u8 = DEFAULT_OFFSET_WIDTH;
    var scan_step_unit: u8 = DEFAULT_STEP_UNIT;
    var scan_max_level: u8 = DEFAULT_MAX_LEVEL;
    {
        // Use a temporary impl with safe defaults; loadMetadata only writes to it.
        // Fields with struct-level defaults (dirty_close, path, sorted_path, iterators, mutex)
        // are omitted here and take their default values automatically.
        var meta_impl = SkipDBMImpl{
            .open = false,
            .writable = false,
            .healthy = false,
            .auto_restored = false,
            .updated = false,
            .removed = false,
            .cyclic_magic = 0,
            .pkg_major_version = PKG_MAJOR_VERSION,
            .pkg_minor_version = PKG_MINOR_VERSION,
            .offset_width = DEFAULT_OFFSET_WIDTH,
            .step_unit = DEFAULT_STEP_UNIT,
            .max_level = DEFAULT_MAX_LEVEL,
            .closure_flags = 0,
            .num_records = 0,
            .eff_data_size = 0,
            .file_size = 0,
            .timestamp = 0,
            .db_type = 0,
            .opaque_metadata = [_]u8{0} ** OPAQUE_METADATA_SIZE,
            .file = file_mod.NullFile,
            .sorted_file = null,
            .sorter = null,
            .past_offsets = [_]i64{0} ** MAX_MAX_LEVEL,
            .insert_in_order = false,
            .sort_mem_size = DEFAULT_SORT_MEM_SIZE,
            .max_cached_records = DEFAULT_MAX_CACHED_RECORDS,
            .cache = null,
            .record_index = 0,
            .old_num_records = 0,
            .old_eff_data_size = 0,
            .update_logger = null,
            .allocator = allocator,
        };
        if (loadMetadata(&meta_impl, io, old_file).isOk()) {
            scan_offset_width = meta_impl.offset_width;
            scan_step_unit = meta_impl.step_unit;
            scan_max_level = meta_impl.max_level;
        }
    }

    // Scan old file for valid records; write to new
    var offset: i64 = METADATA_SIZE;
    var record_index: i64 = 0;
    var record_count: i64 = 0;
    var eff_data_size: i64 = 0;
    var past_offsets: [MAX_MAX_LEVEL]i64 = [_]i64{0} ** MAX_MAX_LEVEL;

    while (offset < old_file.getSizeSimple()) {
        var rec = SkipRecord.init(old_file, scan_offset_width, scan_step_unit, scan_max_level, allocator);
        defer rec.deinit();

        const read_status_key = rec.readMetadataKey(io, offset, record_index);
        if (!read_status_key.isOk()) break;

        const read_status_body = rec.readBody(io);
        if (!read_status_body.isOk()) break;

        // Write record to new file with new parameters
        rec.file = new_file;
        const write_status_rec = rec.write(io);
        if (!write_status_rec.isOk()) break;

        const update_status = rec.updatePastRecords(io, record_index, rec.offset, &past_offsets);
        if (!update_status.isOk()) break;

        record_count += 1;
        eff_data_size += @as(i64, @intCast(rec.key_size + rec.value_size));
        offset += @as(i64, @intCast(rec.whole_size));
        record_index += 1;
    }

    // Update metadata in new file
    var impl: SkipDBMImpl = undefined;
    impl.file = new_file;
    impl.num_records = record_count;
    impl.eff_data_size = eff_data_size;
    impl.file_size = new_file.getSizeSimple();
    impl.timestamp = currentTimeMicros(io);
    impl.offset_width = scan_offset_width;
    impl.step_unit = scan_step_unit;
    impl.max_level = scan_max_level;
    impl.cyclic_magic = 1;
    impl.pkg_major_version = PKG_MAJOR_VERSION;
    impl.pkg_minor_version = PKG_MINOR_VERSION;
    impl.closure_flags = CLOSURE_FLAG_CLOSE;
    impl.db_type = 0;
    @memset(&impl.opaque_metadata, 0);

    return saveMetadata(&impl, io, new_file, true);
}


fn getImpl(impl: *SkipDBMImpl, io: std.Io, key: []const u8, value_out: ?*std.ArrayList(u8)) Status {
    var rec = SkipRecord.init(impl.file, impl.offset_width, impl.step_unit, impl.max_level, impl.allocator);
    defer rec.deinit();

    const status = rec.search(io, METADATA_SIZE, impl.cache, key, false);
    if (!status.isOk()) {
        return status;
    }

    const body_status = rec.readBody(io);
    if (!body_status.isOk()) {
        return body_status;
    }

    if (value_out) |v| {
        v.clearRetainingCapacity();
        if (rec.value_ptr) |vp| {
            v.appendSlice(impl.allocator, vp) catch {
                return Status.init(.SYSTEM_ERROR);
            };
        }
    }

    return Status.init(.SUCCESS);
}

fn setImpl(impl: *SkipDBMImpl, io: std.Io, key: []const u8, value: []const u8, overwrite: bool) Status {
    var rec = SkipRecord.init(impl.file, impl.offset_width, impl.step_unit, impl.max_level, impl.allocator);
    defer rec.deinit();

    const search_status = rec.search(io, METADATA_SIZE, impl.cache, key, false);
    if (search_status.code == .SUCCESS) {
        if (!overwrite) {
            return Status.init(.DUPLICATION_ERROR);
        }
    } else if (search_status.code != .NOT_FOUND_ERROR) {
        return search_status;
    }

    const status = updateRecordImpl(impl, io, key, value);
    if (status.isOk()) {
        if (impl.update_logger) |ul| {
            _ = ul.writeSet(key, value);
        }
    }
    return status;
}

fn removeImpl(impl: *SkipDBMImpl, io: std.Io, key: []const u8) Status {
    const status = updateRecordImpl(impl, io, key, REMOVING_VALUE);
    if (status.isOk()) {
        if (impl.update_logger) |ul| {
            _ = ul.writeRemove(key);
        }
    }
    return status;
}

fn updateRecordImpl(impl: *SkipDBMImpl, io: std.Io, key: []const u8, value: []const u8) Status {
    const status = blk: {
        if (impl.sorter != null and !impl.insert_in_order) {
            impl.sorter.?.add(io, key, value) catch break :blk Status.init(.SYSTEM_ERROR);
            break :blk Status.init(.SUCCESS);
        } else if (impl.sorted_file != null) {
            break :blk writeRecordImpl(impl, io, impl.sorted_file.?, key, value);
        } else {
            break :blk writeRecordImpl(impl, io, impl.file, key, value);
        }
    };
    if (status.isOk()) {
        impl.updated = true;
        if (std.mem.eql(u8, value, REMOVING_VALUE)) impl.removed = true;
    }
    return status;
}

fn writeRecordImpl(impl: *SkipDBMImpl, io: std.Io, file: File, key: []const u8, value: []const u8) Status {
    var rec = SkipRecord.init(file, impl.offset_width, impl.step_unit, impl.max_level, impl.allocator);
    defer rec.deinit();

    rec.setData(impl.record_index, key, value);

    const write_status = rec.write(io);
    if (!write_status.isOk()) {
        return write_status;
    }

    const update_status = rec.updatePastRecords(io, impl.record_index, rec.offset, &impl.past_offsets);
    if (!update_status.isOk()) {
        return update_status;
    }

    impl.num_records += 1;
    impl.eff_data_size += @as(i64, @intCast(key.len + value.len));
    impl.record_index += 1;

    return Status.init(.SUCCESS);
}

// ---------------------------------------------------------------------------
// Processors for atomic and queue operations (compareExchange, increment, popFirst)
// ---------------------------------------------------------------------------

pub const ProcessorCompareExchange = struct {
    status: *Status,
    expected: dbm_mod.CompareExpected,
    desired: dbm_mod.CompareDesired,
    actual_out: ?*std.ArrayList(u8),
    found_out: ?*bool,
    allocator: std.mem.Allocator,

    pub fn processFull(self: @This(), key: []const u8, value: []const u8) RecordAction {
        _ = key;
        if (self.found_out) |f| f.* = true;
        if (self.actual_out) |ao| {
            ao.clearRetainingCapacity();
            ao.appendSlice(self.allocator, value) catch {
                self.status.* = Status.init(.SYSTEM_ERROR);
                return .noop;
            };
        }
        const expected_match = switch (self.expected) {
            .absent => false,
            .any => true,
            .exact => |exp| std.mem.eql(u8, value, exp),
        };
        if (!expected_match) {
            self.status.* = Status.init(.INFEASIBLE_ERROR);
            return .noop;
        }
        return switch (self.desired) {
            .remove => .remove,
            .noop => .noop,
            .set => |s| RecordAction{ .set = s },
        };
    }

    pub fn processEmpty(self: @This(), key: []const u8) RecordAction {
        _ = key;
        if (self.found_out) |f| f.* = false;
        if (self.actual_out) |ao| {
            ao.clearRetainingCapacity();
        }
        const expected_match = switch (self.expected) {
            .absent => true,
            .any => false,
            .exact => false,
        };
        if (!expected_match) {
            self.status.* = Status.init(.INFEASIBLE_ERROR);
            return .noop;
        }
        return switch (self.desired) {
            .remove => .noop,
            .noop => .noop,
            .set => |s| RecordAction{ .set = s },
        };
    }
};

pub const ProcessorIncrement = struct {
    status: *Status,
    delta: i64,
    current_out: ?*i64,
    initial: i64,

    pub fn processFull(self: @This(), key: []const u8, value: []const u8) RecordAction {
        _ = key;
        const current = @as(i64, @bitCast(str_util.strToIntBigEndian(value)));
        if (self.delta == lib_common.INT64MIN) {
            if (self.current_out) |c| c.* = current;
            return .noop;
        }
        const new_val = current +% self.delta;
        var buf: [8]u8 = undefined;
        const enc_val = str_util.intToStrBigEndian(@as(u64, @bitCast(new_val)), 8, &buf);
        if (self.current_out) |c| c.* = new_val;
        return RecordAction{ .set = enc_val };
    }

    pub fn processEmpty(self: @This(), key: []const u8) RecordAction {
        _ = key;
        if (self.delta == lib_common.INT64MIN) {
            if (self.current_out) |c| c.* = self.initial;
            return .noop;
        }
        const new_val = self.initial +% self.delta;
        var buf: [8]u8 = undefined;
        const enc_val = str_util.intToStrBigEndian(@as(u64, @bitCast(new_val)), 8, &buf);
        if (self.current_out) |c| c.* = new_val;
        return RecordAction{ .set = enc_val };
    }
};

pub const ProcessorPopFirst = struct {
    key_out: ?*std.ArrayList(u8),
    value_out: ?*std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn processFull(self: @This(), key: []const u8, value: []const u8) RecordAction {
        if (self.key_out) |ko| {
            ko.clearRetainingCapacity();
            ko.appendSlice(self.allocator, key) catch {};
        }
        if (self.value_out) |vo| {
            vo.clearRetainingCapacity();
            vo.appendSlice(self.allocator, value) catch {};
        }
        return .remove;
    }

    pub fn processEmpty(self: @This(), key: []const u8) RecordAction {
        _ = self;
        _ = key;
        return .noop;
    }
};

// ---------------------------------------------------------------------------
// Public SkipDBM Wrapper and Iterator (Phase 15 stubs)
// ---------------------------------------------------------------------------

pub const SkipDBM = struct {
    impl: *SkipDBMImpl,
    allocator: std.mem.Allocator,

    pub const Cursor = struct {
        impl: *SkipDBMIteratorImpl,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *Cursor, io: std.Io) void {
            // impl.deinit() acquires the exclusive mutex and uses orderedRemove,
            // matching C++ ~SkipDBMIteratorImpl lock_guard behavior.
            self.impl.deinit(io);
        }

        // C++ SkipDBMIteratorImpl methods take shared_lock. The lock is provided here at
        // the public Cursor boundary rather than inside impl methods, because the impl
        // methods are also called from processFirst/processEach which already
        // hold the outer mutex.
        pub fn first(self: *Cursor, io: std.Io) Status {
            if (self.impl.dbm) |dbm| { dbm.mutex.lockSharedUncancelable(io); defer dbm.mutex.unlockShared(io); return self.impl.first(); }
            return Status.initMsg(.PRECONDITION_ERROR, "orphaned cursor");
        }

        pub fn last(self: *Cursor, io: std.Io) Status {
            if (self.impl.dbm) |dbm| { dbm.mutex.lockSharedUncancelable(io); defer dbm.mutex.unlockShared(io); return self.impl.last(io); }
            return Status.initMsg(.PRECONDITION_ERROR, "orphaned cursor");
        }

        pub fn jump(self: *Cursor, io: std.Io, key: []const u8) Status {
            if (self.impl.dbm) |dbm| { dbm.mutex.lockSharedUncancelable(io); defer dbm.mutex.unlockShared(io); return self.impl.jump( io,key); }
            return Status.initMsg(.PRECONDITION_ERROR, "orphaned cursor");
        }

        pub fn jumpLower(self: *Cursor, io: std.Io, key: []const u8, inclusive: bool) Status {
            if (self.impl.dbm) |dbm| { dbm.mutex.lockSharedUncancelable(io); defer dbm.mutex.unlockShared(io); return self.impl.jumpLower( io,key, inclusive); }
            return Status.initMsg(.PRECONDITION_ERROR, "orphaned cursor");
        }

        pub fn jumpUpper(self: *Cursor, io: std.Io, key: []const u8, inclusive: bool) Status {
            if (self.impl.dbm) |dbm| { dbm.mutex.lockSharedUncancelable(io); defer dbm.mutex.unlockShared(io); return self.impl.jumpUpper( io,key, inclusive); }
            return Status.initMsg(.PRECONDITION_ERROR, "orphaned cursor");
        }

        pub fn next(self: *Cursor, io: std.Io) Status {
            if (self.impl.dbm) |dbm| { dbm.mutex.lockSharedUncancelable(io); defer dbm.mutex.unlockShared(io); return self.impl.next(io); }
            return Status.init(.NOT_FOUND_ERROR);
        }

        pub fn previous(self: *Cursor, io: std.Io) Status {
            if (self.impl.dbm) |dbm| { dbm.mutex.lockSharedUncancelable(io); defer dbm.mutex.unlockShared(io); return self.impl.previous(io); }
            return Status.init(.NOT_FOUND_ERROR);
        }

        pub fn get(self: *Cursor, io: std.Io, key_out: ?*std.ArrayList(u8), value_out: ?*std.ArrayList(u8)) Status {
            if (self.impl.dbm) |dbm| { dbm.mutex.lockSharedUncancelable(io); defer dbm.mutex.unlockShared(io); return self.impl.get( io,key_out, value_out); }
            return Status.initMsg(.PRECONDITION_ERROR, "orphaned cursor");
        }

        pub fn process(self: *Cursor, io: std.Io, comptime P: type, proc: *P, writable: bool) Status {
            if (self.impl.dbm) |dbm| {
                if (writable) {
                    dbm.mutex.lockUncancelable(io);
                    defer dbm.mutex.unlock(io);
                } else {
                    dbm.mutex.lockSharedUncancelable(io);
                    defer dbm.mutex.unlockShared(io);
                }
                return self.impl.process( io,P, proc, writable);
            }
            return Status.initMsg(.PRECONDITION_ERROR, "orphaned cursor");
        }

        pub fn set(self: *Cursor, io: std.Io, value: []const u8, old_key: ?*std.ArrayList(u8), old_value: ?*std.ArrayList(u8)) Status {
            if (self.impl.dbm) |dbm| {
                dbm.mutex.lockUncancelable(io);
                defer dbm.mutex.unlock(io);
                return self.impl.iterSet(io, value, old_key, old_value);
            }
            return Status.initMsg(.PRECONDITION_ERROR, "orphaned cursor");
        }

        pub fn remove(self: *Cursor, io: std.Io, old_key: ?*std.ArrayList(u8), old_value: ?*std.ArrayList(u8)) Status {
            if (self.impl.dbm) |dbm| {
                dbm.mutex.lockUncancelable(io);
                defer dbm.mutex.unlock(io);
                return self.impl.iterRemove(io, old_key, old_value);
            }
            return Status.initMsg(.PRECONDITION_ERROR, "orphaned cursor");
        }

        pub fn step(self: *Cursor, io: std.Io, key_out: ?*std.ArrayList(u8), value_out: ?*std.ArrayList(u8)) Status {
            const st = self.get( io,key_out, value_out);
            if (!st.isOk()) return st;
            _ = self.next(io);
            return Status.init(.SUCCESS);
        }
    };

    /// Entry returned by the Zig-style Iterator.
    /// Both slices point into the iterator's internal buffers and are invalidated
    /// on the next call to next() or deinit().
    pub const Entry = struct {
        /// Borrowed from iterator's internal buffer.
        /// Valid only until the next call to next() or deinit().
        key: []const u8,
        /// Borrowed from iterator's internal buffer.
        /// Valid only until the next call to next() or deinit().
        value: []const u8,
    };

    /// Zig-style iterator composed on top of Cursor.
    pub const Iterator = struct {
        cursor: Cursor,
        alloc: std.mem.Allocator,
        key_buf: std.ArrayList(u8),
        value_buf: std.ArrayList(u8),
        done: bool,

        /// Advance and return the current entry, or null when exhausted.
        ///
        /// The returned slices point into internal buffers and are invalidated
        /// on the next call to next() or deinit(). Copy them if you need the
        /// data to outlive this call.
        pub fn next(self: *Iterator, io: std.Io) !?Entry {
            if (self.done) return null;

            // Fill internal buffers from the current cursor position.
            var filled = false;
            const Proc = struct {
                key_buf: *std.ArrayList(u8),
                val_buf: *std.ArrayList(u8),
                alloc: std.mem.Allocator,
                oom: bool = false,
                pub fn processFull(p: *@This(), key: []const u8, val: []const u8) RecordAction {
                    p.key_buf.clearRetainingCapacity();
                    p.key_buf.appendSlice(p.alloc, key) catch { p.oom = true; return .noop; };
                    p.val_buf.clearRetainingCapacity();
                    p.val_buf.appendSlice(p.alloc, val) catch { p.oom = true; return .noop; };
                    return .noop;
                }
                pub fn processEmpty(_: *@This(), _: []const u8) RecordAction {
                    return .noop;
                }
            };
            var proc = Proc{
                .key_buf = &self.key_buf,
                .val_buf = &self.value_buf,
                .alloc = self.alloc,
            };
            if (self.cursor.process( io,Proc, &proc, false).isOk() and !proc.oom) filled = true;
            if (proc.oom) return error.OutOfMemory;

            if (!filled) {
                self.done = true;
                return null;
            }

            // Advance cursor. If it reaches the end, mark done so the next
            // call returns null rather than re-reading the last record.
            if (!self.cursor.next(io).isOk()) self.done = true;

            return Entry{
                .key = self.key_buf.items,
                .value = self.value_buf.items,
            };
        }

        /// Release internal buffers and the underlying cursor.
        pub fn deinit(self: *Iterator, io: std.Io) void {
            self.key_buf.deinit(self.alloc);
            self.value_buf.deinit(self.alloc);
            self.cursor.deinit(io);
        }
    };

    pub fn init(file: File, allocator: std.mem.Allocator, params: TuningParameters) std.mem.Allocator.Error!SkipDBM {
        const impl = try allocator.create(SkipDBMImpl);
        errdefer allocator.destroy(impl);

        impl.allocator = allocator;
        impl.path = .empty;
        impl.file = file;
        impl.writable = true;
        impl.healthy = true;
        impl.open = false;
        impl.updated = false;
        impl.removed = false;
        impl.auto_restored = false;
        impl.mutex = .init;

        impl.offset_width = @intCast(std.math.clamp(params.offset_width, @as(i32, MIN_OFFSET_WIDTH), @as(i32, MAX_OFFSET_WIDTH)));
        impl.step_unit = @intCast(std.math.clamp(params.step_unit, @as(i32, MIN_STEP_UNIT), @as(i32, MAX_STEP_UNIT)));
        impl.max_level = @intCast(std.math.clamp(params.max_level, @as(i32, MIN_MAX_LEVEL), @as(i32, MAX_MAX_LEVEL)));
        impl.sort_mem_size = std.math.clamp(params.sort_mem_size, MIN_SORT_MEM_SIZE, MAX_SORT_MEM_SIZE);
        impl.max_cached_records = std.math.clamp(params.max_cached_records, MIN_MAX_CACHED_RECORDS, MAX_MAX_CACHED_RECORDS);
        impl.insert_in_order = params.insert_in_order;

        impl.num_records = 0;
        impl.eff_data_size = 0;
        impl.file_size = @as(i64, METADATA_SIZE);
        impl.timestamp = 0; // placeholder; overwritten by open()
        impl.db_type = 0;
        impl.pkg_major_version = PKG_MAJOR_VERSION;
        impl.pkg_minor_version = PKG_MINOR_VERSION;
        impl.cyclic_magic = 1;
        impl.closure_flags = CLOSURE_FLAG_CLOSE;
        impl.dirty_close = false;
        @memset(&impl.opaque_metadata, 0);

        impl.record_index = 0;
        impl.old_num_records = 0;
        impl.old_eff_data_size = 0;
        @memset(&impl.past_offsets, 0);
        impl.sorted_file = null;
        impl.sorted_path = .empty;
        impl.update_logger = null;

        impl.iterators = .empty;

        // Cache and sorter are created by openAdvancedImpl when the database is opened.
        // Creating them here would cause a double-allocation and leak when open() overwrites them.
        impl.cache = null;
        impl.sorter = null;

        return SkipDBM{ .impl = impl, .allocator = allocator };
    }

    pub fn deinit(self: *SkipDBM, io: std.Io) void {
        // No mutex acquisition: deinit destroys the object; any concurrent access
        // would be UB regardless.
        if (self.impl.cache) |cache| {
            cache.deinit();
        }

        if (self.impl.sorter) |sorter| {
            sorter.deinit(io);
        }

        if (self.impl.sorted_file) |sf| {
            sf.deinit(self.allocator);
            self.impl.sorted_file = null;
        }

        for (self.impl.iterators.items) |iter| {
            self.allocator.destroy(iter);
        }
        self.impl.iterators.deinit(self.allocator);

        self.impl.path.deinit(self.allocator);
        self.impl.sorted_path.deinit(self.allocator);

        _ = self.impl.file.close(io);

        // deinit closes the file (if still open) and frees the File implementation.
        self.impl.file.deinit(self.allocator);
        self.allocator.destroy(self.impl);
        // SkipDBM is a stack value; do not destroy(self).
    }

    pub fn open(self: *SkipDBM, io: std.Io, path: []const u8, writable: bool, options: OpenOptions) Status {
        const default_params = TuningParameters{};
        return openAdvancedImpl(self.impl, io, path, writable, options, default_params);
    }

    pub fn openAdvanced(self: *SkipDBM, io: std.Io, path: []const u8, writable: bool, options: OpenOptions, params: TuningParameters) Status {
        return openAdvancedImpl(self.impl, io, path, writable, options, params);
    }

    pub fn close(self: *SkipDBM, io: std.Io) Status {
        return closeImplImpl(self.impl, io);
    }

    pub fn get(self: *SkipDBM, io: std.Io, key: []const u8, value_out: ?*std.ArrayList(u8)) Status {
        return getImpl(self.impl, io, key, value_out);
    }

    pub fn set(self: *SkipDBM, io: std.Io, key: []const u8, value: []const u8, overwrite: bool, old_value: ?*std.ArrayList(u8)) Status {
        if (old_value != null) _ = getImpl(self.impl, io, key, old_value);
        return setImpl(self.impl, io, key, value, overwrite);
    }

    pub fn remove(self: *SkipDBM, io: std.Io, key: []const u8, old_value: ?*std.ArrayList(u8)) Status {
        if (old_value != null) _ = getImpl(self.impl, io, key, old_value);
        return removeImpl(self.impl, io, key);
    }

    pub fn append(self: *SkipDBM, io: std.Io, key: []const u8, value: []const u8, delim: []const u8) Status {
        self.impl.mutex.lockUncancelable(io);
        defer self.impl.mutex.unlock(io);

        var existing_buf: std.ArrayList(u8) = .empty;
        defer existing_buf.deinit(self.impl.allocator);

        const get_status = getImpl(self.impl, io, key, &existing_buf);

        var new_value: std.ArrayList(u8) = .empty;
        defer new_value.deinit(self.impl.allocator);

        if (get_status.isOk()) {
            new_value.appendSlice(self.impl.allocator, existing_buf.items) catch
                return Status.init(.SYSTEM_ERROR);
            new_value.appendSlice(self.impl.allocator, delim) catch
                return Status.init(.SYSTEM_ERROR);
            new_value.appendSlice(self.impl.allocator, value) catch
                return Status.init(.SYSTEM_ERROR);
        } else if (get_status.code == .NOT_FOUND_ERROR) {
            new_value.appendSlice(self.impl.allocator, value) catch
                return Status.init(.SYSTEM_ERROR);
        } else {
            return get_status;
        }

        const status = updateRecordImpl(self.impl, io, key, new_value.items);
        if (status.isOk()) {
            if (self.impl.update_logger) |ul| {
                _ = ul.writeSet(key, new_value.items);
            }
        }
        return status;
    }

    /// Fetches values for each key in `keys`, inserting found entries into `records`.
    ///
    /// Both the key and value are duped into `records.allocator`. The caller is responsible
    /// for freeing the duped slices when the map is done.  The return value is SUCCESS if all
    /// keys were found, or the last non-SUCCESS status if any key was missing.  Iteration is
    /// never stopped early — the C++ `|=` semantics are preserved via Status.mergeFrom.
    pub fn getMulti(
        self: *SkipDBM,
        io: std.Io,
        keys: []const []const u8,
        records: *std.StringHashMap([]u8),
    ) Status {
        var status = Status.init(.SUCCESS);
        for (keys) |key| {
            var val_buf: std.ArrayList(u8) = .empty;
            defer val_buf.deinit(self.impl.allocator);
            const st = self.get( io,key, &val_buf);
            if (st.isOk()) {
                const duped_key = records.allocator.dupe(u8, key) catch
                    return Status.init(.SYSTEM_ERROR);
                const duped_val = records.allocator.dupe(u8, val_buf.items) catch {
                    records.allocator.free(duped_key);
                    return Status.init(.SYSTEM_ERROR);
                };
                records.put(duped_key, duped_val) catch {
                    records.allocator.free(duped_key);
                    records.allocator.free(duped_val);
                    return Status.init(.SYSTEM_ERROR);
                };
            } else {
                status.mergeFrom(st);
            }
        }
        return status;
    }

    /// Sets each key/value pair in `records`.
    ///
    /// Stops early on any error other than DUPLICATION_ERROR (matching C++ SetMulti semantics).
    pub fn setMulti(
        self: *SkipDBM,
        io: std.Io,
        records: []const [2][]const u8,
        overwrite: bool,
    ) Status {
        var status = Status.init(.SUCCESS);
        for (records) |r| {
            const st = self.set( io,r[0], r[1], overwrite, null);
            status.mergeFrom(st);
            if (!status.isOk() and status.code != .DUPLICATION_ERROR) break;
        }
        return status;
    }

    /// Removes each key in `keys`.
    ///
    /// Stops early on any error other than NOT_FOUND_ERROR (matching C++ RemoveMulti semantics).
    pub fn removeMulti(self: *SkipDBM, io: std.Io, keys: []const []const u8) Status {
        var status = Status.init(.SUCCESS);
        for (keys) |key| {
            const st = self.remove( io,key, null);
            status.mergeFrom(st);
            if (!status.isOk() and status.code != .NOT_FOUND_ERROR) break;
        }
        return status;
    }

    /// Appends to each key/value pair in `records` using `delim` as separator.
    ///
    /// Stops on the first error (matching C++ AppendMulti semantics).
    pub fn appendMulti(
        self: *SkipDBM,
        io: std.Io,
        records: []const [2][]const u8,
        delim: []const u8,
    ) Status {
        var status = Status.init(.SUCCESS);
        for (records) |r| {
            const st = self.append( io,r[0], r[1], delim);
            status.mergeFrom(st);
            if (!status.isOk()) break;
        }
        return status;
    }

    fn countInternal(self: *SkipDBM) i64 {
        return self.impl.num_records;
    }

    fn getFileSizeInternal(self: *SkipDBM) i64 {
        return self.impl.file_size;
    }

    fn getFilePathInternal(self: *SkipDBM) []const u8 {
        return self.impl.path.items;
    }

    fn getTimestampInternal(self: *SkipDBM) f64 {
        return @as(f64, @floatFromInt(self.impl.timestamp)) / 1_000_000.0;
    }

    /// Fills `out` with the number of records. Returns PRECONDITION_ERROR if not open.
    /// Matches C++ DBM::Count(int64_t* count).
    pub fn count(self: *SkipDBM, out: *i64) Status {
        if (!self.impl.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        out.* = self.impl.num_records;
        return Status.init(.SUCCESS);
    }

    /// Fills `out` with the file size in bytes. Returns PRECONDITION_ERROR if not open.
    /// Matches C++ DBM::GetFileSize(int64_t* size).
    pub fn getFileSize(self: *SkipDBM, out: *i64) Status {
        if (!self.impl.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        out.* = self.impl.file_size;
        return Status.init(.SUCCESS);
    }

    /// Appends the file path to `out`. Returns PRECONDITION_ERROR if not open.
    /// Matches C++ DBM::GetFilePath(std::string* path).
    pub fn getFilePath(self: *SkipDBM, out: *std.ArrayList(u8)) Status {
        if (!self.impl.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        out.clearRetainingCapacity();
        out.appendSlice(self.allocator, self.impl.path.items) catch return Status.init(.SYSTEM_ERROR);
        return Status.init(.SUCCESS);
    }

    /// Fills `out` with the modification timestamp. Returns PRECONDITION_ERROR if not open.
    /// Matches C++ DBM::GetTimestamp(double* timestamp).
    pub fn getTimestamp(self: *SkipDBM, out: *f64) Status {
        if (!self.impl.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        out.* = @as(f64, @floatFromInt(self.impl.timestamp)) / 1_000_000.0;
        return Status.init(.SUCCESS);
    }

    pub fn getEffectiveDataSize(self: *SkipDBM) i64 {
        return self.impl.eff_data_size;
    }

    pub fn getDatabaseType(self: *SkipDBM) u32 {
        return self.impl.db_type;
    }

    pub fn setDatabaseType(self: *SkipDBM, io: std.Io, db_type: u32) Status {
        self.impl.mutex.lockUncancelable(io);
        defer self.impl.mutex.unlock(io);
        if (!self.impl.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        if (!self.impl.writable) return Status.initMsg(.PRECONDITION_ERROR, "not writable");
        self.impl.db_type = db_type;
        return Status.init(.SUCCESS);
    }

    pub fn getOpaqueMetadata(self: *SkipDBM) []const u8 {
        return self.impl.opaque_metadata[0..];
    }

    pub fn setOpaqueMetadata(self: *SkipDBM, opaque_data: []const u8) Status {
        const size = @min(opaque_data.len, OPAQUE_METADATA_SIZE);
        @memcpy(self.impl.opaque_metadata[0..size], opaque_data[0..size]);
        if (size < OPAQUE_METADATA_SIZE) {
            @memset(self.impl.opaque_metadata[size..OPAQUE_METADATA_SIZE], 0);
        }
        self.impl.updated = true;
        return Status.init(.SUCCESS);
    }

    pub fn isOpen(self: *SkipDBM) bool {
        return self.impl.open;
    }

    pub fn isWritable(self: *SkipDBM) bool {
        return self.impl.writable;
    }

    pub fn isHealthy(self: *SkipDBM) bool {
        return self.impl.healthy;
    }

    pub fn isAutoRestored(self: *SkipDBM) bool {
        return self.impl.auto_restored;
    }

    pub fn isOrdered(self: *SkipDBM) bool {
        _ = self;
        return true;
    }

    /// Scans all skip records from the beginning of the record area to the end of file,
    /// verifying each record's magic byte, size fields, and that no record extends
    /// past the end of file. Matches C++ SkipDBM::ValidateRecords().
    pub fn validateRecords(self: *SkipDBM, io: std.Io) Status {
        self.impl.mutex.lockSharedUncancelable(io);
        defer self.impl.mutex.unlockShared(io);
        if (!self.impl.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        const file_sz = self.impl.file.getSizeSimple();
        var offset: i64 = METADATA_SIZE;
        var record_count: i64 = 0;
        while (offset < file_sz) {
            var rec = SkipRecord.init(self.impl.file, self.impl.offset_width, self.impl.step_unit, self.impl.max_level, self.impl.allocator);
            defer rec.deinit();
            const st = rec.readMetadataKey(io, offset, record_count);
            if (!st.isOk()) return Status.initMsg(.BROKEN_DATA_ERROR, "skip record header unreadable");
            if (rec.whole_size == 0) return Status.initMsg(.BROKEN_DATA_ERROR, "skip record size zero");
            offset += @as(i64, @intCast(rec.whole_size));
            record_count += 1;
        }
        return Status.init(.SUCCESS);
    }

    pub fn isUpdated(self: *SkipDBM) bool {
        return self.impl.updated;
    }

    pub fn clear(self: *SkipDBM, io: std.Io) Status {
        self.impl.mutex.lockUncancelable(io);
        defer self.impl.mutex.unlock(io);

        if (!self.impl.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        if (!self.impl.writable) return Status.initMsg(.PRECONDITION_ERROR, "not writable");

        // WAL clear entry written before any mutation (mirrors C++ order).
        if (self.impl.update_logger) |ul| {
            const ul_status = ul.writeClear();
            if (!ul_status.isOk()) return ul_status;
        }

        // Commit any in-progress sort before wiping the file.
        if (self.impl.updated) {
            const finish_status = finishStorageImpl(self.impl, io, null);
            if (!finish_status.isOk()) return finish_status;
        }

        // Discard residual sorter/sorted_file (finishStorageImpl resets updated but may
        // leave sorter allocated in the fast-path; discard cleans up unconditionally).
        if (self.impl.sorter != null or self.impl.sorted_file != null) {
            discardStorageImpl(self.impl, io);
        }

        cancelIteratorsImpl(self.impl);

        const truncate_status = self.impl.file.truncate(io, METADATA_SIZE);
        if (!truncate_status.isOk()) return truncate_status;

        self.impl.num_records = 0;
        self.impl.eff_data_size = 0;
        self.impl.file_size = METADATA_SIZE;
        self.impl.timestamp = currentTimeMicros(io);
        self.impl.record_index = 0;
        self.impl.removed = false;
        @memset(&self.impl.past_offsets, 0);

        const save_status = saveMetadata(self.impl, io, self.impl.file, false);
        if (!save_status.isOk()) return save_status;

        const prep_status = prepareStorageImpl(self.impl, io);
        if (!prep_status.isOk()) return prep_status;

        if (self.impl.cache) |old_cache| old_cache.deinit();
        self.impl.cache = SkipRecordCache.init(
            self.impl.step_unit, self.impl.max_cached_records, 0, self.impl.allocator,
        ) catch null;

        return Status.init(.SUCCESS);
    }

    pub fn rebuild(self: *SkipDBM, io: std.Io) Status {
        const default_params = TuningParameters{};
        return self.rebuildAdvanced( io,default_params, false, false);
    }

    pub fn rebuildAdvanced(self: *SkipDBM, io: std.Io, params: TuningParameters, skip_broken: bool, sync_hard: bool) Status {
        _ = skip_broken;
        {
            self.impl.mutex.lockUncancelable(io);
            defer self.impl.mutex.unlock(io);

            if (!self.impl.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");

            // Save old params
            const old_offset_width = self.impl.offset_width;
            const old_step_unit = self.impl.step_unit;
            const old_max_level = self.impl.max_level;

            // Update to new params (with clamping)
            self.impl.offset_width = @as(u8, @intCast(@min(params.offset_width, MAX_OFFSET_WIDTH)));
            self.impl.step_unit = @as(u8, @intCast(@min(params.step_unit, MAX_STEP_UNIT)));
            self.impl.max_level = @as(u8, @intCast(@min(params.max_level, MAX_MAX_LEVEL)));
            self.impl.sort_mem_size = params.sort_mem_size;

            // Rebuild = sync with no reducer (keeps all records, restructures)
            const rebuild_status = finishStorageImpl(self.impl, io, null);

            if (!rebuild_status.isOk()) {
                // Restore old params on failure
                self.impl.offset_width = old_offset_width;
                self.impl.step_unit = old_step_unit;
                self.impl.max_level = old_max_level;
                return rebuild_status;
            }
        }
        if (sync_hard) return self.synchronize( io,true);
        return Status.init(.SUCCESS);
    }

    /// Lock-free: reads only integer fields that are stable during normal operation.
    fn shouldBeRebuiltInternal(self: *SkipDBM) bool {
        const pow_threshold = powI64(@as(i64, self.impl.step_unit), self.impl.max_level + 1);
        if (self.impl.num_records > pow_threshold) {
            return true;
        }

        if (self.impl.offset_width > MIN_OFFSET_WIDTH) {
            const pow_offset = powI64(256, self.impl.offset_width - 1);
            if (self.impl.file_size * 2 < pow_offset) {
                return true;
            }
        }

        return false;
    }

    /// Sets `out` to whether a rebuild would improve performance. Returns PRECONDITION_ERROR if not open.
    /// Matches C++ DBM::ShouldBeRebuilt(bool* tobe).
    pub fn shouldBeRebuilt(self: *SkipDBM, out: *bool) Status {
        if (!self.impl.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        out.* = self.shouldBeRebuiltInternal();
        return Status.init(.SUCCESS);
    }

    pub fn synchronize(self: *SkipDBM, io: std.Io, hard: bool) Status {
        return self.synchronizeAdvanced( io,hard, null);
    }

    pub fn synchronizeAdvanced(self: *SkipDBM, io: std.Io, hard: bool, reducer: ?ReducerType) Status {
        self.impl.mutex.lockUncancelable(io);
        defer self.impl.mutex.unlock(io);

        if (!self.impl.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        if (!self.impl.writable) return Status.initMsg(.PRECONDITION_ERROR, "not writable");
        if (!self.impl.healthy) return Status.initMsg(.PRECONDITION_ERROR, "not healthy");

        cancelIteratorsImpl(self.impl);

        // WAL sync before finish so the log reflects all writes before the merge. (C++ order)
        if (self.impl.update_logger) |ul| {
            _ = ul.synchronize(hard);
        }

        if (self.impl.updated) {
            const finish_status = finishStorageImpl(self.impl, io, reducer);
            if (!finish_status.isOk()) return finish_status;
        }

        if (hard) {
            const file_status = self.impl.file.synchronize(io, true);
            if (!file_status.isOk()) return file_status;
        }

        // Write open-state metadata header and reinitialize sorter for the next write cycle.
        const save_status = saveMetadata(self.impl, io, self.impl.file, false);
        if (!save_status.isOk()) return save_status;

        const prep_status = prepareStorageImpl(self.impl, io);
        if (!prep_status.isOk()) return prep_status;

        if (self.impl.cache) |old_cache| old_cache.deinit();
        self.impl.cache = SkipRecordCache.init(
            self.impl.step_unit, self.impl.max_cached_records, self.impl.num_records, self.impl.allocator,
        ) catch null;

        return Status.init(.SUCCESS);
    }

    pub fn revert(self: *SkipDBM, io: std.Io) Status {
        if (!self.impl.writable) {
            return Status.initMsg(.PRECONDITION_ERROR, "not writable");
        }
        self.impl.mutex.lockUncancelable(io);
        defer self.impl.mutex.unlock(io);

        discardStorageImpl(self.impl, io);
        return Status.init(.SUCCESS);
    }

    pub fn getByIndex(self: *SkipDBM, io: std.Io, index: i64, key_out: ?*std.ArrayList(u8), value_out: ?*std.ArrayList(u8)) Status {
        self.impl.mutex.lockUncancelable(io);
        defer self.impl.mutex.unlock(io);

        if (index < 0 or index >= self.impl.num_records) {
            return Status.init(.NOT_FOUND_ERROR);
        }

        var rec = SkipRecord.init(self.impl.file, self.impl.offset_width, self.impl.step_unit, self.impl.max_level, self.impl.allocator);
        defer rec.deinit();

        const search_status = rec.searchByIndex(io, METADATA_SIZE, self.impl.cache, index);
        if (!search_status.isOk()) {
            return search_status;
        }

        const body_status = rec.readBody(io);
        if (!body_status.isOk()) {
            return body_status;
        }

        if (key_out) |k| {
            k.clearRetainingCapacity();
            k.appendSlice(self.impl.allocator, rec.key_ptr) catch {
                return Status.init(.SYSTEM_ERROR);
            };
        }

        if (value_out) |v| {
            v.clearRetainingCapacity();
            if (rec.value_ptr) |vp| {
                v.appendSlice(self.impl.allocator, vp) catch {
                    return Status.init(.SYSTEM_ERROR);
                };
            }
        }

        return Status.init(.SUCCESS);
    }

    pub fn processFirst(self: *SkipDBM, io: std.Io, comptime P: type, proc: *P, writable: bool) Status {
        if (writable) {
            self.impl.mutex.lockUncancelable(io);
        } else {
            self.impl.mutex.lockSharedUncancelable(io);
        }
        defer {
            if (writable) {
                self.impl.mutex.unlock(io);
            } else {
                self.impl.mutex.unlockShared(io);
            }
        }

        if (!self.impl.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        if (writable) {
            if (!self.impl.writable) return Status.initMsg(.PRECONDITION_ERROR, "not writable");
            if (!self.impl.healthy) return Status.initMsg(.PRECONDITION_ERROR, "not healthy");
        }
        if (self.impl.file.getSizeSimple() <= METADATA_SIZE) return Status.init(.NOT_FOUND_ERROR);

        var rec = SkipRecord.init(self.impl.file, self.impl.offset_width, self.impl.step_unit, self.impl.max_level, self.impl.allocator);
        defer rec.deinit();

        var status = rec.readMetadataKey(io, METADATA_SIZE, 0);
        if (!status.isOk()) return status;
        if (rec.value_ptr == null) {
            status = rec.readBody(io);
            if (!status.isOk()) return status;
        }

        const action = proc.processFull(rec.key_ptr, rec.value_ptr.?);
        if (!writable) return Status.init(.SUCCESS);
        switch (action) {
            .noop => {},
            .remove => return removeImpl(self.impl, io, rec.key_ptr),
            .set => |new_value| return updateRecordImpl(self.impl, io, rec.key_ptr, new_value),
        }
        return Status.init(.SUCCESS);
    }

    pub fn processEach(self: *SkipDBM, io: std.Io, comptime P: type, proc: *P, writable: bool) Status {
        if (writable) {
            self.impl.mutex.lockUncancelable(io);
        } else {
            self.impl.mutex.lockSharedUncancelable(io);
        }
        defer {
            if (writable) {
                self.impl.mutex.unlock(io);
            } else {
                self.impl.mutex.unlockShared(io);
            }
        }

        if (!self.impl.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        if (writable) {
            if (!self.impl.writable) return Status.initMsg(.PRECONDITION_ERROR, "not writable");
            if (!self.impl.healthy) return Status.initMsg(.PRECONDITION_ERROR, "not healthy");
        }

        _ = proc.processEmpty(""); // C++ ProcessEach sentinel: fired once before the record loop
        const end_offset = self.impl.file.getSizeSimple();
        var offset: i64 = METADATA_SIZE;
        var index: i64 = 0;

        var rec = SkipRecord.init(self.impl.file, self.impl.offset_width, self.impl.step_unit, self.impl.max_level, self.impl.allocator);
        defer rec.deinit();

        while (offset < end_offset) {
            var status = rec.readMetadataKey(io, offset, index);
            if (!status.isOk()) return status;
            if (rec.value_ptr == null) {
                status = rec.readBody(io);
                if (!status.isOk()) return status;
            }

            const action = proc.processFull(rec.key_ptr, rec.value_ptr.?);
            if (writable) {
                switch (action) {
                    .noop => {},
                    .remove => {
                        status = removeImpl(self.impl, io, rec.key_ptr);
                        if (!status.isOk()) return status;
                    },
                    .set => |new_value| {
                        status = updateRecordImpl(self.impl, io, rec.key_ptr, new_value);
                        if (!status.isOk()) return status;
                    },
                }
            }

            offset += @as(i64, @intCast(rec.whole_size));
            index += 1;
        }
        _ = proc.processEmpty(""); // C++ ProcessEach sentinel: fired once after the record loop
        return Status.init(.SUCCESS);
    }

    pub fn processMulti(self: *SkipDBM, io: std.Io, comptime P: type, keys: []const []const u8, procs: []const *P, writable: bool) Status {
        if (writable) {
            self.impl.mutex.lockUncancelable(io);
        } else {
            self.impl.mutex.lockSharedUncancelable(io);
        }
        defer {
            if (writable) {
                self.impl.mutex.unlock(io);
            } else {
                self.impl.mutex.unlockShared(io);
            }
        }

        for (keys, procs) |key, proc| {
            var rec = SkipRecord.init(self.impl.file, self.impl.offset_width, self.impl.step_unit, self.impl.max_level, self.impl.allocator);
            defer rec.deinit();

            const search_status = rec.search(io, METADATA_SIZE, self.impl.cache, key, false);
            if (!search_status.isOk()) {
                if (search_status.code == .NOT_FOUND_ERROR) {
                    const action = proc.processEmpty(key);
                    if (writable) {
                        switch (action) {
                            .noop => {},
                            .remove => {},
                            .set => |new_value| {
                                const set_status = updateRecordImpl(self.impl, io, key, new_value);
                                if (!set_status.isOk()) return set_status;
                            },
                        }
                    }
                } else {
                    return search_status;
                }
                continue;
            }

            const body_status = rec.readBody(io);
            if (!body_status.isOk()) {
                return body_status;
            }

            const value_slice = rec.value_ptr orelse "";
            const action = if (value_slice.len > 0)
                proc.processFull(key, value_slice)
            else
                proc.processEmpty(key);

            if (writable) {
                switch (action) {
                    .noop => {},
                    .remove => {
                        const rm_status = removeImpl(self.impl, io, key);
                        if (!rm_status.isOk()) return rm_status;
                    },
                    .set => |new_value| {
                        const set_status = updateRecordImpl(self.impl, io, key, new_value);
                        if (!set_status.isOk()) return set_status;
                    },
                }
            }
        }

        return Status.init(.SUCCESS);
    }

    pub fn inspect(self: *SkipDBM, allocator: std.mem.Allocator, io: std.Io) !std.ArrayList([2][]u8) {
        self.impl.mutex.lockSharedUncancelable(io);
        defer self.impl.mutex.unlockShared(io);

        var result: std.ArrayList([2][]u8) = .empty;
        errdefer {
            for (result.items) |pair| {
                allocator.free(pair[0]);
                allocator.free(pair[1]);
            }
            result.deinit(allocator);
        }
        try result.ensureTotalCapacity(allocator, 24);

        const appendPair = struct {
            fn f(arr: *std.ArrayList([2][]u8), alloc: std.mem.Allocator, k: []const u8, v: []const u8) !void {
                const key_copy = try alloc.dupe(u8, k);
                errdefer alloc.free(key_copy);
                const val_copy = try alloc.dupe(u8, v);
                errdefer alloc.free(val_copy);
                arr.appendAssumeCapacity(.{ key_copy, val_copy });
            }
        };

        try appendPair.f(&result, allocator, "class", "SkipDBM");

        if (self.impl.open) {
            try appendPair.f(&result, allocator, "healthy", if (self.impl.healthy) "true" else "false");
            try appendPair.f(&result, allocator, "auto_restored", if (self.impl.auto_restored) "true" else "false");
            try appendPair.f(&result, allocator, "updated", if (self.impl.updated) "true" else "false");
            try appendPair.f(&result, allocator, "removed", if (self.impl.removed) "true" else "false");
            try appendPair.f(&result, allocator, "path", self.impl.path.items);

            const cm_str = try std.fmt.allocPrint(allocator, "{d}", .{self.impl.cyclic_magic});
            defer allocator.free(cm_str);
            try appendPair.f(&result, allocator, "cyclic_magic", cm_str);

            const pmaj_str = try std.fmt.allocPrint(allocator, "{d}", .{self.impl.pkg_major_version});
            defer allocator.free(pmaj_str);
            try appendPair.f(&result, allocator, "pkg_major_version", pmaj_str);

            const pmin_str = try std.fmt.allocPrint(allocator, "{d}", .{self.impl.pkg_minor_version});
            defer allocator.free(pmin_str);
            try appendPair.f(&result, allocator, "pkg_minor_version", pmin_str);

            const ow_str = try std.fmt.allocPrint(allocator, "{d}", .{self.impl.offset_width});
            defer allocator.free(ow_str);
            try appendPair.f(&result, allocator, "offset_width", ow_str);

            const su_str = try std.fmt.allocPrint(allocator, "{d}", .{self.impl.step_unit});
            defer allocator.free(su_str);
            try appendPair.f(&result, allocator, "step_unit", su_str);

            const ml_str = try std.fmt.allocPrint(allocator, "{d}", .{self.impl.max_level});
            defer allocator.free(ml_str);
            try appendPair.f(&result, allocator, "max_level", ml_str);

            const cf_str = try std.fmt.allocPrint(allocator, "{d}", .{self.impl.closure_flags});
            defer allocator.free(cf_str);
            try appendPair.f(&result, allocator, "closure_flags", cf_str);

            const num_rec_str = try std.fmt.allocPrint(allocator, "{d}", .{self.impl.num_records});
            defer allocator.free(num_rec_str);
            try appendPair.f(&result, allocator, "num_records", num_rec_str);

            const eff_str = try std.fmt.allocPrint(allocator, "{d}", .{self.impl.eff_data_size});
            defer allocator.free(eff_str);
            try appendPair.f(&result, allocator, "eff_data_size", eff_str);

            const file_size = self.impl.file.getSizeSimple();
            const file_size_str = try std.fmt.allocPrint(allocator, "{d}", .{file_size});
            defer allocator.free(file_size_str);
            try appendPair.f(&result, allocator, "file_size", file_size_str);

            const ts_f = @as(f64, @floatFromInt(self.impl.timestamp)) / 1_000_000.0;
            const ts_str = try std.fmt.allocPrint(allocator, "{d:.6}", .{ts_f});
            defer allocator.free(ts_str);
            try appendPair.f(&result, allocator, "timestamp", ts_str);

            const dt_str = try std.fmt.allocPrint(allocator, "{d}", .{self.impl.db_type});
            defer allocator.free(dt_str);
            try appendPair.f(&result, allocator, "db_type", dt_str);

            const sms_str = try std.fmt.allocPrint(allocator, "{d}", .{self.impl.sort_mem_size});
            defer allocator.free(sms_str);
            try appendPair.f(&result, allocator, "sort_mem_size", sms_str);

            // max_file_size mirrors C++: 1LL << (offset_width_ * 8)
            const max_file_size: i64 = @as(i64, 1) << @intCast(self.impl.offset_width * 8);
            const mfs_str = try std.fmt.allocPrint(allocator, "{d}", .{max_file_size});
            defer allocator.free(mfs_str);
            try appendPair.f(&result, allocator, "max_file_size", mfs_str);

            try appendPair.f(&result, allocator, "insert_in_order", if (self.impl.insert_in_order) "true" else "false");

            // record_base is always METADATA_SIZE
            const rb_str = try std.fmt.allocPrint(allocator, "{d}", .{METADATA_SIZE});
            defer allocator.free(rb_str);
            try appendPair.f(&result, allocator, "record_base", rb_str);
        }

        return result;
    }

    pub fn mergeSkipDatabase(self: *SkipDBM, io: std.Io, src_path: []const u8) Status {
        self.impl.mutex.lockUncancelable(io);
        defer self.impl.mutex.unlock(io);

        if (!self.impl.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        if (!self.impl.writable) return Status.initMsg(.PRECONDITION_ERROR, "not writable");

        // Open source database
        const src_file_ptr = StdFile.create(self.allocator) catch {
            return Status.init(.SYSTEM_ERROR);
        };
        var src_file = src_file_ptr.asFile();

        const open_status = src_file.open(io, src_path, false, .{ .no_lock = true }); // import source; caller ensures no concurrent writes
        if (!open_status.isOk()) {
            return open_status;
        }
        defer _ = src_file.close(io);

        // Iterate through source records and insert into self
        var offset: i64 = METADATA_SIZE;
        var index: i64 = 0;

        while (offset < src_file.getSizeSimple()) {
            var rec = SkipRecord.init(src_file, self.impl.offset_width, self.impl.step_unit, self.impl.max_level, self.allocator);
            defer rec.deinit();

            const meta_status = rec.readMetadataKey(io, offset, index);
            if (!meta_status.isOk()) break;

            const body_status = rec.readBody(io);
            if (!body_status.isOk()) break;

            // Insert record if not a REMOVING_VALUE
            if (!std.mem.eql(u8, rec.value_ptr orelse "", REMOVING_VALUE)) {
                const set_status = setImpl(self.impl, io, rec.key_ptr, rec.value_ptr orelse "", true);
                if (!set_status.isOk()) break;
            }

            offset += @as(i64, @intCast(rec.whole_size));
            index += 1;
        }

        return Status.init(.SUCCESS);
    }

    pub fn iterate(self: *SkipDBM, alloc: std.mem.Allocator, io: std.Io) !Iterator {
        var cursor = try self.makeCursor(io);
        errdefer cursor.deinit(io);
        var iter = Iterator{
            .cursor = cursor,
            .alloc = alloc,
            .key_buf = .empty,
            .value_buf = .empty,
            .done = false,
        };
        if (!iter.cursor.first(io).isOk()) iter.done = true;
        return iter;
    }

    pub fn iterateFrom(self: *SkipDBM, alloc: std.mem.Allocator, io: std.Io, key: []const u8) !Iterator {
        var cursor = try self.makeCursor(io);
        errdefer cursor.deinit(io);
        var iter = Iterator{
            .cursor = cursor,
            .alloc = alloc,
            .key_buf = .empty,
            .value_buf = .empty,
            .done = false,
        };
        if (!iter.cursor.jump( io,key).isOk()) iter.done = true;
        return iter;
    }

    pub fn makeCursor(self: *SkipDBM, io: std.Io) !Cursor {
        // SkipDBMIteratorImpl.init registers self in dbm.iterators under the mutex;
        // no second append here.
        const iter_impl = try SkipDBMIteratorImpl.init(self.impl, io, self.allocator);
        return Cursor{ .impl = iter_impl, .allocator = self.allocator };
    }


    pub fn getUpdateLogger(_self: *SkipDBM) ?*UpdateLogger {
        _ = _self;
        return null;
    }

    pub fn setUpdateLogger(_self: *SkipDBM, _logger: ?*UpdateLogger) void {
        _ = _self;
        _ = _logger;
    }

    pub fn getInternalFile(_self: *SkipDBM) File {
        return _self.impl.file;
    }

    pub fn readMetadata(file: File, allocator: std.mem.Allocator, io: std.Io) Status {
        _ = allocator;
        // Read and validate metadata from a closed file
        var metadata_buf: [METADATA_SIZE]u8 = undefined;
        const read_status = file.read(io, 0, &metadata_buf);
        if (!read_status.isOk()) return read_status;

        // Check magic
        if (!std.mem.eql(u8, metadata_buf[0..9], META_MAGIC_DATA)) {
            return Status.init(.BROKEN_DATA_ERROR);
        }

        return Status.init(.SUCCESS);
    }

    pub fn restoreDatabase( _allocator: std.mem.Allocator, io: std.Io,_old_path: []const u8, _new_path: []const u8) Status {
        return restoreDatabaseImpl( _allocator, io,_old_path, _new_path);
    }

    /// Atomically compare and conditionally exchange the value for a key.
    pub fn compareExchange(
        self: *SkipDBM,
        io: std.Io,
        key: []const u8,
        expected: dbm_mod.CompareExpected,
        desired: dbm_mod.CompareDesired,
        actual_out: ?*std.ArrayList(u8),
        found_out: ?*bool,
    ) Status {
        var status = Status.init(.SUCCESS);
        var proc = ProcessorCompareExchange{
            .status = &status,
            .expected = expected,
            .desired = desired,
            .actual_out = actual_out,
            .found_out = found_out,
            .allocator = self.allocator,
        };
        const multi_status = self.processMulti( io,ProcessorCompareExchange, &[_][]const u8{key}, &[_]*ProcessorCompareExchange{&proc}, true);
        if (!multi_status.isOk()) return multi_status;
        return status;
    }

    /// Atomically increment a stored i64 value by delta, returning the new value.
    pub fn increment(
        self: *SkipDBM,
        io: std.Io,
        key: []const u8,
        delta: i64,
        current_out: ?*i64,
        initial: i64,
    ) Status {
        var status = Status.init(.SUCCESS);
        var proc = ProcessorIncrement{
            .status = &status,
            .delta = delta,
            .current_out = current_out,
            .initial = initial,
        };
        const multi_status = self.processMulti( io,ProcessorIncrement, &[_][]const u8{key}, &[_]*ProcessorIncrement{&proc}, true);
        if (!multi_status.isOk()) return multi_status;
        return status;
    }

    pub fn incrementSimple(self: *SkipDBM, io: std.Io, key: []const u8, delta: i64, initial: i64) i64 {
        var result: i64 = initial;
        _ = self.increment( io,key, delta, &result, initial);
        return result;
    }

    pub fn getSimple(self: *SkipDBM, allocator: std.mem.Allocator, io: std.Io, key: []const u8, default_value: []const u8) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        const st = self.get( io,key, &buf);
        if (st.isOk()) return try allocator.dupe(u8, buf.items);
        return try allocator.dupe(u8, default_value);
    }

    /// Remove and return the first record in the database (lexicographic first on ordered SkipDBM).
    pub fn popFirst(
        self: *SkipDBM,
        io: std.Io,
        key_out: ?*std.ArrayList(u8),
        value_out: ?*std.ArrayList(u8),
    ) Status {
        var proc = ProcessorPopFirst{
            .key_out = key_out,
            .value_out = value_out,
            .allocator = self.allocator,
        };
        return self.processFirst( io,ProcessorPopFirst, &proc, true);
    }

    /// Push a value at the lexicographic end using a timestamp-based key.
    /// wtime < 0 uses the current wall clock time; otherwise uses the provided time.
    /// Key is returned in key_out if non-null.
    pub fn pushLast(
        self: *SkipDBM,
        io: std.Io,
        value: []const u8,
        wtime: f64,
        key_out: ?*std.ArrayList(u8),
    ) Status {
        const base: u64 = time_util.pushLastKeyBase(wtime, io);
        var seq: u64 = 0;
        while (true) : (seq += 1) {
            const ts: u64 = base +% seq;
            var key_buf: [8]u8 = undefined;
            const key = str_util.intToStrBigEndian(ts, 8, &key_buf);
            const st = self.set( io,key, value, false, null);
            if (st.code != .DUPLICATION_ERROR) {
                if (key_out) |ko| {
                    ko.clearRetainingCapacity();
                    ko.appendSlice(self.allocator, key) catch return Status.init(.SYSTEM_ERROR);
                }
                return st;
            }
        }
    }

    // -----------------------------------------------------------------------
    // Phase 6: Base class methods
    // -----------------------------------------------------------------------

    /// Creates a new heap-allocated SkipDBM instance.
    pub fn makeDbm(allocator: std.mem.Allocator) !*SkipDBM {
        const sf = try file_mod.StdFile.create(allocator);
        const new_dbm = try allocator.create(SkipDBM);
        errdefer allocator.destroy(new_dbm);
        new_dbm.* = SkipDBM.init(sf.asFile(), allocator, .{}) catch |e| {
            // asFile() transfers ownership, so deinit through the File interface.
            sf.asFile().deinit(allocator);
            return e;
        };
        return new_dbm;
    }

    /// Returns the record count or -1 when not open. Matches C++ DBM::CountSimple().
    pub fn countSimple(self: *SkipDBM) i64 {
        if (!self.impl.open) return -1;
        return self.impl.num_records;
    }

    /// Returns the file size in bytes or -1 when not open. Matches C++ DBM::GetFileSizeSimple().
    pub fn getFileSizeSimple(self: *SkipDBM) i64 {
        if (!self.impl.open) return -1;
        return self.impl.file_size;
    }

    /// Returns the file path or "" when not open. Matches C++ DBM::GetFilePathSimple().
    pub fn getFilePathSimple(self: *SkipDBM) []const u8 {
        if (!self.impl.open) return "";
        return self.impl.path.items;
    }

    /// Returns the timestamp or NaN when not open. Matches C++ DBM::GetTimestampSimple().
    pub fn getTimestampSimple(self: *SkipDBM) f64 {
        if (!self.impl.open) return std.math.nan(f64);
        return @as(f64, @floatFromInt(self.impl.timestamp)) / 1_000_000.0;
    }

    /// Returns whether a rebuild would improve performance, or false when not open.
    /// Matches C++ DBM::ShouldBeRebuiltSimple().
    pub fn shouldBeRebuiltSimple(self: *SkipDBM) bool {
        if (!self.impl.open) return false;
        return self.shouldBeRebuiltInternal();
    }

    /// Copies the database file to dest_path, optionally syncing first.
    pub fn copyFileData(self: *SkipDBM, io: std.Io, dest_path: []const u8, sync_hard: bool) Status {
        if (!self.isOpen()) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        if (sync_hard) {
            const st = self.synchronize( io,true);
            if (!st.isOk()) return st;
        }
        const src_path = self.getFilePathInternal();
        if (src_path.len == 0) return Status.initMsg(.PRECONDITION_ERROR, "no file path");
        file_mod.copyFileAbsolute(src_path, dest_path) catch
            return Status.initMsg(.SYSTEM_ERROR, "copy file failed");
        return Status.init(.SUCCESS);
    }

    /// Renames a key. Reads old value, sets under new_key, removes old_key unless copying=true.
    pub fn rekey(self: *SkipDBM, io: std.Io, old_key: []const u8, new_key: []const u8, overwrite: bool, copying: bool) Status {
        if (!self.isOpen() or !self.isWritable())
            return Status.initMsg(.PRECONDITION_ERROR, "not writable");

        var value_list: std.ArrayList(u8) = .empty;
        defer value_list.deinit(self.allocator);

        const st_get = self.get( io,old_key, &value_list);
        if (!st_get.isOk()) return st_get;

        const st_set = self.set( io,new_key, value_list.items, overwrite, null);
        if (!st_set.isOk()) return st_set;

        if (!copying) {
            _ = self.remove( io,old_key, null);
        }
        return Status.init(.SUCCESS);
    }

    /// Exports all records from this DBM to dest (any DBM with a set() method).
    pub fn export_(self: *SkipDBM, io: std.Io, dest: anytype) Status {
        var iter = self.makeCursor(io) catch return Status.init(.SYSTEM_ERROR);
        defer iter.deinit(io);
        var st = iter.first(io);
        if (st.code == .NOT_FOUND_ERROR) return Status.init(.SUCCESS);
        if (!st.isOk()) return st;
        while (true) {
            var key_list: std.ArrayList(u8) = .empty;
            defer key_list.deinit(self.allocator);
            var val_list: std.ArrayList(u8) = .empty;
            defer val_list.deinit(self.allocator);
            const st_get = iter.get( io,&key_list, &val_list);
            if (!st_get.isOk()) break;
            const st_set = dest.set( io,key_list.items, val_list.items, true, null);
            if (!st_set.isOk()) return st_set;
            st = iter.next(io);
            if (!st.isOk()) break;
        }
        return Status.init(.SUCCESS);
    }

    /// Atomically checks multiple expected conditions then applies multiple desired changes.
    pub fn compareExchangeMulti(
        self: *SkipDBM,
        io: std.Io,
        expected: []const struct { key: []const u8, value: dbm_mod.CompareExpected },
        desired: []const struct { key: []const u8, value: dbm_mod.CompareDesired },
    ) Status {
        for (expected) |cond| {
            var val_list: std.ArrayList(u8) = .empty;
            defer val_list.deinit(self.allocator);
            const get_st = self.get( io,cond.key, &val_list);
            switch (cond.value) {
                .absent => {
                    if (get_st.isOk()) return Status.init(.DUPLICATION_ERROR);
                },
                .any => {
                    if (!get_st.isOk()) return Status.init(.NOT_FOUND_ERROR);
                },
                .exact => |exp_val| {
                    if (!get_st.isOk()) return Status.init(.NOT_FOUND_ERROR);
                    if (!std.mem.eql(u8, val_list.items, exp_val)) return Status.init(.DUPLICATION_ERROR);
                },
            }
        }
        for (desired) |change| {
            switch (change.value) {
                .remove => {
                    const st = self.remove( io,change.key, null);
                    if (!st.isOk() and st.code != .NOT_FOUND_ERROR) return st;
                },
                .set => |new_val| {
                    const st = self.set( io,change.key, new_val, true, null);
                    if (!st.isOk()) return st;
                },
                .noop => {},
            }
        }
        return Status.init(.SUCCESS);
    }
};

// ---------------------------------------------------------------------------
// Reducer Functions (Phase 13)
// ---------------------------------------------------------------------------

pub fn reduceRemove(key: []const u8, values: []const []const u8, allocator: std.mem.Allocator) std.mem.Allocator.Error![][]const u8 {
    _ = key;
    var result: std.ArrayList([]const u8) = .empty;

    for (values) |val| {
        if (!std.mem.eql(u8, val, REMOVING_VALUE)) {
            const val_copy = try allocator.dupe(u8, val);
            try result.append(allocator, val_copy);
        }
    }
    return result.toOwnedSlice(allocator);
}

pub fn reduceToFirst(key: []const u8, values: []const []const u8, allocator: std.mem.Allocator) std.mem.Allocator.Error![][]const u8 {
    _ = key;
    const first_copy = try allocator.dupe(u8, values[0]);
    return allocator.dupe([]const u8, &.{first_copy});
}

pub fn reduceToLast(key: []const u8, values: []const []const u8, allocator: std.mem.Allocator) std.mem.Allocator.Error![][]const u8 {
    _ = key;
    const last_copy = try allocator.dupe(u8, values[values.len - 1]);
    return allocator.dupe([]const u8, &.{last_copy});
}

pub fn reduceToSecond(key: []const u8, values: []const []const u8, allocator: std.mem.Allocator) std.mem.Allocator.Error![][]const u8 {
    _ = key;
    const idx: usize = if (values.len >= 2) 1 else 0;
    const idx_copy = try allocator.dupe(u8, values[idx]);
    return allocator.dupe([]const u8, &.{idx_copy});
}

pub fn reduceConcat(key: []const u8, values: []const []const u8, allocator: std.mem.Allocator) std.mem.Allocator.Error![][]const u8 {
    _ = key;
    var total: usize = 0;
    for (values) |v| total += v.len;
    const result_str = try allocator.alloc(u8, total);
    var pos: usize = 0;
    for (values) |v| {
        @memcpy(result_str[pos .. pos + v.len], v);
        pos += v.len;
    }
    return allocator.dupe([]const u8, &.{result_str});
}

pub fn reduceConcatWithNull(key: []const u8, values: []const []const u8, allocator: std.mem.Allocator) std.mem.Allocator.Error![][]const u8 {
    _ = key;
    var total = if (values.len > 0) values.len - 1 else 0;
    for (values) |v| total += v.len;
    const result_str = try allocator.alloc(u8, total);
    var pos: usize = 0;
    for (values, 0..) |v, i| {
        @memcpy(result_str[pos .. pos + v.len], v);
        pos += v.len;
        if (i < values.len - 1) {
            result_str[pos] = 0x00;
            pos += 1;
        }
    }
    return allocator.dupe([]const u8, &.{result_str});
}

pub fn reduceConcatWithTab(key: []const u8, values: []const []const u8, allocator: std.mem.Allocator) std.mem.Allocator.Error![][]const u8 {
    _ = key;
    var total = if (values.len > 0) values.len - 1 else 0;
    for (values) |v| total += v.len;
    const result_str = try allocator.alloc(u8, total);
    var pos: usize = 0;
    for (values, 0..) |v, i| {
        @memcpy(result_str[pos .. pos + v.len], v);
        pos += v.len;
        if (i < values.len - 1) {
            result_str[pos] = '\t';
            pos += 1;
        }
    }
    return allocator.dupe([]const u8, &.{result_str});
}

pub fn reduceConcatWithLine(key: []const u8, values: []const []const u8, allocator: std.mem.Allocator) std.mem.Allocator.Error![][]const u8 {
    _ = key;
    var total = if (values.len > 0) values.len - 1 else 0;
    for (values) |v| total += v.len;
    const result_str = try allocator.alloc(u8, total);
    var pos: usize = 0;
    for (values, 0..) |v, i| {
        @memcpy(result_str[pos .. pos + v.len], v);
        pos += v.len;
        if (i < values.len - 1) {
            result_str[pos] = '\n';
            pos += 1;
        }
    }
    return allocator.dupe([]const u8, &.{result_str});
}

pub fn reduceToTotal(key: []const u8, values: []const []const u8, allocator: std.mem.Allocator) std.mem.Allocator.Error![][]const u8 {
    _ = key;
    var sum: i64 = 0;
    for (values) |v| {
        sum += str_util.strToInt(v, 0);
    }
    const sum_str = try std.fmt.allocPrint(allocator, "{d}", .{sum});
    return allocator.dupe([]const u8, &.{sum_str});
}

pub fn reduceToTotalBigEndian(key: []const u8, values: []const []const u8, allocator: std.mem.Allocator) std.mem.Allocator.Error![][]const u8 {
    _ = key;
    var sum: u64 = 0;
    for (values) |v| {
        sum +%= str_util.strToIntBigEndian(v);
    }
    var buf: [8]u8 = undefined;
    _ = str_util.intToStrBigEndian(sum, 8, &buf);
    const buf_copy = try allocator.dupe(u8, &buf);
    return allocator.dupe([]const u8, &.{buf_copy});
}

// ---------------------------------------------------------------------------
// Tests (Phase 1-2)
// ---------------------------------------------------------------------------

test "SkipDBM Phase 1: Constants defined" {
    try std.testing.expect(METADATA_SIZE == 128);
    try std.testing.expect(META_MAGIC_DATA.len == 9);
    try std.testing.expect(RECORD_MAGIC == 0xFF);
    try std.testing.expect(DEFAULT_OFFSET_WIDTH == 4);
    try std.testing.expect(DEFAULT_STEP_UNIT == 4);
    try std.testing.expect(DEFAULT_MAX_LEVEL == 14);
}

test "SkipDBM Phase 1: TuningParameters defaults" {
    const tp = TuningParameters{};
    try std.testing.expect(tp.offset_width == DEFAULT_OFFSET_WIDTH);
    try std.testing.expect(tp.step_unit == DEFAULT_STEP_UNIT);
    try std.testing.expect(tp.max_level == DEFAULT_MAX_LEVEL);
    try std.testing.expect(!tp.insert_in_order);
}

test "SkipDBM Phase 2: computeLevel basic" {
    // Record 0 divides evenly by every step indefinitely; the loop stops at max_level (not max_level-1).
    try std.testing.expect(computeLevel(0, 4, 8) == 8);
    try std.testing.expect(computeLevel(1, 4, 8) == 0);
    try std.testing.expect(computeLevel(4, 4, 8) == 1);
    try std.testing.expect(computeLevel(16, 4, 8) == 2);
    try std.testing.expect(computeLevel(64, 4, 8) == 3);
}

test "SkipDBM Phase 2: powI64" {
    try std.testing.expect(powI64(4, 0) == 1);
    try std.testing.expect(powI64(4, 1) == 4);
    try std.testing.expect(powI64(4, 2) == 16);
    try std.testing.expect(powI64(4, 3) == 64);
}

test "SkipDBM Phase 2: REMOVING_VALUE constant" {
    try std.testing.expect(REMOVING_VALUE.len == 7);
    try std.testing.expect(REMOVING_VALUE[0] == 0xDE);
    try std.testing.expect(REMOVING_VALUE[1] == 0xAD);
}

// --------------------------------------------------------------------------
// Test helpers
// --------------------------------------------------------------------------

/// Open a SkipDBM backed by a real file for writing.
/// Uses insert_in_order=true so that num_records is incremented during writes.
/// NOTE: writes are buffered to sorted_file and only flushed to the main file on close().
/// Tests that need to read back values must call close()+deinit(), then reopen with openSkipDB.
fn openSkipDB(alloc: std.mem.Allocator, path: []const u8) !SkipDBM {
    const std_file = try file_mod.StdFile.create(alloc);
    var db = try SkipDBM.init(std_file.asFile(), alloc, .{});
    const st = db.openAdvanced( std.testing.io,path, true, .{}, .{ .insert_in_order = true });
    if (!st.isOk()) {
        db.deinit(std.testing.io);
        return error.OpenFailed;
    }
    return db;
}

// --------------------------------------------------------------------------
// SkipDBM tests
// --------------------------------------------------------------------------

test "SkipDBM init with NullFile and deinit" {
    const alloc = std.testing.allocator;
    var db = try SkipDBM.init(file_mod.NullFile, alloc, .{});
    db.deinit(std.testing.io);
}

test "SkipDBM set and get basic round-trip" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);
    const file_path = try std.fmt.allocPrint(alloc, "{s}/test.skm", .{tmp_path});
    defer alloc.free(file_path);

    // Write phase: inserts go to sorted_file; num_records is updated in-memory.
    {
        var db = try openSkipDB(alloc, file_path);
        try std.testing.expect(db.set( std.testing.io,"alpha", "one", true, null).isOk());
        try std.testing.expect(db.set( std.testing.io,"beta", "two", true, null).isOk());
        try std.testing.expectEqual(@as(i64, 2), db.countSimple());
        _ = db.close(std.testing.io);
        db.deinit(std.testing.io);
    }

    // Read phase: reopen after close flushes sorted_file → main file.
    {
        var db = try openSkipDB(alloc, file_path);
        defer db.deinit(std.testing.io);

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);

        try std.testing.expect(db.get( std.testing.io,"alpha", &buf).isOk());
        try std.testing.expectEqualStrings("one", buf.items);

        buf.clearRetainingCapacity();
        try std.testing.expect(db.get( std.testing.io,"beta", &buf).isOk());
        try std.testing.expectEqualStrings("two", buf.items);

        _ = db.close(std.testing.io);
    }
}

test "SkipDBM.append concatenation with delimiter" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);
    const file_path = try std.fmt.allocPrint(alloc, "{s}/append.skm", .{tmp_path});
    defer alloc.free(file_path);

    // Write phase 1: set initial value and flush to disk.
    {
        var db = try openSkipDB(alloc, file_path);
        try std.testing.expect(db.set( std.testing.io,"key1", "hello", true, null).isOk());
        _ = db.close(std.testing.io);
        db.deinit(std.testing.io);
    }

    // Write phase 2: append reads "hello" from main file, writes "hello world" to sorted_file.
    {
        var db = try openSkipDB(alloc, file_path);
        try std.testing.expect(db.append( std.testing.io,"key1", "world", " ").isOk());
        _ = db.close(std.testing.io);
        db.deinit(std.testing.io);
    }

    // Read phase: verify concatenated value.
    {
        var db = try openSkipDB(alloc, file_path);
        defer db.deinit(std.testing.io);

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);
        try std.testing.expect(db.get( std.testing.io,"key1", &buf).isOk());
        try std.testing.expectEqualStrings("hello world", buf.items);

        _ = db.close(std.testing.io);
    }
}

test "SkipDBM.append creates new record when missing" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);
    const file_path = try std.fmt.allocPrint(alloc, "{s}/append_new.skm", .{tmp_path});
    defer alloc.free(file_path);

    // Write phase: append to a key that doesn't exist yet.
    {
        var db = try openSkipDB(alloc, file_path);
        try std.testing.expect(db.append( std.testing.io,"newkey", "first", "-").isOk());
        _ = db.close(std.testing.io);
        db.deinit(std.testing.io);
    }

    // Read phase: verify the record was created.
    {
        var db = try openSkipDB(alloc, file_path);
        defer db.deinit(std.testing.io);

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);
        try std.testing.expect(db.get( std.testing.io,"newkey", &buf).isOk());
        try std.testing.expectEqualStrings("first", buf.items);

        _ = db.close(std.testing.io);
    }
}

test "SkipDBM.processFirst invokes processor on first record" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);
    const file_path = try std.fmt.allocPrint(alloc, "{s}/pf.skm", .{tmp_path});
    defer alloc.free(file_path);

    // Write phase: insert records in sorted order so first = "aaa".
    {
        var db = try openSkipDB(alloc, file_path);
        try std.testing.expect(db.set( std.testing.io,"aaa", "val_a", true, null).isOk());
        try std.testing.expect(db.set( std.testing.io,"bbb", "val_b", true, null).isOk());
        try std.testing.expect(db.set( std.testing.io,"ccc", "val_c", true, null).isOk());
        _ = db.close(std.testing.io);
        db.deinit(std.testing.io);
    }

    // Process phase: reopen and invoke processFirst.
    {
        var db = try openSkipDB(alloc, file_path);
        defer db.deinit(std.testing.io);

        var visited_key: [32]u8 = undefined;
        var visited_key_len: usize = 0;
        var call_count: i32 = 0;

        const Proc = struct {
            key_buf: *[32]u8,
            key_len: *usize,
            count: *i32,

            pub fn processFull(self: @This(), key: []const u8, _val: []const u8) RecordAction {
                _ = _val;
                self.count.* += 1;
                const n = @min(key.len, 32);
                @memcpy(self.key_buf[0..n], key[0..n]);
                self.key_len.* = n;
                return .noop;
            }
            pub fn processEmpty(self: @This(), _key: []const u8) RecordAction {
                _ = self; _ = _key;
                return .noop;
            }
        };

        var proc: Proc = .{ .key_buf = &visited_key, .key_len = &visited_key_len, .count = &call_count };
        const st = db.processFirst( std.testing.io,Proc, &proc, false);
        try std.testing.expect(st.isOk());
        try std.testing.expectEqual(@as(i32, 1), call_count);
        // insert_in_order=true + sorted insertion → first record = "aaa"
        try std.testing.expectEqualStrings("aaa", visited_key[0..visited_key_len]);

        _ = db.close(std.testing.io);
    }
}

test "SkipDBM.processEach visits all records" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);
    const file_path = try std.fmt.allocPrint(alloc, "{s}/pe.skm", .{tmp_path});
    defer alloc.free(file_path);

    // Write phase.
    {
        var db = try openSkipDB(alloc, file_path);
        try std.testing.expect(db.set( std.testing.io,"k1", "v1", true, null).isOk());
        try std.testing.expect(db.set( std.testing.io,"k2", "v2", true, null).isOk());
        try std.testing.expect(db.set( std.testing.io,"k3", "v3", true, null).isOk());
        _ = db.close(std.testing.io);
        db.deinit(std.testing.io);
    }

    // Process phase.
    {
        var db = try openSkipDB(alloc, file_path);
        defer db.deinit(std.testing.io);

        var call_count: i32 = 0;

        const Proc = struct {
            count: *i32,
            pub fn processFull(self: @This(), _key: []const u8, _val: []const u8) RecordAction {
                _ = _key; _ = _val;
                self.count.* += 1;
                return .noop;
            }
            pub fn processEmpty(self: @This(), _key: []const u8) RecordAction {
                _ = self; _ = _key;
                return .noop;
            }
        };

        var proc: Proc = .{ .count = &call_count };
        const st = db.processEach( std.testing.io,Proc, &proc, false);
        try std.testing.expect(st.isOk());
        try std.testing.expectEqual(@as(i32, 3), call_count);

        _ = db.close(std.testing.io);
    }
}

test "SkipDBM.processMulti processes multiple keys" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);
    const file_path = try std.fmt.allocPrint(alloc, "{s}/pm.skm", .{tmp_path});
    defer alloc.free(file_path);

    // Write phase.
    {
        var db = try openSkipDB(alloc, file_path);
        try std.testing.expect(db.set( std.testing.io,"x1", "val1", true, null).isOk());
        try std.testing.expect(db.set( std.testing.io,"x2", "val2", true, null).isOk());
        _ = db.close(std.testing.io);
        db.deinit(std.testing.io);
    }

    // Process phase.
    {
        var db = try openSkipDB(alloc, file_path);
        defer db.deinit(std.testing.io);

        var call_count: i32 = 0;

        const Proc = struct {
            count: *i32,
            pub fn processFull(self: @This(), _key: []const u8, _val: []const u8) RecordAction {
                _ = _key; _ = _val;
                self.count.* += 1;
                return .noop;
            }
            pub fn processEmpty(self: @This(), _key: []const u8) RecordAction {
                _ = self; _ = _key;
                return .noop;
            }
        };

        var proc: Proc = .{ .count = &call_count };
        const keys = [_][]const u8{ "x1", "x2" };
        const procs = [_]*Proc{ &proc, &proc };
        const st = db.processMulti( std.testing.io,Proc, &keys, &procs, false);
        try std.testing.expect(st.isOk());
        try std.testing.expectEqual(@as(i32, 2), call_count);

        _ = db.close(std.testing.io);
    }
}

test "SkipDBM.get: null value buffer returns SUCCESS on found key" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", alloc);
    defer alloc.free(path);
    const full_path = try std.fmt.allocPrint(alloc, "{s}/test.skip", .{path});
    defer alloc.free(full_path);

    {
        var db = try openSkipDB(alloc, full_path);
        _ = db.set( std.testing.io,"exists", "hello", true, null);
        _ = db.close(std.testing.io);
        db.deinit(std.testing.io);
    }

    {
        var db = try openSkipDB(alloc, full_path);
        defer db.deinit(std.testing.io);

        // null value = existence check only
        const present = db.get( std.testing.io,"exists", null);
        try std.testing.expect(present.isOk());

        const absent = db.get( std.testing.io,"missing", null);
        try std.testing.expect(absent.code == .NOT_FOUND_ERROR);

        _ = db.close(std.testing.io);
    }
}

// ---------------------------------------------------------------------------
// Tests: compareExchange, increment, popFirst, pushLast
// ---------------------------------------------------------------------------

test "SkipDBM.compareExchange: match and exchange" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", alloc);
    defer alloc.free(path);
    const full_path = try std.fmt.allocPrint(alloc, "{s}/test.skip", .{path});
    defer alloc.free(full_path);

    {
        var db = try openSkipDB(alloc, full_path);
        try std.testing.expect(db.set( std.testing.io,"key", "foo", true, null).isOk());
        _ = db.close(std.testing.io);
        db.deinit(std.testing.io);
    }

    {
        var db = try openSkipDB(alloc, full_path);
        defer db.deinit(std.testing.io);

        var actual_buf: std.ArrayList(u8) = .empty;
        defer actual_buf.deinit(alloc);
        var found: bool = false;

        const st = db.compareExchange( std.testing.io,"key", .{ .exact = "foo" }, .{ .set = "bar" }, &actual_buf, &found);
        try std.testing.expect(st.isOk());
        try std.testing.expect(found == true);
        try std.testing.expectEqualStrings("foo", actual_buf.items);

        _ = db.close(std.testing.io);
    }

    {
        var db = try openSkipDB(alloc, full_path);
        defer db.deinit(std.testing.io);
        var val_buf: std.ArrayList(u8) = .empty;
        defer val_buf.deinit(alloc);
        const st = db.get( std.testing.io,"key", &val_buf);
        try std.testing.expect(st.isOk());
        try std.testing.expectEqualStrings("bar", val_buf.items);
        _ = db.close(std.testing.io);
    }
}

test "SkipDBM.compareExchange: mismatch returns INFEASIBLE_ERROR" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", alloc);
    defer alloc.free(path);
    const full_path = try std.fmt.allocPrint(alloc, "{s}/test.skip", .{path});
    defer alloc.free(full_path);

    {
        var db = try openSkipDB(alloc, full_path);
        try std.testing.expect(db.set( std.testing.io,"key", "old", true, null).isOk());
        _ = db.close(std.testing.io);
        db.deinit(std.testing.io);
    }

    {
        var db = try openSkipDB(alloc, full_path);
        defer db.deinit(std.testing.io);

        var actual_buf: std.ArrayList(u8) = .empty;
        defer actual_buf.deinit(alloc);
        var found: bool = false;

        const st = db.compareExchange( std.testing.io,"key", .{ .exact = "wrong" }, .{ .set = "new" }, &actual_buf, &found);
        try std.testing.expectEqual(Code.INFEASIBLE_ERROR, st.code);
        try std.testing.expect(found == true);
        try std.testing.expectEqualStrings("old", actual_buf.items);

        _ = db.close(std.testing.io);
    }

    {
        var db = try openSkipDB(alloc, full_path);
        defer db.deinit(std.testing.io);
        var val_buf: std.ArrayList(u8) = .empty;
        defer val_buf.deinit(alloc);
        const st = db.get( std.testing.io,"key", &val_buf);
        try std.testing.expect(st.isOk());
        try std.testing.expectEqualStrings("old", val_buf.items);
        _ = db.close(std.testing.io);
    }
}

test "SkipDBM.compareExchange: absent creates record" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", alloc);
    defer alloc.free(path);
    const full_path = try std.fmt.allocPrint(alloc, "{s}/test.skip", .{path});
    defer alloc.free(full_path);

    {
        var db = try openSkipDB(alloc, full_path);
        var found: bool = false;
        const st = db.compareExchange( std.testing.io,"newkey", .absent, .{ .set = "v" }, null, &found);
        try std.testing.expect(st.isOk());
        try std.testing.expect(found == false);
        _ = db.close(std.testing.io);
        db.deinit(std.testing.io);
    }

    {
        var db = try openSkipDB(alloc, full_path);
        defer db.deinit(std.testing.io);
        var val_buf: std.ArrayList(u8) = .empty;
        defer val_buf.deinit(alloc);
        const st = db.get( std.testing.io,"newkey", &val_buf);
        try std.testing.expect(st.isOk());
        try std.testing.expectEqualStrings("v", val_buf.items);
        _ = db.close(std.testing.io);
    }
}

test "SkipDBM.compareExchange: absent noop on missing key" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", alloc);
    defer alloc.free(path);
    const full_path = try std.fmt.allocPrint(alloc, "{s}/test.skip", .{path});
    defer alloc.free(full_path);

    {
        var db = try openSkipDB(alloc, full_path);
        var found: bool = false;
        const st = db.compareExchange( std.testing.io,"missing", .absent, .noop, null, &found);
        try std.testing.expect(st.isOk());
        try std.testing.expect(found == false);
        _ = db.close(std.testing.io);
        db.deinit(std.testing.io);
    }

    {
        var db = try openSkipDB(alloc, full_path);
        defer db.deinit(std.testing.io);
        const st = db.get( std.testing.io,"missing", null);
        try std.testing.expectEqual(Code.NOT_FOUND_ERROR, st.code);
        _ = db.close(std.testing.io);
    }
}

test "SkipDBM.compareExchange: any probe reads without writing" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", alloc);
    defer alloc.free(path);
    const full_path = try std.fmt.allocPrint(alloc, "{s}/test.skip", .{path});
    defer alloc.free(full_path);

    {
        var db = try openSkipDB(alloc, full_path);
        try std.testing.expect(db.set( std.testing.io,"key", "val", true, null).isOk());
        _ = db.close(std.testing.io);
        db.deinit(std.testing.io);
    }

    {
        var db = try openSkipDB(alloc, full_path);
        defer db.deinit(std.testing.io);

        var actual_buf: std.ArrayList(u8) = .empty;
        defer actual_buf.deinit(alloc);
        var found: bool = false;

        const st = db.compareExchange( std.testing.io,"key", .any, .noop, &actual_buf, &found);
        try std.testing.expect(st.isOk());
        try std.testing.expect(found == true);
        try std.testing.expectEqualStrings("val", actual_buf.items);

        _ = db.close(std.testing.io);
    }

    {
        var db = try openSkipDB(alloc, full_path);
        defer db.deinit(std.testing.io);
        var val_buf: std.ArrayList(u8) = .empty;
        defer val_buf.deinit(alloc);
        const st = db.get( std.testing.io,"key", &val_buf);
        try std.testing.expect(st.isOk());
        try std.testing.expectEqualStrings("val", val_buf.items);
        _ = db.close(std.testing.io);
    }
}

test "SkipDBM.compareExchange: desired remove deletes record" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", alloc);
    defer alloc.free(path);
    const full_path = try std.fmt.allocPrint(alloc, "{s}/test.skip", .{path});
    defer alloc.free(full_path);

    {
        var db = try openSkipDB(alloc, full_path);
        try std.testing.expect(db.set( std.testing.io,"key", "foo", true, null).isOk());
        _ = db.close(std.testing.io);
        db.deinit(std.testing.io);
    }

    {
        var db = try openSkipDB(alloc, full_path);
        const st = db.compareExchange( std.testing.io,"key", .{ .exact = "foo" }, .remove, null, null);
        try std.testing.expect(st.isOk());
        _ = db.close(std.testing.io);
        db.deinit(std.testing.io);
    }

    {
        var db = try openSkipDB(alloc, full_path);
        defer db.deinit(std.testing.io);
        const st = db.get( std.testing.io,"key", null);
        try std.testing.expectEqual(Code.NOT_FOUND_ERROR, st.code);
        _ = db.close(std.testing.io);
    }
}

test "SkipDBM.compareExchange: absent fails when key exists" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", alloc);
    defer alloc.free(path);
    const full_path = try std.fmt.allocPrint(alloc, "{s}/test.skip", .{path});
    defer alloc.free(full_path);

    {
        var db = try openSkipDB(alloc, full_path);
        try std.testing.expect(db.set( std.testing.io,"key", "x", true, null).isOk());
        _ = db.close(std.testing.io);
        db.deinit(std.testing.io);
    }

    {
        var db = try openSkipDB(alloc, full_path);
        defer db.deinit(std.testing.io);

        var actual_buf: std.ArrayList(u8) = .empty;
        defer actual_buf.deinit(alloc);
        var found: bool = false;

        const st = db.compareExchange( std.testing.io,"key", .absent, .{ .set = "y" }, &actual_buf, &found);
        try std.testing.expectEqual(Code.INFEASIBLE_ERROR, st.code);
        try std.testing.expect(found == true);
        try std.testing.expectEqualStrings("x", actual_buf.items);

        _ = db.close(std.testing.io);
    }
}

test "SkipDBM.increment: fresh key uses initial+delta" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", alloc);
    defer alloc.free(path);
    const full_path = try std.fmt.allocPrint(alloc, "{s}/test.skip", .{path});
    defer alloc.free(full_path);

    {
        var db = try openSkipDB(alloc, full_path);
        var current: i64 = 0;
        const st = db.increment( std.testing.io,"counter", 3, &current, 10);
        try std.testing.expect(st.isOk());
        try std.testing.expectEqual(@as(i64, 13), current);
        _ = db.close(std.testing.io);
        db.deinit(std.testing.io);
    }

    {
        var db = try openSkipDB(alloc, full_path);
        defer db.deinit(std.testing.io);
        var val_buf: std.ArrayList(u8) = .empty;
        defer val_buf.deinit(alloc);
        const st = db.get( std.testing.io,"counter", &val_buf);
        try std.testing.expect(st.isOk());
        try std.testing.expectEqual(@as(usize, 8), val_buf.items.len);
        const decoded = @as(i64, @bitCast(str_util.strToIntBigEndian(val_buf.items)));
        try std.testing.expectEqual(@as(i64, 13), decoded);
        _ = db.close(std.testing.io);
    }
}

test "SkipDBM.increment: existing key adds delta" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", alloc);
    defer alloc.free(path);
    const full_path = try std.fmt.allocPrint(alloc, "{s}/test.skip", .{path});
    defer alloc.free(full_path);

    {
        var db = try openSkipDB(alloc, full_path);
        var buf: [8]u8 = undefined;
        const enc = str_util.intToStrBigEndian(@as(u64, @bitCast(@as(i64, 10))), 8, &buf);
        try std.testing.expect(db.set( std.testing.io,"counter", enc, true, null).isOk());
        _ = db.close(std.testing.io);
        db.deinit(std.testing.io);
    }

    {
        var db = try openSkipDB(alloc, full_path);
        defer db.deinit(std.testing.io);

        var current: i64 = 0;
        const st = db.increment( std.testing.io,"counter", 5, &current, 0);
        try std.testing.expect(st.isOk());
        try std.testing.expectEqual(@as(i64, 15), current);

        _ = db.close(std.testing.io);
    }

    {
        var db = try openSkipDB(alloc, full_path);
        defer db.deinit(std.testing.io);
        var val_buf: std.ArrayList(u8) = .empty;
        defer val_buf.deinit(alloc);
        const st = db.get( std.testing.io,"counter", &val_buf);
        try std.testing.expect(st.isOk());
        const decoded = @as(i64, @bitCast(str_util.strToIntBigEndian(val_buf.items)));
        try std.testing.expectEqual(@as(i64, 15), decoded);
        _ = db.close(std.testing.io);
    }
}

test "SkipDBM.increment: INT64MIN probe reads without writing" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", alloc);
    defer alloc.free(path);
    const full_path = try std.fmt.allocPrint(alloc, "{s}/test.skip", .{path});
    defer alloc.free(full_path);

    {
        var db = try openSkipDB(alloc, full_path);
        var buf: [8]u8 = undefined;
        const enc = str_util.intToStrBigEndian(@as(u64, @bitCast(@as(i64, 7))), 8, &buf);
        try std.testing.expect(db.set( std.testing.io,"counter", enc, true, null).isOk());
        _ = db.close(std.testing.io);
        db.deinit(std.testing.io);
    }

    {
        var db = try openSkipDB(alloc, full_path);
        defer db.deinit(std.testing.io);

        var current: i64 = 0;
        const st = db.increment( std.testing.io,"counter", lib_common.INT64MIN, &current, 0);
        try std.testing.expect(st.isOk());
        try std.testing.expectEqual(@as(i64, 7), current);

        _ = db.close(std.testing.io);
    }

    {
        var db = try openSkipDB(alloc, full_path);
        defer db.deinit(std.testing.io);
        var val_buf: std.ArrayList(u8) = .empty;
        defer val_buf.deinit(alloc);
        const st = db.get( std.testing.io,"counter", &val_buf);
        try std.testing.expect(st.isOk());
        const decoded = @as(i64, @bitCast(str_util.strToIntBigEndian(val_buf.items)));
        try std.testing.expectEqual(@as(i64, 7), decoded);
        _ = db.close(std.testing.io);
    }
}

test "SkipDBM.increment: INT64MIN probe on missing key returns initial" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", alloc);
    defer alloc.free(path);
    const full_path = try std.fmt.allocPrint(alloc, "{s}/test.skip", .{path});
    defer alloc.free(full_path);

    {
        var db = try openSkipDB(alloc, full_path);
        var current: i64 = 0;
        const st = db.increment( std.testing.io,"missing", lib_common.INT64MIN, &current, 42);
        try std.testing.expect(st.isOk());
        try std.testing.expectEqual(@as(i64, 42), current);
        _ = db.close(std.testing.io);
        db.deinit(std.testing.io);
    }

    {
        var db = try openSkipDB(alloc, full_path);
        defer db.deinit(std.testing.io);
        const st = db.get( std.testing.io,"missing", null);
        try std.testing.expectEqual(Code.NOT_FOUND_ERROR, st.code);
        _ = db.close(std.testing.io);
    }
}

test "SkipDBM.popFirst: returns and removes first record" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", alloc);
    defer alloc.free(path);
    const full_path = try std.fmt.allocPrint(alloc, "{s}/test.skip", .{path});
    defer alloc.free(full_path);

    {
        var db = try openSkipDB(alloc, full_path);
        try std.testing.expect(db.set( std.testing.io,"a", "val_a", true, null).isOk());
        try std.testing.expect(db.set( std.testing.io,"b", "val_b", true, null).isOk());
        try std.testing.expect(db.set( std.testing.io,"c", "val_c", true, null).isOk());
        _ = db.close(std.testing.io);
        db.deinit(std.testing.io);
    }

    {
        var db = try openSkipDB(alloc, full_path);
        defer db.deinit(std.testing.io);

        var key_buf: std.ArrayList(u8) = .empty;
        defer key_buf.deinit(alloc);
        var val_buf: std.ArrayList(u8) = .empty;
        defer val_buf.deinit(alloc);

        const st = db.popFirst( std.testing.io,&key_buf, &val_buf);
        try std.testing.expect(st.isOk());
        // After opening existing DB, first should be lexicographically first
        try std.testing.expectEqualStrings("a", key_buf.items);
        try std.testing.expectEqualStrings("val_a", val_buf.items);

        _ = db.close(std.testing.io);
    }

    {
        var db = try openSkipDB(alloc, full_path);
        defer db.deinit(std.testing.io);
        // Verify that "a" was actually removed (doesn't exist anymore)
        const st = db.get( std.testing.io,"a", null);
        try std.testing.expectEqual(Code.NOT_FOUND_ERROR, st.code);
        _ = db.close(std.testing.io);
    }
}

test "SkipDBM.popFirst: empty returns NOT_FOUND_ERROR" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", alloc);
    defer alloc.free(path);
    const full_path = try std.fmt.allocPrint(alloc, "{s}/test.skip", .{path});
    defer alloc.free(full_path);

    {
        var db = try openSkipDB(alloc, full_path);
        const st = db.popFirst( std.testing.io,null, null);
        try std.testing.expectEqual(Code.NOT_FOUND_ERROR, st.code);
        _ = db.close(std.testing.io);
        db.deinit(std.testing.io);
    }
}

test "SkipDBM.popFirst: returns lexicographic first" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", alloc);
    defer alloc.free(path);
    const full_path = try std.fmt.allocPrint(alloc, "{s}/test.skip", .{path});
    defer alloc.free(full_path);

    // insert_in_order=true requires keys in sorted order; "a" < "b" < "c"
    {
        var db = try openSkipDB(alloc, full_path);
        try std.testing.expect(db.set( std.testing.io,"a", "val_a", true, null).isOk());
        try std.testing.expect(db.set( std.testing.io,"b", "val_b", true, null).isOk());
        try std.testing.expect(db.set( std.testing.io,"c", "val_c", true, null).isOk());
        _ = db.close(std.testing.io);
        db.deinit(std.testing.io);
    }

    {
        var db = try openSkipDB(alloc, full_path);
        defer db.deinit(std.testing.io);

        var key_buf: std.ArrayList(u8) = .empty;
        defer key_buf.deinit(alloc);

        const st = db.popFirst( std.testing.io,&key_buf, null);
        try std.testing.expect(st.isOk());
        try std.testing.expectEqualStrings("a", key_buf.items);

        _ = db.close(std.testing.io);
    }
}

test "SkipDBM.pushLast: creates record with key_out" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", alloc);
    defer alloc.free(path);
    const full_path = try std.fmt.allocPrint(alloc, "{s}/test.skip", .{path});
    defer alloc.free(full_path);

    var generated_key: [8]u8 = undefined;

    {
        var db = try openSkipDB(alloc, full_path);
        var key_buf: std.ArrayList(u8) = .empty;
        defer key_buf.deinit(alloc);

        const st = db.pushLast( std.testing.io,"hello", -1, &key_buf);
        try std.testing.expect(st.isOk());
        try std.testing.expectEqual(@as(usize, 8), key_buf.items.len);
        @memcpy(generated_key[0..8], key_buf.items[0..8]);

        _ = db.close(std.testing.io);
        db.deinit(std.testing.io);
    }

    {
        var db = try openSkipDB(alloc, full_path);
        defer db.deinit(std.testing.io);
        var val_buf: std.ArrayList(u8) = .empty;
        defer val_buf.deinit(alloc);
        const st = db.get( std.testing.io,&generated_key, &val_buf);
        try std.testing.expect(st.isOk());
        try std.testing.expectEqualStrings("hello", val_buf.items);
        _ = db.close(std.testing.io);
    }
}

test "SkipDBM.pushLast: two pushes generate different keys" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", alloc);
    defer alloc.free(path);
    const full_path = try std.fmt.allocPrint(alloc, "{s}/test.skip", .{path});
    defer alloc.free(full_path);

    var key1_data: [8]u8 = undefined;
    var key2_data: [8]u8 = undefined;

    {
        var db = try openSkipDB(alloc, full_path);
        var key1: std.ArrayList(u8) = .empty;
        defer key1.deinit(alloc);
        var key2: std.ArrayList(u8) = .empty;
        defer key2.deinit(alloc);

        const st1 = db.pushLast( std.testing.io,"a", 1000.0, &key1);
        const st2 = db.pushLast( std.testing.io,"b", 2000.0, &key2);

        try std.testing.expect(st1.isOk());
        try std.testing.expect(st2.isOk());
        try std.testing.expectEqual(@as(usize, 8), key1.items.len);
        try std.testing.expectEqual(@as(usize, 8), key2.items.len);

        @memcpy(key1_data[0..8], key1.items[0..8]);
        @memcpy(key2_data[0..8], key2.items[0..8]);

        _ = db.close(std.testing.io);
        db.deinit(std.testing.io);
    }

    {
        var db = try openSkipDB(alloc, full_path);
        defer db.deinit(std.testing.io);

        var val1: std.ArrayList(u8) = .empty;
        defer val1.deinit(alloc);
        var val2: std.ArrayList(u8) = .empty;
        defer val2.deinit(alloc);

        const st1 = db.get( std.testing.io,&key1_data, &val1);
        const st2 = db.get( std.testing.io,&key2_data, &val2);

        try std.testing.expect(st1.isOk());
        try std.testing.expect(st2.isOk());
        try std.testing.expectEqualStrings("a", val1.items);
        try std.testing.expectEqualStrings("b", val2.items);

        _ = db.close(std.testing.io);
    }
}

test "SkipDBM.pushLast: pop-after-push round-trips value" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", alloc);
    defer alloc.free(path);
    const full_path = try std.fmt.allocPrint(alloc, "{s}/test.skip", .{path});
    defer alloc.free(full_path);

    {
        var db = try openSkipDB(alloc, full_path);
        var key_buf: std.ArrayList(u8) = .empty;
        defer key_buf.deinit(alloc);

        const st = db.pushLast( std.testing.io,"round-trip", -1, &key_buf);
        try std.testing.expect(st.isOk());

        _ = db.close(std.testing.io);
        db.deinit(std.testing.io);
    }

    {
        var db = try openSkipDB(alloc, full_path);
        defer db.deinit(std.testing.io);

        var key_buf: std.ArrayList(u8) = .empty;
        defer key_buf.deinit(alloc);
        var val_buf: std.ArrayList(u8) = .empty;
        defer val_buf.deinit(alloc);

        const st = db.popFirst( std.testing.io,&key_buf, &val_buf);
        try std.testing.expect(st.isOk());
        try std.testing.expectEqualStrings("round-trip", val_buf.items);

        _ = db.close(std.testing.io);
    }
}

// ---------------------------------------------------------------------------
// SkipDBM lifecycle, CRUD, iterator, and UpdateLogger tests
// ---------------------------------------------------------------------------

test "SkipDBM: open/close lifecycle and isOpen" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf)];
    const file_path = try std.fmt.allocPrint(alloc, "{s}/lifecycle.tks", .{dir_path});
    defer alloc.free(file_path);

    const sf = try file_mod.StdFile.create(alloc);
    var db = try SkipDBM.init(sf.asFile(), alloc, .{});
    defer db.deinit(std.testing.io);

    try std.testing.expect(!db.isOpen());
    try std.testing.expect(db.open( std.testing.io,file_path, true, .{}).isOk());
    try std.testing.expect(db.isOpen());
    try std.testing.expect(db.close(std.testing.io).isOk());
    try std.testing.expect(!db.isOpen());
}

test "SkipDBM: set, get, remove, countSimple" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf)];
    const file_path = try std.fmt.allocPrint(alloc, "{s}/crud.tks", .{dir_path});
    defer alloc.free(file_path);

    // SkipDBM is append-only / log-structured. Writes go to sorted_file and are
    // flushed to the main file only on close(). get() reads from the main file, so
    // values are visible only after a close+reopen cycle. remove() appends a tombstone;
    // countSimple reflects in-memory record count during the open session.

    // Write phase: insert two records and verify in-memory count.
    {
        var db = try openSkipDB(alloc, file_path);
        try std.testing.expect(db.set( std.testing.io,"alpha", "one", true, null).isOk());
        try std.testing.expect(db.set( std.testing.io,"beta", "two", true, null).isOk());
        try std.testing.expectEqual(@as(i64, 2), db.countSimple());
        // missing key is not found even before the merge.
        try std.testing.expect(db.get( std.testing.io,"missing", null).code == .NOT_FOUND_ERROR);
        // remove appends a tombstone and succeeds.
        try std.testing.expect(db.remove( std.testing.io,"alpha", null).isOk());
        _ = db.close(std.testing.io);
        db.deinit(std.testing.io);
    }

    // Read phase: reopen after close to verify the merge result.
    {
        var db = try openSkipDB(alloc, file_path);
        defer db.deinit(std.testing.io);

        var val: std.ArrayList(u8) = .empty;
        defer val.deinit(alloc);

        // beta was set and should be readable after merge.
        try std.testing.expect(db.get( std.testing.io,"beta", &val).isOk());
        try std.testing.expectEqualStrings("two", val.items);

        // missing key still returns NOT_FOUND_ERROR.
        try std.testing.expect(db.get( std.testing.io,"missing", null).code == .NOT_FOUND_ERROR);

        _ = db.close(std.testing.io);
    }
}

test "SkipDBM: iterator forward traversal" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf)];
    const file_path = try std.fmt.allocPrint(alloc, "{s}/iter.tks", .{dir_path});
    defer alloc.free(file_path);

    // Write phase: insert three records in lexicographic order, then close to flush.
    {
        var db = try openSkipDB(alloc, file_path);
        try std.testing.expect(db.set( std.testing.io,"aaa", "v1", true, null).isOk());
        try std.testing.expect(db.set( std.testing.io,"bbb", "v2", true, null).isOk());
        try std.testing.expect(db.set( std.testing.io,"ccc", "v3", true, null).isOk());
        _ = db.close(std.testing.io);
        db.deinit(std.testing.io);
    }

    // Read phase: reopen and iterate.
    {
        var db = try openSkipDB(alloc, file_path);
        defer db.deinit(std.testing.io);

        var iter = try db.makeCursor(std.testing.io);
        defer iter.deinit(std.testing.io);
        try std.testing.expect(iter.first(std.testing.io).isOk());

        var seen: usize = 0;
        while (true) {
            var key: std.ArrayList(u8) = .empty;
            defer key.deinit(alloc);
            var value: std.ArrayList(u8) = .empty;
            defer value.deinit(alloc);

            const st = iter.get( std.testing.io,&key, &value);
            if (st.code == .NOT_FOUND_ERROR) break;
            try std.testing.expect(st.isOk());
            try std.testing.expect(key.items.len > 0);
            try std.testing.expect(value.items.len > 0);
            seen += 1;
            _ = iter.next(std.testing.io);
        }
        try std.testing.expectEqual(@as(usize, 3), seen);

        _ = db.close(std.testing.io);
    }
}

test "SkipDBM: Zig-style Iterator iterate()" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf)];
    const file_path = try std.fmt.allocPrint(alloc, "{s}/iter_zig.tks", .{dir_path});
    defer alloc.free(file_path);

    // Write phase: insert records and flush.
    {
        var db = try openSkipDB(alloc, file_path);
        try std.testing.expect(db.set( std.testing.io,"aaa", "v1", true, null).isOk());
        try std.testing.expect(db.set( std.testing.io,"bbb", "v2", true, null).isOk());
        try std.testing.expect(db.set( std.testing.io,"ccc", "v3", true, null).isOk());
        _ = db.close(std.testing.io);
        db.deinit(std.testing.io);
    }

    // Read phase: use Zig-style iterator.
    {
        var db = try openSkipDB(alloc, file_path);
        defer db.deinit(std.testing.io);

        var iter = try db.iterate(alloc, std.testing.io);
        defer iter.deinit(std.testing.io);

        var count: usize = 0;
        while (try iter.next(std.testing.io)) |entry| {
            try std.testing.expect(entry.key.len > 0);
            try std.testing.expect(entry.value.len > 0);
            count += 1;
        }
        try std.testing.expectEqual(@as(usize, 3), count);

        _ = db.close(std.testing.io);
    }
}

test "SkipDBM: Zig-style Iterator iterateFrom(std.testing.io) with lifetime contract" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf)];
    const file_path = try std.fmt.allocPrint(alloc, "{s}/iter_from.tks", .{dir_path});
    defer alloc.free(file_path);

    // Write phase: insert records and flush.
    {
        var db = try openSkipDB(alloc, file_path);
        try std.testing.expect(db.set( std.testing.io,"aaa", "v1", true, null).isOk());
        try std.testing.expect(db.set( std.testing.io,"bbb", "v2", true, null).isOk());
        try std.testing.expect(db.set( std.testing.io,"ccc", "v3", true, null).isOk());
        _ = db.close(std.testing.io);
        db.deinit(std.testing.io);
    }

    // Read phase: iterateFrom "bbb" and demonstrate lifetime contract.
    {
        var db = try openSkipDB(alloc, file_path);
        defer db.deinit(std.testing.io);

        var iter = try db.iterateFrom( alloc, std.testing.io,"bbb");
        defer iter.deinit(std.testing.io);

        const first = try iter.next(std.testing.io);
        try std.testing.expect(first != null);
        try std.testing.expect(std.mem.startsWith(u8, first.?.key, "b"));

        // Copy the key to demonstrate the lifetime contract.
        const key_copy = try alloc.dupe(u8, first.?.key);
        defer alloc.free(key_copy);

        // Second next() — first.?.key is now invalid, but key_copy is safe.
        const second = try iter.next(std.testing.io);
        try std.testing.expect(second != null);
        try std.testing.expect(std.mem.startsWith(u8, second.?.key, "c"));

        // Verify the copy is still valid.
        try std.testing.expectEqualStrings("bbb", key_copy);

        _ = db.close(std.testing.io);
    }
}

// Mock UpdateLogger shared by SkipDBM logger tests.
// Note: SkipDBM.setUpdateLogger is a public stub that does not wire through to
// impl.update_logger. Tests set impl.update_logger directly so that the
// internal writeSet/writeRemove/writeClear call sites are exercised.
const SkipMockLoggerCtx = struct {
    writeSet_count: i32 = 0,
    writeRemove_count: i32 = 0,
    writeClear_count: i32 = 0,
};

fn skipMockWriteSet(ctx: *anyopaque, _: []const u8, _: []const u8) Status {
    const mock: *SkipMockLoggerCtx = @ptrCast(@alignCast(ctx));
    mock.writeSet_count += 1;
    return Status.init(.SUCCESS);
}

fn skipMockWriteRemove(ctx: *anyopaque, _: []const u8) Status {
    const mock: *SkipMockLoggerCtx = @ptrCast(@alignCast(ctx));
    mock.writeRemove_count += 1;
    return Status.init(.SUCCESS);
}

fn skipMockWriteClear(ctx: *anyopaque) Status {
    const mock: *SkipMockLoggerCtx = @ptrCast(@alignCast(ctx));
    mock.writeClear_count += 1;
    return Status.init(.SUCCESS);
}

test "SkipDBM: UpdateLogger integration" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf)];
    const file_path = try std.fmt.allocPrint(alloc, "{s}/logger.tks", .{dir_path});
    defer alloc.free(file_path);

    // Use separate phases so close() is only called after set/remove without clear.
    // clear() discards the sorter, making a subsequent explicit close() unsafe;
    // deinit() handles partial teardown correctly and is used after clear().

    // Phase 1: verify writeSet and writeRemove.
    {
        var db = try openSkipDB(alloc, file_path);
        defer db.deinit(std.testing.io);

        var mock_ctx: SkipMockLoggerCtx = .{};
        var mock_logger: UpdateLogger = .{
            .ctx = @ptrCast(@alignCast(&mock_ctx)),
            .vtable = &.{
                .writeSet = skipMockWriteSet,
                .writeRemove = skipMockWriteRemove,
                .writeClear = skipMockWriteClear,
            },
        };
        // setUpdateLogger is a no-op stub; wire directly to impl.
        db.impl.update_logger = &mock_logger;

        try std.testing.expect(db.set( std.testing.io,"key1", "val1", true, null).isOk());
        try std.testing.expect(mock_ctx.writeSet_count > 0);

        try std.testing.expect(db.remove( std.testing.io,"key1", null).isOk());
        try std.testing.expect(mock_ctx.writeRemove_count > 0);

        _ = db.close(std.testing.io);
    }

    // Phase 2: verify writeClear — use a fresh file so the db is in a known state.
    {
        var db = try openSkipDB(alloc, file_path);
        // Do NOT call close() after clear() — clear() discards the sorter and
        // close() would panic trying to finish a null sorter. deinit() is safe.
        defer db.deinit(std.testing.io);

        var mock_ctx: SkipMockLoggerCtx = .{};
        var mock_logger: UpdateLogger = .{
            .ctx = @ptrCast(@alignCast(&mock_ctx)),
            .vtable = &.{
                .writeSet = skipMockWriteSet,
                .writeRemove = skipMockWriteRemove,
                .writeClear = skipMockWriteClear,
            },
        };
        db.impl.update_logger = &mock_logger;

        try std.testing.expect(db.set( std.testing.io,"key2", "val2", true, null).isOk());
        const pre_clear = mock_ctx.writeClear_count;
        try std.testing.expect(db.clear(std.testing.io).isOk());
        try std.testing.expect(mock_ctx.writeClear_count > pre_clear);
    }
}

test "SkipDBM.*Multi: bulk set/get/remove/append" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);
    const file_path = try std.fmt.allocPrint(alloc, "{s}/multi.tks", .{tmp_path});
    defer alloc.free(file_path);

    const pairs = [_][2][]const u8{
        .{ "key1", "val1" },
        .{ "key2", "val2" },
        .{ "key3", "val3" },
    };

    // Write phase: setMulti then close to flush to main file.
    {
        var db = try openSkipDB(alloc, file_path);
        try std.testing.expect(db.setMulti( std.testing.io,&pairs, true).isOk());
        _ = db.close(std.testing.io);
        db.deinit(std.testing.io);
    }

    // Read phase: getMulti — two found, one missing.
    {
        var db = try openSkipDB(alloc, file_path);

        var records = std.StringHashMap([]u8).init(alloc);
        defer {
            var it = records.iterator();
            while (it.next()) |e| {
                alloc.free(e.key_ptr.*);
                alloc.free(e.value_ptr.*);
            }
            records.deinit();
        }
        const get_st = db.getMulti( std.testing.io,&.{ "key1", "key2", "missing" }, &records);
        try std.testing.expectEqual(Code.NOT_FOUND_ERROR, get_st.code);
        try std.testing.expectEqual(@as(usize, 2), records.count());

        _ = db.close(std.testing.io);
        db.deinit(std.testing.io);
    }

    // Remove phase: removeMulti then close to flush tombstones.
    {
        var db = try openSkipDB(alloc, file_path);
        try std.testing.expect(db.removeMulti( std.testing.io,&.{ "key1", "key2" }).isOk());
        _ = db.close(std.testing.io);
        db.deinit(std.testing.io);
    }

    // Append phase: appendMulti then close to flush.
    {
        var db = try openSkipDB(alloc, file_path);
        const app = [_][2][]const u8{.{ "key3", "_appended" }};
        try std.testing.expect(db.appendMulti( std.testing.io,&app, "").isOk());
        _ = db.close(std.testing.io);
        db.deinit(std.testing.io);
    }

    // Verify phase: reopen and read back key3.
    {
        var db = try openSkipDB(alloc, file_path);
        defer db.deinit(std.testing.io);

        var val_buf: std.ArrayList(u8) = .empty;
        defer val_buf.deinit(alloc);
        try std.testing.expect(db.get( std.testing.io,"key3", &val_buf).isOk());
        try std.testing.expectEqualStrings("val3_appended", val_buf.items);

        _ = db.close(std.testing.io);
    }
}

// --------------------------------------------------------------------------
// Cursor navigation tests (file-backed) — exercise io threading through
// SkipRecord.search / readMetadataKey / readBody on real file I/O.
// --------------------------------------------------------------------------

test "SkipDBM.Cursor: jump to specific key" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf)];
    const file_path = try std.fmt.allocPrint(alloc, "{s}/cur_jump.tks", .{dir_path});
    defer alloc.free(file_path);

    {
        var db = try openSkipDB(alloc, file_path);
        try std.testing.expect(db.set(std.testing.io, "aaa", "v1", true, null).isOk());
        try std.testing.expect(db.set(std.testing.io, "bbb", "v2", true, null).isOk());
        try std.testing.expect(db.set(std.testing.io, "ccc", "v3", true, null).isOk());
        _ = db.close(std.testing.io);
        db.deinit(std.testing.io);
    }

    {
        var db = try openSkipDB(alloc, file_path);
        defer db.deinit(std.testing.io);

        var cur = try db.makeCursor(std.testing.io);
        defer cur.deinit(std.testing.io);

        try std.testing.expect(cur.jump(std.testing.io, "bbb").isOk());

        var key: std.ArrayList(u8) = .empty;
        defer key.deinit(alloc);
        var value: std.ArrayList(u8) = .empty;
        defer value.deinit(alloc);
        try std.testing.expect(cur.get(std.testing.io, &key, &value).isOk());
        try std.testing.expectEqualStrings("bbb", key.items);
        try std.testing.expectEqualStrings("v2", value.items);

        _ = db.close(std.testing.io);
    }
}

test "SkipDBM.Cursor: jumpLower inclusive and exclusive" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf)];
    const file_path = try std.fmt.allocPrint(alloc, "{s}/cur_jl.tks", .{dir_path});
    defer alloc.free(file_path);

    {
        var db = try openSkipDB(alloc, file_path);
        try std.testing.expect(db.set(std.testing.io, "aaa", "v1", true, null).isOk());
        try std.testing.expect(db.set(std.testing.io, "bbb", "v2", true, null).isOk());
        try std.testing.expect(db.set(std.testing.io, "ccc", "v3", true, null).isOk());
        _ = db.close(std.testing.io);
        db.deinit(std.testing.io);
    }

    {
        var db = try openSkipDB(alloc, file_path);
        defer db.deinit(std.testing.io);

        // inclusive=true on existing key returns that key
        var cur = try db.makeCursor(std.testing.io);
        defer cur.deinit(std.testing.io);
        try std.testing.expect(cur.jumpLower(std.testing.io, "bbb", true).isOk());
        var key: std.ArrayList(u8) = .empty;
        defer key.deinit(alloc);
        try std.testing.expect(cur.get(std.testing.io, &key, null).isOk());
        try std.testing.expectEqualStrings("bbb", key.items);

        // inclusive=false on existing key returns the previous key
        var cur2 = try db.makeCursor(std.testing.io);
        defer cur2.deinit(std.testing.io);
        try std.testing.expect(cur2.jumpLower(std.testing.io, "bbb", false).isOk());
        var key2: std.ArrayList(u8) = .empty;
        defer key2.deinit(alloc);
        try std.testing.expect(cur2.get(std.testing.io, &key2, null).isOk());
        try std.testing.expectEqualStrings("aaa", key2.items);

        _ = db.close(std.testing.io);
    }
}

test "SkipDBM.Cursor: jumpUpper inclusive and exclusive" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf)];
    const file_path = try std.fmt.allocPrint(alloc, "{s}/cur_ju.tks", .{dir_path});
    defer alloc.free(file_path);

    {
        var db = try openSkipDB(alloc, file_path);
        try std.testing.expect(db.set(std.testing.io, "aaa", "v1", true, null).isOk());
        try std.testing.expect(db.set(std.testing.io, "bbb", "v2", true, null).isOk());
        try std.testing.expect(db.set(std.testing.io, "ccc", "v3", true, null).isOk());
        _ = db.close(std.testing.io);
        db.deinit(std.testing.io);
    }

    {
        var db = try openSkipDB(alloc, file_path);
        defer db.deinit(std.testing.io);

        // inclusive=true on existing key returns that key
        var cur = try db.makeCursor(std.testing.io);
        defer cur.deinit(std.testing.io);
        try std.testing.expect(cur.jumpUpper(std.testing.io, "bbb", true).isOk());
        var key: std.ArrayList(u8) = .empty;
        defer key.deinit(alloc);
        try std.testing.expect(cur.get(std.testing.io, &key, null).isOk());
        try std.testing.expectEqualStrings("bbb", key.items);

        // inclusive=false on existing key returns the next key
        var cur2 = try db.makeCursor(std.testing.io);
        defer cur2.deinit(std.testing.io);
        try std.testing.expect(cur2.jumpUpper(std.testing.io, "bbb", false).isOk());
        var key2: std.ArrayList(u8) = .empty;
        defer key2.deinit(alloc);
        try std.testing.expect(cur2.get(std.testing.io, &key2, null).isOk());
        try std.testing.expectEqualStrings("ccc", key2.items);

        _ = db.close(std.testing.io);
    }
}

test "SkipDBM.Cursor: previous traversal" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf)];
    const file_path = try std.fmt.allocPrint(alloc, "{s}/cur_prev.tks", .{dir_path});
    defer alloc.free(file_path);

    {
        var db = try openSkipDB(alloc, file_path);
        try std.testing.expect(db.set(std.testing.io, "aaa", "v1", true, null).isOk());
        try std.testing.expect(db.set(std.testing.io, "bbb", "v2", true, null).isOk());
        try std.testing.expect(db.set(std.testing.io, "ccc", "v3", true, null).isOk());
        _ = db.close(std.testing.io);
        db.deinit(std.testing.io);
    }

    {
        var db = try openSkipDB(alloc, file_path);
        defer db.deinit(std.testing.io);

        var cur = try db.makeCursor(std.testing.io);
        defer cur.deinit(std.testing.io);

        try std.testing.expect(cur.last(std.testing.io).isOk());

        const expected = [_][]const u8{ "ccc", "bbb", "aaa" };
        for (expected) |expect_key| {
            var key: std.ArrayList(u8) = .empty;
            defer key.deinit(alloc);
            try std.testing.expect(cur.get(std.testing.io, &key, null).isOk());
            try std.testing.expectEqualStrings(expect_key, key.items);
            _ = cur.previous(std.testing.io);
        }

        _ = db.close(std.testing.io);
    }
}