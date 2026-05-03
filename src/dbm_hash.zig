// Zig 0.15.2 port of tkrzw HashDBM — file-backed hash table database.
//
// Architecture notes:
//   - Records are stored in a flat file after a 128-byte header and 1008-byte FBP section.
//   - Hash buckets are stored as an array of file offsets >> align_pow (LE integers).
//   - Records use a chained hash (linked list per bucket via child_offset field).
//   - On write, new records are always appended (FBP is skipped — always append).
//   - Overwritten records are voided in place; the chain is repaired.
//   - Thread safety: SpinSharedMutex (impl.mutex) guards open/close/clear/rebuild.
//     Per-bucket locking via HashMutex (impl.record_mutex) for processImpl.

const std = @import("std");
const lib_common = @import("lib_common.zig");
const varint = @import("varint.zig");
const hash_util = @import("hash_util.zig");
const thread_util = @import("thread_util.zig");
const str_util = @import("str_util.zig");
const time_util = @import("time_util.zig");
const dbm_mod = @import("dbm.zig");
const file_mod = @import("file.zig");

pub const Status = lib_common.Status;
pub const Code = lib_common.Code;
pub const RecordAction = dbm_mod.RecordAction;
pub const UpdateLogger = dbm_mod.UpdateLogger;
pub const File = file_mod.File;
pub const OpenOptions = file_mod.OpenOptions;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const METADATA_SIZE: i32 = 128;
const FBP_SECTION_SIZE: i32 = 1008;
const RECORD_BASE_ALIGN: i32 = 4096;
const BUCKET_BASE_OFFSET: i64 = METADATA_SIZE + FBP_SECTION_SIZE; // 1136
pub const DEFAULT_OFFSET_WIDTH: i32 = 4;
pub const DEFAULT_ALIGN_POW: i32 = 3;
pub const DEFAULT_NUM_BUCKETS: i64 = 1_048_583;
pub const DEFAULT_FBP_CAPACITY: i32 = 2048;
const RECORD_MUTEX_NUM_SLOTS: i32 = 256;
pub const OPAQUE_METADATA_SIZE: usize = 64;
const RECORD_MAGIC_VOID: u8 = 0xC0;
const RECORD_MAGIC_SET: u8 = 0x80;
const RECORD_MAGIC_REMOVE: u8 = 0x40;
const RECORD_MAGIC_ADD: u8 = 0x00;
const PADDING_TOP_MAGIC: u8 = 0xDD;
const CLOSURE_FLAG_CLOSE: u8 = 1;
const PKG_MAJOR_VERSION: u8 = 1;
const PKG_MINOR_VERSION: u8 = 0;
const STATIC_FLAG_UPDATE_IN_PLACE: u8 = 1 << 0;
const STATIC_FLAG_UPDATE_APPENDING: u8 = 1 << 1;
pub const DEFAULT_MIN_READ_SIZE: i32 = 48;
const META_MAGIC: []const u8 = "TkrzwHDB\n";

// ---------------------------------------------------------------------------
// Helper functions
// ---------------------------------------------------------------------------

fn alignUp(value: i64, align_size: i64) i64 {
    return @divTrunc(value + align_size - 1, align_size) * align_size;
}

fn readOffsetWidth(buf: []const u8, offset_width: i32) i64 {
    var result: i64 = 0;
    const ow: usize = @intCast(offset_width);
    var i: usize = 0;
    while (i < ow) : (i += 1) {
        result |= @as(i64, buf[i]) << @intCast(i * 8);
    }
    return result;
}

fn writeOffsetWidth(buf: []u8, value: i64, offset_width: i32) void {
    const ow: usize = @intCast(offset_width);
    var i: usize = 0;
    while (i < ow) : (i += 1) {
        buf[i] = @intCast((value >> @intCast(i * 8)) & 0xFF);
    }
}

fn computeMagicChecksum(key: []const u8, value: []const u8) u8 {
    var sum: u32 = 11;
    for (key) |b| sum += b;
    for (value) |b| sum += b;
    return @intCast(sum % 61 + 3);
}

fn recordBaseOffset(num_buckets: i64, offset_width: i32, align_pow: i32) i64 {
    const bucket_region_size = num_buckets * @as(i64, offset_width);
    const align_size: i64 = @max(RECORD_BASE_ALIGN, @as(i64, 1) << @intCast(align_pow));
    return alignUp(BUCKET_BASE_OFFSET + bucket_region_size, align_size);
}

fn bucketFileOffset(bucket_index: i64, offset_width: i32) i64 {
    return BUCKET_BASE_OFFSET + bucket_index * @as(i64, offset_width);
}

// ---------------------------------------------------------------------------
// Record I/O helpers
// ---------------------------------------------------------------------------

// Decoded record header (minimal — not yet including key/value data)
const RecordHeader = struct {
    magic: u8,
    op_type: u8, // VOID/SET/REMOVE/ADD
    child_offset: i64,
    key_size: u64,
    value_size: u64,
    padding_size: u64,
    header_size: usize, // bytes consumed for header (1 + ow + varints)
};

fn readRecordHeader(buf: []const u8, offset_width: i32) ?RecordHeader {
    if (buf.len < 1) return null;
    const magic = buf[0];
    const op_type: u8 = magic & 0xC0;
    const ow: usize = @intCast(offset_width);
    if (buf.len < 1 + ow) return null;
    const child_raw = readOffsetWidth(buf[1 .. 1 + ow], offset_width);
    var rp: usize = 1 + ow;
    var key_size: u64 = 0;
    const ks_bytes = varint.readVarNum(buf[rp..], &key_size);
    if (ks_bytes == 0) return null;
    rp += ks_bytes;
    var value_size: u64 = 0;
    const vs_bytes = varint.readVarNum(buf[rp..], &value_size);
    if (vs_bytes == 0) return null;
    rp += vs_bytes;
    var padding_size: u64 = 0;
    const ps_bytes = varint.readVarNum(buf[rp..], &padding_size);
    if (ps_bytes == 0) return null;
    rp += ps_bytes;
    return RecordHeader{
        .magic = magic,
        .op_type = op_type,
        .child_offset = child_raw,
        .key_size = key_size,
        .value_size = value_size,
        .padding_size = padding_size,
        .header_size = rp,
    };
}

// Compute child_offset from raw stored value and align_pow.
fn decodeChildOffset(raw: i64, align_pow: i32) i64 {
    return raw << @intCast(align_pow);
}

fn encodeOffset(offset: i64, align_pow: i32) i64 {
    return offset >> @intCast(align_pow);
}

// ---------------------------------------------------------------------------
// Header save/load
// ---------------------------------------------------------------------------

fn saveMetadata(
    file: File,
    cyclic_magic: *u8,
    static_flags: u8,
    offset_width: i32,
    align_pow: i32,
    num_buckets: i64,
    num_records: i64,
    eff_data_size: i64,
    file_size: i64,
    timestamp: i64,
    db_type: i32,
    opaque_metadata: []const u8,
    finish: bool,
) Status {
    cyclic_magic.* +%= 1;

    var buf: [METADATA_SIZE]u8 = [_]u8{0} ** METADATA_SIZE;
    @memcpy(buf[0..9], META_MAGIC);
    buf[9] = cyclic_magic.*;
    buf[10] = 1; // pkg_major
    buf[11] = 0; // pkg_minor
    buf[12] = static_flags;
    buf[13] = @intCast(offset_width);
    buf[14] = @intCast(align_pow);
    buf[15] = if (finish) CLOSURE_FLAG_CLOSE else 0;

    // num_buckets at offset 16 (8 bytes LE)
    std.mem.writeInt(i64, buf[16..24], num_buckets, .little);
    // num_records at offset 24
    std.mem.writeInt(i64, buf[24..32], num_records, .little);
    // eff_data_size at offset 32
    std.mem.writeInt(i64, buf[32..40], eff_data_size, .little);
    // file_size at offset 40
    std.mem.writeInt(i64, buf[40..48], file_size, .little);
    // timestamp at offset 48
    std.mem.writeInt(i64, buf[48..56], timestamp, .little);
    // db_type at offset 56 (2 bytes LE)
    std.mem.writeInt(i16, buf[56..58], @intCast(db_type), .little);
    // opaque_metadata at offset 62 (64 bytes)
    const om_len = @min(opaque_metadata.len, OPAQUE_METADATA_SIZE);
    @memcpy(buf[62 .. 62 + om_len], opaque_metadata[0..om_len]);
    // cyclic_magic_back at offset 127
    buf[127] = cyclic_magic.*;

    return file.write(0, &buf);
}

fn loadMetadata(
    file: File,
    static_flags: *u8,
    offset_width: *i32,
    align_pow: *i32,
    num_buckets: *i64,
    num_records: *i64,
    eff_data_size: *i64,
    file_size_out: *i64,
    timestamp: *i64,
    db_type: *i32,
    opaque_metadata: []u8,
    cyclic_magic: *u8,
    closure_flags: *u8,
    auto_restored: *bool,
) Status {
    var buf: [METADATA_SIZE]u8 = undefined;
    const st = file.read(0, &buf);
    if (!st.isOk()) return st;

    if (!std.mem.eql(u8, buf[0..9], META_MAGIC)) {
        return Status.initMsg(.BROKEN_DATA_ERROR, "bad magic");
    }
    cyclic_magic.* = buf[9];
    // buf[10] = pkg_major, buf[11] = pkg_minor
    static_flags.* = buf[12];
    offset_width.* = buf[13];
    align_pow.* = buf[14];
    const closure_flags_val: u8 = buf[15];
    closure_flags.* = closure_flags_val;
    auto_restored.* = (closure_flags_val & CLOSURE_FLAG_CLOSE) == 0;

    num_buckets.* = std.mem.readInt(i64, buf[16..24], .little);
    num_records.* = std.mem.readInt(i64, buf[24..32], .little);
    eff_data_size.* = std.mem.readInt(i64, buf[32..40], .little);
    file_size_out.* = std.mem.readInt(i64, buf[40..48], .little);
    timestamp.* = std.mem.readInt(i64, buf[48..56], .little);
    db_type.* = std.mem.readInt(i16, buf[56..58], .little);

    const om_copy = @min(opaque_metadata.len, OPAQUE_METADATA_SIZE);
    @memcpy(opaque_metadata[0..om_copy], buf[62 .. 62 + om_copy]);

    return Status.init(.SUCCESS);
}

// ---------------------------------------------------------------------------
// Iterator impl (forward declaration)
// ---------------------------------------------------------------------------

const HashDBMIteratorImpl = struct {
    dbm: ?*HashDBMImpl,
    bucket_index: i64, // -1 = before start
    record_offset: i64, // 0 = need to scan from bucket
    allocator: std.mem.Allocator,
};

// ---------------------------------------------------------------------------
// HashDBMImpl
// ---------------------------------------------------------------------------

