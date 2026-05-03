const std = @import("std");
const lib_common = @import("lib_common.zig");
const varint = @import("varint.zig");
const file_mod = @import("file.zig");
pub const Status = lib_common.Status;
pub const File = file_mod.File;

pub const RECORD_MAGIC_NORMAL: u8 = 0xFF;
pub const RECORD_MAGIC_METADATA: u8 = 0xFE;
const READ_BUFFER_SIZE: usize = 48;
const WRITE_BUFFER_SIZE: usize = 4096;
pub const DEFAULT_READER_BUFFER_SIZE: usize = 32768;

pub const RecordType = enum(i32) { normal = 0, metadata = 1 };

// ---------------------------------------------------------------------------
// FlatRecord — port of tkrzw C++ FlatRecord
// ---------------------------------------------------------------------------

pub const FlatRecord = struct {
    file: File,
    buf: [READ_BUFFER_SIZE]u8 = undefined,
    offset: i64 = 0,
    whole_size: usize = 0,
    /// Points into buf or body_buf; valid until next call to read/write.
    data_slice: []const u8 = &.{},
    /// Heap buffer for records that exceed READ_BUFFER_SIZE. Owned by self.
    body_buf: ?[]u8 = null,
    rec_type: RecordType = .normal,
    allocator: std.mem.Allocator,

    /// Reads a flat record from the file at the given offset.
    /// Matches C++ FlatRecord::Read.
    pub fn read(self: *FlatRecord, offset: i64) Status {
        self.offset = offset;

        const file_size = self.file.getSizeSimple();
        if (file_size < 0) {
            return Status.initMsg(.BROKEN_DATA_ERROR, "too short record data");
        }
        const remaining = file_size - offset;
        if (remaining < 0) {
            return Status.initMsg(.BROKEN_DATA_ERROR, "too short record data");
        }

        const max_read: i64 = @min(remaining, lib_common.MAX_MEMORY_SIZE);
        const record_size: usize = @intCast(@min(max_read, @as(i64, READ_BUFFER_SIZE)));

        if (record_size < 2) {
            return Status.initMsg(.BROKEN_DATA_ERROR, "too short record data");
        }

        // Read the initial bytes into the stack buffer.
        {
            const st = self.file.read(offset, self.buf[0..record_size]);
            if (!st.isOk()) return st;
        }

        // Parse magic byte to determine record type.
        self.rec_type = switch (self.buf[0]) {
            RECORD_MAGIC_NORMAL => .normal,
            RECORD_MAGIC_METADATA => .metadata,
            else => return Status.initMsg(.BROKEN_DATA_ERROR, "invalid magic byte"),
        };

        // Decode the data-size varint that follows the magic byte.
        var data_size: u64 = 0;
        const step = varint.readVarNum(self.buf[1..record_size], &data_size);
        if (step == 0) {
            return Status.initMsg(.BROKEN_DATA_ERROR, "truncated varint");
        }

        const header_size: usize = 1 + step;
        self.whole_size = header_size + @as(usize, @intCast(data_size));

        if (record_size >= header_size and record_size - header_size >= @as(usize, @intCast(data_size))) {
            // Fast path: entire record is already in the stack buffer.
            self.data_slice = self.buf[header_size .. header_size + @as(usize, @intCast(data_size))];
        } else {
            // Slow path: allocate a body buffer and read the full data.
            if (self.body_buf) |old| {
                self.allocator.free(old);
                self.body_buf = null;
            }
            const dsz: usize = @intCast(data_size);
            const new_buf = self.allocator.alloc(u8, dsz) catch
                return Status.init(.SYSTEM_ERROR);
            self.body_buf = new_buf;

            const st = self.file.read(offset + @as(i64, @intCast(header_size)), new_buf);
            if (!st.isOk()) {
                self.allocator.free(new_buf);
                self.body_buf = null;
                return st;
            }
            self.data_slice = new_buf;
        }

        return Status.init(.SUCCESS);
    }

    /// Appends a flat record to the file.
    /// Matches C++ FlatRecord::Write.
    pub fn write(self: *FlatRecord, data: []const u8, rec_type: RecordType) Status {
        const magic: u8 = switch (rec_type) {
            .normal => RECORD_MAGIC_NORMAL,
            .metadata => RECORD_MAGIC_METADATA,
        };

        const varint_size = varint.sizeVarNum(@intCast(data.len));
        self.whole_size = 1 + varint_size + data.len;

        if (self.whole_size <= WRITE_BUFFER_SIZE) {
            // Use a stack buffer.
            var stack_buf: [WRITE_BUFFER_SIZE]u8 = undefined;
            stack_buf[0] = magic;
            const written = varint.writeVarNum(stack_buf[1..], @intCast(data.len));
            @memcpy(stack_buf[1 + written .. 1 + written + data.len], data);
            return self.file.append(stack_buf[0..self.whole_size], &self.offset);
        } else {
            // Use a heap buffer for large records.
            const heap_buf = self.allocator.alloc(u8, self.whole_size) catch
                return Status.init(.SYSTEM_ERROR);
            defer self.allocator.free(heap_buf);

            heap_buf[0] = magic;
            const written = varint.writeVarNum(heap_buf[1..], @intCast(data.len));
            @memcpy(heap_buf[1 + written .. 1 + written + data.len], data);
            return self.file.append(heap_buf, &self.offset);
        }
    }

    pub fn getData(self: *const FlatRecord) []const u8 {
        return self.data_slice;
    }

    pub fn getRecordType(self: *const FlatRecord) RecordType {
        return self.rec_type;
    }

    pub fn getOffset(self: *const FlatRecord) i64 {
        return self.offset;
    }

    pub fn getWholeSize(self: *const FlatRecord) usize {
        return self.whole_size;
    }

    pub fn deinit(self: *FlatRecord) void {
        if (self.body_buf) |b| {
            self.allocator.free(b);
            self.body_buf = null;
        }
    }
};