const HashDBMImpl = struct {
    allocator: std.mem.Allocator,
    file: file_mod.File,
    open: bool = false,
    writable: bool = false,
    healthy: bool = false,
    auto_restored: bool = false,
    open_options: file_mod.OpenOptions = .{},
    path: std.ArrayListUnmanaged(u8) = .empty,
    static_flags: u8 = 0,
    offset_width: i32 = DEFAULT_OFFSET_WIDTH,
    align_pow: i32 = DEFAULT_ALIGN_POW,
    num_buckets: i64 = DEFAULT_NUM_BUCKETS,
    num_records: std.atomic.Value(i64),
    eff_data_size: std.atomic.Value(i64),
    file_size: i64 = 0,
    timestamp: i64 = 0,
    db_type: i32 = 0,
    opaque_metadata: [OPAQUE_METADATA_SIZE]u8 = [_]u8{0} ** OPAQUE_METADATA_SIZE,
    record_base: i64 = 0,
    update_logger: ?*dbm_mod.UpdateLogger = null,
    iterators: std.ArrayListUnmanaged(*HashDBMIteratorImpl) = .empty,
    mutex: thread_util.SpinSharedMutex = .{},
    record_mutex: thread_util.HashMutex,
    cyclic_magic: u8 = 0,
    closure_flags: u8 = 0,

    fn init(file: file_mod.File, num_buckets_hint: i64, align_pow_hint: i32, allocator: std.mem.Allocator) !*HashDBMImpl {
        const nb = if (num_buckets_hint > 0) num_buckets_hint else DEFAULT_NUM_BUCKETS;
        const ap = if (align_pow_hint >= 0) align_pow_hint else DEFAULT_ALIGN_POW;
        const self = try allocator.create(HashDBMImpl);
        errdefer allocator.destroy(self);
        const rm = try thread_util.HashMutex.init(
            RECORD_MUTEX_NUM_SLOTS,
            nb,
            hash_util.primaryHash,
            allocator,
        );
        self.* = HashDBMImpl{
            .allocator = allocator,
            .file = file,
            .num_records = std.atomic.Value(i64).init(0),
            .eff_data_size = std.atomic.Value(i64).init(0),
            .num_buckets = nb,
            .align_pow = ap,
            .record_mutex = rm,
        };
        return self;
    }

    fn deinit(self: *HashDBMImpl) void {
        if (self.open) {
            _ = self.closeImpl();
        }
        // Orphan iterators.
        for (self.iterators.items) |iter| {
            iter.dbm = null;
        }
        self.iterators.deinit(self.allocator);
        self.path.deinit(self.allocator);
        self.record_mutex.deinit();
        self.file.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn openImpl(self: *HashDBMImpl, path: []const u8, writable: bool, options: file_mod.OpenOptions, io: std.Io) Status {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.open) {
            return Status.initMsg(.PRECONDITION_ERROR, "already open");
        }

        const st_open = self.file.open(path, writable, options);
        if (!st_open.isOk()) return st_open;

        const file_sz = self.file.getSizeSimple();
        if (file_sz < METADATA_SIZE) {
            // New file — write initial metadata + FBP + bucket array.
            if (!writable) {
                _ = self.file.close();
                return Status.initMsg(.BROKEN_DATA_ERROR, "new file opened read-only");
            }
            const ts_i64: i64 = std.Io.Clock.real.now(io).toMicroseconds();
            self.timestamp = ts_i64;
            self.num_records.store(0, .release);
            self.eff_data_size.store(0, .release);
            const rb = recordBaseOffset(self.num_buckets, self.offset_width, self.align_pow);
            self.record_base = rb;
            self.file_size = rb;

            // Write header.
            var cm: u8 = 0;
            const st_meta = saveMetadata(
                self.file,
                &cm,
                self.static_flags,
                self.offset_width,
                self.align_pow,
                self.num_buckets,
                0,
                0,
                rb,
                ts_i64,
                self.db_type,
                &self.opaque_metadata,
                false,
            );
            if (!st_meta.isOk()) {
                _ = self.file.close();
                return st_meta;
            }
            self.cyclic_magic = cm;

            // Write FBP section (zeros).
            var fbp_buf: [FBP_SECTION_SIZE]u8 = [_]u8{0} ** FBP_SECTION_SIZE;
            const st_fbp = self.file.write(METADATA_SIZE, &fbp_buf);
            if (!st_fbp.isOk()) {
                _ = self.file.close();
                return st_fbp;
            }

            // Write bucket array (zeros) + padding to record_base.
            const bucket_bytes: i64 = self.num_buckets * @as(i64, self.offset_width);
            const total_zero: usize = @intCast(rb - BUCKET_BASE_OFFSET);
            const zero_buf = self.allocator.alloc(u8, total_zero) catch {
                _ = self.file.close();
                return Status.init(.SYSTEM_ERROR);
            };
            defer self.allocator.free(zero_buf);
            @memset(zero_buf, 0);
            const st_zero = self.file.write(BUCKET_BASE_OFFSET, zero_buf);
            if (!st_zero.isOk()) {
                _ = self.file.close();
                return st_zero;
            }
            _ = bucket_bytes;
            // Truncate to record_base to set logical_size so appends start at the right offset.
            const st_trunc_init = self.file.truncate(rb);
            if (!st_trunc_init.isOk()) {
                _ = self.file.close();
                return st_trunc_init;
            }
        } else {
            // Existing file — load metadata.
            var auto_restored_flag: bool = false;
            var nr: i64 = 0;
            var eds: i64 = 0;
            var fsz: i64 = 0;
            var ts: i64 = 0;
            const st_load = loadMetadata(
                self.file,
                &self.static_flags,
                &self.offset_width,
                &self.align_pow,
                &self.num_buckets,
                &nr,
                &eds,
                &fsz,
                &ts,
                &self.db_type,
                &self.opaque_metadata,
                &self.cyclic_magic,
                &self.closure_flags,
                &auto_restored_flag,
            );
            if (!st_load.isOk()) {
                _ = self.file.close();
                return st_load;
            }
            self.auto_restored = auto_restored_flag;
            self.num_records.store(nr, .release);
            self.eff_data_size.store(eds, .release);
            self.timestamp = ts;
            self.record_base = recordBaseOffset(self.num_buckets, self.offset_width, self.align_pow);
            // Actual file size from OS.
            self.file_size = self.file.getSizeSimple();
            // Update HashMutex num_buckets in case it differs from init hint.
            self.record_mutex.rehash(self.num_buckets);
        }

        self.path.clearRetainingCapacity();
        self.path.appendSlice(self.allocator, path) catch {
            _ = self.file.close();
            return Status.init(.SYSTEM_ERROR);
        };
        self.open = true;
        self.writable = writable;
        self.healthy = true;
        self.open_options = options;
        return Status.init(.SUCCESS);
    }

    fn closeImpl(self: *HashDBMImpl) Status {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (!self.open) {
            return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        }

        var status = Status.init(.SUCCESS);

        if (self.writable) {
            self.file_size = self.file.getSizeSimple();
            var cm = self.cyclic_magic;
            const st_meta = saveMetadata(
                self.file,
                &cm,
                self.static_flags,
                self.offset_width,
                self.align_pow,
                self.num_buckets,
                self.num_records.load(.acquire),
                self.eff_data_size.load(.acquire),
                self.file_size,
                self.timestamp,
                self.db_type,
                &self.opaque_metadata,
                true,
            );
            self.cyclic_magic = cm;
            status.mergeFrom(st_meta);
        }

        status.mergeFrom(self.file.close());

        // Orphan iterators.
        for (self.iterators.items) |iter| {
            iter.dbm = null;
        }
        self.iterators.clearRetainingCapacity();

        self.open = false;
        self.writable = false;
        self.healthy = false;
        self.path.clearRetainingCapacity();
        return status;
    }

    // Read a bucket value (raw encoded offset; 0 = empty).
    fn readBucket(self: *HashDBMImpl, bucket_index: i64) !i64 {
        const off = bucketFileOffset(bucket_index, self.offset_width);
        var buf: [8]u8 = undefined;
        const ow: usize = @intCast(self.offset_width);
        const st = self.file.read(off, buf[0..ow]);
        if (!st.isOk()) return error.IOError;
        return readOffsetWidth(buf[0..ow], self.offset_width);
    }

    // Write a bucket value.
    fn writeBucket(self: *HashDBMImpl, bucket_index: i64, raw_offset: i64) !void {
        const off = bucketFileOffset(bucket_index, self.offset_width);
        var buf: [8]u8 = [_]u8{0} ** 8;
        writeOffsetWidth(buf[0..@intCast(self.offset_width)], raw_offset, self.offset_width);
        const st = self.file.write(off, buf[0..@intCast(self.offset_width)]);
        if (!st.isOk()) return error.IOError;
    }

    // Read child offset field from an existing record.
    fn readChildOffset(self: *HashDBMImpl, record_offset: i64) !i64 {
        var buf: [8]u8 = undefined;
        const ow: usize = @intCast(self.offset_width);
        const st = self.file.read(record_offset + 1, buf[0..ow]);
        if (!st.isOk()) return error.IOError;
        const raw = readOffsetWidth(buf[0..ow], self.offset_width);
        return decodeChildOffset(raw, self.align_pow);
    }

    // Write child offset field in an existing record.
    fn writeChildOffset(self: *HashDBMImpl, record_offset: i64, child_offset: i64) !void {
        var buf: [8]u8 = [_]u8{0} ** 8;
        const raw = encodeOffset(child_offset, self.align_pow);
        writeOffsetWidth(buf[0..@intCast(self.offset_width)], raw, self.offset_width);
        const st = self.file.write(record_offset + 1, buf[0..@intCast(self.offset_width)]);
        if (!st.isOk()) return error.IOError;
    }

    // Void a record in place (overwrite magic byte with RECORD_MAGIC_VOID).
    fn voidRecord(self: *HashDBMImpl, record_offset: i64) !void {
        const st = self.file.write(record_offset, &[_]u8{RECORD_MAGIC_VOID});
        if (!st.isOk()) return error.IOError;
    }

    // Read and parse a full record from file at record_offset.
    // Returns record header + allocates key and value slices.
    const FullRecord = struct {
        header: RecordHeader,
        key: []u8,
        value: []u8,
        allocator: std.mem.Allocator,

        fn deinit(self: *FullRecord) void {
            self.allocator.free(self.key);
            self.allocator.free(self.value);
        }
    };

    // Read just the record header from file at record_offset without allocating key/value.
    // Reads the fixed prefix (magic + child) first, then varint bytes one-at-a-time until
    // the header parses successfully.  Uses an on-stack buffer; safe for small records.
    fn readRecordHeaderFromFile(self: *HashDBMImpl, record_offset: i64) !RecordHeader {
        var hdr_buf: [64]u8 = undefined;
        const fixed_hdr_size: usize = 1 + @as(usize, @intCast(self.offset_width));
        {
            const st = self.file.read(record_offset, hdr_buf[0..fixed_hdr_size]);
            if (!st.isOk()) return error.IOError;
        }
        var varint_read: usize = 0;
        const max_varint_bytes: usize = 30; // 3 varints × max 10 bytes each
        while (varint_read < max_varint_bytes) : (varint_read += 1) {
            const byte_off: i64 = record_offset + @as(i64, @intCast(fixed_hdr_size + varint_read));
            const st = self.file.read(byte_off, hdr_buf[fixed_hdr_size + varint_read .. fixed_hdr_size + varint_read + 1]);
            if (!st.isOk()) break;
            const tentative = readRecordHeader(hdr_buf[0 .. fixed_hdr_size + varint_read + 1], self.offset_width);
            if (tentative != null) {
                varint_read += 1;
                break;
            }
        }
        return readRecordHeader(hdr_buf[0 .. fixed_hdr_size + varint_read], self.offset_width) orelse error.BrokenData;
    }

    fn readFullRecord(self: *HashDBMImpl, record_offset: i64, allocator: std.mem.Allocator) !FullRecord {
        const hdr = blk: {
            const hdr_raw = try self.readRecordHeaderFromFile(record_offset);
            var h = hdr_raw;
            h.child_offset = decodeChildOffset(hdr_raw.child_offset, self.align_pow);
            break :blk h;
        };

        // Phase 2: read key + value at their exact offset.
        const data_start: i64 = record_offset + @as(i64, @intCast(hdr.header_size));
        const key_size: usize = @intCast(hdr.key_size);
        const value_size: usize = @intCast(hdr.value_size);
        const total_data = key_size + value_size;

        const key = try allocator.alloc(u8, key_size);
        errdefer allocator.free(key);
        const value = try allocator.alloc(u8, value_size);
        errdefer allocator.free(value);

        if (total_data > 0) {
            // Read key and value together for efficiency if sizes are small.
            const data_buf = try allocator.alloc(u8, total_data);
            defer allocator.free(data_buf);
            const st = self.file.read(data_start, data_buf);
            if (!st.isOk()) return error.IOError;
            @memcpy(key, data_buf[0..key_size]);
            if (value_size > 0) @memcpy(value, data_buf[key_size..]);
        }

        return FullRecord{
            .header = hdr,
            .key = key,
            .value = value,
            .allocator = allocator,
        };
    }

    // Compute the whole_size of a record given key/value sizes and an ideal_whole_size.
    fn computeWholeSize(self: *HashDBMImpl, key_size: usize, value_size: usize, ideal_whole_size: i64) i64 {
        const base_size: i64 = @intCast(
            1 + @as(usize, @intCast(self.offset_width)) +
                varint.sizeVarNum(key_size) +
                varint.sizeVarNum(value_size) +
                1 + // min 1-byte padding varint
                key_size + value_size,
        );
        const align_size: i64 = @as(i64, 1) << @intCast(self.align_pow);
        const min_size = @max(base_size, ideal_whole_size);
        return alignUp(min_size, align_size);
    }

    // Write a new record to file (appended). Returns the file offset of the new record.
    fn appendRecord(
        self: *HashDBMImpl,
        op_type: u8,
        child_offset: i64,
        key: []const u8,
        value: []const u8,
        ideal_whole_size: i64,
    ) !i64 {
        const key_vsize = varint.sizeVarNum(key.len);
        const val_vsize = varint.sizeVarNum(value.len);
        const base_size: i64 = @intCast(
            1 + @as(usize, @intCast(self.offset_width)) +
                key_vsize + val_vsize + 1 + key.len + value.len,
        );
        const align_size: i64 = @as(i64, 1) << @intCast(self.align_pow);
        const min_size = @max(base_size, ideal_whole_size);
        const whole_size: i64 = alignUp(min_size, align_size);
        const padding_size: u64 = @intCast(whole_size - base_size);

        const pad_vsize = varint.sizeVarNum(padding_size);
        const actual_base_size: i64 = @intCast(
            1 + @as(usize, @intCast(self.offset_width)) +
                key_vsize + val_vsize + pad_vsize + key.len + value.len,
        );
        const actual_padding: u64 = @intCast(whole_size - actual_base_size);

        // Allocate write buffer.
        const buf = try self.allocator.alloc(u8, @intCast(whole_size));
        defer self.allocator.free(buf);
        @memset(buf, 0);

        // Write magic byte.
        const checksum = computeMagicChecksum(key, value);
        buf[0] = op_type | checksum;

        // Write child offset.
        const raw_child = encodeOffset(child_offset, self.align_pow);
        writeOffsetWidth(buf[1..@intCast(1 + self.offset_width)], raw_child, self.offset_width);

        // Write varints and data.
        var wp: usize = @intCast(1 + self.offset_width);
        wp += varint.writeVarNum(buf[wp..], key.len);
        wp += varint.writeVarNum(buf[wp..], value.len);
        wp += varint.writeVarNum(buf[wp..], actual_padding);
        @memcpy(buf[wp .. wp + key.len], key);
        wp += key.len;
        @memcpy(buf[wp .. wp + value.len], value);
        wp += value.len;
        if (actual_padding > 0) {
            buf[wp] = PADDING_TOP_MAGIC;
        }

        // Append to file and get offset.
        var new_off: i64 = 0;
        const st = self.file.append(buf, &new_off);
        if (!st.isOk()) return error.IOError;
        return new_off;
    }

    // Update a record's value in-place (only valid when value_size + varint width is same).
    fn updateRecordValueInPlace(
        self: *HashDBMImpl,
        record_offset: i64,
        hdr: RecordHeader,
        key: []const u8,
        new_value: []const u8,
    ) !void {
        // Update magic checksum.
        const checksum = computeMagicChecksum(key, new_value);
        const new_magic = (hdr.magic & 0xC0) | checksum;

        // Build the header portion + new value.
        const new_val_vsize = varint.sizeVarNum(new_value.len);
        const old_val_vsize = varint.sizeVarNum(hdr.value_size);
        const pad_vsize = varint.sizeVarNum(hdr.padding_size);

        // Total header bytes = 1 + ow + key_vsize + val_vsize + pad_vsize
        const header_bytes: usize = 1 + @as(usize, @intCast(self.offset_width)) +
            varint.sizeVarNum(hdr.key_size) + old_val_vsize + pad_vsize;

        _ = new_val_vsize;

        // Write magic byte.
        const st1 = self.file.write(record_offset, &[_]u8{new_magic});
        if (!st1.isOk()) return error.IOError;

        // Write new value at key_data_end.
        const value_start: i64 = record_offset + @as(i64, @intCast(header_bytes)) + @as(i64, @intCast(hdr.key_size));
        const st2 = self.file.write(value_start, new_value);
        if (!st2.isOk()) return error.IOError;

        // If new_value is shorter, zero out the remainder (part of old value that's now padding).
        if (new_value.len < @as(usize, @intCast(hdr.value_size))) {
            const leftover: usize = @as(usize, @intCast(hdr.value_size)) - new_value.len;
            const zero_buf = try self.allocator.alloc(u8, leftover);
            defer self.allocator.free(zero_buf);
            @memset(zero_buf, 0);
            const st3 = self.file.write(value_start + @as(i64, @intCast(new_value.len)), zero_buf);
            if (!st3.isOk()) return error.IOError;
        }
    }

    // Core process implementation — called with bucket mutex already held.
    fn processImpl(self: *HashDBMImpl, key: []const u8, proc: anytype, writable: bool, bucket_index: i64) Status {
        // Read first_offset from bucket.
        const first_raw = self.readBucket(bucket_index) catch return Status.init(.SYSTEM_ERROR);
        const first_offset: i64 = if (first_raw == 0) 0 else decodeChildOffset(first_raw, self.align_pow);

        var prev_offset: i64 = 0; // 0 = no prev (head of chain)
        var cur_offset: i64 = first_offset;

        while (cur_offset != 0) {
            var rec = self.readFullRecord(cur_offset, self.allocator) catch return Status.init(.SYSTEM_ERROR);
            defer rec.deinit();

            if (rec.header.op_type == RECORD_MAGIC_VOID) {
                // Skip void records (defensive; shouldn't normally appear in live chain).
                cur_offset = rec.header.child_offset;
                continue;
            }

            if (!std.mem.eql(u8, rec.key, key)) {
                // Different key — follow chain.
                prev_offset = cur_offset;
                cur_offset = rec.header.child_offset;
                continue;
            }

            // Found matching key.
            if (!writable) {
                const action = proc.processFull(key, rec.value);
                _ = action; // readonly — noop always
                return Status.init(.SUCCESS);
            }

            const action = proc.processFull(key, rec.value);
            switch (action) {
                .noop => return Status.init(.SUCCESS),
                .remove => {
                    // Void record and unlink from chain.
                    self.voidRecord(cur_offset) catch return Status.init(.SYSTEM_ERROR);
                    // Unlink: point prev (or bucket) to child.
                    const child = rec.header.child_offset;
                    if (prev_offset == 0) {
                        // Update bucket to point to child.
                        const raw_child = if (child == 0) @as(i64, 0) else encodeOffset(child, self.align_pow);
                        self.writeBucket(bucket_index, raw_child) catch return Status.init(.SYSTEM_ERROR);
                    } else {
                        self.writeChildOffset(prev_offset, child) catch return Status.init(.SYSTEM_ERROR);
                    }
                    _ = self.num_records.fetchSub(1, .monotonic);
                    const eds_delta: i64 = -@as(i64, @intCast(key.len + rec.value.len));
                    _ = self.eff_data_size.fetchAdd(eds_delta, .monotonic);
                    if (self.update_logger) |ul| {
                        _ = ul.writeRemove(key);
                    }
                    return Status.init(.SUCCESS);
                },
                .set => |new_v| {
                    // Check if we can update in-place: same value_size varint width.
                    const old_val_vsize = varint.sizeVarNum(rec.header.value_size);
                    const new_val_vsize = varint.sizeVarNum(new_v.len);
                    // In-place update: new value fits within old value size (no varint growth needed
                    // if varint width is same and new value <= old value size).
                    if (new_val_vsize == old_val_vsize and new_v.len <= @as(usize, @intCast(rec.header.value_size))) {
                        self.updateRecordValueInPlace(cur_offset, rec.header, key, new_v) catch
                            return Status.init(.SYSTEM_ERROR);
                        const eds_delta: i64 = @as(i64, @intCast(new_v.len)) - @as(i64, @intCast(rec.header.value_size));
                        _ = self.eff_data_size.fetchAdd(eds_delta, .monotonic);
                    } else {
                        // Append new record with child = rec.child_offset.
                        const new_off = self.appendRecord(RECORD_MAGIC_SET, rec.header.child_offset, key, new_v, 0) catch
                            return Status.init(.SYSTEM_ERROR);
                        // Void the old record.
                        self.voidRecord(cur_offset) catch return Status.init(.SYSTEM_ERROR);
                        // Update chain link.
                        if (prev_offset == 0) {
                            const raw_new = encodeOffset(new_off, self.align_pow);
                            self.writeBucket(bucket_index, raw_new) catch return Status.init(.SYSTEM_ERROR);
                        } else {
                            self.writeChildOffset(prev_offset, new_off) catch return Status.init(.SYSTEM_ERROR);
                        }
                        const eds_delta: i64 = @as(i64, @intCast(new_v.len)) - @as(i64, @intCast(rec.header.value_size));
                        _ = self.eff_data_size.fetchAdd(eds_delta, .monotonic);
                    }
                    if (self.update_logger) |ul| {
                        _ = ul.writeSet(key, new_v);
                    }
                    return Status.init(.SUCCESS);
                },
            }
        }

        // Key not found — call processEmpty.
        if (!writable) {
            const action = proc.processEmpty(key);
            _ = action;
            return Status.init(.NOT_FOUND_ERROR);
        }

        const action = proc.processEmpty(key);
        switch (action) {
            .noop, .remove => return Status.init(.NOT_FOUND_ERROR),
            .set => |new_v| {
                // Append ADD record with child = old first_offset.
                const raw_first = if (first_offset == 0) @as(i64, 0) else first_raw;
                _ = raw_first;
                const new_off = self.appendRecord(RECORD_MAGIC_ADD, first_offset, key, new_v, 0) catch
                    return Status.init(.SYSTEM_ERROR);
                // Update bucket to point to new record.
                const raw_new = encodeOffset(new_off, self.align_pow);
                self.writeBucket(bucket_index, raw_new) catch return Status.init(.SYSTEM_ERROR);
                _ = self.num_records.fetchAdd(1, .monotonic);
                _ = self.eff_data_size.fetchAdd(@as(i64, @intCast(key.len + new_v.len)), .monotonic);
                if (self.update_logger) |ul| {
                    _ = ul.writeSet(key, new_v);
                }
                return Status.init(.SUCCESS);
            },
        }
    }

    fn process(self: *HashDBMImpl, key: []const u8, proc: anytype, writable: bool) Status {
        if (!self.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        if (writable and !self.writable) return Status.initMsg(.PRECONDITION_ERROR, "not writable");
        const bucket_index = if (writable)
            self.record_mutex.lockOne(key)
        else
            self.record_mutex.lockOneShared(key);
        defer if (writable)
            self.record_mutex.unlockOne(bucket_index)
        else
            self.record_mutex.unlockOneShared(bucket_index);
        return self.processImpl(key, proc, writable, bucket_index);
    }

    fn processMulti(
        self: *HashDBMImpl,
        comptime P: type,
        keys: []const []const u8,
        procs: []const *P,
        writable: bool,
    ) Status {
        if (!self.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        if (writable and !self.writable) return Status.initMsg(.PRECONDITION_ERROR, "not writable");

        const bucket_indices = if (writable)
            self.record_mutex.lockMulti(keys, self.allocator) catch return Status.init(.SYSTEM_ERROR)
        else
            self.record_mutex.lockMultiShared(keys, self.allocator) catch return Status.init(.SYSTEM_ERROR);
        defer self.allocator.free(bucket_indices);
        defer if (writable)
            self.record_mutex.unlockMulti(bucket_indices)
        else
            self.record_mutex.unlockMultiShared(bucket_indices);

        var status = Status.init(.SUCCESS);
        for (keys, procs, bucket_indices) |key, proc, bucket_index| {
            const st = self.processImpl(key, proc, writable, bucket_index);
            status.mergeFrom(st);
        }
        return status;
    }

    fn processFirst(self: *HashDBMImpl, proc: anytype, writable: bool) Status {
        if (!self.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        if (writable and !self.writable) return Status.initMsg(.PRECONDITION_ERROR, "not writable");

        self.mutex.lockShared();
        defer self.mutex.unlockShared();

        var bucket_index: i64 = 0;
        while (bucket_index < self.num_buckets) : (bucket_index += 1) {
            const first_raw = self.readBucket(bucket_index) catch return Status.init(.SYSTEM_ERROR);
            if (first_raw == 0) continue;
            var cur_offset: i64 = decodeChildOffset(first_raw, self.align_pow);
            while (cur_offset != 0) {
                var rec = self.readFullRecord(cur_offset, self.allocator) catch return Status.init(.SYSTEM_ERROR);
                defer rec.deinit();
                if (rec.header.op_type == RECORD_MAGIC_VOID) {
                    cur_offset = rec.header.child_offset;
                    continue;
                }
                // Found a live record.
                if (!writable) {
                    _ = proc.processFull(rec.key, rec.value);
                    return Status.init(.SUCCESS);
                }
                const action = proc.processFull(rec.key, rec.value);
                switch (action) {
                    .noop => return Status.init(.SUCCESS),
                    .remove => {
                        self.voidRecord(cur_offset) catch return Status.init(.SYSTEM_ERROR);
                        const raw_child = if (rec.header.child_offset == 0) @as(i64, 0) else encodeOffset(rec.header.child_offset, self.align_pow);
                        self.writeBucket(bucket_index, raw_child) catch return Status.init(.SYSTEM_ERROR);
                        _ = self.num_records.fetchSub(1, .monotonic);
                        _ = self.eff_data_size.fetchAdd(-@as(i64, @intCast(rec.key.len + rec.value.len)), .monotonic);
                        if (self.update_logger) |ul| _ = ul.writeRemove(rec.key);
                        return Status.init(.SUCCESS);
                    },
                    .set => |new_v| {
                        const new_off = self.appendRecord(RECORD_MAGIC_SET, rec.header.child_offset, rec.key, new_v, 0) catch
                            return Status.init(.SYSTEM_ERROR);
                        self.voidRecord(cur_offset) catch return Status.init(.SYSTEM_ERROR);
                        const raw_new = encodeOffset(new_off, self.align_pow);
                        self.writeBucket(bucket_index, raw_new) catch return Status.init(.SYSTEM_ERROR);
                        const eds_delta: i64 = @as(i64, @intCast(new_v.len)) - @as(i64, @intCast(rec.value.len));
                        _ = self.eff_data_size.fetchAdd(eds_delta, .monotonic);
                        if (self.update_logger) |ul| _ = ul.writeSet(rec.key, new_v);
                        return Status.init(.SUCCESS);
                    },
                }
            }
        }
        return Status.init(.NOT_FOUND_ERROR);
    }

    fn processEach(self: *HashDBMImpl, proc: anytype, writable: bool) Status {
        if (!self.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        if (writable and !self.writable) return Status.initMsg(.PRECONDITION_ERROR, "not writable");

        self.mutex.lockShared();
        defer self.mutex.unlockShared();

        _ = proc.processEmpty("");

        var bucket_index: i64 = 0;
        while (bucket_index < self.num_buckets) : (bucket_index += 1) {
            const first_raw = self.readBucket(bucket_index) catch return Status.init(.SYSTEM_ERROR);
            if (first_raw == 0) continue;
            var cur_offset: i64 = decodeChildOffset(first_raw, self.align_pow);
            while (cur_offset != 0) {
                var rec = self.readFullRecord(cur_offset, self.allocator) catch return Status.init(.SYSTEM_ERROR);
                defer rec.deinit();
                const next_offset = rec.header.child_offset;
                if (rec.header.op_type == RECORD_MAGIC_VOID) {
                    cur_offset = next_offset;
                    continue;
                }
                if (!writable) {
                    _ = proc.processFull(rec.key, rec.value);
                    cur_offset = next_offset;
                    continue;
                }
                const action = proc.processFull(rec.key, rec.value);
                switch (action) {
                    .noop => {},
                    .remove => {
                        self.voidRecord(cur_offset) catch return Status.init(.SYSTEM_ERROR);
                        // We need to unlink — scan chain for prev.
                        const br = self.readBucket(bucket_index) catch return Status.init(.SYSTEM_ERROR);
                        const head_off: i64 = if (br == 0) 0 else decodeChildOffset(br, self.align_pow);
                        var prev_off2: i64 = 0;
                        var scan_off = head_off;
                        while (scan_off != 0 and scan_off != cur_offset) {
                            const scan_rec = self.readFullRecord(scan_off, self.allocator) catch break;
                            prev_off2 = scan_off;
                            scan_off = scan_rec.header.child_offset;
                            scan_rec.allocator.free(scan_rec.key);
                            scan_rec.allocator.free(scan_rec.value);
                        }
                        if (prev_off2 == 0) {
                            const raw_c = if (next_offset == 0) @as(i64, 0) else encodeOffset(next_offset, self.align_pow);
                            self.writeBucket(bucket_index, raw_c) catch return Status.init(.SYSTEM_ERROR);
                        } else {
                            self.writeChildOffset(prev_off2, next_offset) catch return Status.init(.SYSTEM_ERROR);
                        }
                        _ = self.num_records.fetchSub(1, .monotonic);
                        _ = self.eff_data_size.fetchAdd(-@as(i64, @intCast(rec.key.len + rec.value.len)), .monotonic);
                        if (self.update_logger) |ul| _ = ul.writeRemove(rec.key);
                    },
                    .set => |new_v| {
                        const new_off = self.appendRecord(RECORD_MAGIC_SET, next_offset, rec.key, new_v, 0) catch
                            return Status.init(.SYSTEM_ERROR);
                        self.voidRecord(cur_offset) catch return Status.init(.SYSTEM_ERROR);
                        const br = self.readBucket(bucket_index) catch return Status.init(.SYSTEM_ERROR);
                        const head_off: i64 = if (br == 0) 0 else decodeChildOffset(br, self.align_pow);
                        var prev_off2: i64 = 0;
                        var scan_off = head_off;
                        while (scan_off != 0 and scan_off != cur_offset) {
                            const scan_rec = self.readFullRecord(scan_off, self.allocator) catch break;
                            prev_off2 = scan_off;
                            scan_off = scan_rec.header.child_offset;
                            scan_rec.allocator.free(scan_rec.key);
                            scan_rec.allocator.free(scan_rec.value);
                        }
                        if (prev_off2 == 0) {
                            const raw_new = encodeOffset(new_off, self.align_pow);
                            self.writeBucket(bucket_index, raw_new) catch return Status.init(.SYSTEM_ERROR);
                        } else {
                            self.writeChildOffset(prev_off2, new_off) catch return Status.init(.SYSTEM_ERROR);
                        }
                        const eds_delta: i64 = @as(i64, @intCast(new_v.len)) - @as(i64, @intCast(rec.value.len));
                        _ = self.eff_data_size.fetchAdd(eds_delta, .monotonic);
                        if (self.update_logger) |ul| _ = ul.writeSet(rec.key, new_v);
                    },
                }
                cur_offset = next_offset;
            }
        }

        _ = proc.processEmpty("");
        return Status.init(.SUCCESS);
    }

    fn clearImpl(self: *HashDBMImpl) Status {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (!self.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        if (!self.writable) return Status.initMsg(.PRECONDITION_ERROR, "not writable");

        if (self.update_logger) |ul| {
            _ = ul.writeClear();
        }

        // Orphan iterators.
        for (self.iterators.items) |iter| iter.dbm = null;
        self.iterators.clearRetainingCapacity();

        // Zero bucket array.
        const bucket_bytes: usize = @intCast(self.num_buckets * @as(i64, self.offset_width));
        const zero_buf = self.allocator.alloc(u8, bucket_bytes) catch return Status.init(.SYSTEM_ERROR);
        defer self.allocator.free(zero_buf);
        @memset(zero_buf, 0);
        const st = self.file.write(BUCKET_BASE_OFFSET, zero_buf);
        if (!st.isOk()) return st;

        // Truncate file to record_base.
        const st_trunc = self.file.truncate(self.record_base);
        if (!st_trunc.isOk()) return st_trunc;

        self.num_records.store(0, .release);
        self.eff_data_size.store(0, .release);
        self.file_size = self.record_base;
        return Status.init(.SUCCESS);
    }

    fn synchronizeImpl(self: *HashDBMImpl, hard: bool, io: std.Io) Status {
        _ = io;
        self.mutex.lock();
        defer self.mutex.unlock();

        if (!self.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");

        var status = Status.init(.SUCCESS);
        if (self.writable) {
            if (self.update_logger) |ul| status.mergeFrom(ul.synchronize(hard));
            self.file_size = self.file.getSizeSimple();
            var cm = self.cyclic_magic;
            const st_meta = saveMetadata(
                self.file,
                &cm,
                self.static_flags,
                self.offset_width,
                self.align_pow,
                self.num_buckets,
                self.num_records.load(.acquire),
                self.eff_data_size.load(.acquire),
                self.file_size,
                self.timestamp,
                self.db_type,
                &self.opaque_metadata,
                false,
            );
            self.cyclic_magic = cm;
            status.mergeFrom(st_meta);
            if (hard) {
                status.mergeFrom(self.file.synchronize(true));
            }
        }
        return status;
    }

    fn rebuildImpl(self: *HashDBMImpl, skip_broken_records: bool, io: std.Io) Status {
        _ = io;
        self.mutex.lock();
        defer self.mutex.unlock();

        if (!self.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        if (!self.writable) return Status.initMsg(.PRECONDITION_ERROR, "not writable");

        // Collect all live records.
        const KVPair = struct { key: []u8, value: []u8 };
        var records: std.ArrayListUnmanaged(KVPair) = .empty;
        defer {
            for (records.items) |rec| {
                self.allocator.free(rec.key);
                self.allocator.free(rec.value);
            }
            records.deinit(self.allocator);
        }

        var bucket_index: i64 = 0;
        while (bucket_index < self.num_buckets) : (bucket_index += 1) {
            const first_raw = self.readBucket(bucket_index) catch {
                if (skip_broken_records) continue;
                return Status.init(.SYSTEM_ERROR);
            };
            if (first_raw == 0) continue;
            var cur_offset: i64 = decodeChildOffset(first_raw, self.align_pow);
            while (cur_offset != 0) {
                var rec = self.readFullRecord(cur_offset, self.allocator) catch {
                    if (skip_broken_records) break;
                    return Status.init(.SYSTEM_ERROR);
                };
                defer rec.deinit();
                const next_offset = rec.header.child_offset;
                if (rec.header.op_type != RECORD_MAGIC_VOID) {
                    const key_copy = self.allocator.dupe(u8, rec.key) catch return Status.init(.SYSTEM_ERROR);
                    const val_copy = self.allocator.dupe(u8, rec.value) catch {
                        self.allocator.free(key_copy);
                        return Status.init(.SYSTEM_ERROR);
                    };
                    records.append(self.allocator, KVPair{ .key = key_copy, .value = val_copy }) catch {
                        self.allocator.free(key_copy);
                        self.allocator.free(val_copy);
                        return Status.init(.SYSTEM_ERROR);
                    };
                }
                cur_offset = next_offset;
            }
        }

        // Orphan iterators.
        for (self.iterators.items) |iter| iter.dbm = null;
        self.iterators.clearRetainingCapacity();

        // Zero bucket array.
        const bucket_bytes: usize = @intCast(self.num_buckets * @as(i64, self.offset_width));
        const zero_buf = self.allocator.alloc(u8, bucket_bytes) catch return Status.init(.SYSTEM_ERROR);
        defer self.allocator.free(zero_buf);
        @memset(zero_buf, 0);
        const st_zero = self.file.write(BUCKET_BASE_OFFSET, zero_buf);
        if (!st_zero.isOk()) return st_zero;

        // Truncate to record_base and re-insert all records.
        const st_trunc = self.file.truncate(self.record_base);
        if (!st_trunc.isOk()) return st_trunc;

        self.num_records.store(0, .release);
        self.eff_data_size.store(0, .release);

        for (records.items) |kv| {
            const bucket_idx2 = hash_util.primaryHash(kv.key, @intCast(self.num_buckets));
            const first_raw2 = self.readBucket(@intCast(bucket_idx2)) catch return Status.init(.SYSTEM_ERROR);
            const first_off2: i64 = if (first_raw2 == 0) 0 else decodeChildOffset(first_raw2, self.align_pow);
            const new_off = self.appendRecord(RECORD_MAGIC_ADD, first_off2, kv.key, kv.value, 0) catch
                return Status.init(.SYSTEM_ERROR);
            const raw_new = encodeOffset(new_off, self.align_pow);
            self.writeBucket(@intCast(bucket_idx2), raw_new) catch return Status.init(.SYSTEM_ERROR);
            _ = self.num_records.fetchAdd(1, .monotonic);
            _ = self.eff_data_size.fetchAdd(@as(i64, @intCast(kv.key.len + kv.value.len)), .monotonic);
        }

        self.file_size = self.file.getSizeSimple();
        return Status.init(.SUCCESS);
    }

    // ---------------------------------------------------------------------------
    // Iterator helpers
    // ---------------------------------------------------------------------------

    // Advance iterator to the next live record.
    fn advanceToLiveRecord(self: *HashDBMImpl, iter: *HashDBMIteratorImpl) void {
        while (iter.bucket_index < self.num_buckets) {
            if (iter.record_offset == 0) {
                // Need to start from bucket head.
                const first_raw = self.readBucket(iter.bucket_index) catch {
                    iter.bucket_index += 1;
                    continue;
                };
                if (first_raw == 0) {
                    iter.bucket_index += 1;
                    continue;
                }
                iter.record_offset = decodeChildOffset(first_raw, self.align_pow);
            }

            // Scan from current record_offset for a live record.
            while (iter.record_offset != 0) {
                const hdr = self.readRecordHeaderFromFile(iter.record_offset) catch {
                    iter.bucket_index = self.num_buckets; // invalidate
                    return;
                };
                const child = decodeChildOffset(hdr.child_offset, self.align_pow);
                if (hdr.op_type == RECORD_MAGIC_VOID) {
                    iter.record_offset = child;
                    continue;
                }
                // Live record found — stop here.
                return;
            }

            // Exhausted this bucket.
            iter.record_offset = 0;
            iter.bucket_index += 1;
        }
    }

    fn iterFirst(self: *HashDBMImpl, iter: *HashDBMIteratorImpl) Status {
        if (!self.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        iter.bucket_index = 0;
        iter.record_offset = 0;
        self.advanceToLiveRecord(iter);
        return Status.init(.SUCCESS);
    }

    fn iterJump(self: *HashDBMImpl, iter: *HashDBMIteratorImpl, key: []const u8) Status {
        if (!self.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");

        const bucket_idx: i64 = @intCast(hash_util.primaryHash(key, @intCast(self.num_buckets)));
        const first_raw = self.readBucket(bucket_idx) catch return Status.init(.SYSTEM_ERROR);
        if (first_raw == 0) {
            iter.bucket_index = self.num_buckets; // not found
            iter.record_offset = 0;
            return Status.init(.NOT_FOUND_ERROR);
        }

        var cur_offset: i64 = decodeChildOffset(first_raw, self.align_pow);
        while (cur_offset != 0) {
            var rec = self.readFullRecord(cur_offset, self.allocator) catch return Status.init(.SYSTEM_ERROR);
            defer rec.deinit();
            const next_off = rec.header.child_offset;
            if (rec.header.op_type != RECORD_MAGIC_VOID and std.mem.eql(u8, rec.key, key)) {
                iter.bucket_index = bucket_idx;
                iter.record_offset = cur_offset;
                return Status.init(.SUCCESS);
            }
            cur_offset = next_off;
        }

        iter.bucket_index = self.num_buckets;
        iter.record_offset = 0;
        return Status.init(.NOT_FOUND_ERROR);
    }

    fn iterNext(self: *HashDBMImpl, iter: *HashDBMIteratorImpl) Status {
        if (!self.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        if (iter.bucket_index >= self.num_buckets) {
            return Status.init(.NOT_FOUND_ERROR);
        }

        // Advance past current record.
        if (iter.record_offset != 0) {
            const hdr = self.readRecordHeaderFromFile(iter.record_offset) catch return Status.init(.SYSTEM_ERROR);
            const child = decodeChildOffset(hdr.child_offset, self.align_pow);
            iter.record_offset = child;
        }

        if (iter.record_offset == 0) {
            iter.bucket_index += 1;
        }

        self.advanceToLiveRecord(iter);
        if (iter.bucket_index >= self.num_buckets) {
            return Status.init(.NOT_FOUND_ERROR);
        }
        return Status.init(.SUCCESS);
    }

    fn iterProcess(self: *HashDBMImpl, iter: *HashDBMIteratorImpl, proc: anytype, writable: bool) Status {
        if (!self.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        if (iter.bucket_index >= self.num_buckets or iter.record_offset == 0) {
            return Status.init(.NOT_FOUND_ERROR);
        }
        if (writable and !self.writable) return Status.initMsg(.PRECONDITION_ERROR, "not writable");

        var rec = self.readFullRecord(iter.record_offset, self.allocator) catch return Status.init(.SYSTEM_ERROR);
        defer rec.deinit();

        if (!writable) {
            _ = proc.processFull(rec.key, rec.value);
            return Status.init(.SUCCESS);
        }

        const cur_offset = iter.record_offset;
        const action = proc.processFull(rec.key, rec.value);
        switch (action) {
            .noop => return Status.init(.SUCCESS),
            .remove => {
                self.voidRecord(cur_offset) catch return Status.init(.SYSTEM_ERROR);
                const child = rec.header.child_offset;
                const first_raw = self.readBucket(iter.bucket_index) catch return Status.init(.SYSTEM_ERROR);
                const head_off: i64 = if (first_raw == 0) 0 else decodeChildOffset(first_raw, self.align_pow);
                var prev_off: i64 = 0;
                var scan = head_off;
                while (scan != 0 and scan != cur_offset) {
                    const scan_rec = self.readFullRecord(scan, self.allocator) catch break;
                    prev_off = scan;
                    scan = scan_rec.header.child_offset;
                    scan_rec.allocator.free(scan_rec.key);
                    scan_rec.allocator.free(scan_rec.value);
                }
                if (prev_off == 0) {
                    const raw_c = if (child == 0) @as(i64, 0) else encodeOffset(child, self.align_pow);
                    self.writeBucket(iter.bucket_index, raw_c) catch return Status.init(.SYSTEM_ERROR);
                } else {
                    self.writeChildOffset(prev_off, child) catch return Status.init(.SYSTEM_ERROR);
                }
                _ = self.num_records.fetchSub(1, .monotonic);
                _ = self.eff_data_size.fetchAdd(-@as(i64, @intCast(rec.key.len + rec.value.len)), .monotonic);
                if (self.update_logger) |ul| _ = ul.writeRemove(rec.key);
                // Advance iterator past deleted record.
                iter.record_offset = child;
                if (child == 0) {
                    iter.bucket_index += 1;
                    self.advanceToLiveRecord(iter);
                }
                return Status.init(.SUCCESS);
            },
            .set => |new_v| {
                const child = rec.header.child_offset;
                const new_off = self.appendRecord(RECORD_MAGIC_SET, child, rec.key, new_v, 0) catch
                    return Status.init(.SYSTEM_ERROR);
                self.voidRecord(cur_offset) catch return Status.init(.SYSTEM_ERROR);
                const first_raw2 = self.readBucket(iter.bucket_index) catch return Status.init(.SYSTEM_ERROR);
                const head_off2: i64 = if (first_raw2 == 0) 0 else decodeChildOffset(first_raw2, self.align_pow);
                var prev_off: i64 = 0;
                var scan = head_off2;
                while (scan != 0 and scan != cur_offset) {
                    const scan_rec = self.readFullRecord(scan, self.allocator) catch break;
                    prev_off = scan;
                    scan = scan_rec.header.child_offset;
                    scan_rec.allocator.free(scan_rec.key);
                    scan_rec.allocator.free(scan_rec.value);
                }
                if (prev_off == 0) {
                    const raw_new = encodeOffset(new_off, self.align_pow);
                    self.writeBucket(iter.bucket_index, raw_new) catch return Status.init(.SYSTEM_ERROR);
                } else {
                    self.writeChildOffset(prev_off, new_off) catch return Status.init(.SYSTEM_ERROR);
                }
                const eds_delta: i64 = @as(i64, @intCast(new_v.len)) - @as(i64, @intCast(rec.value.len));
                _ = self.eff_data_size.fetchAdd(eds_delta, .monotonic);
                if (self.update_logger) |ul| _ = ul.writeSet(rec.key, new_v);
                iter.record_offset = new_off;
                return Status.init(.SUCCESS);
            },
        }
    }

    fn iterGet(
        self: *HashDBMImpl,
        iter: *HashDBMIteratorImpl,
        key_out: ?*std.ArrayList(u8),
        value_out: ?*std.ArrayList(u8),
    ) Status {
        if (!self.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        if (iter.bucket_index >= self.num_buckets or iter.record_offset == 0) {
            return Status.init(.NOT_FOUND_ERROR);
        }

        var rec = self.readFullRecord(iter.record_offset, self.allocator) catch return Status.init(.SYSTEM_ERROR);
        defer rec.deinit();

        if (key_out) |ko| {
            ko.clearRetainingCapacity();
            ko.appendSlice(self.allocator, rec.key) catch return Status.init(.SYSTEM_ERROR);
        }
        if (value_out) |vo| {
            vo.clearRetainingCapacity();
            vo.appendSlice(self.allocator, rec.value) catch return Status.init(.SYSTEM_ERROR);
        }
        return Status.init(.SUCCESS);
    }
};

// ---------------------------------------------------------------------------
// Built-in processors
// ---------------------------------------------------------------------------

const ProcessorGet = struct {
    status: *Status,
    value: ?*std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn processFull(self: *ProcessorGet, key: []const u8, value: []const u8) RecordAction {
        _ = key;
        if (self.value) |v| {
            v.clearRetainingCapacity();
            v.appendSlice(self.allocator, value) catch {
                self.status.* = Status.init(.SYSTEM_ERROR);
                return .noop;
            };
        }
        self.status.* = Status.init(.SUCCESS);
        return .noop;
    }

    pub fn processEmpty(self: *ProcessorGet, key: []const u8) RecordAction {
        _ = key;
        self.status.* = Status.init(.NOT_FOUND_ERROR);
        return .noop;
    }
};

const ProcessorSet = struct {
    status: *Status,
    value: []const u8,
    overwrite: bool,
    old_value: ?*std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn processFull(self: *ProcessorSet, key: []const u8, value: []const u8) RecordAction {
        _ = key;
        if (self.old_value) |ov| {
            ov.clearRetainingCapacity();
            ov.appendSlice(self.allocator, value) catch {
                self.status.* = Status.init(.SYSTEM_ERROR);
                return .noop;
            };
        }
        if (self.overwrite) {
            return RecordAction{ .set = self.value };
        }
        self.status.* = Status.init(.DUPLICATION_ERROR);
        return .noop;
    }

    pub fn processEmpty(self: *ProcessorSet, key: []const u8) RecordAction {
        _ = key;
        return RecordAction{ .set = self.value };
    }
};

const ProcessorRemove = struct {
    status: *Status,

    pub fn processFull(self: *ProcessorRemove, key: []const u8, value: []const u8) RecordAction {
        _ = self;
        _ = key;
        _ = value;
        return .remove;
    }

    pub fn processEmpty(self: *ProcessorRemove, key: []const u8) RecordAction {
        _ = key;
        self.status.* = Status.init(.NOT_FOUND_ERROR);
        return .noop;
    }
};

const ProcessorCompareExchange = struct {
    status: *Status,
    expected: dbm_mod.CompareExpected,
    desired: dbm_mod.CompareDesired,
    allocator: std.mem.Allocator,
    actual_out: ?*std.ArrayList(u8) = null,
    found_out: ?*bool = null,

    pub fn processFull(self: *ProcessorCompareExchange, key: []const u8, value: []const u8) RecordAction {
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

    pub fn processEmpty(self: *ProcessorCompareExchange, key: []const u8) RecordAction {
        _ = key;
        if (self.found_out) |f| f.* = false;
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

const ProcessorIncrement = struct {
    status: *Status,
    delta: i64,
    current_out: ?*i64,
    initial: i64,
    result_buf: [8]u8 = [_]u8{0} ** 8,
    result_slice: []const u8 = &[_]u8{},

    pub fn processFull(self: *ProcessorIncrement, key: []const u8, value: []const u8) RecordAction {
        _ = key;
        const current = @as(i64, @bitCast(str_util.strToIntBigEndian(value)));
        if (self.delta == lib_common.INT64MIN) {
            if (self.current_out) |c| c.* = current;
            return .noop;
        }
        const new_val = current +% self.delta;
        const enc = str_util.intToStrBigEndian(@as(u64, @bitCast(new_val)), 8, &self.result_buf);
        self.result_slice = enc;
        if (self.current_out) |c| c.* = new_val;
        return RecordAction{ .set = self.result_slice };
    }

    pub fn processEmpty(self: *ProcessorIncrement, key: []const u8) RecordAction {
        _ = key;
        if (self.delta == lib_common.INT64MIN) {
            if (self.current_out) |c| c.* = self.initial;
            return .noop;
        }
        const new_val = self.initial +% self.delta;
        const enc = str_util.intToStrBigEndian(@as(u64, @bitCast(new_val)), 8, &self.result_buf);
        self.result_slice = enc;
        if (self.current_out) |c| c.* = new_val;
        return RecordAction{ .set = self.result_slice };
    }
};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

pub const HashDBM = struct {
    impl: *HashDBMImpl,
    allocator: std.mem.Allocator,

    pub fn init(file: file_mod.File, num_buckets: i64, allocator: std.mem.Allocator) !HashDBM {
        const impl = try HashDBMImpl.init(file, num_buckets, -1, allocator);
        return HashDBM{ .impl = impl, .allocator = allocator };
    }

    /// Like init but also sets the alignment power. Used by TreeDBM which needs non-default
    /// align_pow and num_buckets to match C++ TreeDBM::DEFAULT_* constants.
    pub fn initWithOptions(file: file_mod.File, num_buckets: i64, align_pow: i32, allocator: std.mem.Allocator) !HashDBM {
        const impl = try HashDBMImpl.init(file, num_buckets, align_pow, allocator);
        return HashDBM{ .impl = impl, .allocator = allocator };
    }

    /// Controls how records are written to the hash file. Matches C++ HashDBM::UpdateMode.
    pub const UpdateMode = enum(i32) {
        default    = 0,
        in_place   = 1,
        appending  = 2,
    };

    /// Per-record CRC mode. Matches C++ HashDBM::RecordCRCMode.
    pub const RecordCRCMode = enum(i32) {
        default = 0,
        none    = 1,
        crc_8   = 2,
        crc_16  = 3,
        crc_32  = 4,
    };

    /// Per-record compression mode. Matches C++ HashDBM::RecordCompressionMode.
    pub const RecordCompressionMode = enum(i32) {
        default = 0,
        none    = 1,
        zlib    = 2,
        zstd    = 3,
        lz4     = 4,
        lzma    = 5,
        rc4     = 6,
        aes     = 7,
    };

    /// Crash-recovery mode on open. Matches C++ HashDBM::RestoreMode (same values as SkipDBM).
    pub const RestoreMode = enum(i32) {
        restore_default   = 0,
        restore_sync      = 1,
        restore_read_only = 2,
        restore_noop      = 3,
    };
    pub const RESTORE_NO_SHORTCUTS: i32  = 1 << 16;
    pub const RESTORE_WITH_HARDSYNC: i32 = 1 << 17;

    pub const TuningParameters = struct {
        update_mode:      UpdateMode             = .default,
        record_crc_mode:  RecordCRCMode          = .default,
        record_comp_mode: RecordCompressionMode  = .default,
        offset_width:     i32                    = DEFAULT_OFFSET_WIDTH,
        align_pow:        i32                    = DEFAULT_ALIGN_POW,
        num_buckets:      i64                    = DEFAULT_NUM_BUCKETS,
        restore_mode:     i32                    = 0,
        fbp_capacity:     i32                    = -1,
        min_read_size:    i32                    = -1,
        cache_buckets:    i32                    = -1,
        cipher_key:       []const u8             = "",
    };

    pub fn openAdvanced(self: *HashDBM, path: []const u8, writable: bool, options: file_mod.OpenOptions, params: TuningParameters, io: std.Io) Status {
        if (params.num_buckets > 0) self.impl.num_buckets = params.num_buckets;
        if (params.align_pow >= 0) self.impl.align_pow = params.align_pow;
        if (params.offset_width > 0) self.impl.offset_width = params.offset_width;
        return self.impl.openImpl(path, writable, options, io);
    }

    pub fn deinit(self: *HashDBM) void {
        self.impl.deinit();
    }

    pub fn open(self: *HashDBM, path: []const u8, writable: bool, options: file_mod.OpenOptions, io: std.Io) Status {
        return self.impl.openImpl(path, writable, options, io);
    }

    pub fn close(self: *HashDBM, io: std.Io) Status {
        _ = io;
        return self.impl.closeImpl();
    }

    pub fn get(self: *HashDBM, key: []const u8, value: ?*std.ArrayList(u8)) Status {
        var status = Status.init(.SUCCESS);
        var proc = ProcessorGet{
            .status = &status,
            .value = value,
            .allocator = self.allocator,
        };
        const st = self.impl.process(key, &proc, false);
        if (!st.isOk()) return st;
        return status;
    }

    pub fn getSimple(self: *HashDBM, key: []const u8, default_value: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        // get() appends into buf using self.allocator (the DB allocator), so deinit with it.
        defer buf.deinit(self.allocator);
        const st = self.get(key, &buf);
        if (st.isOk()) return try allocator.dupe(u8, buf.items);
        return try allocator.dupe(u8, default_value);
    }

    pub fn set(self: *HashDBM, key: []const u8, value: []const u8, overwrite: bool, old_value: ?*std.ArrayList(u8)) Status {
        var status = Status.init(.SUCCESS);
        var proc = ProcessorSet{
            .status = &status,
            .value = value,
            .overwrite = overwrite,
            .old_value = old_value,
            .allocator = self.allocator,
        };
        const st = self.impl.process(key, &proc, true);
        if (!st.isOk()) return st;
        return status;
    }

    pub fn remove(self: *HashDBM, key: []const u8) Status {
        var status = Status.init(.SUCCESS);
        var proc = ProcessorRemove{ .status = &status };
        const st = self.impl.process(key, &proc, true);
        if (!st.isOk()) return st;
        return status;
    }

    pub fn append(self: *HashDBM, key: []const u8, value: []const u8, delim: []const u8) Status {
        const AppendProc = struct {
            value: []const u8,
            delim: []const u8,
            status: *Status,
            allocator: std.mem.Allocator,
            combined: ?[]u8 = null,

            pub fn processFull(ap: *@This(), key2: []const u8, existing: []const u8) RecordAction {
                _ = key2;
                const new_buf = ap.allocator.alloc(u8, existing.len + ap.delim.len + ap.value.len) catch {
                    ap.status.* = Status.init(.SYSTEM_ERROR);
                    return .noop;
                };
                @memcpy(new_buf[0..existing.len], existing);
                @memcpy(new_buf[existing.len .. existing.len + ap.delim.len], ap.delim);
                @memcpy(new_buf[existing.len + ap.delim.len ..], ap.value);
                ap.combined = new_buf;
                return RecordAction{ .set = new_buf };
            }

            pub fn processEmpty(ap: *@This(), key2: []const u8) RecordAction {
                _ = key2;
                return RecordAction{ .set = ap.value };
            }
        };

        var status = Status.init(.SUCCESS);
        var proc = AppendProc{
            .value = value,
            .delim = delim,
            .status = &status,
            .allocator = self.allocator,
        };
        defer if (proc.combined) |buf| self.allocator.free(buf);
        const st = self.impl.process(key, &proc, true);
        if (!st.isOk()) return st;
        return status;
    }

    pub fn getMulti(self: *HashDBM, keys: []const []const u8, records: *std.StringHashMap([]u8)) Status {
        const map_alloc = records.allocator;
        var status = Status.init(.SUCCESS);
        var val_buf: std.ArrayList(u8) = .empty;
        defer val_buf.deinit(self.allocator);
        for (keys) |key| {
            val_buf.clearRetainingCapacity();
            const st = self.get(key, &val_buf);
            if (st.isOk()) {
                const duped_key = map_alloc.dupe(u8, key) catch {
                    status.mergeFrom(Status.init(.SYSTEM_ERROR));
                    continue;
                };
                const duped_val = map_alloc.dupe(u8, val_buf.items) catch {
                    map_alloc.free(duped_key);
                    status.mergeFrom(Status.init(.SYSTEM_ERROR));
                    continue;
                };
                records.put(duped_key, duped_val) catch {
                    map_alloc.free(duped_key);
                    map_alloc.free(duped_val);
                    status.mergeFrom(Status.init(.SYSTEM_ERROR));
                    continue;
                };
            } else {
                status.mergeFrom(st);
            }
        }
        return status;
    }

    pub fn setMulti(self: *HashDBM, records: []const [2][]const u8, overwrite: bool) Status {
        var status = Status.init(.SUCCESS);
        for (records) |r| {
            const st = self.set(r[0], r[1], overwrite, null);
            status.mergeFrom(st);
            if (!status.isOk() and status.code != .DUPLICATION_ERROR) break;
        }
        return status;
    }

    pub fn removeMulti(self: *HashDBM, keys: []const []const u8) Status {
        var status = Status.init(.SUCCESS);
        for (keys) |key| {
            const st = self.remove(key);
            status.mergeFrom(st);
            if (!status.isOk() and status.code != .NOT_FOUND_ERROR) break;
        }
        return status;
    }

    pub fn appendMulti(self: *HashDBM, records: []const [2][]const u8, delim: []const u8) Status {
        var status = Status.init(.SUCCESS);
        for (records) |r| {
            const st = self.append(r[0], r[1], delim);
            status.mergeFrom(st);
            if (!status.isOk()) break;
        }
        return status;
    }

    pub fn countInternal(self: *HashDBM) i64 {
        return self.impl.num_records.load(.acquire);
    }

    pub fn getEffectiveDataSize(self: *HashDBM) i64 {
        return self.impl.eff_data_size.load(.acquire);
    }

    pub fn getFileSizeInternal(self: *HashDBM) i64 {
        return self.impl.file.getSizeSimple();
    }

    fn getFilePathInternal(self: *HashDBM) []const u8 {
        return self.impl.path.items;
    }

    pub fn isOrdered(_: *HashDBM) bool {
        return false;
    }

    pub fn getTimestampInternal(self: *HashDBM) f64 {
        return @as(f64, @floatFromInt(self.impl.timestamp)) / 1e6;
    }

    pub fn isOpen(self: *HashDBM) bool {
        return self.impl.open;
    }

    pub fn isWritable(self: *HashDBM) bool {
        return self.impl.writable;
    }

    pub fn isHealthy(self: *HashDBM) bool {
        return self.impl.healthy;
    }

    pub fn isAutoRestored(self: *HashDBM) bool {
        return self.impl.auto_restored;
    }

    /// Returns the total number of hash buckets. Matches C++ HashDBM::CountBuckets().
    pub fn countBuckets(self: *HashDBM) i64 {
        return self.impl.num_buckets;
    }

    /// Returns the number of non-empty hash buckets by scanning the bucket array.
    /// Matches C++ HashDBM::CountUsedBuckets().
    pub fn countUsedBuckets(self: *HashDBM) i64 {
        self.impl.mutex.lockShared();
        defer self.impl.mutex.unlockShared();
        if (!self.impl.open) return 0;
        var used: i64 = 0;
        var i: i64 = 0;
        while (i < self.impl.num_buckets) : (i += 1) {
            const raw = self.impl.readBucket(i) catch continue;
            if (raw != 0) used += 1;
        }
        return used;
    }

    /// Returns the current update mode derived from the file's static_flags.
    /// Matches C++ HashDBM::GetUpdateMode().
    pub fn getUpdateMode(self: *HashDBM) UpdateMode {
        const flags = self.impl.static_flags;
        if (flags & STATIC_FLAG_UPDATE_APPENDING != 0) return .appending;
        if (flags & STATIC_FLAG_UPDATE_IN_PLACE != 0) return .in_place;
        return .default;
    }

    /// Switches the open database to appending update mode, updating the on-disk header.
    /// Matches C++ HashDBM::SetUpdateModeAppending().
    pub fn setUpdateModeAppending(self: *HashDBM) Status {
        self.impl.mutex.lock();
        defer self.impl.mutex.unlock();
        if (!self.impl.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        if (!self.impl.writable) return Status.initMsg(.PRECONDITION_ERROR, "not writable");
        self.impl.static_flags &= ~@as(u8, STATIC_FLAG_UPDATE_IN_PLACE);
        self.impl.static_flags |= STATIC_FLAG_UPDATE_APPENDING;
        return saveMetadata(
            self.impl.file,
            &self.impl.cyclic_magic,
            self.impl.static_flags,
            self.impl.offset_width,
            self.impl.align_pow,
            self.impl.num_buckets,
            self.impl.num_records.load(.acquire),
            self.impl.eff_data_size.load(.acquire),
            self.impl.file_size,
            self.impl.timestamp,
            self.impl.db_type,
            &self.impl.opaque_metadata,
            false,
        );
    }

    /// Validates every hash-bucket chain, checking that all record offsets lie within
    /// the valid record area. Matches C++ HashDBM::ValidateHashBuckets().
    pub fn validateHashBuckets(self: *HashDBM) Status {
        self.impl.mutex.lockShared();
        defer self.impl.mutex.unlockShared();
        if (!self.impl.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        const max_chain_len = self.impl.num_records.load(.acquire) + 1;
        var i: i64 = 0;
        while (i < self.impl.num_buckets) : (i += 1) {
            const first_raw = self.impl.readBucket(i) catch
                return Status.initMsg(.BROKEN_DATA_ERROR, "bucket read error");
            if (first_raw == 0) continue;
            var cur_offset = decodeChildOffset(first_raw, self.impl.align_pow);
            var chain_len: i64 = 0;
            while (cur_offset != 0) {
                if (cur_offset < self.impl.record_base or cur_offset >= self.impl.file_size) {
                    return Status.initMsg(.BROKEN_DATA_ERROR, "record offset out of range");
                }
                chain_len += 1;
                if (chain_len > max_chain_len) {
                    return Status.initMsg(.BROKEN_DATA_ERROR, "bucket chain cycle detected");
                }
                const hdr = self.impl.readRecordHeaderFromFile(cur_offset) catch
                    return Status.initMsg(.BROKEN_DATA_ERROR, "record header read error");
                cur_offset = decodeChildOffset(hdr.child_offset, self.impl.align_pow);
            }
        }
        return Status.init(.SUCCESS);
    }

    /// Scans all records between record_base and end_offset, verifying each record's
    /// magic byte and size fields. Pass end_offset=0 to scan to end of file.
    /// Matches C++ HashDBM::ValidateRecords().
    pub fn validateRecords(self: *HashDBM, record_base_arg: i64, end_offset_arg: i64) Status {
        self.impl.mutex.lockShared();
        defer self.impl.mutex.unlockShared();
        if (!self.impl.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        const file_sz = self.impl.file.getSizeSimple();
        const base: i64 = if (record_base_arg > 0) record_base_arg else self.impl.record_base;
        const end: i64 = if (end_offset_arg > 0) @min(end_offset_arg, file_sz) else file_sz;
        var offset: i64 = base;
        while (offset < end) {
            var hdr_buf: [1]u8 = undefined;
            const st_peek = self.impl.file.read(offset, &hdr_buf);
            if (!st_peek.isOk()) break;
            const magic = hdr_buf[0];
            // Padding record — advance one alignment unit.
            if (magic == PADDING_TOP_MAGIC) {
                const align_size: i64 = @as(i64, 1) << @intCast(self.impl.align_pow);
                offset += align_size;
                continue;
            }
            const op = magic & 0xC0;
            if (op != RECORD_MAGIC_VOID and op != RECORD_MAGIC_SET and
                op != RECORD_MAGIC_REMOVE and op != RECORD_MAGIC_ADD)
            {
                return Status.initMsg(.BROKEN_DATA_ERROR, "invalid record magic");
            }
            const hdr = self.impl.readRecordHeaderFromFile(offset) catch
                return Status.initMsg(.BROKEN_DATA_ERROR, "record header parse error");
            const align_size: i64 = @as(i64, 1) << @intCast(self.impl.align_pow);
            const raw_size: i64 = @as(i64, @intCast(hdr.header_size)) +
                @as(i64, @intCast(hdr.key_size)) +
                @as(i64, @intCast(hdr.value_size)) +
                @as(i64, @intCast(hdr.padding_size));
            const whole_size = alignUp(raw_size, align_size);
            if (whole_size <= 0) return Status.initMsg(.BROKEN_DATA_ERROR, "record size zero");
            offset += whole_size;
        }
        return Status.init(.SUCCESS);
    }

    /// Returns true when the database would benefit from a rebuild.
    /// Matches C++ ShouldBeRebuilt: fires on bucket overflow or heavy fragmentation.
    pub fn shouldBeRebuiltInternal(self: *HashDBM) bool {
        if (!self.impl.open) return false;
        const nr = self.impl.num_records.load(.acquire);
        if (nr > self.impl.num_buckets) return true;
        const file_sz = self.impl.file.getSizeSimple();
        const record_section = file_sz - self.impl.record_base;
        if (record_section <= 0) return false;
        const min_record: i64 = 1 + @as(i64, self.impl.offset_width) + 3;
        const eds = self.impl.eff_data_size.load(.acquire);
        const total_rec = eds + min_record * nr;
        const aligned_min = (@as(i64, 1) << @intCast(self.impl.align_pow)) * nr;
        const min_total = total_rec + aligned_min;
        if (record_section > min_total * 2) return true;
        return false;
    }

    /// Fills `out` with the number of records. Returns PRECONDITION_ERROR if not open.
    /// Matches C++ DBM::Count(int64_t* count).
    pub fn count(self: *HashDBM, out: *i64) Status {
        if (!self.impl.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        out.* = self.impl.num_records.load(.acquire);
        return Status.init(.SUCCESS);
    }

    /// Fills `out` with the file size in bytes. Returns PRECONDITION_ERROR if not open.
    /// Matches C++ DBM::GetFileSize(int64_t* size).
    pub fn getFileSize(self: *HashDBM, out: *i64) Status {
        if (!self.impl.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        out.* = self.impl.file.getSizeSimple();
        return Status.init(.SUCCESS);
    }

    /// Appends the file path to `out`. Returns PRECONDITION_ERROR if not open.
    /// Matches C++ DBM::GetFilePath(std::string* path).
    pub fn getFilePath(self: *HashDBM, out: *std.ArrayList(u8)) Status {
        if (!self.impl.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        out.clearRetainingCapacity();
        out.appendSlice(self.allocator, self.impl.path.items) catch return Status.init(.SYSTEM_ERROR);
        return Status.init(.SUCCESS);
    }

    /// Fills `out` with the modification timestamp. Returns PRECONDITION_ERROR if not open.
    /// Matches C++ DBM::GetTimestamp(double* timestamp).
    pub fn getTimestamp(self: *HashDBM, out: *f64) Status {
        if (!self.impl.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        out.* = @as(f64, @floatFromInt(self.impl.timestamp)) / 1e6;
        return Status.init(.SUCCESS);
    }

    /// Sets `out` to whether a rebuild would improve performance. Returns PRECONDITION_ERROR if not open.
    /// Matches C++ DBM::ShouldBeRebuilt(bool* tobe).
    pub fn shouldBeRebuilt(self: *HashDBM, out: *bool) Status {
        if (!self.impl.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        out.* = self.shouldBeRebuiltInternal();
        return Status.init(.SUCCESS);
    }

    pub fn getOpaqueMetadata(self: *HashDBM) []const u8 {
        return &self.impl.opaque_metadata;
    }

    pub fn setOpaqueMetadata(self: *HashDBM, data: []const u8) Status {
        if (!self.impl.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        const copy_len = @min(data.len, OPAQUE_METADATA_SIZE);
        @memcpy(self.impl.opaque_metadata[0..copy_len], data[0..copy_len]);
        if (copy_len < OPAQUE_METADATA_SIZE) {
            @memset(self.impl.opaque_metadata[copy_len..], 0);
        }
        return Status.init(.SUCCESS);
    }

    pub fn setUpdateLogger(self: *HashDBM, logger: ?*dbm_mod.UpdateLogger) void {
        self.impl.update_logger = logger;
    }

    pub fn getUpdateLogger(self: *HashDBM) ?*dbm_mod.UpdateLogger {
        return self.impl.update_logger;
    }

    pub fn process(self: *HashDBM, key: []const u8, proc: anytype, writable: bool) Status {
        return self.impl.process(key, proc, writable);
    }

    pub fn processMulti(self: *HashDBM, comptime P: type, keys: []const []const u8, procs: []const *P, writable: bool) Status {
        return self.impl.processMulti(P, keys, procs, writable);
    }

    pub fn processFirst(self: *HashDBM, proc: anytype, writable: bool) Status {
        return self.impl.processFirst(proc, writable);
    }

    pub fn processEach(self: *HashDBM, proc: anytype, writable: bool) Status {
        return self.impl.processEach(proc, writable);
    }

    pub fn synchronize(self: *HashDBM, hard: bool, io: std.Io) Status {
        return self.impl.synchronizeImpl(hard, io);
    }

    pub fn clear(self: *HashDBM) Status {
        return self.impl.clearImpl();
    }

    pub fn rebuild(self: *HashDBM, io: std.Io) Status {
        return self.impl.rebuildImpl(false, io);
    }

    pub fn rebuildAdvanced(self: *HashDBM, params: TuningParameters, skip_broken_records: bool, sync_hard: bool, io: std.Io) Status {
        if (params.num_buckets > 0) self.impl.num_buckets = params.num_buckets;
        if (params.align_pow >= 0) self.impl.align_pow = params.align_pow;
        if (params.offset_width > 0) self.impl.offset_width = params.offset_width;
        const st = self.impl.rebuildImpl(skip_broken_records, io);
        if (!st.isOk()) return st;
        if (sync_hard) return self.synchronize(true, io);
        return st;
    }

    pub const Entry = struct {
        /// Borrowed from iterator's internal buffer.
        /// Valid only until the next call to next() or deinit().
        key: []const u8,
        /// Borrowed from iterator's internal buffer.
        /// Valid only until the next call to next() or deinit().
        value: []const u8,
    };

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
        pub fn next(self: *Iterator) !?Entry {
            if (self.done) return null;

            // Fill internal buffers from the current cursor position.
            self.key_buf.clearRetainingCapacity();
            self.value_buf.clearRetainingCapacity();
            const st = self.cursor.get(&self.key_buf, &self.value_buf);
            if (!st.isOk()) {
                self.done = true;
                return null;
            }

            // Advance cursor. If it reaches the end, mark done so the next
            // call returns null rather than re-reading the last record.
            if (!self.cursor.next().isOk()) self.done = true;

            return Entry{
                .key = self.key_buf.items,
                .value = self.value_buf.items,
            };
        }

        /// Release internal buffers and the underlying cursor.
        pub fn deinit(self: *Iterator) void {
            self.key_buf.deinit(self.alloc);
            self.value_buf.deinit(self.alloc);
            self.cursor.deinit();
        }
    };

    pub const Cursor = struct {
        impl: *HashDBMIteratorImpl,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *Cursor) void {
            if (self.impl.dbm) |dbm| {
                dbm.mutex.lock();
                defer dbm.mutex.unlock();
                for (0..dbm.iterators.items.len) |i| {
                    if (dbm.iterators.items[i] == self.impl) {
                        _ = dbm.iterators.orderedRemove(i);
                        break;
                    }
                }
            }
            self.allocator.destroy(self.impl);
        }

        pub fn first(self: *Cursor) Status {
            const dbm = self.impl.dbm orelse return Status.initMsg(.PRECONDITION_ERROR, "orphaned iterator");
            return dbm.iterFirst(self.impl);
        }

        pub fn jump(self: *Cursor, key: []const u8) Status {
            const dbm = self.impl.dbm orelse return Status.initMsg(.PRECONDITION_ERROR, "orphaned iterator");
            return dbm.iterJump(self.impl, key);
        }

        pub fn next(self: *Cursor) Status {
            const dbm = self.impl.dbm orelse return Status.initMsg(.PRECONDITION_ERROR, "orphaned iterator");
            return dbm.iterNext(self.impl);
        }

        pub fn last(self: *Cursor) Status {
            _ = self;
            return Status.init(.NOT_IMPLEMENTED_ERROR);
        }

        pub fn previous(self: *Cursor) Status {
            _ = self;
            return Status.init(.NOT_IMPLEMENTED_ERROR);
        }

        pub fn jumpLower(self: *Cursor, key: []const u8, inclusive: bool) Status {
            _ = self;
            _ = key;
            _ = inclusive;
            return Status.init(.NOT_IMPLEMENTED_ERROR);
        }

        pub fn jumpUpper(self: *Cursor, key: []const u8, inclusive: bool) Status {
            _ = self;
            _ = key;
            _ = inclusive;
            return Status.init(.NOT_IMPLEMENTED_ERROR);
        }

        pub fn process(self: *Cursor, proc: anytype, writable: bool) Status {
            const dbm = self.impl.dbm orelse return Status.initMsg(.PRECONDITION_ERROR, "orphaned iterator");
            return dbm.iterProcess(self.impl, proc, writable);
        }

        pub fn get(self: *Cursor, key_out: ?*std.ArrayList(u8), value_out: ?*std.ArrayList(u8)) Status {
            const dbm = self.impl.dbm orelse return Status.initMsg(.PRECONDITION_ERROR, "orphaned iterator");
            return dbm.iterGet(self.impl, key_out, value_out);
        }

        pub fn set(self: *Cursor, value: []const u8, old_key: ?*std.ArrayList(u8), old_value: ?*std.ArrayList(u8)) Status {
            const SetProc = struct {
                value: []const u8,
                old_key: ?*std.ArrayList(u8),
                old_value: ?*std.ArrayList(u8),
                allocator: std.mem.Allocator,
                status: Status = Status.init(.SUCCESS),
                pub fn processFull(p: *@This(), key: []const u8, val: []const u8) RecordAction {
                    if (p.old_key) |ok| {
                        ok.clearRetainingCapacity();
                        ok.appendSlice(p.allocator, key) catch { p.status = Status.init(.SYSTEM_ERROR); return .noop; };
                    }
                    if (p.old_value) |ov| {
                        ov.clearRetainingCapacity();
                        ov.appendSlice(p.allocator, val) catch { p.status = Status.init(.SYSTEM_ERROR); return .noop; };
                    }
                    return RecordAction{ .set = p.value };
                }
                pub fn processEmpty(_: *@This(), _: []const u8) RecordAction { return .noop; }
            };
            var proc = SetProc{ .value = value, .old_key = old_key, .old_value = old_value, .allocator = self.allocator };
            const st = self.process(&proc, true);
            if (!st.isOk()) return st;
            return proc.status;
        }

        pub fn remove(self: *Cursor, old_key: ?*std.ArrayList(u8), old_value: ?*std.ArrayList(u8)) Status {
            const RemoveProc = struct {
                old_key: ?*std.ArrayList(u8),
                old_value: ?*std.ArrayList(u8),
                allocator: std.mem.Allocator,
                status: Status = Status.init(.SUCCESS),
                pub fn processFull(p: *@This(), key: []const u8, val: []const u8) RecordAction {
                    if (p.old_key) |ok| {
                        ok.clearRetainingCapacity();
                        ok.appendSlice(p.allocator, key) catch { p.status = Status.init(.SYSTEM_ERROR); return .noop; };
                    }
                    if (p.old_value) |ov| {
                        ov.clearRetainingCapacity();
                        ov.appendSlice(p.allocator, val) catch { p.status = Status.init(.SYSTEM_ERROR); return .noop; };
                    }
                    return .remove;
                }
                pub fn processEmpty(p: *@This(), _: []const u8) RecordAction { p.status = Status.init(.NOT_FOUND_ERROR); return .noop; }
            };
            var proc = RemoveProc{ .old_key = old_key, .old_value = old_value, .allocator = self.allocator };
            const st = self.process(&proc, true);
            if (!st.isOk()) return st;
            return proc.status;
        }

        pub fn step(self: *Cursor, key_out: ?*std.ArrayList(u8), value_out: ?*std.ArrayList(u8)) Status {
            const st = self.get(key_out, value_out);
            if (!st.isOk()) return st;
            _ = self.next();
            return Status.init(.SUCCESS);
        }
    };

    /// Return a Zig-style iterator positioned at the first record.
    /// The caller must call deinit() when done.
    pub fn iterate(self: *HashDBM, alloc: std.mem.Allocator) !Iterator {
        var cursor = try self.makeCursor();
        errdefer cursor.deinit();
        var iter = Iterator{
            .cursor = cursor,
            .alloc = alloc,
            .key_buf = .empty,
            .value_buf = .empty,
            .done = false,
        };
        if (!iter.cursor.first().isOk()) iter.done = true;
        return iter;
    }

    /// Return a Zig-style iterator positioned at the first record >= key.
    /// The caller must call deinit() when done.
    pub fn iterateFrom(self: *HashDBM, key: []const u8, alloc: std.mem.Allocator) !Iterator {
        var cursor = try self.makeCursor();
        errdefer cursor.deinit();
        var iter = Iterator{
            .cursor = cursor,
            .alloc = alloc,
            .key_buf = .empty,
            .value_buf = .empty,
            .done = false,
        };
        if (!iter.cursor.jump(key).isOk()) iter.done = true;
        return iter;
    }

    /// Deprecated: use makeCursor instead.
    pub const makeIterator = makeCursor;

    pub fn makeCursor(self: *HashDBM) !Cursor {
        const iter_impl = try self.allocator.create(HashDBMIteratorImpl);
        iter_impl.* = HashDBMIteratorImpl{
            .dbm = self.impl,
            .bucket_index = self.impl.num_buckets, // exhausted until first() called
            .record_offset = 0,
            .allocator = self.allocator,
        };
        self.impl.mutex.lock();
        self.impl.iterators.append(self.allocator, iter_impl) catch {
            self.impl.mutex.unlock();
            self.allocator.destroy(iter_impl);
            return error.OutOfMemory;
        };
        self.impl.mutex.unlock();
        return Cursor{ .impl = iter_impl, .allocator = self.allocator };
    }

    pub fn compareExchange(self: *HashDBM, key: []const u8, expected: dbm_mod.CompareExpected, desired: dbm_mod.CompareDesired, actual_out: ?*std.ArrayList(u8), found_out: ?*bool) Status {
        var status = Status.init(.SUCCESS);
        var proc = ProcessorCompareExchange{
            .status = &status,
            .expected = expected,
            .desired = desired,
            .allocator = self.allocator,
            .actual_out = actual_out,
            .found_out = found_out,
        };
        const st = self.impl.process(key, &proc, true);
        if (!st.isOk()) return st;
        return status;
    }

    pub fn increment(self: *HashDBM, key: []const u8, delta: i64, current_out: ?*i64, initial: i64) Status {
        var status = Status.init(.SUCCESS);
        var proc = ProcessorIncrement{
            .status = &status,
            .delta = delta,
            .current_out = current_out,
            .initial = initial,
        };
        const st = self.impl.process(key, &proc, true);
        if (!st.isOk()) return st;
        return status;
    }

    pub fn incrementSimple(self: *HashDBM, key: []const u8, delta: i64, initial: i64) i64 {
        var result: i64 = initial;
        _ = self.increment(key, delta, &result, initial);
        return result;
    }

    pub fn popFirst(self: *HashDBM, key_out: ?*std.ArrayList(u8), value_out: ?*std.ArrayList(u8)) Status {
        const PopFirstProc = struct {
            status: *Status,
            key_out: ?*std.ArrayList(u8),
            value_out: ?*std.ArrayList(u8),
            allocator: std.mem.Allocator,

            pub fn processFull(ap: *@This(), key2: []const u8, value2: []const u8) RecordAction {
                if (ap.key_out) |ko| {
                    ko.clearRetainingCapacity();
                    ko.appendSlice(ap.allocator, key2) catch {
                        ap.status.* = Status.init(.SYSTEM_ERROR);
                        return .noop;
                    };
                }
                if (ap.value_out) |vo| {
                    vo.clearRetainingCapacity();
                    vo.appendSlice(ap.allocator, value2) catch {
                        ap.status.* = Status.init(.SYSTEM_ERROR);
                        return .noop;
                    };
                }
                return .remove;
            }

            pub fn processEmpty(ap: *@This(), key2: []const u8) RecordAction {
                _ = ap;
                _ = key2;
                return .noop;
            }
        };
        var status = Status.init(.SUCCESS);
        var proc = PopFirstProc{
            .status = &status,
            .key_out = key_out,
            .value_out = value_out,
            .allocator = self.allocator,
        };
        return self.impl.processFirst(&proc, true);
    }

    pub fn pushLast(self: *HashDBM, value: []const u8, wtime: f64, key_out: ?*std.ArrayList(u8), io: std.Io) Status {
        const base: u64 = time_util.pushLastKeyBase(wtime, io);
        var seq: u64 = 0;
        while (true) : (seq += 1) {
            const ts: u64 = base +% seq;
            var key_buf: [8]u8 = undefined;
            const key = str_util.intToStrBigEndian(ts, 8, &key_buf);
            const st = self.set(key, value, false, null);
            if (st.code != .DUPLICATION_ERROR) {
                if (key_out) |ko| {
                    ko.clearRetainingCapacity();
                    ko.appendSlice(self.allocator, key) catch return Status.init(.SYSTEM_ERROR);
                }
                return st;
            }
        }
    }

    /// Returns a list of property name/value pairs describing the database.
    /// Caller owns the returned list and all strings within it.
    pub fn inspect(self: *HashDBM, allocator: std.mem.Allocator) !std.ArrayList([2][]u8) {
        self.impl.mutex.lockShared();
        defer self.impl.mutex.unlockShared();
        var list: std.ArrayList([2][]u8) = .empty;
        errdefer {
            for (list.items) |pair| {
                allocator.free(pair[0]);
                allocator.free(pair[1]);
            }
            list.deinit(allocator);
        }
        const add = struct {
            fn call(lst: *std.ArrayList([2][]u8), alloc: std.mem.Allocator, k: []const u8, v: []const u8) !void {
                const kd = try alloc.dupe(u8, k);
                errdefer alloc.free(kd);
                const vd = try alloc.dupe(u8, v);
                errdefer alloc.free(vd);
                try lst.append(alloc, .{ kd, vd });
            }
        }.call;
        try add(&list, allocator, "class", "HashDBM");
        if (self.impl.open) {
            const healthy_s = if (self.impl.healthy) "true" else "false";
            try add(&list, allocator, "healthy", healthy_s);
            const ar_s = if (self.impl.auto_restored) "true" else "false";
            try add(&list, allocator, "auto_restored", ar_s);
            try add(&list, allocator, "path", self.impl.path.items);
            const cm = try std.fmt.allocPrint(allocator, "{d}", .{self.impl.cyclic_magic});
            defer allocator.free(cm);
            try add(&list, allocator, "cyclic_magic", cm);
            const pkg_maj = try std.fmt.allocPrint(allocator, "{d}", .{PKG_MAJOR_VERSION});
            defer allocator.free(pkg_maj);
            try add(&list, allocator, "pkg_major_version", pkg_maj);
            const pkg_min = try std.fmt.allocPrint(allocator, "{d}", .{PKG_MINOR_VERSION});
            defer allocator.free(pkg_min);
            try add(&list, allocator, "pkg_minor_version", pkg_min);
            const sf = try std.fmt.allocPrint(allocator, "{d}", .{self.impl.static_flags});
            defer allocator.free(sf);
            try add(&list, allocator, "static_flags", sf);
            const ow = try std.fmt.allocPrint(allocator, "{d}", .{self.impl.offset_width});
            defer allocator.free(ow);
            try add(&list, allocator, "offset_width", ow);
            const ap = try std.fmt.allocPrint(allocator, "{d}", .{self.impl.align_pow});
            defer allocator.free(ap);
            try add(&list, allocator, "align_pow", ap);
            const cf = try std.fmt.allocPrint(allocator, "{d}", .{self.impl.closure_flags});
            defer allocator.free(cf);
            try add(&list, allocator, "closure_flags", cf);
            const nb = try std.fmt.allocPrint(allocator, "{d}", .{self.impl.num_buckets});
            defer allocator.free(nb);
            try add(&list, allocator, "num_buckets", nb);
            const nr = try std.fmt.allocPrint(allocator, "{d}", .{self.impl.num_records.load(.acquire)});
            defer allocator.free(nr);
            try add(&list, allocator, "num_records", nr);
            const eds = try std.fmt.allocPrint(allocator, "{d}", .{self.impl.eff_data_size.load(.acquire)});
            defer allocator.free(eds);
            try add(&list, allocator, "eff_data_size", eds);
            const fsz = try std.fmt.allocPrint(allocator, "{d}", .{self.impl.file_size});
            defer allocator.free(fsz);
            try add(&list, allocator, "file_size", fsz);
            const ts_f: f64 = @as(f64, @floatFromInt(self.impl.timestamp)) / 1_000_000.0;
            const ts = try std.fmt.allocPrint(allocator, "{d:.6}", .{ts_f});
            defer allocator.free(ts);
            try add(&list, allocator, "timestamp", ts);
            const dbt = try std.fmt.allocPrint(allocator, "{d}", .{self.impl.db_type});
            defer allocator.free(dbt);
            try add(&list, allocator, "db_type", dbt);
            const shift: u6 = @intCast(@as(i32, self.impl.offset_width) * 8 + @as(i32, self.impl.align_pow));
            const max_fsz: i64 = @as(i64, 1) << shift;
            const mfs = try std.fmt.allocPrint(allocator, "{d}", .{max_fsz});
            defer allocator.free(mfs);
            try add(&list, allocator, "max_file_size", mfs);
            const rb = try std.fmt.allocPrint(allocator, "{d}", .{self.impl.record_base});
            defer allocator.free(rb);
            try add(&list, allocator, "record_base", rb);
            const update_mode = if (self.impl.static_flags & STATIC_FLAG_UPDATE_IN_PLACE != 0)
                "in-place"
            else if (self.impl.static_flags & STATIC_FLAG_UPDATE_APPENDING != 0)
                "appending"
            else
                "unknown";
            try add(&list, allocator, "update_mode", update_mode);
            try add(&list, allocator, "record_crc_mode", "none");
            try add(&list, allocator, "record_comp_mode", "none");
        }
        return list;
    }

    /// Returns the internal File handle. Acquires a shared lock. For testing only.
    /// Returns the database type stored in the file header. Matches C++ GetDatabaseType().
    pub fn getDatabaseType(self: *HashDBM) i32 {
        return self.impl.db_type;
    }

    /// Sets the database type in the file header. Persisted on next synchronize/close.
    /// Matches C++ SetDatabaseType(). Returns PRECONDITION_ERROR if the file is not open for writing.
    pub fn setDatabaseType(self: *HashDBM, db_type: u32) Status {
        if (!self.impl.writable) return Status.initMsg(.PRECONDITION_ERROR, "not writable");
        self.impl.db_type = @intCast(db_type);
        return Status.init(.SUCCESS);
    }

    pub fn getInternalFile(self: *HashDBM) file_mod.File {
        self.impl.mutex.lockShared();
        defer self.impl.mutex.unlockShared();
        return self.impl.file;
    }

    // -----------------------------------------------------------------------
    // Static methods (Phase 5.1)
    // -----------------------------------------------------------------------

    /// Returns the CRC byte-width encoded in static_flags.
    /// 0=none, 1=crc8, 2=crc16, 4=crc32.
    /// Matches C++ HashDBM::GetCRCWidthFromStaticFlags().
    pub fn getCRCWidthFromStaticFlags(static_flags: i32) i32 {
        const sf: u8 = @intCast(static_flags & 0xFF);
        const crc_mask: u8 = 0x38; // bits 3-5 encode CRC type
        return switch (sf & crc_mask) {
            0x08 => 1,
            0x18 => 2,
            0x38 => 4,
            else => 0,
        };
    }

    /// Reads the 128-byte metadata header from a file.
    /// On success fills all output parameters.
    /// If cyclic magic front != back, sets cyclic_magic_out to -1 but still returns SUCCESS.
    /// Matches C++ HashDBM::ReadMetadata().
    pub fn readMetadata(
        file: File,
        cyclic_magic_out: *i32,
        pkg_major_version_out: *i32,
        pkg_minor_version_out: *i32,
        static_flags_out: *i32,
        offset_width_out: *i32,
        align_pow_out: *i32,
        closure_flags_out: *i32,
        num_buckets_out: *i64,
        num_records_out: *i64,
        eff_data_size_out: *i64,
        file_size_out: *i64,
        timestamp_out: *i64,
        db_type_out: *i32,
        opaque_out: []u8,
    ) Status {
        const file_sz = file.getSizeSimple();
        if (file_sz < METADATA_SIZE) return Status.initMsg(.BROKEN_DATA_ERROR, "too small metadata");
        var buf: [METADATA_SIZE]u8 = undefined;
        const st = file.read(0, &buf);
        if (!st.isOk()) return st;
        if (!std.mem.eql(u8, buf[0..9], META_MAGIC)) return Status.initMsg(.BROKEN_DATA_ERROR, "bad magic data");
        const cm_front: i32 = buf[9];
        pkg_major_version_out.* = buf[10];
        pkg_minor_version_out.* = buf[11];
        static_flags_out.* = buf[12];
        offset_width_out.* = buf[13];
        align_pow_out.* = buf[14];
        closure_flags_out.* = buf[15];
        num_buckets_out.* = std.mem.readInt(i64, buf[16..24], .little);
        num_records_out.* = std.mem.readInt(i64, buf[24..32], .little);
        eff_data_size_out.* = std.mem.readInt(i64, buf[32..40], .little);
        file_size_out.* = std.mem.readInt(i64, buf[40..48], .little);
        timestamp_out.* = std.mem.readInt(i64, buf[48..56], .little);
        db_type_out.* = std.mem.readInt(i16, buf[56..58], .little);
        const copy_len = @min(opaque_out.len, OPAQUE_METADATA_SIZE);
        @memcpy(opaque_out[0..copy_len], buf[62..62 + copy_len]);
        const cm_back: i32 = buf[127];
        cyclic_magic_out.* = if (cm_front == cm_back) cm_front else -1;
        return Status.init(.SUCCESS);
    }

    /// Finds the record base offset and format parameters from a HashDBM file header.
    /// Matches C++ HashDBM::FindRecordBase().
    pub fn findRecordBase(
        file: File,
        record_base_out: *i64,
        static_flags_out: *i32,
        offset_width_out: *i32,
        align_pow_out: *i32,
        last_sync_size_out: *i64,
    ) Status {
        const file_sz = file.getSizeSimple();
        if (file_sz < METADATA_SIZE) return Status.initMsg(.BROKEN_DATA_ERROR, "too small file");
        var buf: [METADATA_SIZE]u8 = undefined;
        const st = file.read(0, &buf);
        if (!st.isOk()) return st;
        if (!std.mem.eql(u8, buf[0..9], META_MAGIC)) return Status.initMsg(.BROKEN_DATA_ERROR, "bad magic data");
        const sf: i32 = buf[12];
        const ow: i32 = buf[13];
        const ap: i32 = buf[14];
        const nb = std.mem.readInt(i64, buf[16..24], .little);
        const fsz = std.mem.readInt(i64, buf[40..48], .little);
        static_flags_out.* = sf;
        offset_width_out.* = ow;
        align_pow_out.* = ap;
        record_base_out.* = recordBaseOffset(nb, ow, ap);
        const cm_front = buf[9];
        const cm_back = buf[127];
        last_sync_size_out.* = if (cm_front == cm_back) fsz else 0;
        return Status.init(.SUCCESS);
    }

    // -----------------------------------------------------------------------
    // Import instance methods (Phase 5.2)
    // -----------------------------------------------------------------------

    /// Imports records from a HashDBM File object in forward order (first-to-last).
    /// Matches C++ HashDBM::ImportFromFileForward(File*, ...).
    pub fn importFromFileForwardFile(
        self: *HashDBM,
        file: File,
        skip_broken_records: bool,
        record_base: i64,
        end_offset: i64,
    ) Status {
        if (!self.impl.open or !self.impl.writable)
            return Status.initMsg(.PRECONDITION_ERROR, "not open or not writable");

        var src_rb: i64 = 0;
        var src_sf: i32 = 0;
        var src_ow: i32 = DEFAULT_OFFSET_WIDTH;
        var src_ap: i32 = DEFAULT_ALIGN_POW;
        var last_sync: i64 = 0;
        {
            const st = HashDBM.findRecordBase(file, &src_rb, &src_sf, &src_ow, &src_ap, &last_sync);
            if (!st.isOk()) return st;
        }

        const eff_rb: i64 = if (record_base >= 0) record_base else src_rb;
        const file_sz = file.getSizeSimple();
        var eff_end: i64 = if (end_offset > 0) @min(end_offset, file_sz)
            else if (end_offset == 0) (if (last_sync > eff_rb) last_sync else file_sz)
            else file_sz;
        if (eff_end > file_sz) eff_end = file_sz;

        const align_size: i64 = @as(i64, 1) << @intCast(@as(u6, @intCast(@max(0, src_ap))));
        var offset: i64 = eff_rb;

        while (offset < eff_end) {
            var hdr_buf: [64]u8 = undefined;
            const avail: i64 = eff_end - offset;
            const read_n: usize = @intCast(@min(64, avail));
            const st_r = file.read(offset, hdr_buf[0..read_n]);
            if (!st_r.isOk()) {
                if (skip_broken_records) { offset += align_size; continue; }
                return st_r;
            }

            const magic = hdr_buf[0];

            if (magic == PADDING_TOP_MAGIC) {
                offset += align_size;
                continue;
            }

            const op = magic & 0xC0;

            const hdr = readRecordHeader(hdr_buf[0..read_n], src_ow) orelse {
                if (skip_broken_records) { offset += align_size; continue; }
                return Status.initMsg(.BROKEN_DATA_ERROR, "bad record header in import");
            };

            const raw_size: i64 = @as(i64, @intCast(hdr.header_size)) +
                @as(i64, @intCast(hdr.key_size)) +
                @as(i64, @intCast(hdr.value_size)) +
                @as(i64, @intCast(hdr.padding_size));
            const whole_size = alignUp(raw_size, align_size);
            if (whole_size <= 0) {
                if (skip_broken_records) { offset += align_size; continue; }
                return Status.initMsg(.BROKEN_DATA_ERROR, "zero record size in import");
            }

            if (op == RECORD_MAGIC_SET or op == RECORD_MAGIC_ADD) {
                const kv_size = hdr.key_size + hdr.value_size;
                const kv_buf = self.allocator.alloc(u8, kv_size) catch return Status.init(.SYSTEM_ERROR);
                defer self.allocator.free(kv_buf);
                const kv_off = offset + @as(i64, @intCast(hdr.header_size));
                const st_kv = file.read(kv_off, kv_buf);
                if (!st_kv.isOk()) {
                    if (skip_broken_records) { offset += whole_size; continue; }
                    return st_kv;
                }
                const key = kv_buf[0..hdr.key_size];
                const value = kv_buf[hdr.key_size..kv_size];
                const st_set = self.set(key, value, true, null);
                if (!st_set.isOk()) {
                    if (skip_broken_records) { offset += whole_size; continue; }
                    return st_set;
                }
            } else if (op == RECORD_MAGIC_REMOVE) {
                if (hdr.key_size > 0) {
                    const key_buf = self.allocator.alloc(u8, hdr.key_size) catch return Status.init(.SYSTEM_ERROR);
                    defer self.allocator.free(key_buf);
                    const key_off = offset + @as(i64, @intCast(hdr.header_size));
                    const st_k = file.read(key_off, key_buf);
                    if (!st_k.isOk()) {
                        if (skip_broken_records) { offset += whole_size; continue; }
                        return st_k;
                    }
                    _ = self.remove(key_buf);
                }
            }
            // VOID records: skip

            offset += whole_size;
        }
        return Status.init(.SUCCESS);
    }

    /// Imports records from a HashDBM file by path, in forward order.
    /// Matches C++ HashDBM::ImportFromFileForward(const std::string&, ...).
    pub fn importFromFileForward(
        self: *HashDBM,
        path: []const u8,
        skip_broken_records: bool,
        record_base: i64,
        end_offset: i64,
    ) Status {
        const sf = file_mod.StdFile.create(self.allocator) catch return Status.init(.SYSTEM_ERROR);
        var file = sf.asFile();
        defer file.deinit(self.allocator);
        {
            const st = file.open(path, false, .{});
            if (!st.isOk()) return st;
        }
        defer _ = file.close();
        return self.importFromFileForwardFile(file, skip_broken_records, record_base, end_offset);
    }

    /// Imports records from a HashDBM File object in backward order (last-to-first).
    /// This ensures the latest record for each key wins, which is correct for
    /// UPDATE_APPENDING mode databases.
    /// Matches C++ HashDBM::ImportFromFileBackward(File*, ...).
    pub fn importFromFileBackwardFile(
        self: *HashDBM,
        file: File,
        skip_broken_records: bool,
        record_base: i64,
        end_offset: i64,
    ) Status {
        if (!self.impl.open or !self.impl.writable)
            return Status.initMsg(.PRECONDITION_ERROR, "not open or not writable");

        var src_rb: i64 = 0;
        var src_sf: i32 = 0;
        var src_ow: i32 = DEFAULT_OFFSET_WIDTH;
        var src_ap: i32 = DEFAULT_ALIGN_POW;
        var last_sync: i64 = 0;
        {
            const st = HashDBM.findRecordBase(file, &src_rb, &src_sf, &src_ow, &src_ap, &last_sync);
            if (!st.isOk()) return st;
        }

        const eff_rb: i64 = if (record_base >= 0) record_base else src_rb;
        const file_sz = file.getSizeSimple();
        var eff_end: i64 = if (end_offset > 0) @min(end_offset, file_sz)
            else if (end_offset == 0) (if (last_sync > eff_rb) last_sync else file_sz)
            else file_sz;
        if (eff_end > file_sz) eff_end = file_sz;

        const align_size: i64 = @as(i64, 1) << @intCast(@as(u6, @intCast(@max(0, src_ap))));

        // Pass 1: collect all non-VOID record offsets via forward scan.
        var offsets: std.ArrayListUnmanaged(i64) = .empty;
        defer offsets.deinit(self.allocator);

        {
            var offset: i64 = eff_rb;
            while (offset < eff_end) {
                var hdr_buf: [64]u8 = undefined;
                const avail: i64 = eff_end - offset;
                const read_n: usize = @intCast(@min(64, avail));
                const st_r = file.read(offset, hdr_buf[0..read_n]);
                if (!st_r.isOk()) {
                    if (skip_broken_records) { offset += align_size; continue; }
                    return st_r;
                }
                const magic = hdr_buf[0];
                if (magic == PADDING_TOP_MAGIC) {
                    offset += align_size;
                    continue;
                }
                const hdr = readRecordHeader(hdr_buf[0..read_n], src_ow) orelse {
                    if (skip_broken_records) { offset += align_size; continue; }
                    return Status.initMsg(.BROKEN_DATA_ERROR, "bad record header");
                };
                const raw_size: i64 = @as(i64, @intCast(hdr.header_size)) +
                    @as(i64, @intCast(hdr.key_size)) +
                    @as(i64, @intCast(hdr.value_size)) +
                    @as(i64, @intCast(hdr.padding_size));
                const whole_size = alignUp(raw_size, align_size);
                if (whole_size <= 0) {
                    if (skip_broken_records) { offset += align_size; continue; }
                    return Status.initMsg(.BROKEN_DATA_ERROR, "zero size record");
                }
                const op = magic & 0xC0;
                if (op != RECORD_MAGIC_VOID) {
                    offsets.append(self.allocator, offset) catch return Status.init(.SYSTEM_ERROR);
                }
                offset += whole_size;
            }
        }

        // Pass 2: process in reverse order.
        // dead_set tracks keys already handled (either set or deleted by a later record).
        var dead_set: std.StringHashMapUnmanaged(void) = .{};
        defer {
            var it = dead_set.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            dead_set.deinit(self.allocator);
        }

        var i: usize = offsets.items.len;
        while (i > 0) {
            i -= 1;
            const offset = offsets.items[i];

            var hdr_buf: [64]u8 = undefined;
            const avail: i64 = eff_end - offset;
            const read_n: usize = @intCast(@min(64, avail));
            _ = file.read(offset, hdr_buf[0..read_n]);

            const magic = hdr_buf[0];
            const op = magic & 0xC0;

            const hdr = readRecordHeader(hdr_buf[0..read_n], src_ow) orelse continue;

            // Read the key.
            const key_buf = self.allocator.alloc(u8, hdr.key_size) catch return Status.init(.SYSTEM_ERROR);
            defer self.allocator.free(key_buf);
            const key_off = offset + @as(i64, @intCast(hdr.header_size));
            {
                const st_k = file.read(key_off, key_buf);
                if (!st_k.isOk()) {
                    if (skip_broken_records) continue;
                    return st_k;
                }
            }
            const key: []const u8 = key_buf;

            if (op == RECORD_MAGIC_SET or op == RECORD_MAGIC_ADD) {
                // Skip if a later record already handled this key.
                if (dead_set.contains(key)) continue;

                // Read value.
                const val_buf = self.allocator.alloc(u8, hdr.value_size) catch return Status.init(.SYSTEM_ERROR);
                defer self.allocator.free(val_buf);
                const val_off = key_off + @as(i64, @intCast(hdr.key_size));
                {
                    const st_v = file.read(val_off, val_buf);
                    if (!st_v.isOk()) {
                        if (skip_broken_records) continue;
                        return st_v;
                    }
                }

                // overwrite=false so later (already imported) records win over earlier ones.
                const st_set = self.set(key, val_buf, false, null);
                if (!st_set.isOk() and st_set.code != .DUPLICATION_ERROR) {
                    if (skip_broken_records) continue;
                    return st_set;
                }
                // Mark key as handled so earlier records for this key are skipped.
                const key_copy = self.allocator.dupe(u8, key) catch return Status.init(.SYSTEM_ERROR);
                dead_set.put(self.allocator, key_copy, {}) catch {
                    self.allocator.free(key_copy);
                    return Status.init(.SYSTEM_ERROR);
                };
            } else if (op == RECORD_MAGIC_REMOVE) {
                // REMOVE record — if no later SET imported this key, mark dead so earlier ADDs are skipped.
                if (!dead_set.contains(key)) {
                    const key_copy = self.allocator.dupe(u8, key) catch return Status.init(.SYSTEM_ERROR);
                    dead_set.put(self.allocator, key_copy, {}) catch {
                        self.allocator.free(key_copy);
                        return Status.init(.SYSTEM_ERROR);
                    };
                }
            }
        }
        return Status.init(.SUCCESS);
    }

    /// Imports records from a HashDBM file by path, in backward order.
    /// Matches C++ HashDBM::ImportFromFileBackward(const std::string&, ...).
    pub fn importFromFileBackward(
        self: *HashDBM,
        path: []const u8,
        skip_broken_records: bool,
        record_base: i64,
        end_offset: i64,
    ) Status {
        const sf = file_mod.StdFile.create(self.allocator) catch return Status.init(.SYSTEM_ERROR);
        var file = sf.asFile();
        defer file.deinit(self.allocator);
        {
            const st = file.open(path, false, .{});
            if (!st.isOk()) return st;
        }
        defer _ = file.close();
        return self.importFromFileBackwardFile(file, skip_broken_records, record_base, end_offset);
    }

    /// Restores a broken HashDBM database by creating a new valid copy.
    /// Matches C++ HashDBM::RestoreDatabase().
    pub fn restoreDatabase(
        allocator: std.mem.Allocator,
        old_path: []const u8,
        new_path: []const u8,
        end_offset: i64,
        cipher_key: []const u8,
        io: std.Io,
    ) Status {
        _ = cipher_key; // Zig port does not implement compression/encryption

        // Open old file read-only to inspect format.
        const old_sf = file_mod.StdFile.create(allocator) catch return Status.init(.SYSTEM_ERROR);
        var old_file = old_sf.asFile();
        defer old_file.deinit(allocator);
        {
            const st = old_file.open(old_path, false, .{});
            if (!st.isOk()) return st;
        }
        defer _ = old_file.close();

        // Read format parameters.
        var src_rb: i64 = 0;
        var src_sf_flags: i32 = 0;
        var src_ow: i32 = DEFAULT_OFFSET_WIDTH;
        var src_ap: i32 = DEFAULT_ALIGN_POW;
        var last_sync: i64 = 0;
        _ = HashDBM.findRecordBase(old_file, &src_rb, &src_sf_flags, &src_ow, &src_ap, &last_sync);

        // Read full metadata for num_buckets, db_type, opaque, etc.
        var cm: i32 = 0;
        var pmaj: i32 = 0;
        var pmin: i32 = 0;
        var cf: i32 = 0;
        var nb: i64 = DEFAULT_NUM_BUCKETS;
        var nr: i64 = 0;
        var eds: i64 = 0;
        var fsz: i64 = 0;
        var ts: i64 = 0;
        var db_type: i32 = 0;
        var opaque_buf: [OPAQUE_METADATA_SIZE]u8 = [_]u8{0} ** OPAQUE_METADATA_SIZE;
        _ = HashDBM.readMetadata(old_file, &cm, &pmaj, &pmin, &src_sf_flags, &src_ow, &src_ap,
            &cf, &nb, &nr, &eds, &fsz, &ts, &db_type, &opaque_buf);

        const file_sz = old_file.getSizeSimple();
        const eff_end: i64 = if (end_offset < 0) file_sz
            else if (end_offset == 0) (if (last_sync > src_rb) last_sync else file_sz)
            else @min(end_offset, file_sz);

        var update_mode: UpdateMode = .default;
        if (src_sf_flags & @as(i32, STATIC_FLAG_UPDATE_IN_PLACE) != 0) {
            update_mode = .in_place;
        } else if (src_sf_flags & @as(i32, STATIC_FLAG_UPDATE_APPENDING) != 0) {
            update_mode = .appending;
        }

        // Create new database.
        const new_sf = file_mod.StdFile.create(allocator) catch return Status.init(.SYSTEM_ERROR);
        var new_db = HashDBM.init(new_sf.asFile(), nb, allocator) catch {
            new_sf.asFile().deinit(allocator);
            return Status.init(.SYSTEM_ERROR);
        };
        defer new_db.deinit();
        {
            const params = TuningParameters{
                .num_buckets = nb,
                .offset_width = src_ow,
                .align_pow = src_ap,
                .update_mode = update_mode,
            };
            const st = new_db.openAdvanced(new_path, true, .{ .truncate = true }, params, io);
            if (!st.isOk()) return st;
        }
        new_db.impl.db_type = db_type;
        @memcpy(&new_db.impl.opaque_metadata, &opaque_buf);

        // Import records using path-based variants (the old file is still open for reading).
        const st_import = if (update_mode == .appending)
            new_db.importFromFileBackward(old_path, true, src_rb, eff_end)
        else
            new_db.importFromFileForward(old_path, true, src_rb, eff_end);
        if (!st_import.isOk()) return st_import;

        return new_db.close(io);
    }

    // -----------------------------------------------------------------------
    // Phase 6: Base class methods
    // -----------------------------------------------------------------------

    /// Creates a new heap-allocated HashDBM instance.
    pub fn makeDbm(allocator: std.mem.Allocator) !*HashDBM {
        const sf = try file_mod.StdFile.create(allocator);
        const new_dbm = try allocator.create(HashDBM);
        errdefer allocator.destroy(new_dbm);
        new_dbm.* = HashDBM.init(sf.asFile(), 0, allocator) catch |e| {
            // asFile() transfers ownership, so deinit through the File interface.
            sf.asFile().deinit(allocator);
            return e;
        };
        return new_dbm;
    }

    /// Returns the record count or -1 when not open. Matches C++ DBM::CountSimple().
    pub fn countSimple(self: *HashDBM) i64 {
        if (!self.impl.open) return -1;
        return self.countInternal();
    }

    /// Returns the file size in bytes or -1 when not open. Matches C++ DBM::GetFileSizeSimple().
    pub fn getFileSizeSimple(self: *HashDBM) i64 {
        if (!self.impl.open) return -1;
        return self.getFileSizeInternal();
    }

    /// Returns the file path or "" when not open. Matches C++ DBM::GetFilePathSimple().
    pub fn getFilePathSimple(self: *HashDBM) []const u8 {
        if (!self.impl.open) return "";
        return self.getFilePathInternal();
    }

    /// Returns the timestamp or NaN when not open. Matches C++ DBM::GetTimestampSimple().
    pub fn getTimestampSimple(self: *HashDBM) f64 {
        if (!self.impl.open) return std.math.nan(f64);
        return self.getTimestampInternal();
    }

    /// Returns whether a rebuild would improve performance, or false when not open.
    /// Matches C++ DBM::ShouldBeRebuiltSimple().
    pub fn shouldBeRebuiltSimple(self: *HashDBM) bool {
        if (!self.impl.open) return false;
        return self.shouldBeRebuiltInternal();
    }

    /// Copies the database file to dest_path, optionally syncing first.
    pub fn copyFileData(self: *HashDBM, dest_path: []const u8, sync_hard: bool, io: std.Io) Status {
        if (!self.isOpen()) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        if (sync_hard) {
            const st = self.synchronize(true, io);
            if (!st.isOk()) return st;
        }
        const src_path = self.getFilePathInternal();
        if (src_path.len == 0) return Status.initMsg(.PRECONDITION_ERROR, "no file path");
        file_mod.copyFileAbsolute(src_path, dest_path) catch
            return Status.initMsg(.SYSTEM_ERROR, "copy file failed");
        return Status.init(.SUCCESS);
    }

    /// Renames a key. Reads the old value, sets it under new_key, then removes old_key
    /// unless copying=true. Fails if new_key already exists and overwrite=false.
    pub fn rekey(self: *HashDBM, old_key: []const u8, new_key: []const u8, overwrite: bool, copying: bool) Status {
        if (!self.isOpen() or !self.isWritable())
            return Status.initMsg(.PRECONDITION_ERROR, "not writable");

        var value_list: std.ArrayList(u8) = .empty;
        defer value_list.deinit(self.allocator);

        const st_get = self.get(old_key, &value_list);
        if (!st_get.isOk()) return st_get;

        const st_set = self.set(new_key, value_list.items, overwrite, null);
        if (!st_set.isOk()) return st_set;

        if (!copying) {
            _ = self.remove(old_key);
        }
        return Status.init(.SUCCESS);
    }

    /// Exports all records from this DBM to dest (any DBM with a set() method).
    pub fn export_(self: *HashDBM, dest: anytype) Status {
        var iter = self.makeCursor() catch return Status.init(.SYSTEM_ERROR);
        defer iter.deinit();
        var st = iter.first();
        if (st.code == .NOT_FOUND_ERROR) return Status.init(.SUCCESS);
        if (!st.isOk()) return st;
        while (true) {
            var key_list: std.ArrayList(u8) = .empty;
            defer key_list.deinit(self.allocator);
            var val_list: std.ArrayList(u8) = .empty;
            defer val_list.deinit(self.allocator);
            const st_get = iter.get(&key_list, &val_list);
            if (!st_get.isOk()) break;
            const st_set = dest.set(key_list.items, val_list.items, true, null);
            if (!st_set.isOk()) return st_set;
            st = iter.next();
            if (!st.isOk()) break;
        }
        return Status.init(.SUCCESS);
    }

    /// Atomically checks multiple expected conditions then applies multiple desired changes.
    /// Matches C++ DBM::CompareExchangeMulti().
    pub fn compareExchangeMulti(
        self: *HashDBM,
        expected: []const struct { key: []const u8, value: dbm_mod.CompareExpected },
        desired: []const struct { key: []const u8, value: dbm_mod.CompareDesired },
    ) Status {
        // Check all expected conditions first.
        for (expected) |cond| {
            var val_list: std.ArrayList(u8) = .empty;
            defer val_list.deinit(self.allocator);
            const get_st = self.get(cond.key, &val_list);
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
        // Apply all desired changes.
        for (desired) |change| {
            switch (change.value) {
                .remove => {
                    const st = self.remove(change.key);
                    if (!st.isOk() and st.code != .NOT_FOUND_ERROR) return st;
                },
                .set => |new_val| {
                    const st = self.set(change.key, new_val, true, null);
                    if (!st.isOk()) return st;
                },
                .noop => {},
            }
        }
        return Status.init(.SUCCESS);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "HashDBM.init and deinit: no open" {
    // StdFile ownership transfers to HashDBM via asFile(); db.deinit() frees it.
    const std_file = try file_mod.StdFile.create(std.testing.allocator);
    var db = try HashDBM.init(std_file.asFile(), 0, std.testing.allocator);
    defer db.deinit();
    try std.testing.expect(!db.isOpen());
}

test "HashDBM.open and close: creates file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf)];
    var full_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/test.hash", .{path});

    const std_file = try file_mod.StdFile.create(std.testing.allocator);
    var db = try HashDBM.init(std_file.asFile(), 1024, std.testing.allocator);
    defer db.deinit();

    const st_open = db.open(full_path, true, .{}, std.testing.io);
    try std.testing.expect(st_open.isOk());
    try std.testing.expect(db.isOpen());
    try std.testing.expect(db.isWritable());

    const st_close = db.close(std.testing.io);
    try std.testing.expect(st_close.isOk());
    try std.testing.expect(!db.isOpen());
}

test "HashDBM.set and get: basic CRUD" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf)];
    var full_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/test.hash", .{path});

    const std_file = try file_mod.StdFile.create(std.testing.allocator);
    var db = try HashDBM.init(std_file.asFile(), 1024, std.testing.allocator);
    defer db.deinit();
    try std.testing.expect(db.open(full_path, true, .{}, std.testing.io).isOk());

    try std.testing.expect(db.set("hello", "world", true, null).isOk());
    try std.testing.expect(db.set("foo", "bar", true, null).isOk());

    var val: std.ArrayList(u8) = .empty;
    defer val.deinit(std.testing.allocator);
    try std.testing.expect(db.get("hello", &val).isOk());
    try std.testing.expectEqualStrings("world", val.items);

    try std.testing.expect(db.get("missing", null).code == .NOT_FOUND_ERROR);
    try std.testing.expect(db.close(std.testing.io).isOk());
}

test "HashDBM.set: overwrite=false returns DUPLICATION_ERROR" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf)];
    var full_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/test.hash", .{path});

    const std_file = try file_mod.StdFile.create(std.testing.allocator);
    var db = try HashDBM.init(std_file.asFile(), 1024, std.testing.allocator);
    defer db.deinit();
    try std.testing.expect(db.open(full_path, true, .{}, std.testing.io).isOk());
    try std.testing.expect(db.set("key", "val1", true, null).isOk());
    try std.testing.expect(db.set("key", "val2", false, null).code == .DUPLICATION_ERROR);
    try std.testing.expect(db.close(std.testing.io).isOk());
}

test "HashDBM.remove: existing key" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf)];
    var full_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/test.hash", .{path});

    const std_file = try file_mod.StdFile.create(std.testing.allocator);
    var db = try HashDBM.init(std_file.asFile(), 1024, std.testing.allocator);
    defer db.deinit();
    try std.testing.expect(db.open(full_path, true, .{}, std.testing.io).isOk());
    try std.testing.expect(db.set("k", "v", true, null).isOk());
    try std.testing.expect(db.remove("k").isOk());
    try std.testing.expect(db.get("k", null).code == .NOT_FOUND_ERROR);
    try std.testing.expect(db.remove("k").code == .NOT_FOUND_ERROR);
    try std.testing.expect(db.close(std.testing.io).isOk());
}

test "HashDBM.count and getEffectiveDataSize" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf)];
    var full_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/test.hash", .{path});

    const std_file = try file_mod.StdFile.create(std.testing.allocator);
    var db = try HashDBM.init(std_file.asFile(), 1024, std.testing.allocator);
    defer db.deinit();
    try std.testing.expect(db.open(full_path, true, .{}, std.testing.io).isOk());
    try std.testing.expectEqual(@as(i64, 0), db.countSimple());
    try std.testing.expect(db.set("a", "1", true, null).isOk());
    try std.testing.expect(db.set("b", "2", true, null).isOk());
    try std.testing.expectEqual(@as(i64, 2), db.countSimple());
    try std.testing.expect(db.getEffectiveDataSize() >= 4);
    try std.testing.expect(db.close(std.testing.io).isOk());
}

test "HashDBM.processFirst: empty returns NOT_FOUND_ERROR" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf)];
    var full_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/test.hash", .{path});

    const std_file = try file_mod.StdFile.create(std.testing.allocator);
    var db = try HashDBM.init(std_file.asFile(), 1024, std.testing.allocator);
    defer db.deinit();
    try std.testing.expect(db.open(full_path, true, .{}, std.testing.io).isOk());

    const NoopProc = struct {
        pub fn processFull(self: *@This(), k: []const u8, v: []const u8) RecordAction {
            _ = self; _ = k; _ = v; return .noop;
        }
        pub fn processEmpty(self: *@This(), k: []const u8) RecordAction {
            _ = self; _ = k; return .noop;
        }
    };
    var proc: NoopProc = .{};
    try std.testing.expect(db.processFirst(&proc, false).code == .NOT_FOUND_ERROR);
    try std.testing.expect(db.close(std.testing.io).isOk());
}

test "HashDBM.processEach: visits all records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf)];
    var full_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/test.hash", .{path});

    const std_file = try file_mod.StdFile.create(std.testing.allocator);
    var db = try HashDBM.init(std_file.asFile(), 1024, std.testing.allocator);
    defer db.deinit();
    try std.testing.expect(db.open(full_path, true, .{}, std.testing.io).isOk());
    try std.testing.expect(db.set("a", "1", true, null).isOk());
    try std.testing.expect(db.set("b", "2", true, null).isOk());
    try std.testing.expect(db.set("c", "3", true, null).isOk());

    const CountProc = struct {
        count: i64 = 0,
        pub fn processFull(self: *@This(), k: []const u8, v: []const u8) RecordAction {
            _ = k; _ = v; self.count += 1; return .noop;
        }
        pub fn processEmpty(self: *@This(), k: []const u8) RecordAction {
            _ = self; _ = k; return .noop;
        }
    };
    var proc: CountProc = .{};
    try std.testing.expect(db.processEach(&proc, false).isOk());
    try std.testing.expectEqual(@as(i64, 3), proc.count);
    try std.testing.expect(db.close(std.testing.io).isOk());
}

test "HashDBM.clear: empties database" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf)];
    var full_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/test.hash", .{path});

    const std_file = try file_mod.StdFile.create(std.testing.allocator);
    var db = try HashDBM.init(std_file.asFile(), 1024, std.testing.allocator);
    defer db.deinit();
    try std.testing.expect(db.open(full_path, true, .{}, std.testing.io).isOk());
    try std.testing.expect(db.set("a", "1", true, null).isOk());
    try std.testing.expect(db.set("b", "2", true, null).isOk());
    try std.testing.expect(db.clear().isOk());
    try std.testing.expectEqual(@as(i64, 0), db.countSimple());
    try std.testing.expect(db.get("a", null).code == .NOT_FOUND_ERROR);
    try std.testing.expect(db.close(std.testing.io).isOk());
}

test "HashDBM.synchronize and reopen: data persists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf)];
    var full_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/test.hash", .{path});

    {
        const std_file = try file_mod.StdFile.create(std.testing.allocator);
        var db = try HashDBM.init(std_file.asFile(), 1024, std.testing.allocator);
        defer db.deinit();
        try std.testing.expect(db.open(full_path, true, .{}, std.testing.io).isOk());
        try std.testing.expect(db.set("persist_key", "persist_val", true, null).isOk());
        try std.testing.expect(db.synchronize(false, std.testing.io).isOk());
        try std.testing.expect(db.close(std.testing.io).isOk());
    }

    {
        const std_file2 = try file_mod.StdFile.create(std.testing.allocator);
        var db2 = try HashDBM.init(std_file2.asFile(), 0, std.testing.allocator);
        defer db2.deinit();
        try std.testing.expect(db2.open(full_path, true, .{}, std.testing.io).isOk());
        var val: std.ArrayList(u8) = .empty;
        defer val.deinit(std.testing.allocator);
        try std.testing.expect(db2.get("persist_key", &val).isOk());
        try std.testing.expectEqualStrings("persist_val", val.items);
        try std.testing.expect(db2.close(std.testing.io).isOk());
    }
}

test "HashDBM.getOpaqueMetadata and setOpaqueMetadata: roundtrip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf)];
    var full_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/test.hash", .{path});

    const std_file = try file_mod.StdFile.create(std.testing.allocator);
    var db = try HashDBM.init(std_file.asFile(), 1024, std.testing.allocator);
    defer db.deinit();
    try std.testing.expect(db.open(full_path, true, .{}, std.testing.io).isOk());

    const meta_data = "my_custom_meta_data";
    try std.testing.expect(db.setOpaqueMetadata(meta_data).isOk());
    const got = db.getOpaqueMetadata();
    try std.testing.expectEqualStrings(meta_data, got[0..meta_data.len]);
    try std.testing.expect(db.close(std.testing.io).isOk());
}

test "HashDBM.Cursor: first and next" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf)];
    var full_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/test.hash", .{path});

    const std_file = try file_mod.StdFile.create(std.testing.allocator);
    var db = try HashDBM.init(std_file.asFile(), 1024, std.testing.allocator);
    defer db.deinit();
    try std.testing.expect(db.open(full_path, true, .{}, std.testing.io).isOk());
    try std.testing.expect(db.set("a", "1", true, null).isOk());
    try std.testing.expect(db.set("b", "2", true, null).isOk());

    var iter = try db.makeCursor();
    defer iter.deinit();

    try std.testing.expect(iter.first().isOk());

    var count: i64 = 0;
    var k: std.ArrayList(u8) = .empty;
    defer k.deinit(std.testing.allocator);
    var v: std.ArrayList(u8) = .empty;
    defer v.deinit(std.testing.allocator);

    while (iter.get(&k, &v).isOk()) {
        count += 1;
        if (iter.next().code == .NOT_FOUND_ERROR) break;
    }
    try std.testing.expectEqual(@as(i64, 2), count);
    try std.testing.expect(db.close(std.testing.io).isOk());
}

test "HashDBM.Cursor: jump to key" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf)];
    var full_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/test.hash", .{path});

    const std_file = try file_mod.StdFile.create(std.testing.allocator);
    var db = try HashDBM.init(std_file.asFile(), 1024, std.testing.allocator);
    defer db.deinit();
    try std.testing.expect(db.open(full_path, true, .{}, std.testing.io).isOk());
    try std.testing.expect(db.set("alpha", "A", true, null).isOk());
    try std.testing.expect(db.set("beta", "B", true, null).isOk());

    var iter = try db.makeCursor();
    defer iter.deinit();

    try std.testing.expect(iter.jump("alpha").isOk());
    var v: std.ArrayList(u8) = .empty;
    defer v.deinit(std.testing.allocator);
    try std.testing.expect(iter.get(null, &v).isOk());
    try std.testing.expectEqualStrings("A", v.items);

    try std.testing.expect(iter.jump("missing").code == .NOT_FOUND_ERROR);
    try std.testing.expect(db.close(std.testing.io).isOk());
}

test "HashDBM.Cursor: orphan on close" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf)];
    var full_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/test.hash", .{path});

    const std_file = try file_mod.StdFile.create(std.testing.allocator);
    var db = try HashDBM.init(std_file.asFile(), 1024, std.testing.allocator);
    defer db.deinit();
    try std.testing.expect(db.open(full_path, true, .{}, std.testing.io).isOk());

    var iter = try db.makeCursor();
    defer iter.deinit();
    try std.testing.expect(db.close(std.testing.io).isOk());
    // After close, iterator is orphaned — operations return PRECONDITION_ERROR.
    try std.testing.expect(iter.first().code == .PRECONDITION_ERROR);
}