// ---------------------------------------------------------------------------
// FlatRecordReader — port of tkrzw C++ FlatRecordReader
// ---------------------------------------------------------------------------

pub const FlatRecordReader = struct {
    file: File,
    offset: i64 = 0,
    /// Heap-allocated read buffer, owned by self.
    buf: []u8,
    buf_size: usize,
    /// Number of valid bytes currently in buf.
    data_size: usize = 0,
    /// Read cursor within buf.
    index: usize = 0,
    allocator: std.mem.Allocator,

    pub fn init(file: File, allocator: std.mem.Allocator, buffer_size: usize) !FlatRecordReader {
        const buf = try allocator.alloc(u8, buffer_size);
        return FlatRecordReader{
            .file = file,
            .buf = buf,
            .buf_size = buffer_size,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FlatRecordReader) void {
        self.allocator.free(self.buf);
    }

    /// Reads the next record from the stream.
    ///
    /// On success, *str points into self.buf and is valid until the next call.
    /// Matches C++ FlatRecordReader::Read (3-stage approach).
    pub fn read(self: *FlatRecordReader, str: *[]const u8, rec_type: ?*RecordType) Status {
        // ------------------------------------------------------------------
        // Stage 1: fast path — enough bytes buffered for a full header + data.
        // ------------------------------------------------------------------
        // Maximum header size: 1 magic byte + up to 9 varint bytes = 10 bytes.
        if (self.index + 10 <= self.data_size) {
            const magic = self.buf[self.index];
            const rt: RecordType = switch (magic) {
                RECORD_MAGIC_NORMAL => .normal,
                RECORD_MAGIC_METADATA => .metadata,
                else => return Status.initMsg(.BROKEN_DATA_ERROR, "invalid magic byte"),
            };

            var value_size: u64 = 0;
            const step = varint.readVarNum(self.buf[self.index + 1 .. self.data_size], &value_size);
            if (step > 0) {
                const header_size: usize = 1 + step;
                const available = self.data_size - self.index;
                const vsz: usize = @intCast(value_size);
                if (available >= header_size and available - header_size >= vsz) {
                    const start = self.index + header_size;
                    str.* = self.buf[start .. start + vsz];
                    if (rec_type) |rtp| rtp.* = rt;
                    const record_size = header_size + vsz;
                    self.offset += @intCast(record_size);
                    self.index += record_size;
                    return Status.init(.SUCCESS);
                }
            }
        }

        // ------------------------------------------------------------------
        // Stage 2: refill path — reload the buffer from the file.
        // ------------------------------------------------------------------
        const file_size = self.file.getSizeSimple();
        // NOTE: `<= offset + 2` rejects a valid 2-byte record sitting at exact
        // EOF. This matches the C++ FlatRecordReader::Read verbatim — pre-existing
        // in tkrzw, not a porting mistake.
        if (file_size < 0 or file_size <= self.offset + 2) {
            return Status.init(.NOT_FOUND_ERROR);
        }

        const bytes_from_file: i64 = @min(@as(i64, @intCast(self.buf_size)), file_size - self.offset);
        if (bytes_from_file < 2) {
            return Status.init(.NOT_FOUND_ERROR);
        }
        self.data_size = @intCast(bytes_from_file);
        self.index = 0;

        {
            const st = self.file.read(self.offset, self.buf[0..self.data_size]);
            if (!st.isOk()) return st;
        }

        // Try to parse after refill.
        const magic2 = self.buf[0];
        const rt2: RecordType = switch (magic2) {
            RECORD_MAGIC_NORMAL => .normal,
            RECORD_MAGIC_METADATA => .metadata,
            else => return Status.initMsg(.BROKEN_DATA_ERROR, "invalid magic byte"),
        };

        var value_size2: u64 = 0;
        const step2 = varint.readVarNum(self.buf[1..self.data_size], &value_size2);
        if (step2 == 0) {
            return Status.initMsg(.BROKEN_DATA_ERROR, "truncated varint");
        }

        const header_size2: usize = 1 + step2;
        const vsz2: usize = @intCast(value_size2);

        if (self.data_size >= header_size2 and self.data_size - header_size2 >= vsz2) {
            str.* = self.buf[header_size2 .. header_size2 + vsz2];
            if (rec_type) |rtp| rtp.* = rt2;
            const record_size2 = header_size2 + vsz2;
            self.offset += @intCast(record_size2);
            self.index = record_size2;
            return Status.init(.SUCCESS);
        }

        // ------------------------------------------------------------------
        // Stage 3: grow buffer path — record is larger than current buf_size.
        // ------------------------------------------------------------------
        const shortfall = vsz2 - (self.data_size - header_size2);
        const new_buf_size = self.buf_size + shortfall;

        const new_buf = self.allocator.realloc(self.buf, new_buf_size) catch
            return Status.init(.SYSTEM_ERROR);
        self.buf = new_buf;
        self.buf_size = new_buf_size;
        self.data_size = 0;
        self.index = 0;

        // Re-read the entire record into the enlarged buffer.
        const full_read = header_size2 + vsz2;
        {
            const st = self.file.read(self.offset, self.buf[0..full_read]);
            if (!st.isOk()) return st;
        }
        self.data_size = full_read;

        // Parse once more (magic + varint are the same bytes we already checked).
        var value_size3: u64 = 0;
        const step3 = varint.readVarNum(self.buf[1..self.data_size], &value_size3);
        if (step3 == 0) {
            return Status.initMsg(.BROKEN_DATA_ERROR, "truncated varint after grow");
        }
        const header_size3: usize = 1 + step3;
        const vsz3: usize = @intCast(value_size3);

        if (self.data_size < header_size3 or self.data_size - header_size3 < vsz3) {
            return Status.initMsg(.BROKEN_DATA_ERROR, "record does not fit after buffer grow");
        }

        str.* = self.buf[header_size3 .. header_size3 + vsz3];
        // rt2 is used here rather than re-parsing: magic byte is at buf[0] in
        // all three stages, so rt3 would equal rt2. Matches C++ which re-checks
        // the magic byte in stage 3; rt2 is correct by identity.
        if (rec_type) |rtp| rtp.* = rt2;
        const record_size3 = header_size3 + vsz3;
        self.offset += @intCast(record_size3);
        self.index = record_size3;
        return Status.init(.SUCCESS);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "FlatRecord write + read round-trip (normal)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_path);

    const file_name = try std.fmt.allocPrint(std.testing.allocator, "{s}/flat_rw.bin", .{tmp_path});
    defer std.testing.allocator.free(file_name);

    const sf = try file_mod.StdFile.create(std.testing.allocator);
    var f = sf.asFile();
    defer f.deinit(std.testing.allocator);

    var st = f.open(file_name, true, .{});
    try std.testing.expect(st.isOk());

    var rec = FlatRecord{
        .file = f,
        .allocator = std.testing.allocator,
    };
    defer rec.deinit();

    const payload = "hello flat record";
    st = rec.write(payload, .normal);
    try std.testing.expect(st.isOk());

    _ = f.close();

    // Re-open read-only for reading.
    st = f.open(file_name, false, .{});
    try std.testing.expect(st.isOk());

    var rec2 = FlatRecord{
        .file = f,
        .allocator = std.testing.allocator,
    };
    defer rec2.deinit();

    st = rec2.read(0);
    try std.testing.expect(st.isOk());
    try std.testing.expectEqual(RecordType.normal, rec2.getRecordType());
    try std.testing.expectEqualStrings(payload, rec2.getData());

    _ = f.close();
}

test "FlatRecordReader reads metadata + normal records in order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_path);

    const file_name = try std.fmt.allocPrint(std.testing.allocator, "{s}/frr_multi.bin", .{tmp_path});
    defer std.testing.allocator.free(file_name);

    const sf = try file_mod.StdFile.create(std.testing.allocator);
    var f = sf.asFile();
    defer f.deinit(std.testing.allocator);

    var st = f.open(file_name, true, .{});
    try std.testing.expect(st.isOk());

    var wr = FlatRecord{
        .file = f,
        .allocator = std.testing.allocator,
    };
    defer wr.deinit();

    st = wr.write("meta_payload", .metadata);
    try std.testing.expect(st.isOk());

    st = wr.write("normal_payload", .normal);
    try std.testing.expect(st.isOk());

    _ = f.close();

    // Re-open and read sequentially.
    st = f.open(file_name, false, .{});
    try std.testing.expect(st.isOk());

    var reader = try FlatRecordReader.init(f, std.testing.allocator, DEFAULT_READER_BUFFER_SIZE);
    defer reader.deinit();

    var str: []const u8 = undefined;
    var rt: RecordType = undefined;

    st = reader.read(&str, &rt);
    try std.testing.expect(st.isOk());
    try std.testing.expectEqual(RecordType.metadata, rt);
    try std.testing.expectEqualStrings("meta_payload", str);

    st = reader.read(&str, &rt);
    try std.testing.expect(st.isOk());
    try std.testing.expectEqual(RecordType.normal, rt);
    try std.testing.expectEqualStrings("normal_payload", str);

    _ = f.close();
}

test "FlatRecordReader returns NOT_FOUND_ERROR at EOF" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_path);

    const file_name = try std.fmt.allocPrint(std.testing.allocator, "{s}/frr_eof.bin", .{tmp_path});
    defer std.testing.allocator.free(file_name);

    const sf = try file_mod.StdFile.create(std.testing.allocator);
    var f = sf.asFile();
    defer f.deinit(std.testing.allocator);

    var st = f.open(file_name, true, .{});
    try std.testing.expect(st.isOk());

    var wr = FlatRecord{
        .file = f,
        .allocator = std.testing.allocator,
    };
    defer wr.deinit();

    st = wr.write("only", .normal);
    try std.testing.expect(st.isOk());

    _ = f.close();

    st = f.open(file_name, false, .{});
    try std.testing.expect(st.isOk());

    var reader = try FlatRecordReader.init(f, std.testing.allocator, DEFAULT_READER_BUFFER_SIZE);
    defer reader.deinit();

    var str: []const u8 = undefined;

    // First record — should succeed.
    st = reader.read(&str, null);
    try std.testing.expect(st.isOk());
    try std.testing.expectEqualStrings("only", str);

    // Second read — should be NOT_FOUND_ERROR.
    st = reader.read(&str, null);
    try std.testing.expectEqual(lib_common.Code.NOT_FOUND_ERROR, st.code);

    _ = f.close();
}