test "HashDBM.compareExchange: success and mismatch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf)];
    var full_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/test.hash", .{path});

    const std_file = try file_mod.StdFile.create(std.testing.allocator);
    var db = try HashDBM.init(std_file.asFile(), 1024, std.testing.allocator);
    defer db.deinit();
    try std.testing.expect(db.open(full_path, true, .{}, std.testing.io).isOk());
    try std.testing.expect(db.set("ce_key", "old", true, null).isOk());

    // Correct expected value — should succeed.
    try std.testing.expect(db.compareExchange("ce_key", .{ .exact = "old" }, .{ .set = "new" }, null, null).isOk());

    // Wrong expected value — should fail.
    try std.testing.expect(db.compareExchange("ce_key", .{ .exact = "old" }, .{ .set = "newer" }, null, null).code == .INFEASIBLE_ERROR);

    // Absent key — correct expected absent.
    try std.testing.expect(db.compareExchange("absent", .absent, .{ .set = "created" }, null, null).isOk());
    try std.testing.expect(db.close(std.testing.io).isOk());
}

test "HashDBM.increment: with initial value" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf)];
    var full_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/test.hash", .{path});

    const std_file = try file_mod.StdFile.create(std.testing.allocator);
    var db = try HashDBM.init(std_file.asFile(), 1024, std.testing.allocator);
    defer db.deinit();
    try std.testing.expect(db.open(full_path, true, .{}, std.testing.io).isOk());

    var current: i64 = 0;
    try std.testing.expect(db.increment("counter", 5, &current, 100).isOk());
    try std.testing.expectEqual(@as(i64, 105), current);
    try std.testing.expect(db.increment("counter", 3, &current, 0).isOk());
    try std.testing.expectEqual(@as(i64, 108), current);
    try std.testing.expect(db.close(std.testing.io).isOk());
}

test "HashDBM.popFirst and pushLast" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf)];
    var full_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/test.hash", .{path});

    const std_file = try file_mod.StdFile.create(std.testing.allocator);
    var db = try HashDBM.init(std_file.asFile(), 1024, std.testing.allocator);
    defer db.deinit();
    try std.testing.expect(db.open(full_path, true, .{}, std.testing.io).isOk());

    try std.testing.expect(db.pushLast("payload1", time_util.getWallTime(std.testing.io), null, std.testing.io).isOk());
    try std.testing.expect(db.countSimple() == 1);

    var key_out: std.ArrayList(u8) = .empty;
    defer key_out.deinit(std.testing.allocator);
    var val_out: std.ArrayList(u8) = .empty;
    defer val_out.deinit(std.testing.allocator);
    try std.testing.expect(db.popFirst(&key_out, &val_out).isOk());
    try std.testing.expectEqualStrings("payload1", val_out.items);
    try std.testing.expectEqual(@as(i64, 0), db.countSimple());

    try std.testing.expect(db.popFirst(null, null).code == .NOT_FOUND_ERROR);
    try std.testing.expect(db.close(std.testing.io).isOk());
}

test "HashDBM.append: with delimiter" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf)];
    var full_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/test.hash", .{path});

    const std_file = try file_mod.StdFile.create(std.testing.allocator);
    var db = try HashDBM.init(std_file.asFile(), 1024, std.testing.allocator);
    defer db.deinit();
    try std.testing.expect(db.open(full_path, true, .{}, std.testing.io).isOk());

    try std.testing.expect(db.append("list", "a", ",").isOk());
    try std.testing.expect(db.append("list", "b", ",").isOk());
    try std.testing.expect(db.append("list", "c", ",").isOk());

    var val: std.ArrayList(u8) = .empty;
    defer val.deinit(std.testing.allocator);
    try std.testing.expect(db.get("list", &val).isOk());
    try std.testing.expectEqualStrings("a,b,c", val.items);
    try std.testing.expect(db.close(std.testing.io).isOk());
}