test "FlatRecord.read uses body_buf for records larger than READ_BUFFER_SIZE" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_path);

    const file_name = try std.fmt.allocPrint(std.testing.allocator, "{s}/flat_large.bin", .{tmp_path});
    defer std.testing.allocator.free(file_name);

    const sf = try file_mod.StdFile.create(std.testing.allocator);
    var f = sf.asFile();
    defer f.deinit(std.testing.allocator);

    var st = f.open(file_name, true, .{});
    try std.testing.expect(st.isOk());

    // Build a payload that exceeds READ_BUFFER_SIZE (48 bytes).
    const large_payload = "A" ** 128;

    var wr = FlatRecord{
        .file = f,
        .allocator = std.testing.allocator,
    };
    defer wr.deinit();

    st = wr.write(large_payload, .normal);
    try std.testing.expect(st.isOk());

    _ = f.close();

    st = f.open(file_name, false, .{});
    try std.testing.expect(st.isOk());

    var rd = FlatRecord{
        .file = f,
        .allocator = std.testing.allocator,
    };
    defer rd.deinit();

    st = rd.read(0);
    try std.testing.expect(st.isOk());
    try std.testing.expectEqualStrings(large_payload, rd.getData());
    // body_buf must be non-null since the payload did not fit in the stack buf.
    try std.testing.expect(rd.body_buf != null);

    _ = f.close();
}