test "HashDBM.rebuild: preserves records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf)];
    var full_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/test.hash", .{path});

    const std_file = try file_mod.StdFile.create(std.testing.allocator);
    var db = try HashDBM.init(std_file.asFile(), 1024, std.testing.allocator);
    defer db.deinit();
    try std.testing.expect(db.open(full_path, true, .{}, std.testing.io).isOk());

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var k_buf: [16]u8 = undefined;
        var v_buf: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&k_buf, "key{d}", .{i});
        const v = try std.fmt.bufPrint(&v_buf, "val{d}", .{i});
        try std.testing.expect(db.set(k, v, true, null).isOk());
    }
    try std.testing.expectEqual(@as(i64, 10), db.countSimple());

    try std.testing.expect(db.rebuild(std.testing.io).isOk());
    try std.testing.expectEqual(@as(i64, 10), db.countSimple());

    var val: std.ArrayList(u8) = .empty;
    defer val.deinit(std.testing.allocator);
    try std.testing.expect(db.get("key5", &val).isOk());
    try std.testing.expectEqualStrings("val5", val.items);
    try std.testing.expect(db.close(std.testing.io).isOk());
}

test "HashDBM.getDatabaseType and setDatabaseType" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf)];
    var full_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/test.hash", .{path});

    const std_file = try file_mod.StdFile.create(std.testing.allocator);
    var db = try HashDBM.init(std_file.asFile(), 1024, std.testing.allocator);
    defer db.deinit();
    try std.testing.expect(db.open(full_path, true, .{}, std.testing.io).isOk());

    // Default type is 0.
    try std.testing.expectEqual(@as(i32, 0), db.getDatabaseType());

    // Set and read back.
    try std.testing.expect(db.setDatabaseType(42).isOk());
    try std.testing.expectEqual(@as(i32, 42), db.getDatabaseType());

    // Persists across close + reopen.
    try std.testing.expect(db.close(std.testing.io).isOk());

    const std_file2 = try file_mod.StdFile.create(std.testing.allocator);
    var db2 = try HashDBM.init(std_file2.asFile(), 0, std.testing.allocator);
    defer db2.deinit();
    try std.testing.expect(db2.open(full_path, false, .{}, std.testing.io).isOk());
    try std.testing.expectEqual(@as(i32, 42), db2.getDatabaseType());
    _ = db2.close(std.testing.io);
}

test "HashDBM: read-only rejects setDatabaseType" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf)];
    var full_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/test.hash", .{path});

    // Create the file first.
    const std_file = try file_mod.StdFile.create(std.testing.allocator);
    var db = try HashDBM.init(std_file.asFile(), 1024, std.testing.allocator);
    defer db.deinit();
    try std.testing.expect(db.open(full_path, true, .{}, std.testing.io).isOk());
    try std.testing.expect(db.close(std.testing.io).isOk());

    // Reopen read-only: setDatabaseType must fail.
    const std_file2 = try file_mod.StdFile.create(std.testing.allocator);
    var db2 = try HashDBM.init(std_file2.asFile(), 0, std.testing.allocator);
    defer db2.deinit();
    try std.testing.expect(db2.open(full_path, false, .{}, std.testing.io).isOk());
    try std.testing.expectEqual(lib_common.Code.PRECONDITION_ERROR, db2.setDatabaseType(1).code);
    _ = db2.close(std.testing.io);
}

test "HashDBM.TuningParameters: enum defaults compile" {
    // Verify enum values match C++ integer constants.
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(HashDBM.UpdateMode.default));
    try std.testing.expectEqual(@as(i32, 1), @intFromEnum(HashDBM.UpdateMode.in_place));
    try std.testing.expectEqual(@as(i32, 2), @intFromEnum(HashDBM.UpdateMode.appending));

    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(HashDBM.RecordCRCMode.default));
    try std.testing.expectEqual(@as(i32, 4), @intFromEnum(HashDBM.RecordCRCMode.crc_32));

    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(HashDBM.RecordCompressionMode.default));
    try std.testing.expectEqual(@as(i32, 7), @intFromEnum(HashDBM.RecordCompressionMode.aes));

    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(HashDBM.RestoreMode.restore_default));
    try std.testing.expectEqual(@as(i32, 2), @intFromEnum(HashDBM.RestoreMode.restore_read_only));
    try std.testing.expectEqual(@as(i32, 3), @intFromEnum(HashDBM.RestoreMode.restore_noop));

    // Default TuningParameters are accepted by openAdvanced without error (field types compile).
    const params = HashDBM.TuningParameters{};
    try std.testing.expectEqual(HashDBM.UpdateMode.default, params.update_mode);
    try std.testing.expectEqual(@as(i64, DEFAULT_NUM_BUCKETS), params.num_buckets);
}

// ---------------------------------------------------------------------------
// HashDBM lifecycle, CRUD, iterator, and UpdateLogger tests
// ---------------------------------------------------------------------------

test "HashDBM: open/close lifecycle and isOpen" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf)];
    var full_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/lifecycle.tkh", .{dir_path});

    const std_file = try file_mod.StdFile.create(alloc);
    var db = try HashDBM.init(std_file.asFile(), 1024, alloc);
    defer db.deinit();

    try std.testing.expect(!db.isOpen());
    try std.testing.expect(db.open(full_path, true, .{}, std.testing.io).isOk());
    try std.testing.expect(db.isOpen());
    try std.testing.expect(db.close(std.testing.io).isOk());
    try std.testing.expect(!db.isOpen());
}

test "HashDBM: set, get, remove, countSimple" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf)];
    var full_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/crud.tkh", .{dir_path});

    const std_file = try file_mod.StdFile.create(alloc);
    var db = try HashDBM.init(std_file.asFile(), 1024, alloc);
    defer db.deinit();
    try std.testing.expect(db.open(full_path, true, .{}, std.testing.io).isOk());

    try std.testing.expect(db.set("alpha", "one", true, null).isOk());
    try std.testing.expect(db.set("beta", "two", true, null).isOk());
    try std.testing.expectEqual(@as(i64, 2), db.countSimple());

    var val: std.ArrayList(u8) = .empty;
    defer val.deinit(alloc);
    try std.testing.expect(db.get("alpha", &val).isOk());
    try std.testing.expectEqualStrings("one", val.items);

    try std.testing.expect(db.get("missing", null).code == .NOT_FOUND_ERROR);

    try std.testing.expect(db.remove("alpha").isOk());
    try std.testing.expect(db.get("alpha", null).code == .NOT_FOUND_ERROR);
    try std.testing.expectEqual(@as(i64, 1), db.countSimple());

    try std.testing.expect(db.close(std.testing.io).isOk());
}

test "HashDBM: iterator forward traversal" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf)];
    var full_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/iter.tkh", .{dir_path});

    const std_file = try file_mod.StdFile.create(alloc);
    var db = try HashDBM.init(std_file.asFile(), 1024, alloc);
    defer db.deinit();
    try std.testing.expect(db.open(full_path, true, .{}, std.testing.io).isOk());

    try std.testing.expect(db.set("key1", "val1", true, null).isOk());
    try std.testing.expect(db.set("key2", "val2", true, null).isOk());
    try std.testing.expect(db.set("key3", "val3", true, null).isOk());

    var iter = try db.makeCursor();
    defer iter.deinit();
    try std.testing.expect(iter.first().isOk());

    var seen: usize = 0;
    while (true) {
        var key: std.ArrayList(u8) = .empty;
        defer key.deinit(alloc);
        var value: std.ArrayList(u8) = .empty;
        defer value.deinit(alloc);

        const st = iter.get(&key, &value);
        if (st.code == .NOT_FOUND_ERROR) break;
        try std.testing.expect(st.isOk());
        try std.testing.expect(key.items.len > 0);
        try std.testing.expect(value.items.len > 0);
        seen += 1;
        _ = iter.next();
    }
    try std.testing.expectEqual(@as(usize, 3), seen);

    try std.testing.expect(db.close(std.testing.io).isOk());
}

// Mock UpdateLogger shared by HashDBM logger tests.
const HashMockLoggerCtx = struct {
    writeSet_count: i32 = 0,
    writeRemove_count: i32 = 0,
    writeClear_count: i32 = 0,
};

fn hashMockWriteSet(ctx: *anyopaque, _: []const u8, _: []const u8) Status {
    const mock: *HashMockLoggerCtx = @ptrCast(@alignCast(ctx));
    mock.writeSet_count += 1;
    return Status.init(.SUCCESS);
}

fn hashMockWriteRemove(ctx: *anyopaque, _: []const u8) Status {
    const mock: *HashMockLoggerCtx = @ptrCast(@alignCast(ctx));
    mock.writeRemove_count += 1;
    return Status.init(.SUCCESS);
}

fn hashMockWriteClear(ctx: *anyopaque) Status {
    const mock: *HashMockLoggerCtx = @ptrCast(@alignCast(ctx));
    mock.writeClear_count += 1;
    return Status.init(.SUCCESS);
}

test "HashDBM: UpdateLogger integration" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf)];
    var full_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/logger.tkh", .{dir_path});

    const std_file = try file_mod.StdFile.create(alloc);
    var db = try HashDBM.init(std_file.asFile(), 1024, alloc);
    defer db.deinit();
    try std.testing.expect(db.open(full_path, true, .{}, std.testing.io).isOk());

    var mock_ctx: HashMockLoggerCtx = .{};
    var mock_logger: UpdateLogger = .{
        .ctx = @ptrCast(@alignCast(&mock_ctx)),
        .vtable = &.{
            .writeSet = hashMockWriteSet,
            .writeRemove = hashMockWriteRemove,
            .writeClear = hashMockWriteClear,
        },
    };
    db.setUpdateLogger(&mock_logger);

    // set fires writeSet
    try std.testing.expect(db.set("key1", "val1", true, null).isOk());
    try std.testing.expect(mock_ctx.writeSet_count > 0);

    // remove fires writeRemove
    try std.testing.expect(db.remove("key1").isOk());
    try std.testing.expect(mock_ctx.writeRemove_count > 0);

    // clear fires writeClear
    try std.testing.expect(db.set("key2", "val2", true, null).isOk());
    const pre_clear = mock_ctx.writeClear_count;
    try std.testing.expect(db.clear().isOk());
    try std.testing.expect(mock_ctx.writeClear_count > pre_clear);

    try std.testing.expect(db.close(std.testing.io).isOk());
}

test "HashDBM.*Multi: bulk set/get/remove/append" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf)];
    var full_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/multi.tkh", .{dir_path});

    const std_file = try file_mod.StdFile.create(alloc);
    var db = try HashDBM.init(std_file.asFile(), 1024, alloc);
    defer db.deinit();
    try std.testing.expect(db.open(full_path, true, .{}, std.testing.io).isOk());

    // setMulti: insert 3 keys
    const pairs = [_][2][]const u8{
        .{ "key1", "val1" }, .{ "key2", "val2" }, .{ "key3", "val3" },
    };
    try std.testing.expect(db.setMulti(&pairs, true).isOk());

    // getMulti: 2 existing + 1 missing → NOT_FOUND_ERROR, 2 entries in map
    var records = std.StringHashMap([]u8).init(alloc);
    defer {
        var it = records.iterator();
        while (it.next()) |e| {
            alloc.free(e.key_ptr.*);
            alloc.free(e.value_ptr.*);
        }
        records.deinit();
    }
    const get_st = db.getMulti(&.{ "key1", "key2", "missing" }, &records);
    try std.testing.expectEqual(lib_common.Code.NOT_FOUND_ERROR, get_st.code);
    try std.testing.expectEqual(@as(usize, 2), records.count());

    // removeMulti: remove 2 existing keys
    try std.testing.expect(db.removeMulti(&.{ "key1", "key2" }).isOk());

    // appendMulti: append to remaining key3
    const app = [_][2][]const u8{ .{ "key3", "_appended" } };
    try std.testing.expect(db.appendMulti(&app, "").isOk());
    const got = try db.getSimple("key3", "", alloc);
    defer alloc.free(got);
    try std.testing.expectEqualStrings("val3_appended", got);

    try std.testing.expect(db.close(std.testing.io).isOk());
}

test "HashDBM.Iterator: iterate() from beginning" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf)];
    var full_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/iter2.tkh", .{dir_path});

    const std_file = try file_mod.StdFile.create(alloc);
    var db = try HashDBM.init(std_file.asFile(), 1024, alloc);
    defer db.deinit();
    try std.testing.expect(db.open(full_path, true, .{}, std.testing.io).isOk());

    try std.testing.expect(db.set("a", "1", true, null).isOk());
    try std.testing.expect(db.set("b", "2", true, null).isOk());
    try std.testing.expect(db.set("c", "3", true, null).isOk());

    var iter = try db.iterate(alloc);
    defer iter.deinit();

    var count: usize = 0;
    while (try iter.next()) |entry| {
        try std.testing.expect(entry.key.len > 0);
        try std.testing.expect(entry.value.len > 0);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), count);

    try std.testing.expect(db.close(std.testing.io).isOk());
}

test "HashDBM.Iterator: iterateFrom() with lifetime contract" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf)];
    var full_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/iter3.tkh", .{dir_path});

    const std_file = try file_mod.StdFile.create(alloc);
    var db = try HashDBM.init(std_file.asFile(), 1024, alloc);
    defer db.deinit();
    try std.testing.expect(db.open(full_path, true, .{}, std.testing.io).isOk());

    try std.testing.expect(db.set("alpha", "one", true, null).isOk());
    try std.testing.expect(db.set("beta", "two", true, null).isOk());
    try std.testing.expect(db.set("gamma", "three", true, null).isOk());

    // iterateFrom() at "beta"
    {
        var iter = try db.iterateFrom("beta", alloc);
        defer iter.deinit();

        const first = try iter.next();
        try std.testing.expect(first != null);
        try std.testing.expect(std.mem.startsWith(u8, first.?.key, "b"));

        // Copy before next() to demonstrate lifetime contract
        const key_copy = try alloc.dupe(u8, first.?.key);
        defer alloc.free(key_copy);
        const val_copy = try alloc.dupe(u8, first.?.value);
        defer alloc.free(val_copy);

        // Second next() — first.?.key is now invalid, copies are safe
        _ = try iter.next();

        // Verify copies are still valid
        try std.testing.expectEqualStrings("beta", key_copy);
        try std.testing.expectEqualStrings("two", val_copy);
    }

    try std.testing.expect(db.close(std.testing.io).isOk());
}
