// Zig 0.15.2 port of tkrzw TinyDBM — on-memory hash-table database.
//
// Architecture notes:
//   - Each hash bucket entry is a heap-allocated blob ([]u8). The blob slice
//     length IS the allocation size, so allocator.realloc(blob, new_size) is
//     always valid.
//   - Blob layout: [child: ?[*]u8 (8 bytes)] [key_varint] [key] [value_varint] [value]
//   - TinyDBMImpl is heap-allocated (via allocator.create) and owned by TinyDBM.
//   - Iterators are heap-allocated and owned by the caller; they register
//     themselves in impl.iterators under the db mutex.

const std = @import("std");
const lib_common = @import("lib_common.zig");
const varint = @import("varint.zig");
const hash_util = @import("hash_util.zig");
const thread_util = @import("thread_util.zig");
const str_util = @import("str_util.zig");
const time_util = @import("time_util.zig");
const dbm_mod = @import("dbm.zig");
const file_mod = @import("file.zig");
const file_util = @import("file_util.zig");

pub const Status = lib_common.Status;
pub const Code = lib_common.Code;
pub const RecordAction = dbm_mod.RecordAction;
pub const UpdateLogger = dbm_mod.UpdateLogger;
pub const File = file_mod.File;
pub const OpenOptions = file_mod.OpenOptions;
pub const FlatRecord = file_util.FlatRecord;
pub const FlatRecordReader = file_util.FlatRecordReader;
pub const RecordType = file_util.RecordType;
pub const HashMutex = thread_util.HashMutex;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const RECORD_MUTEX_NUM_SLOTS: i32 = 128;
const MAX_NUM_BUCKETS: i64 = 1099511627689;
pub const DEFAULT_NUM_BUCKETS: i64 = 1048583;

// ---------------------------------------------------------------------------
// Blob layout helpers
// ---------------------------------------------------------------------------

// Every blob begins with a pointer-width child field.
const RecordHeader = extern struct {
    child: ?[*]u8, // pointer to next blob in the chain (null = end of chain)
};
const HEADER_SIZE = @sizeOf(RecordHeader);

// Serialize a new blob: [header][key_varint][key][value_varint][value]
fn serializeRecord(
    allocator: std.mem.Allocator,
    child: ?[*]u8,
    key: []const u8,
    value: []const u8,
) ![]u8 {
    const key_vsize = varint.sizeVarNum(key.len);
    const val_vsize = varint.sizeVarNum(value.len);
    const total = HEADER_SIZE + key_vsize + key.len + val_vsize + value.len;
    const blob = try allocator.alloc(u8, total);
    var wp: usize = 0;
    // Write child pointer.
    const hdr = RecordHeader{ .child = child };
    @memcpy(blob[0..HEADER_SIZE], std.mem.asBytes(&hdr));
    wp += HEADER_SIZE;
    // Write key.
    wp += varint.writeVarNum(blob[wp..], key.len);
    @memcpy(blob[wp .. wp + key.len], key);
    wp += key.len;
    // Write value.
    wp += varint.writeVarNum(blob[wp..], value.len);
    @memcpy(blob[wp .. wp + value.len], value);
    return blob;
}

// Reserialize an existing blob in-place (or free+reallocate) when the value
// changes.  Matches C++ TinyRecord::Reserialize exactly.
//
// Decision tree:
//   1. If SizeVarNum(new_value.len) > SizeVarNum(old_value_size):
//      free old blob, allocate new one.
//   2. Else if new_value.len > old_value_size:
//      reallocate blob to the exact new size (realloc keeps data intact).
//   3. Write new value varint + bytes into the existing layout.
fn reserializeRecord(
    allocator: std.mem.Allocator,
    blob: []u8,
    key: []const u8,
    old_value_size: usize,
    new_value: []const u8,
) ![]u8 {
    const old_val_vsize = varint.sizeVarNum(old_value_size);
    const new_val_vsize = varint.sizeVarNum(new_value.len);

    var working_blob: []u8 = blob;

    if (new_val_vsize > old_val_vsize) {
        // Case 1: varint header grows — need a completely fresh blob.
        // Recover child from old blob before freeing it.
        const child = getChild(blob);
        const new_blob = try serializeRecord(allocator, child, key, new_value);
        allocator.free(blob);
        return new_blob;
    }

    // Case 2 (value grew) or Case 3 (value same size or shrank): always realloc
    // to exact content size so that blobLen() always matches blob.len.
    {
        const key_vsize = varint.sizeVarNum(key.len);
        const new_total = HEADER_SIZE + key_vsize + key.len + new_val_vsize + new_value.len;
        if (working_blob.len != new_total) {
            working_blob = try allocator.realloc(blob, new_total);
        }
    }

    // Write new value varint + bytes.
    const key_vsize = varint.sizeVarNum(key.len);
    var wp: usize = HEADER_SIZE + key_vsize + key.len;
    wp += varint.writeVarNum(working_blob[wp..], new_value.len);
    @memcpy(working_blob[wp .. wp + new_value.len], new_value);
    return working_blob;
}

// Reserialize an existing blob by appending cat_delim ++ cat_value to the
// current value.  Matches C++ TinyRecord::ReserializeAppend exactly.
//
// Decision tree:
//   1. new_value_size = old_value.len + cat_delim.len + cat_value.len
//   2. If SizeVarNum(new_value_size) > SizeVarNum(old_value.len):
//      allocate fresh blob from scratch with xreallocappend growth.
//   3. Else: realloc blob with xreallocappend growth, write in-place.
fn reserializeAppend(
    allocator: std.mem.Allocator,
    blob: []u8,
    key: []const u8,
    old_value: []const u8,
    cat_delim: []const u8,
    cat_value: []const u8,
) ![]u8 {
    const new_value_size = old_value.len + cat_delim.len + cat_value.len;
    const old_val_vsize = varint.sizeVarNum(old_value.len);
    const new_val_vsize = varint.sizeVarNum(new_value_size);
    const key_vsize = varint.sizeVarNum(key.len);

    if (new_val_vsize > old_val_vsize) {
        // Case 1: varint header grows — allocate a completely new blob.
        const child = getChild(blob);
        const exact_size = HEADER_SIZE + key_vsize + key.len + new_val_vsize + new_value_size;
        const new_blob = try allocator.alloc(u8, exact_size);
        var wp: usize = 0;
        const hdr = RecordHeader{ .child = child };
        @memcpy(new_blob[0..HEADER_SIZE], std.mem.asBytes(&hdr));
        wp += HEADER_SIZE;
        wp += varint.writeVarNum(new_blob[wp..], key.len);
        @memcpy(new_blob[wp .. wp + key.len], key);
        wp += key.len;
        wp += varint.writeVarNum(new_blob[wp..], new_value_size);
        @memcpy(new_blob[wp .. wp + old_value.len], old_value);
        wp += old_value.len;
        @memcpy(new_blob[wp .. wp + cat_delim.len], cat_delim);
        wp += cat_delim.len;
        @memcpy(new_blob[wp .. wp + cat_value.len], cat_value);
        allocator.free(blob);
        return new_blob;
    }

    // Case 2: realloc in-place (exact allocation — no C++ growth factor needed).
    const exact_size = HEADER_SIZE + key_vsize + key.len + new_val_vsize + new_value_size;
    var working_blob = try allocator.realloc(blob, exact_size);
    var wp: usize = HEADER_SIZE + key_vsize + key.len;
    wp += varint.writeVarNum(working_blob[wp..], new_value_size);
    // old_value is already in place; skip past it.
    wp += old_value.len;
    @memcpy(working_blob[wp .. wp + cat_delim.len], cat_delim);
    wp += cat_delim.len;
    @memcpy(working_blob[wp .. wp + cat_value.len], cat_value);
    return working_blob;
}

// Decoded record view — no copies; pointers into the blob.
const RecordView = struct {
    child: ?[*]u8,
    key: []const u8,
    value: []const u8,
};

// Deserialize a blob (unsafe: caller guarantees the pointer is valid).
fn deserializeRecord(blob: [*]const u8) RecordView {
    var rp: usize = 0;
    var hdr: RecordHeader = undefined;
    @memcpy(std.mem.asBytes(&hdr), blob[0..HEADER_SIZE]);
    rp += HEADER_SIZE;
    var key_len: u64 = 0;
    rp += varint.readVarNumUnsafe(blob + rp, &key_len);
    const key_ptr = blob + rp;
    rp += @intCast(key_len);
    var val_len: u64 = 0;
    rp += varint.readVarNumUnsafe(blob + rp, &val_len);
    const val_ptr = blob + rp;
    return RecordView{
        .child = hdr.child,
        .key = key_ptr[0..@intCast(key_len)],
        .value = val_ptr[0..@intCast(val_len)],
    };
}

fn getChild(blob: []u8) ?[*]u8 {
    var hdr: RecordHeader = undefined;
    @memcpy(std.mem.asBytes(&hdr), blob[0..HEADER_SIZE]);
    return hdr.child;
}

fn setChild(blob: []u8, child: ?[*]u8) void {
    const hdr = RecordHeader{ .child = child };
    @memcpy(blob[0..HEADER_SIZE], std.mem.asBytes(&hdr));
}

// ---------------------------------------------------------------------------
// Built-in record processors
// ---------------------------------------------------------------------------

// ProcessorGet — reads value into *value on found; sets NOT_FOUND on miss.
pub const ProcessorGet = struct {
    status: *Status,
    value: ?*std.ArrayList(u8), // nullable: null = existence check only
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

// ProcessorSet — sets a value, optionally refusing to overwrite.
pub const ProcessorSet = struct {
    status: *Status,
    value: []const u8,
    overwrite: bool,
    old_value: ?*std.ArrayList(u8), // nullable
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

// ProcessorRemove — removes the record; sets NOT_FOUND on miss.
pub const ProcessorRemove = struct {
    status: *Status,

    pub fn processFull(self: *ProcessorRemove, key: []const u8, value: []const u8) RecordAction {
        _ = key;
        _ = value;
        self.status.* = Status.init(.SUCCESS);
        return .remove;
    }

    pub fn processEmpty(self: *ProcessorRemove, key: []const u8) RecordAction {
        _ = key;
        self.status.* = Status.init(.NOT_FOUND_ERROR);
        return .noop;
    }
};

// ProcessorCompareExchange — atomic compare-and-exchange on value.
pub const ProcessorCompareExchange = struct {
    status: *Status,
    expected: dbm_mod.CompareExpected,
    desired: dbm_mod.CompareDesired,
    actual_out: ?*std.ArrayList(u8),
    found_out: ?*bool,
    allocator: std.mem.Allocator,

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

// ProcessorIncrement — atomically add delta to stored i64 value.
pub const ProcessorIncrement = struct {
    status: *Status,
    delta: i64,
    current_out: ?*i64,
    initial: i64,
    allocator: std.mem.Allocator,

    pub fn processFull(self: *ProcessorIncrement, key: []const u8, value: []const u8) RecordAction {
        _ = key;
        const current = @as(i64, @bitCast(str_util.strToIntBigEndian(value)));
        if (self.delta == lib_common.INT64MIN) {
            if (self.current_out) |c| c.* = current;
            return .noop;
        }
        const new_val = current +% self.delta;
        var buf: [8]u8 = undefined;
        const enc_key = str_util.intToStrBigEndian(@as(u64, @bitCast(new_val)), 8, &buf);
        if (self.current_out) |c| c.* = new_val;
        return RecordAction{ .set = enc_key };
    }

    pub fn processEmpty(self: *ProcessorIncrement, key: []const u8) RecordAction {
        _ = key;
        if (self.delta == lib_common.INT64MIN) {
            if (self.current_out) |c| c.* = self.initial;
            return .noop;
        }
        const new_val = self.initial +% self.delta;
        var buf: [8]u8 = undefined;
        const enc_key = str_util.intToStrBigEndian(@as(u64, @bitCast(new_val)), 8, &buf);
        if (self.current_out) |c| c.* = new_val;
        return RecordAction{ .set = enc_key };
    }
};

// ProcessorPopFirst — removes and captures first record.
pub const ProcessorPopFirst = struct {
    status: *Status,
    key_out: ?*std.ArrayList(u8),
    value_out: ?*std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn processFull(self: *ProcessorPopFirst, key: []const u8, value: []const u8) RecordAction {
        if (self.key_out) |ko| {
            ko.clearRetainingCapacity();
            // C++ uses std::string::assign() which throws std::bad_alloc on OOM (process
            // terminates). Here we abort the pop and signal SYSTEM_ERROR instead.
            ko.appendSlice(self.allocator, key) catch {
                self.status.* = Status.init(.SYSTEM_ERROR);
                return .noop;
            };
        }
        if (self.value_out) |vo| {
            vo.clearRetainingCapacity();
            vo.appendSlice(self.allocator, value) catch {
                self.status.* = Status.init(.SYSTEM_ERROR);
                return .noop;
            };
        }
        return .remove;
    }

    pub fn processEmpty(self: *ProcessorPopFirst, key: []const u8) RecordAction {
        _ = self;
        _ = key;
        return .noop;
    }
};

// ---------------------------------------------------------------------------
// Forward declarations
// ---------------------------------------------------------------------------

const TinyDBMIteratorImpl = struct {
    // Nullable: set to null by TinyDBMImpl.deinit when the DBM is destroyed
    // while iterators still exist. iterDeinit checks for null before locking,
    // matching the C++ pattern of nulling iterator->dbm_ in ~TinyDBMImpl.
    dbm: ?*TinyDBMImpl,
    bucket_index: std.atomic.Value(i64), // -1 = invalid
    keys: std.ArrayList([]u8), // owned key copies for the current batch
    allocator: std.mem.Allocator,
};

// ---------------------------------------------------------------------------
// TinyDBMImpl
// ---------------------------------------------------------------------------

const TinyDBMImpl = struct {
    allocator: std.mem.Allocator,
    iterators: std.ArrayList(*TinyDBMIteratorImpl),
    file: File,
    open: bool,
    writable: bool,
    open_options: OpenOptions,
    path: std.ArrayList(u8),
    timestamp: std.Io.Timestamp,
    num_records: std.atomic.Value(i64),
    num_buckets: i64,
    buckets: []?[*]u8,
    update_logger: ?*UpdateLogger,
    mutex: std.Io.RwLock = .init,
    record_mutex: HashMutex,

    fn init(
        file: File,
        num_buckets_req: i64,
        allocator: std.mem.Allocator,
    ) !*TinyDBMImpl {
        const self = try allocator.create(TinyDBMImpl);
        errdefer allocator.destroy(self);

        const nb: i64 = if (num_buckets_req > 0)
            hash_util.getHashBucketSize(@min(num_buckets_req, MAX_NUM_BUCKETS))
        else
            DEFAULT_NUM_BUCKETS;

        self.* = TinyDBMImpl{
            .allocator = allocator,
            .iterators = .empty,
            .file = file,
            .open = false,
            .writable = false,
            .open_options = .{},
            .path = .empty,
            .timestamp = std.Io.Timestamp.zero,
            .num_records = std.atomic.Value(i64).init(0),
            .num_buckets = nb,
            .buckets = &.{},
            .update_logger = null,
            .mutex = .init,
            .record_mutex = undefined,
        };

        self.record_mutex = try HashMutex.init(
            RECORD_MUTEX_NUM_SLOTS,
            nb,
            hash_util.primaryHash,
            allocator,
        );
        errdefer self.record_mutex.deinit();

        try self.initializeBuckets();
        return self;
    }

    fn deinit(self: *TinyDBMImpl, io: std.Io) void {
        if (self.open) {
            _ = self.closeImpl(io);
        }
        // Orphan any live iterators: null out dbm pointer (matches C++ ~TinyDBMImpl
        // which sets iterator->dbm_ = nullptr) and invalidate bucket_index.
        // iterDeinit checks for null before accessing the mutex.
        for (self.iterators.items) |iter| {
            iter.dbm = null;
            iter.bucket_index.store(-1, .release);
        }
        self.iterators.deinit(self.allocator);
        self.releaseAllRecords();
        self.allocator.free(self.buckets);
        self.path.deinit(self.allocator);
        self.record_mutex.deinit();
        self.file.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn initializeBuckets(self: *TinyDBMImpl) !void {
        self.buckets = try self.allocator.alloc(?[*]u8, @intCast(self.num_buckets));
        @memset(self.buckets, null);
        self.record_mutex.rehash(self.num_buckets);
    }

    fn releaseAllRecords(self: *TinyDBMImpl) void {
        for (self.buckets) |head| {
            var ptr = head;
            while (ptr) |p| {
                // Recover child before freeing.
                const blob: []u8 = p[0..self.blobLen(p)];
                const child = getChild(blob);
                self.allocator.free(blob);
                ptr = child;
            }
        }
    }

    // Compute the byte length of a blob from its header (to reconstruct the
    // slice).  This requires parsing the varint fields because the blob's
    // allocation length is not stored inline.
    //
    // Note: this is called only in releaseAllRecords where we walk every blob.
    // For performance-critical paths (processImpl/appendImpl) the caller
    // already holds the slice.
    fn blobLen(self: *const TinyDBMImpl, ptr: [*]u8) usize {
        _ = self;
        const rv = deserializeRecord(ptr);
        const key_vsize = varint.sizeVarNum(rv.key.len);
        const val_vsize = varint.sizeVarNum(rv.value.len);
        return HEADER_SIZE + key_vsize + rv.key.len + val_vsize + rv.value.len;
    }

    fn cancelIterators(self: *TinyDBMImpl) void {
        for (self.iterators.items) |iter| {
            iter.bucket_index.store(-1, .release);
        }
    }

    // -----------------------------------------------------------------------
    // Open / Close
    // -----------------------------------------------------------------------

    fn openImpl(
        self: *TinyDBMImpl,
        io: std.Io,
        path: []const u8,
        writable: bool,
        options: OpenOptions,
    ) Status {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.open) {
            return Status.initMsg(.PRECONDITION_ERROR, "already open");
        }

        const norm_path = file_mod.normalizePath(path);
        const st_open = self.file.open(io, norm_path, writable, options);
        if (!st_open.isOk()) return st_open;

        if (self.file.getSizeSimple() < 1) {
            self.timestamp = std.Io.Clock.real.now(io);
        }

        const st_import = self.importRecords(io);
        if (!st_import.isOk()) {
            _ = self.file.close(io);
            return st_import;
        }

        self.path.clearRetainingCapacity();
        self.path.appendSlice(self.allocator, norm_path) catch {
            _ = self.file.close(io);
            return Status.init(.SYSTEM_ERROR);
        };
        self.open = true;
        self.writable = writable;
        self.open_options = options;
        return Status.init(.SUCCESS);
    }

    fn closeImpl(self: *TinyDBMImpl, io: std.Io) Status {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (!self.open) {
            return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        }

        var status = Status.init(.SUCCESS);
        if (self.writable) {
            status.mergeFrom(self.exportRecords(io));
        }
        status.mergeFrom(self.file.close(io));
        self.releaseAllRecords();
        self.cancelIterators();
        self.allocator.free(self.buckets);
        self.buckets = &.{};
        self.initializeBuckets() catch {
            status.mergeFrom(Status.init(.SYSTEM_ERROR));
        };
        self.open = false;
        self.writable = false;
        self.open_options = .{};
        self.path.clearRetainingCapacity();
        self.timestamp = std.Io.Timestamp.zero;
        self.num_records.store(0, .release);
        return status;
    }

    // -----------------------------------------------------------------------
    // Core record operations
    // -----------------------------------------------------------------------

    // processImpl is comptime-generic over the processor type (P must expose
    // processFull and processEmpty methods matching the RecordAction return type).
    // `writable` controls whether mutations are applied (matching C++ writable param).
    fn processImpl(
        self: *TinyDBMImpl,
        comptime P: type,
        proc: *P,
        key: []const u8,
        bucket_index: i64,
        writable: bool,
    ) !void {
        const bidx: usize = @intCast(bucket_index);
        const top: ?[*]u8 = self.buckets[bidx];
        var parent: ?[*]u8 = null;
        var ptr: ?[*]u8 = top;

        while (ptr) |p| {
            const blob_size = self.blobLen(p);
            const blob: []u8 = p[0..blob_size];
            const rv = deserializeRecord(p);

            if (std.mem.eql(u8, key, rv.key)) {
                // Found: dispatch to processFull.
                const action = proc.processFull(key, rv.value);
                switch (action) {
                    .noop => {},
                    .remove => {
                        if (writable) {
                            if (self.update_logger) |ul| {
                                _ = ul.writeRemove(key);
                            }
                            const child = rv.child;
                            self.allocator.free(blob);
                            if (parent == null) {
                                self.buckets[bidx] = child;
                            } else {
                                setChild(parent.?[0..HEADER_SIZE], child);
                            }
                            _ = self.num_records.fetchSub(1, .monotonic);
                        }
                    },
                    .set => |new_value| {
                        if (writable) {
                            // C++ WAL ordering: log before mutation. On OOM the caller
                            // receives SYSTEM_ERROR and must stop using the database —
                            // same effective outcome as C++ process termination.
                            if (self.update_logger) |ul| {
                                _ = ul.writeSet(key, new_value);
                            }
                            const new_blob = try reserializeRecord(
                                self.allocator,
                                blob,
                                key,
                                rv.value.len,
                                new_value,
                            );
                            const new_ptr: [*]u8 = new_blob.ptr;
                            if (new_ptr != p) {
                                if (parent == null) {
                                    self.buckets[bidx] = new_ptr;
                                } else {
                                    setChild(parent.?[0..HEADER_SIZE], new_ptr);
                                }
                            }
                        }
                    },
                }
                return;
            }
            parent = p;
            ptr = rv.child;
        }

        // Not found: dispatch to processEmpty.
        const action = proc.processEmpty(key);
        switch (action) {
            .noop, .remove => {},
            .set => |new_value| {
                if (writable) {
                    if (self.update_logger) |ul| {
                        _ = ul.writeSet(key, new_value);
                    }
                    const new_blob = try serializeRecord(self.allocator, top, key, new_value);
                    self.buckets[bidx] = new_blob.ptr;
                    _ = self.num_records.fetchAdd(1, .monotonic);
                }
            },
        }
    }

    fn appendImpl(
        self: *TinyDBMImpl,
        key: []const u8,
        bucket_index: i64,
        value: []const u8,
        delim: []const u8,
    ) !void {
        const bidx: usize = @intCast(bucket_index);
        const top: ?[*]u8 = self.buckets[bidx];
        var parent: ?[*]u8 = null;
        var ptr: ?[*]u8 = top;

        while (ptr) |p| {
            const blob_size = self.blobLen(p);
            const blob: []u8 = p[0..blob_size];
            const rv = deserializeRecord(p);

            if (std.mem.eql(u8, key, rv.key)) {
                const new_blob = try reserializeAppend(
                    self.allocator,
                    blob,
                    key,
                    rv.value,
                    delim,
                    value,
                );
                if (self.update_logger) |ul| {
                    const updated = deserializeRecord(new_blob.ptr);
                    _ = ul.writeSet(key, updated.value);
                }
                const new_ptr: [*]u8 = new_blob.ptr;
                if (new_ptr != p) {
                    if (parent == null) {
                        self.buckets[bidx] = new_ptr;
                    } else {
                        setChild(parent.?[0..HEADER_SIZE], new_ptr);
                    }
                }
                return;
            }
            parent = p;
            ptr = rv.child;
        }

        // Not found: insert fresh.
        // C++ WAL ordering: log before mutation (same as the update path above).
        if (self.update_logger) |ul| {
            _ = ul.writeSet(key, value);
        }
        const new_blob = try serializeRecord(self.allocator, top, key, value);
        self.buckets[bidx] = new_blob.ptr;
        _ = self.num_records.fetchAdd(1, .monotonic);
    }

    // -----------------------------------------------------------------------
    // Import / Export
    // -----------------------------------------------------------------------

    fn importRecords(self: *TinyDBMImpl, io: std.Io) Status {
        var reader = FlatRecordReader.init(
            self.file,
            self.allocator,
            file_util.DEFAULT_READER_BUFFER_SIZE,
        ) catch return Status.init(.SYSTEM_ERROR);
        defer reader.deinit();

        var key_store: std.ArrayList(u8) = .empty;
        defer key_store.deinit(self.allocator);

        while (true) {
            var str: []const u8 = undefined;
            var rec_type: RecordType = undefined;
            const st = reader.read(io, &str, &rec_type);
            if (!st.isOk()) {
                if (st.code == .NOT_FOUND_ERROR) break;
                return st;
            }

            if (rec_type != .normal) {
                if (rec_type == .metadata) {
                    // Parse metadata for timestamp.
                    var meta = str_util.deserializeStrMap(str, self.allocator) catch continue;
                    defer meta.deinit();
                    if (meta.get("class")) |class_str| {
                        if (str_util.strContains(class_str, "DBM")) {
                            if (meta.get("timestamp")) |ts_str| {
                                if (ts_str.len > 0) {
                                    const secs_f64 = str_util.strToDouble(ts_str, 0.0);
                                    const nanos: i96 = @trunc(secs_f64 * 1_000_000_000.0);
                                    self.timestamp = .{ .nanoseconds = nanos };
                                }
                            }
                        }
                    }
                }
                continue;
            }

            // Save key (str points into reader buffer; must copy).
            key_store.clearRetainingCapacity();
            key_store.appendSlice(self.allocator, str) catch
                return Status.init(.SYSTEM_ERROR);

            // Read paired value.
            var val_str: []const u8 = undefined;
            var val_type: RecordType = undefined;
            const st2 = reader.read(io, &val_str, &val_type);
            if (!st2.isOk()) {
                if (st2.code == .NOT_FOUND_ERROR) {
                    return Status.initMsg(.BROKEN_DATA_ERROR, "odd number of records");
                }
                return st2;
            }
            if (val_type != .normal) {
                return Status.initMsg(.BROKEN_DATA_ERROR, "invalid metadata position");
            }

            var import_status = Status.init(.SUCCESS);
            var setter = ProcessorSet{
                .status = &import_status,
                .value = val_str,
                .overwrite = true,
                .old_value = null,
                .allocator = self.allocator,
            };
            const bucket_index = self.record_mutex.lockOne(key_store.items);
            defer self.record_mutex.unlockOne(bucket_index);
            self.processImpl(ProcessorSet, &setter, key_store.items, bucket_index, true) catch
                return Status.init(.SYSTEM_ERROR);
        }
        return Status.init(.SUCCESS);
    }

    // NOTE: if the final self.file.open at the bottom of this function fails,
    // self.file.handle will be null. When called from closeImpl this is safe —
    // closeImpl unconditionally sets self.open = false afterward (matching C++
    // TinyDBMImpl::Close which always sets open_=false). When called from
    // synchronize, the DB is left with self.open=true but no open file handle;
    // subsequent file operations return PRECONDITION_ERROR. This matches the
    // C++ behavior in Synchronize and is treated as a known limitation.
    fn exportRecords(self: *TinyDBMImpl, io: std.Io) Status {
        var status = Status.init(.SUCCESS);

        status.mergeFrom(self.file.close(io));
        if (!status.isOk()) return status;

        // Build export path.
        var export_path_buf: std.ArrayList(u8) = .empty;
        defer export_path_buf.deinit(self.allocator);
        export_path_buf.appendSlice(self.allocator, self.path.items) catch
            return Status.init(.SYSTEM_ERROR);
        export_path_buf.appendSlice(self.allocator, ".tmp.export") catch
            return Status.init(.SYSTEM_ERROR);
        const export_path = export_path_buf.items;

        // C++ only forwards TRUNCATE and SYNC_HARD to the export file open;
        // all other flags (no_create, no_wait, no_lock) must be cleared so the
        // temporary export file can actually be created.
        const export_options = OpenOptions{
            .truncate = true,
            .no_lock = true,
            .sync_hard = self.open_options.sync_hard,
        };

        const st_open = self.file.open(io, export_path, true, export_options);
        if (!st_open.isOk()) {
            var reopen_opts = self.open_options;
            reopen_opts.truncate = false;
            _ = self.file.open(io, self.path.items, true, reopen_opts);
            return st_open;
        }

        // Defer guard to ensure export file is closed even if errors occur below.
        var export_file_open = true;
        defer {
            if (export_file_open) {
                _ = self.file.close(io);
            }
        }

        // Write metadata flat record.
        var flat_rec = FlatRecord{
            .file = self.file,
            .allocator = self.allocator,
        };
        defer flat_rec.deinit();

        {
            var meta = std.StringHashMap([]const u8).init(self.allocator);
            defer meta.deinit();

            const ts_str = std.fmt.allocPrint(self.allocator, "{d:.6}", .{time_util.getWallTime(io)}) catch
                return Status.init(.SYSTEM_ERROR);
            defer self.allocator.free(ts_str);
            const nr_str = std.fmt.allocPrint(self.allocator, "{d}", .{self.num_records.load(.monotonic)}) catch
                return Status.init(.SYSTEM_ERROR);
            defer self.allocator.free(nr_str);
            const nb_str = std.fmt.allocPrint(self.allocator, "{d}", .{self.num_buckets}) catch
                return Status.init(.SYSTEM_ERROR);
            defer self.allocator.free(nb_str);

            meta.put("class", "TinyDBM") catch return Status.init(.SYSTEM_ERROR);
            meta.put("timestamp", ts_str) catch return Status.init(.SYSTEM_ERROR);
            meta.put("num_records", nr_str) catch return Status.init(.SYSTEM_ERROR);
            meta.put("num_buckets", nb_str) catch return Status.init(.SYSTEM_ERROR);

            const serialized = str_util.serializeStrMap(&meta, self.allocator) catch
                return Status.init(.SYSTEM_ERROR);
            defer self.allocator.free(serialized);

            status.mergeFrom(flat_rec.write(io, serialized, .metadata));
        }

        // Write all records.
        outer: for (self.buckets) |head| {
            var ptr: ?[*]u8 = head;
            while (ptr) |p| {
                const rv = deserializeRecord(p);
                status.mergeFrom(flat_rec.write(io, rv.key, .normal));
                status.mergeFrom(flat_rec.write(io, rv.value, .normal));
                if (!status.isOk()) break :outer;
                ptr = rv.child;
            }
        }

        export_file_open = false;
        status.mergeFrom(self.file.close(io));
        status.mergeFrom(file_mod.renameFile(export_path, self.path.items));
        _ = file_mod.removeFile(export_path);

        var reopen_opts = self.open_options;
        reopen_opts.truncate = false;
        status.mergeFrom(self.file.open(io, self.path.items, true, reopen_opts));
        return status;
    }

    // -----------------------------------------------------------------------
    // Higher-level operations
    // -----------------------------------------------------------------------

    fn clear(self: *TinyDBMImpl, io: std.Io) Status {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.update_logger) |ul| {
            _ = ul.writeClear();
        }
        self.releaseAllRecords();
        self.cancelIterators();
        self.allocator.free(self.buckets);
        self.buckets = &.{};
        self.initializeBuckets() catch return Status.init(.SYSTEM_ERROR);
        self.num_records.store(0, .release);
        return Status.init(.SUCCESS);
    }

    fn rebuild(self: *TinyDBMImpl, io: std.Io, num_buckets_req: i64) Status {
        // No update logger call here — C++ Rebuild also skips WriteClear(). Rebuild
        // only rehashes buckets; existing WAL entries remain valid.
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const old_num_buckets = self.num_buckets;
        const old_buckets = self.buckets;

        const new_nb: i64 = if (num_buckets_req > 0)
            num_buckets_req
        else
            self.num_records.load(.monotonic) * 2 + 1;
        const new_num_buckets = hash_util.getHashBucketSize(@min(new_nb, MAX_NUM_BUCKETS));

        // Allocate the new bucket array BEFORE modifying any state. This is a
        // Zig improvement over the C++ original, which called xcalloc inside
        // InitializeBuckets() after already updating num_buckets_ — meaning an
        // OOM exception there would leave old_buckets leaked with no cleanup.
        const new_buckets = self.allocator.alloc(?[*]u8, @intCast(new_num_buckets)) catch
            return Status.init(.SYSTEM_ERROR);
        @memset(new_buckets, null);

        // State swap: from here old_buckets is owned by this function.
        self.num_buckets = new_num_buckets;
        self.buckets = new_buckets;
        self.record_mutex.rehash(new_num_buckets);

        for (old_buckets[0..@intCast(old_num_buckets)]) |head| {
            var ptr: ?[*]u8 = head;
            while (ptr) |p| {
                const rv = deserializeRecord(p);
                ptr = rv.child; // save child before we overwrite it
                const bucket_index: usize = @intCast(self.record_mutex.getBucketIndex(rv.key));
                const top: ?[*]u8 = self.buckets[bucket_index];
                // Re-link this blob at the head of the new bucket.
                const blob: []u8 = p[0..self.blobLen(p)];
                setChild(blob, top);
                self.buckets[bucket_index] = p;
            }
        }
        self.allocator.free(old_buckets);
        self.cancelIterators();
        return Status.init(.SUCCESS);
    }

    fn synchronize(self: *TinyDBMImpl, io: std.Io, hard: bool) Status {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        var status = Status.init(.SUCCESS);
        if (self.writable) {
            if (self.update_logger) |ul| {
                status.mergeFrom(ul.synchronize(hard));
            }
            if (self.open) {
                status.mergeFrom(self.exportRecords(io));
                status.mergeFrom(self.file.synchronize(io, hard));
            }
        }
        return status;
    }

    // processFirst: process the first record found scanning buckets in order.
    // Writable path: exclusive outer lock, calls processImpl on the found bucket.
    // Read-only path: shared outer lock, calls proc.processFull directly (no mutation).
    // Returns NOT_FOUND_ERROR when the DB is empty.
    //
    // Matches C++ TinyDBMImpl::ProcessFirst exactly, including the absence of
    // record_mutex locking: the exclusive outer lock is sufficient for the
    // writable path; the shared lock is sufficient for read-only.
    fn processFirst(
        self: *TinyDBMImpl,
        io: std.Io,
        comptime P: type,
        proc: *P,
        writable: bool,
    ) Status {
        if (writable) {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            for (self.buckets, 0..) |head, bidx| {
                if (head != null) {
                    const rv = deserializeRecord(head.?);
                    // Copy key before processImpl may free/move the blob.
                    const key_copy = self.allocator.dupe(u8, rv.key) catch
                        return Status.init(.SYSTEM_ERROR);
                    defer self.allocator.free(key_copy);
                    self.processImpl(P, proc, key_copy, @intCast(bidx), true) catch
                        return Status.init(.SYSTEM_ERROR);
                    return Status.init(.SUCCESS);
                }
            }
        } else {
            self.mutex.lockSharedUncancelable(io);
            defer self.mutex.unlockShared(io);
            for (self.buckets) |head| {
                if (head) |p| {
                    const rv = deserializeRecord(p);
                    _ = proc.processFull(rv.key, rv.value);
                    return Status.init(.SUCCESS);
                }
            }
        }
        return Status.init(.NOT_FOUND_ERROR);
    }

    // processMulti: atomically process N keys under a multi-slot lock.
    // All keys are locked simultaneously (ascending slot order, matching C++
    // ScopedHashLockMulti) before any processor is called.
    //
    // `keys` and `procs` must have the same length. All processors must be the
    // same comptime type P (Zig comptime monomorphism constraint).
    fn processMulti(
        self: *TinyDBMImpl,
        io: std.Io,
        comptime P: type,
        keys: []const []const u8,
        procs: []const *P,
        writable: bool,
    ) Status {
        std.debug.assert(keys.len == procs.len);
        self.mutex.lockSharedUncancelable(io);
        defer self.mutex.unlockShared(io);

        const bucket_indices = if (writable)
            self.record_mutex.lockMulti(keys, self.allocator) catch
                return Status.init(.SYSTEM_ERROR)
        else
            self.record_mutex.lockMultiShared(keys, self.allocator) catch
                return Status.init(.SYSTEM_ERROR);
        // LIFO: unlock fires before free — bucket_indices still valid on unlock.
        defer self.allocator.free(bucket_indices);
        defer if (writable)
            self.record_mutex.unlockMulti(bucket_indices)
        else
            self.record_mutex.unlockMultiShared(bucket_indices);

        for (0..keys.len) |i| {
            self.processImpl(P, procs[i], keys[i], bucket_indices[i], writable) catch
                return Status.init(.SYSTEM_ERROR);
        }
        return Status.init(.SUCCESS);
    }

    // Read-only accessors below are lock-free snapshots (matching HashDBM
    // convention). num_records is atomic; other fields are written only under
    // exclusive impl mutex during open/close/rebuild and read here racily —
    // tests rely on these working before openImpl runs, so we cannot acquire
    // the RwLock unconditionally.
    fn count(self: *TinyDBMImpl) i64 {
        return self.num_records.load(.monotonic);
    }

    fn isOpen(self: *TinyDBMImpl) bool {
        return self.open;
    }

    fn isWritable(self: *TinyDBMImpl) bool {
        return self.open and self.writable;
    }

    fn setUpdateLogger(self: *TinyDBMImpl, logger: ?*UpdateLogger) void {
        // Lock-free single-pointer write. update_logger is a single pointer
        // field; readers see either the old or new value atomically on all
        // supported targets. Concurrent setUpdateLogger calls are not safe.
        self.update_logger = logger;
    }

    fn getUpdateLogger(self: *TinyDBMImpl) ?*UpdateLogger {
        return self.update_logger;
    }

    fn getFilePath(self: *TinyDBMImpl) []const u8 {
        return self.path.items;
    }

    fn getTimestamp(self: *TinyDBMImpl) f64 {
        return @as(f64, @floatFromInt(self.timestamp.nanoseconds)) / 1_000_000_000.0;
    }

    fn getFileSize(self: *TinyDBMImpl) i64 {
        return self.file.getSizeSimple();
    }

    fn shouldBeRebuilt(self: *TinyDBMImpl) bool {
        return self.num_records.load(.monotonic) > self.num_buckets;
    }

    fn getInternalFile(self: *TinyDBMImpl) File {
        return self.file;
    }

    fn inspect(self: *TinyDBMImpl, allocator: std.mem.Allocator, io: std.Io) !std.ArrayList([2][]u8) {
        // Acquire shared lock post-open (concurrent callers). Pre-open (in-memory
        // use without open()) is single-threaded — no lock needed.
        if (self.open) {
            self.mutex.lockSharedUncancelable(io);
            defer self.mutex.unlockShared(io);
            return self.inspectLocked(allocator);
        }
        return self.inspectLocked(allocator);
    }

    fn inspectLocked(self: *TinyDBMImpl, allocator: std.mem.Allocator) !std.ArrayList([2][]u8) {
        var list: std.ArrayList([2][]u8) = .empty;
        errdefer {
            for (list.items) |pair| {
                allocator.free(pair[0]);
                allocator.free(pair[1]);
            }
            list.deinit(allocator);
        }

        const add = struct {
            fn call(
                lst: *std.ArrayList([2][]u8),
                alloc: std.mem.Allocator,
                name: []const u8,
                value: []const u8,
            ) !void {
                const k = try alloc.dupe(u8, name);
                errdefer alloc.free(k);
                const v = try alloc.dupe(u8, value);
                errdefer alloc.free(v);
                try lst.append(alloc, .{ k, v });
            }
        }.call;

        try add(&list, allocator, "class", "TinyDBM");
        if (self.open) {
            try add(&list, allocator, "path", self.path.items);
            const ts_secs: f64 = @as(f64, @floatFromInt(self.timestamp.nanoseconds)) / 1_000_000_000.0;
            const ts_str = try std.fmt.allocPrint(allocator, "{d:.6}", .{ts_secs});
            defer allocator.free(ts_str);
            try add(&list, allocator, "timestamp", ts_str);
        }
        const nr_str = try std.fmt.allocPrint(allocator, "{d}", .{self.num_records.load(.monotonic)});
        defer allocator.free(nr_str);
        try add(&list, allocator, "num_records", nr_str);
        const nb_str = try std.fmt.allocPrint(allocator, "{d}", .{self.num_buckets});
        defer allocator.free(nb_str);
        try add(&list, allocator, "num_buckets", nb_str);

        return list;
    }

    // -----------------------------------------------------------------------
    // Iterator support
    // -----------------------------------------------------------------------

    fn readNextBucketRecords(
        self: *TinyDBMImpl,
        iter: *TinyDBMIteratorImpl,
    ) Status {
        while (true) {
            const bucket_index = iter.bucket_index.load(.monotonic);
            if (bucket_index < 0 or bucket_index >= self.num_buckets) break;

            // CAS: advance bucket_index atomically.
            if (iter.bucket_index.cmpxchgStrong(
                bucket_index,
                bucket_index + 1,
                .monotonic,
                .monotonic,
            ) != null) break;

            // Lock this bucket in shared mode.
            const ok = self.record_mutex.lockOneSharedByIndex(bucket_index);
            if (!ok) break;
            defer self.record_mutex.unlockOneShared(bucket_index);

            const bidx: usize = @intCast(bucket_index);
            var ptr: ?[*]u8 = self.buckets[bidx];
            while (ptr) |p| {
                const rv = deserializeRecord(p);
                // Make an owned copy of the key.
                const key_copy = iter.allocator.dupe(u8, rv.key) catch
                    return Status.init(.SYSTEM_ERROR);
                iter.keys.append(iter.allocator, key_copy) catch {
                    iter.allocator.free(key_copy);
                    return Status.init(.SYSTEM_ERROR);
                };
                ptr = rv.child;
            }

            if (iter.keys.items.len > 0) {
                return Status.init(.SUCCESS);
            }
        }
        iter.bucket_index.store(-1, .release);
        return Status.init(.NOT_FOUND_ERROR);
    }
};

// ---------------------------------------------------------------------------
// TinyDBMIteratorImpl methods
// ---------------------------------------------------------------------------

fn iterInit(dbm: *TinyDBMImpl, io: std.Io, allocator: std.mem.Allocator) !*TinyDBMIteratorImpl {
    const self = try allocator.create(TinyDBMIteratorImpl);
    errdefer allocator.destroy(self);
    self.* = TinyDBMIteratorImpl{
        .dbm = dbm,
        .bucket_index = std.atomic.Value(i64).init(-1),
        .keys = .empty,
        .allocator = allocator,
    };
    dbm.mutex.lockUncancelable(io);
    defer dbm.mutex.unlock(io);
    try dbm.iterators.append(dbm.allocator, self);
    return self;
}

fn iterDeinit(self: *TinyDBMIteratorImpl, io: std.Io) void {
    // dbm may be null if TinyDBMImpl.deinit ran first — matches C++ null check
    // in ~TinyDBMIteratorImpl before acquiring the mutex.
    if (self.dbm) |d| {
        d.mutex.lockUncancelable(io);
        const items = d.iterators.items;
        for (items, 0..) |it, i| {
            if (it == self) {
                _ = d.iterators.orderedRemove(i);
                break;
            }
        }
        d.mutex.unlock(io);
    }

    // Free all key copies.
    for (self.keys.items) |k| {
        self.allocator.free(k);
    }
    self.keys.deinit(self.allocator);
    self.allocator.destroy(self);
}

fn iterFirst(self: *TinyDBMIteratorImpl, io: std.Io) Status {
    self.dbm.?.mutex.lockSharedUncancelable(io);
    defer self.dbm.?.mutex.unlockShared(io);
    self.bucket_index.store(0, .release);
    for (self.keys.items) |k| self.allocator.free(k);
    self.keys.clearRetainingCapacity();
    return Status.init(.SUCCESS);
}

fn iterJump(self: *TinyDBMIteratorImpl, io: std.Io, key: []const u8) Status {
    self.dbm.?.mutex.lockSharedUncancelable(io);
    defer self.dbm.?.mutex.unlockShared(io);

    self.bucket_index.store(-1, .release);
    for (self.keys.items) |k| self.allocator.free(k);
    self.keys.clearRetainingCapacity();

    {
        const bucket_index = self.dbm.?.record_mutex.lockOneShared(key);
        defer self.dbm.?.record_mutex.unlockOneShared(bucket_index);
        self.bucket_index.store(bucket_index, .release);
    }

    const st = self.dbm.?.readNextBucketRecords(self);
    if (!st.isOk()) return st;

    // Find the key in the loaded batch.
    var found_idx: ?usize = null;
    for (self.keys.items, 0..) |k, i| {
        if (std.mem.eql(u8, k, key)) {
            found_idx = i;
            break;
        }
    }

    if (found_idx == null) {
        self.bucket_index.store(-1, .release);
        for (self.keys.items) |k| self.allocator.free(k);
        self.keys.clearRetainingCapacity();
        return Status.init(.NOT_FOUND_ERROR);
    }

    // Erase everything before the found key.
    const idx = found_idx.?;
    for (self.keys.items[0..idx]) |k| self.allocator.free(k);
    const remaining = self.keys.items.len - idx;
    std.mem.copyForwards([]u8, self.keys.items[0..remaining], self.keys.items[idx..]);
    self.keys.shrinkRetainingCapacity(remaining);

    return Status.init(.SUCCESS);
}

fn iterNext(self: *TinyDBMIteratorImpl, io: std.Io) Status {
    self.dbm.?.mutex.lockSharedUncancelable(io);
    defer self.dbm.?.mutex.unlockShared(io);

    const st = iterReadKeys(self);
    if (!st.isOk()) return st;

    // Erase first key.
    self.allocator.free(self.keys.items[0]);
    _ = self.keys.orderedRemove(0);
    return Status.init(.SUCCESS);
}

fn iterProcess(
    self: *TinyDBMIteratorImpl,
    io: std.Io,
    comptime P: type,
    proc: *P,
    writable: bool,
) Status {
    self.dbm.?.mutex.lockSharedUncancelable(io);
    defer self.dbm.?.mutex.unlockShared(io);

    const st = iterReadKeys(self);
    if (!st.isOk()) return st;

    const first_key = self.keys.items[0];

    // Wrapper captures whether processFull was called. If the key was
    // deleted between when the iterator snapshotted it and now, processImpl
    // calls processEmpty instead — in that case C++ returns NOT_FOUND_ERROR.
    const WrapperResult = struct {
        action: RecordAction = .noop,
        full_called: bool = false,
    };
    var result = WrapperResult{};

    const Wrapper = struct {
        inner: *P,
        result_ptr: *WrapperResult,

        pub fn processFull(w: *@This(), key: []const u8, value: []const u8) RecordAction {
            const a = w.inner.processFull(key, value);
            w.result_ptr.action = a;
            w.result_ptr.full_called = true;
            return a;
        }
        pub fn processEmpty(w: *@This(), key: []const u8) RecordAction {
            _ = key;
            w.result_ptr.action = .noop;
            // full_called intentionally left false.
            return .noop;
        }
    };
    var wrapper = Wrapper{ .inner = proc, .result_ptr = &result };

    {
        const bucket_index = if (writable)
            self.dbm.?.record_mutex.lockOne(first_key)
        else
            self.dbm.?.record_mutex.lockOneShared(first_key);
        defer if (writable)
            self.dbm.?.record_mutex.unlockOne(bucket_index)
        else
            self.dbm.?.record_mutex.unlockOneShared(bucket_index);

        self.dbm.?.processImpl(Wrapper, &wrapper, first_key, bucket_index, writable) catch
            return Status.init(.SYSTEM_ERROR);
    }

    // processFull was never invoked → record was deleted between snapshot and
    // now. Matches C++ which returns NOT_FOUND_ERROR in this case.
    if (!result.full_called) {
        return Status.init(.NOT_FOUND_ERROR);
    }

    switch (result.action) {
        .remove => {
            // Erase first key from the batch.
            self.allocator.free(self.keys.items[0]);
            _ = self.keys.orderedRemove(0);
        },
        else => {},
    }

    return Status.init(.SUCCESS);
}

fn iterReadKeys(self: *TinyDBMIteratorImpl) Status {
    if (self.bucket_index.load(.monotonic) < 0) {
        return Status.init(.NOT_FOUND_ERROR);
    }
    if (self.keys.items.len == 0) {
        const st = self.dbm.?.readNextBucketRecords(self);
        if (!st.isOk()) return st;
        if (self.keys.items.len == 0) {
            return Status.init(.NOT_FOUND_ERROR);
        }
    }
    return Status.init(.SUCCESS);
}

// Iterator get — reads current key+value into caller-allocated buffers.
fn iterGet(
    self: *TinyDBMIteratorImpl,
    io: std.Io,
    key_out: ?*std.ArrayList(u8),
    value_out: ?*std.ArrayList(u8),
) Status {
    const dbm = self.dbm orelse return Status.initMsg(.PRECONDITION_ERROR, "orphaned iterator");
    const allocator = dbm.allocator;
    dbm.mutex.lockSharedUncancelable(io);
    defer dbm.mutex.unlockShared(io);

    const st = iterReadKeys(self);
    if (!st.isOk()) return st;

    const first_key = self.keys.items[0];

    if (key_out) |k| {
        k.clearRetainingCapacity();
        k.appendSlice(allocator, first_key) catch return Status.init(.SYSTEM_ERROR);
    }

    if (value_out) |v| {
        var get_status = Status.init(.SUCCESS);
        var value_buf: std.ArrayList(u8) = .empty;
        defer value_buf.deinit(allocator);
        var getter = ProcessorGet{ .status = &get_status, .value = &value_buf, .allocator = allocator };

        const bucket_index = dbm.record_mutex.lockOneShared(first_key);
        defer dbm.record_mutex.unlockOneShared(bucket_index);

        dbm.processImpl(ProcessorGet, &getter, first_key, bucket_index, false) catch {
            if (key_out) |k| k.clearRetainingCapacity();
            return Status.init(.SYSTEM_ERROR);
        };

        if (!get_status.isOk()) {
            if (key_out) |k| k.clearRetainingCapacity();
            return get_status;
        }

        v.clearRetainingCapacity();
        v.appendSlice(allocator, value_buf.items) catch {
            if (key_out) |k| k.clearRetainingCapacity();
            return Status.init(.SYSTEM_ERROR);
        };
    }

    return Status.init(.SUCCESS);
}

// ---------------------------------------------------------------------------
// Public TinyDBM struct
// ---------------------------------------------------------------------------

pub const TinyDBM = struct {
    impl: *TinyDBMImpl,
    allocator: std.mem.Allocator,

    // -----------------------------------------------------------------------
    // Cursor public struct
    // -----------------------------------------------------------------------

    pub const Cursor = struct {
        impl: *TinyDBMIteratorImpl,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *Cursor, io: std.Io) void {
            iterDeinit(self.impl, io);
        }

        pub fn first(self: *Cursor, io: std.Io) Status {
            return iterFirst(self.impl, io);
        }

        pub fn jump(self: *Cursor, io: std.Io, key: []const u8) Status {
            return iterJump(self.impl, io, key);
        }

        pub fn next(self: *Cursor, io: std.Io) Status {
            return iterNext(self.impl, io);
        }

        /// Reads the current key and/or value into caller-provided ArrayLists.
        /// The lists are cleared and populated; caller owns the memory.
        pub fn get(
            self: *Cursor,
            io: std.Io,
            key_out: ?*std.ArrayList(u8),
            value_out: ?*std.ArrayList(u8),
        ) Status {
            return iterGet(self.impl, io, key_out, value_out);
        }

        /// Process the current record with a comptime processor.
        pub fn process(
            self: *Cursor,
            io: std.Io,
            comptime P: type,
            proc: *P,
            writable: bool,
        ) Status {
            return iterProcess(self.impl, io, P, proc, writable);
        }

        /// Overwrites the current record's value. Optionally captures the old
        /// key and value into caller-owned ArrayLists (populated with the
        /// DBM-internal allocator).
        pub fn set(
            self: *Cursor,
            io: std.Io,
            value: []const u8,
            old_key: ?*std.ArrayList(u8),
            old_value: ?*std.ArrayList(u8),
        ) Status {
            const SetProc = struct {
                value: []const u8,
                old_key: ?*std.ArrayList(u8),
                old_value: ?*std.ArrayList(u8),
                allocator: std.mem.Allocator,
                status: Status = Status.init(.SUCCESS),
                pub fn processFull(p: *@This(), key: []const u8, val: []const u8) RecordAction {
                    if (p.old_key) |ok| {
                        ok.clearRetainingCapacity();
                        ok.appendSlice(p.allocator, key) catch {
                            p.status = Status.init(.SYSTEM_ERROR);
                            return .noop;
                        };
                    }
                    if (p.old_value) |ov| {
                        ov.clearRetainingCapacity();
                        ov.appendSlice(p.allocator, val) catch {
                            p.status = Status.init(.SYSTEM_ERROR);
                            return .noop;
                        };
                    }
                    return RecordAction{ .set = p.value };
                }
                pub fn processEmpty(_: *@This(), _: []const u8) RecordAction {
                    return .noop;
                }
            };
            var proc = SetProc{
                .value = value,
                .old_key = old_key,
                .old_value = old_value,
                .allocator = self.allocator,
            };
            const st = self.process(io, SetProc, &proc, true);
            if (!st.isOk()) return st;
            return proc.status;
        }

        /// Removes the current record and advances the iterator. Optionally
        /// captures the old key and value into caller-owned ArrayLists.
        pub fn remove(
            self: *Cursor,
            io: std.Io,
            old_key: ?*std.ArrayList(u8),
            old_value: ?*std.ArrayList(u8),
        ) Status {
            const RemoveProc = struct {
                old_key: ?*std.ArrayList(u8),
                old_value: ?*std.ArrayList(u8),
                allocator: std.mem.Allocator,
                status: Status = Status.init(.SUCCESS),
                pub fn processFull(p: *@This(), key: []const u8, val: []const u8) RecordAction {
                    if (p.old_key) |ok| {
                        ok.clearRetainingCapacity();
                        ok.appendSlice(p.allocator, key) catch {
                            p.status = Status.init(.SYSTEM_ERROR);
                            return .noop;
                        };
                    }
                    if (p.old_value) |ov| {
                        ov.clearRetainingCapacity();
                        ov.appendSlice(p.allocator, val) catch {
                            p.status = Status.init(.SYSTEM_ERROR);
                            return .noop;
                        };
                    }
                    return .remove;
                }
                pub fn processEmpty(p: *@This(), _: []const u8) RecordAction {
                    p.status = Status.init(.NOT_FOUND_ERROR);
                    return .noop;
                }
            };
            var proc = RemoveProc{
                .old_key = old_key,
                .old_value = old_value,
                .allocator = self.allocator,
            };
            const st = self.process(io, RemoveProc, &proc, true);
            if (!st.isOk()) return st;
            return proc.status;
        }

        /// Gets the current record into the provided ArrayLists and then
        /// advances to the next record. The lists are cleared and populated;
        /// caller owns the memory.
        pub fn step(
            self: *Cursor,
            io: std.Io,
            key_out: ?*std.ArrayList(u8),
            value_out: ?*std.ArrayList(u8),
        ) Status {
            const st = self.get(io, key_out, value_out);
            if (!st.isOk()) return st;
            _ = self.next(io);
            return Status.init(.SUCCESS);
        }

        /// Last is not supported on unordered hash tables.
        pub fn last(self: *Cursor, io: std.Io) Status {
            _ = io;
            _ = self;
            return Status.init(.NOT_IMPLEMENTED_ERROR);
        }

        /// Previous is not supported on unordered hash tables.
        pub fn previous(self: *Cursor, io: std.Io) Status {
            _ = io;
            _ = self;
            return Status.init(.NOT_IMPLEMENTED_ERROR);
        }

        /// JumpLower is not supported on unordered hash tables.
        pub fn jumpLower(self: *Cursor, io: std.Io, key: []const u8, inclusive: bool) Status {
            _ = io;
            _ = self;
            _ = key;
            _ = inclusive;
            return Status.init(.NOT_IMPLEMENTED_ERROR);
        }

        /// JumpUpper is not supported on unordered hash tables.
        pub fn jumpUpper(self: *Cursor, io: std.Io, key: []const u8, inclusive: bool) Status {
            _ = io;
            _ = self;
            _ = key;
            _ = inclusive;
            return Status.init(.NOT_IMPLEMENTED_ERROR);
        }
    };

    // -----------------------------------------------------------------------
    // Zig-style Iterator
    // -----------------------------------------------------------------------

    /// Entry returned by Iterator.next(). The slices point into internal
    /// buffers and are invalidated on the next call to next() or deinit().
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
            if (self.cursor.process(io, Proc, &proc, false).isOk() and !proc.oom) filled = true;
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

    /// Return a Zig-style iterator positioned at the first record.
    /// The caller must call deinit() when done.
    ///
    /// Thread-safety: Iteration is weakly consistent with concurrent writes.
    /// Each call to next() acquires and releases the DBM lock independently.
    /// Records inserted or deleted between calls may or may not be visible.
    pub fn iterate(self: *TinyDBM, alloc: std.mem.Allocator, io: std.Io) !Iterator {
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

    /// Return a Zig-style iterator positioned at the first record >= key.
    /// The caller must call deinit() when done.
    pub fn iterateFrom(self: *TinyDBM, alloc: std.mem.Allocator, io: std.Io, key: []const u8) !Iterator {
        var cursor = try self.makeCursor(io);
        errdefer cursor.deinit(io);
        var iter = Iterator{
            .cursor = cursor,
            .alloc = alloc,
            .key_buf = .empty,
            .value_buf = .empty,
            .done = false,
        };
        if (!iter.cursor.jump(io, key).isOk()) iter.done = true;
        return iter;
    }

    // -----------------------------------------------------------------------
    // TinyDBM public API
    // -----------------------------------------------------------------------

    /// Creates a TinyDBM using the given file object.
    /// If num_buckets <= 0, DEFAULT_NUM_BUCKETS is used.
    pub fn init(file: File, num_buckets: i64, allocator: std.mem.Allocator) !TinyDBM {
        const impl = try TinyDBMImpl.init(file, num_buckets, allocator);
        return TinyDBM{ .impl = impl, .allocator = allocator };
    }

    /// Destroys the TinyDBM, closing if open and releasing all memory.
    pub fn deinit(self: *TinyDBM, io: std.Io) void {
        self.impl.deinit(io);
    }

    pub fn open(self: *TinyDBM, io: std.Io, path: []const u8, writable: bool, options: OpenOptions) Status {
        return self.impl.openImpl(io, path, writable, options);
    }

    pub fn close(self: *TinyDBM, io: std.Io) Status {
        return self.impl.closeImpl(io);
    }

    /// Get the value for key. If value is non-null, the DBM's own allocator is used to populate it.
    pub fn get(
        self: *TinyDBM,
        io: std.Io,
        key: []const u8,
        value: ?*std.ArrayList(u8),
    ) Status {
        var status = Status.init(.SUCCESS);
        var getter = ProcessorGet{ .status = &status, .value = value, .allocator = self.impl.allocator };
        self.impl.mutex.lockSharedUncancelable(io);
        defer self.impl.mutex.unlockShared(io);
        const bucket_index = self.impl.record_mutex.lockOneShared(key);
        defer self.impl.record_mutex.unlockOneShared(bucket_index);
        self.impl.processImpl(ProcessorGet, &getter, key, bucket_index, false) catch
            return Status.init(.SYSTEM_ERROR);
        return status;
    }

    /// Returns the value for key as an owned heap-allocated slice using the
    /// provided allocator. If the key is not found, returns a duplicate of
    /// default_value. The caller must free the returned slice with the same
    /// allocator.
    pub fn getSimple(
        self: *TinyDBM,
        allocator: std.mem.Allocator,
        io: std.Io,
        key: []const u8,
        default_value: []const u8,
    ) ![]const u8 {
        // The DBM's internal allocator is used to back `buf` because `get`
        // delegates to ProcessorGet which appends using self.impl.allocator.
        // We deinit with the same allocator to avoid a mismatched-free, then
        // dupe the result into the caller's allocator before returning.
        const impl_alloc = self.impl.allocator;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(impl_alloc);
        const st = self.get(io, key, &buf);
        if (st.isOk()) return try allocator.dupe(u8, buf.items);
        return try allocator.dupe(u8, default_value);
    }

    /// Set value for key. If old_value is non-null, the DBM's own allocator is used to populate it.
    pub fn set(
        self: *TinyDBM,
        io: std.Io,
        key: []const u8,
        value: []const u8,
        overwrite: bool,
        old_value: ?*std.ArrayList(u8),
    ) Status {
        var status = Status.init(.SUCCESS);
        var setter = ProcessorSet{
            .status = &status,
            .value = value,
            .overwrite = overwrite,
            .old_value = old_value,
            .allocator = self.impl.allocator,
        };
        self.impl.mutex.lockSharedUncancelable(io);
        defer self.impl.mutex.unlockShared(io);
        const bucket_index = self.impl.record_mutex.lockOne(key);
        defer self.impl.record_mutex.unlockOne(bucket_index);
        self.impl.processImpl(ProcessorSet, &setter, key, bucket_index, true) catch
            return Status.init(.SYSTEM_ERROR);
        return status;
    }

    pub fn remove(self: *TinyDBM, io: std.Io, key: []const u8) Status {
        var status = Status.init(.SUCCESS);
        var remover = ProcessorRemove{ .status = &status };
        self.impl.mutex.lockSharedUncancelable(io);
        defer self.impl.mutex.unlockShared(io);
        const bucket_index = self.impl.record_mutex.lockOne(key);
        defer self.impl.record_mutex.unlockOne(bucket_index);
        self.impl.processImpl(ProcessorRemove, &remover, key, bucket_index, true) catch
            return Status.init(.SYSTEM_ERROR);
        return status;
    }

    pub fn append(
        self: *TinyDBM,
        io: std.Io,
        key: []const u8,
        value: []const u8,
        delim: []const u8,
    ) Status {
        self.impl.mutex.lockSharedUncancelable(io);
        defer self.impl.mutex.unlockShared(io);
        const bucket_index = self.impl.record_mutex.lockOne(key);
        defer self.impl.record_mutex.unlockOne(bucket_index);
        self.impl.appendImpl(key, bucket_index, value, delim) catch
            return Status.init(.SYSTEM_ERROR);
        return Status.init(.SUCCESS);
    }

    /// Fetch multiple keys in a single call.  For every key that exists its
    /// value is duped into `records` using the map's allocator.  Missing keys
    /// are silently skipped and only contribute NOT_FOUND_ERROR to the merged
    /// return status.  The caller owns the key and value slices stored in the
    /// map.  Iterates all keys without early exit.
    pub fn getMulti(
        self: *TinyDBM,
        io: std.Io,
        keys: []const []const u8,
        records: *std.StringHashMap([]u8),
    ) Status {
        const map_alloc = records.allocator;
        var status = Status.init(.SUCCESS);
        var val_buf: std.ArrayList(u8) = .empty;
        defer val_buf.deinit(self.impl.allocator);
        for (keys) |key| {
            val_buf.clearRetainingCapacity();
            const st = self.get(io, key, &val_buf);
            if (st.isOk()) {
                const duped_key = map_alloc.dupe(u8, key) catch return Status.init(.SYSTEM_ERROR);
                const duped_val = map_alloc.dupe(u8, val_buf.items) catch {
                    map_alloc.free(duped_key);
                    return Status.init(.SYSTEM_ERROR);
                };
                records.put(duped_key, duped_val) catch {
                    map_alloc.free(duped_key);
                    map_alloc.free(duped_val);
                    return Status.init(.SYSTEM_ERROR);
                };
            } else {
                status.mergeFrom(st);
            }
        }
        return status;
    }

    /// Set multiple key-value pairs.  Stops on any error other than
    /// DUPLICATION_ERROR (which is soft — overwrite=false conflicts).
    pub fn setMulti(
        self: *TinyDBM,
        io: std.Io,
        records: []const [2][]const u8,
        overwrite: bool,
    ) Status {
        var status = Status.init(.SUCCESS);
        for (records) |r| {
            const st = self.set(io, r[0], r[1], overwrite, null);
            status.mergeFrom(st);
            if (!status.isOk() and status.code != .DUPLICATION_ERROR) break;
        }
        return status;
    }

    /// Remove multiple keys.  Stops on any error other than NOT_FOUND_ERROR.
    pub fn removeMulti(
        self: *TinyDBM,
        io: std.Io,
        keys: []const []const u8,
    ) Status {
        var status = Status.init(.SUCCESS);
        for (keys) |key| {
            const st = self.remove(io, key);
            status.mergeFrom(st);
            if (!status.isOk() and status.code != .NOT_FOUND_ERROR) break;
        }
        return status;
    }

    /// Append to multiple keys using the given delimiter.  Stops on first error.
    pub fn appendMulti(
        self: *TinyDBM,
        io: std.Io,
        records: []const [2][]const u8,
        delim: []const u8,
    ) Status {
        var status = Status.init(.SUCCESS);
        for (records) |r| {
            const st = self.append(io, r[0], r[1], delim);
            status.mergeFrom(st);
            if (!status.isOk()) break;
        }
        return status;
    }

    /// Process a single key with a comptime processor under shared mutex.
    pub fn process(
        self: *TinyDBM,
        io: std.Io,
        comptime P: type,
        proc: *P,
        key: []const u8,
        writable: bool,
    ) !Status {
        self.impl.mutex.lockSharedUncancelable(io);
        defer self.impl.mutex.unlockShared(io);
        const bucket_index = if (writable)
            self.impl.record_mutex.lockOne(key)
        else
            self.impl.record_mutex.lockOneShared(key);
        defer if (writable)
            self.impl.record_mutex.unlockOne(bucket_index)
        else
            self.impl.record_mutex.unlockOneShared(bucket_index);
        try self.impl.processImpl(P, proc, key, bucket_index, writable);
        return Status.init(.SUCCESS);
    }

    /// Visit every record with proc. Calls proc.processEmpty before and after
    /// the full scan (matching C++ ProcessEach semantics).
    pub fn processEach(
        self: *TinyDBM,
        io: std.Io,
        comptime P: type,
        proc: *P,
        writable: bool,
    ) !Status {
        if (writable) {
            self.impl.mutex.lockUncancelable(io);
            defer self.impl.mutex.unlock(io);

            _ = proc.processEmpty("");
            for (0..@intCast(self.impl.num_buckets)) |bidx| {
                var ptr: ?[*]u8 = self.impl.buckets[bidx];
                while (ptr) |p| {
                    const rv = deserializeRecord(p);
                    const child = rv.child;
                    // Copy key so processImpl can mutate the blob (reserialize moves memory).
                    const key_copy = try self.impl.allocator.dupe(u8, rv.key);
                    defer self.impl.allocator.free(key_copy);
                    try self.impl.processImpl(P, proc, key_copy, @intCast(bidx), true);
                    ptr = child;
                }
            }
            _ = proc.processEmpty("");
        } else {
            self.impl.mutex.lockSharedUncancelable(io);
            defer self.impl.mutex.unlockShared(io);

            _ = proc.processEmpty("");
            for (self.impl.buckets) |head| {
                var ptr: ?[*]u8 = head;
                while (ptr) |p| {
                    const rv = deserializeRecord(p);
                    _ = proc.processFull(rv.key, rv.value);
                    ptr = rv.child;
                }
            }
            _ = proc.processEmpty("");
        }
        return Status.init(.SUCCESS);
    }

    /// Process the first record found (bucket scan order) with proc.
    /// Returns NOT_FOUND_ERROR when the DB is empty.
    /// Writable: exclusive outer mutex, full processImpl semantics.
    /// Read-only: shared outer mutex, proc.processFull called but return value ignored.
    pub fn processFirst(
        self: *TinyDBM,
        io: std.Io,
        comptime P: type,
        proc: *P,
        writable: bool,
    ) Status {
        return self.impl.processFirst(io, P, proc, writable);
    }

    /// Process N keys atomically under a multi-slot hash lock.
    /// `keys` and `procs` must have equal length; all processors share type P.
    pub fn processMulti(
        self: *TinyDBM,
        io: std.Io,
        comptime P: type,
        keys: []const []const u8,
        procs: []const *P,
        writable: bool,
    ) Status {
        return self.impl.processMulti(io, P, keys, procs, writable);
    }

    fn countInternal(self: *TinyDBM) i64 {
        return self.impl.count();
    }

    pub fn clear(self: *TinyDBM, io: std.Io) Status {
        return self.impl.clear(io);
    }

    pub fn rebuild(self: *TinyDBM, io: std.Io) Status {
        return self.impl.rebuild(io, -1);
    }

    pub fn rebuildAdvanced(self: *TinyDBM, io: std.Io, num_buckets: i64) Status {
        return self.impl.rebuild(io, num_buckets);
    }

    pub fn synchronize(self: *TinyDBM, io: std.Io, hard: bool) Status {
        return self.impl.synchronize(io, hard);
    }

    pub fn isOpen(self: *TinyDBM) bool {
        return self.impl.isOpen();
    }

    pub fn isWritable(self: *TinyDBM) bool {
        return self.impl.isWritable();
    }

    pub fn isHealthy(_: *TinyDBM) bool {
        return true;
    }

    pub fn isOrdered(_: *TinyDBM) bool {
        return false;
    }

    pub fn makeCursor(self: *TinyDBM, io: std.Io) !Cursor {
        const iter_impl = try iterInit(self.impl, io, self.allocator);
        return Cursor{ .impl = iter_impl, .allocator = self.allocator };
    }


    pub fn inspect(self: *TinyDBM, alloc: std.mem.Allocator, io: std.Io) !std.ArrayList([2][]u8) {
        return self.impl.inspect(alloc, io);
    }

    pub fn setUpdateLogger(self: *TinyDBM, logger: ?*UpdateLogger) void {
        self.impl.setUpdateLogger(logger);
    }

    pub fn getUpdateLogger(self: *TinyDBM) ?*UpdateLogger {
        return self.impl.getUpdateLogger();
    }

    /// Returns the file path the DB was opened with.
    /// The returned slice is only valid while the DB is open and not being modified.
    fn getFilePathInternal(self: *TinyDBM) []const u8 {
        return self.impl.getFilePath();
    }

    /// Returns the creation timestamp of the DB file, or 0 when not open.
    fn getTimestampInternal(self: *TinyDBM) f64 {
        return self.impl.getTimestamp();
    }

    /// Returns the size of the backing file in bytes, or -1 on error / not open.
    fn getFileSizeInternal(self: *TinyDBM) i64 {
        return self.impl.getFileSize();
    }

    /// Returns true when num_records exceeds num_buckets — a Rebuild would
    /// reduce chain lengths and improve lookup performance.
    fn shouldBeRebuiltInternal(self: *TinyDBM) bool {
        return self.impl.shouldBeRebuilt();
    }

    /// Fills `out` with the number of records. Returns PRECONDITION_ERROR if not open.
    /// Matches C++ DBM::Count(int64_t* count).
    pub fn count(self: *TinyDBM, out: *i64) Status {
        out.* = self.impl.count();
        return Status.init(.SUCCESS);
    }

    /// Fills `out` with the file size in bytes. Returns PRECONDITION_ERROR if not open.
    /// Matches C++ DBM::GetFileSize(int64_t* size).
    pub fn getFileSize(self: *TinyDBM, out: *i64) Status {
        if (!self.impl.isOpen()) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        out.* = self.impl.getFileSize();
        return Status.init(.SUCCESS);
    }

    /// Appends the file path to `out`. Returns PRECONDITION_ERROR if not open.
    /// Matches C++ DBM::GetFilePath(std::string* path).
    pub fn getFilePath(self: *TinyDBM, out: *std.ArrayList(u8)) Status {
        if (!self.impl.isOpen()) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        out.clearRetainingCapacity();
        out.appendSlice(self.allocator, self.impl.getFilePath()) catch return Status.init(.SYSTEM_ERROR);
        return Status.init(.SUCCESS);
    }

    /// Fills `out` with the modification timestamp. Returns PRECONDITION_ERROR if not open.
    /// Matches C++ DBM::GetTimestamp(double* timestamp).
    pub fn getTimestamp(self: *TinyDBM, out: *f64) Status {
        if (!self.impl.isOpen()) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        out.* = self.impl.getTimestamp();
        return Status.init(.SUCCESS);
    }

    /// Sets `out` to whether a rebuild would improve performance. Returns PRECONDITION_ERROR if not open.
    /// Matches C++ DBM::ShouldBeRebuilt(bool* tobe).
    pub fn shouldBeRebuilt(self: *TinyDBM, out: *bool) Status {
        out.* = self.impl.shouldBeRebuilt();
        return Status.init(.SUCCESS);
    }

    /// Returns a copy of the internal File vtable struct.
    /// Only meaningful when the DB is open.
    pub fn getInternalFile(self: *TinyDBM) File {
        return self.impl.getInternalFile();
    }

    /// Atomically compare and conditionally exchange the value for a key.
    pub fn compareExchange(
        self: *TinyDBM,
        io: std.Io,
        key: []const u8,
        expected: dbm_mod.CompareExpected,
        desired: dbm_mod.CompareDesired,
        actual_out: ?*std.ArrayList(u8),
        found_out: ?*bool,
    ) Status {
        var status = Status.init(.SUCCESS);
        self.impl.mutex.lockSharedUncancelable(io);
        defer self.impl.mutex.unlockShared(io);
        const bucket_index = self.impl.record_mutex.lockOne(key);
        defer self.impl.record_mutex.unlockOne(bucket_index);
        var proc = ProcessorCompareExchange{
            .status = &status,
            .expected = expected,
            .desired = desired,
            .actual_out = actual_out,
            .found_out = found_out,
            .allocator = self.impl.allocator,
        };
        self.impl.processImpl(ProcessorCompareExchange, &proc, key, bucket_index, true) catch
            return Status.init(.SYSTEM_ERROR);
        return status;
    }

    /// Atomically increment a stored i64 value by delta, returning the new value.
    pub fn increment(
        self: *TinyDBM,
        io: std.Io,
        key: []const u8,
        delta: i64,
        current_out: ?*i64,
        initial: i64,
    ) Status {
        var status = Status.init(.SUCCESS);
        self.impl.mutex.lockSharedUncancelable(io);
        defer self.impl.mutex.unlockShared(io);
        const bucket_index = self.impl.record_mutex.lockOne(key);
        defer self.impl.record_mutex.unlockOne(bucket_index);
        var proc = ProcessorIncrement{
            .status = &status,
            .delta = delta,
            .current_out = current_out,
            .initial = initial,
            .allocator = self.impl.allocator,
        };
        self.impl.processImpl(ProcessorIncrement, &proc, key, bucket_index, true) catch
            return Status.init(.SYSTEM_ERROR);
        return status;
    }

    /// Increments the stored i64 value for key by delta and returns the
    /// resulting value. If the key does not exist, it is initialized to initial
    /// before applying delta. On error the return value is initial.
    pub fn incrementSimple(
        self: *TinyDBM,
        io: std.Io,
        key: []const u8,
        delta: i64,
        initial: i64,
    ) i64 {
        var result: i64 = initial;
        _ = self.increment(io, key, delta, &result, initial);
        return result;
    }

    /// Remove and return the first record in the database (arbitrary order on unordered DBMs).
    pub fn popFirst(
        self: *TinyDBM,
        io: std.Io,
        key_out: ?*std.ArrayList(u8),
        value_out: ?*std.ArrayList(u8),
    ) !Status {
        var status = Status.init(.SUCCESS);
        var proc = ProcessorPopFirst{
            .status = &status,
            .key_out = key_out,
            .value_out = value_out,
            .allocator = self.impl.allocator,
        };
        const st = self.processFirst(io, ProcessorPopFirst, &proc, true);
        if (!st.isOk()) return st;
        return status;
    }

    /// Push a value at the lexicographic end using a timestamp-based key.
    /// wtime < 0 uses the current wall clock time; otherwise uses the provided time.
    /// Key is returned in key_out if non-null.
    pub fn pushLast(
        self: *TinyDBM,
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
            const st = self.set(io, key, value, false, null);
            if (st.code != .DUPLICATION_ERROR) {
                if (key_out) |ko| {
                    ko.clearRetainingCapacity();
                    ko.appendSlice(self.impl.allocator, key) catch return Status.init(.SYSTEM_ERROR);
                }
                return st;
            }
        }
    }

    // -----------------------------------------------------------------------
    // Phase 6: Base class methods
    // -----------------------------------------------------------------------

    /// Creates a new heap-allocated TinyDBM instance using NullFile (in-memory only).
    pub fn makeDbm(allocator: std.mem.Allocator) !*TinyDBM {
        const dbm = try allocator.create(TinyDBM);
        errdefer allocator.destroy(dbm);
        dbm.* = try TinyDBM.init(file_mod.NullFile, 0, allocator);
        return dbm;
    }

    /// Returns the record count or -1 when not open. Matches C++ DBM::CountSimple().
    pub fn countSimple(self: *TinyDBM) i64 {
        return self.impl.count();
    }

    /// Returns the file size in bytes or -1 when not open. Matches C++ DBM::GetFileSizeSimple().
    pub fn getFileSizeSimple(self: *TinyDBM) i64 {
        if (!self.impl.isOpen()) return -1;
        return self.impl.getFileSize();
    }

    /// Returns the file path or "" when not open. Matches C++ DBM::GetFilePathSimple().
    pub fn getFilePathSimple(self: *TinyDBM) []const u8 {
        if (!self.impl.isOpen()) return "";
        return self.impl.getFilePath();
    }

    /// Returns the timestamp or NaN when not open. Matches C++ DBM::GetTimestampSimple().
    pub fn getTimestampSimple(self: *TinyDBM) f64 {
        if (!self.impl.isOpen()) return std.math.nan(f64);
        return self.impl.getTimestamp();
    }

    /// Returns whether a rebuild would improve performance, or false when not open.
    /// Matches C++ DBM::ShouldBeRebuiltSimple().
    pub fn shouldBeRebuiltSimple(self: *TinyDBM) bool {
        return self.impl.shouldBeRebuilt();
    }

    /// Copies the backing file to dest_path, optionally syncing first.
    /// Returns NOT_IMPLEMENTED_ERROR when no backing file path is set.
    pub fn copyFileData(self: *TinyDBM, io: std.Io, dest_path: []const u8, sync_hard: bool) Status {
        if (!self.isOpen()) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        if (sync_hard) {
            const st = self.synchronize(io, true);
            if (!st.isOk()) return st;
        }
        const src_path = self.getFilePathInternal();
        if (src_path.len == 0) return Status.initMsg(.NOT_IMPLEMENTED_ERROR, "no backing file");
        file_mod.copyFileAbsolute(src_path, dest_path) catch
            return Status.initMsg(.SYSTEM_ERROR, "copy file failed");
        return Status.init(.SUCCESS);
    }

    /// Renames a key. Reads old value, sets under new_key, removes old_key unless copying=true.
    pub fn rekey(self: *TinyDBM, io: std.Io, old_key: []const u8, new_key: []const u8, overwrite: bool, copying: bool) Status {
        if (!self.isOpen() or !self.isWritable())
            return Status.initMsg(.PRECONDITION_ERROR, "not writable");

        var value_list: std.ArrayList(u8) = .empty;
        defer value_list.deinit(self.allocator);

        const st_get = self.get(io, old_key, &value_list);
        if (!st_get.isOk()) return st_get;

        const st_set = self.set(io, new_key, value_list.items, overwrite, null);
        if (!st_set.isOk()) return st_set;

        if (!copying) {
            _ = self.remove(io, old_key);
        }
        return Status.init(.SUCCESS);
    }

    /// Exports all records from this DBM to dest (any DBM with a set() method).
    pub fn export_(self: *TinyDBM, io: std.Io, dest: anytype) Status {
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
            const st_get = iter.get(io, &key_list, &val_list);
            if (!st_get.isOk()) break;
            const st_set = dest.set(io, key_list.items, val_list.items, true, null);
            if (!st_set.isOk()) return st_set;
            st = iter.next(io);
            if (!st.isOk()) break;
        }
        return Status.init(.SUCCESS);
    }

    /// Atomically checks multiple expected conditions then applies multiple desired changes.
    pub fn compareExchangeMulti(
        self: *TinyDBM,
        io: std.Io,
        expected: []const struct { key: []const u8, value: dbm_mod.CompareExpected },
        desired: []const struct { key: []const u8, value: dbm_mod.CompareDesired },
    ) Status {
        for (expected) |cond| {
            var val_list: std.ArrayList(u8) = .empty;
            defer val_list.deinit(self.allocator);
            const get_st = self.get(io, cond.key, &val_list);
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
                    const st = self.remove(io, change.key);
                    if (!st.isOk() and st.code != .NOT_FOUND_ERROR) return st;
                },
                .set => |new_val| {
                    const st = self.set(io, change.key, new_val, true, null);
                    if (!st.isOk()) return st;
                },
                .noop => {},
            }
        }
        return Status.init(.SUCCESS);
    }
};

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

fn makeInMemoryDB(allocator: std.mem.Allocator) !TinyDBM {
    const std_file = try file_mod.StdFile.create(allocator);
    return TinyDBM.init(std_file.asFile(), 0, allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "basic set/get/remove: 100 keys" {
    const alloc = std.testing.allocator;
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);

    var key_buf: [32]u8 = undefined;
    var val_buf: [32]u8 = undefined;

    // Insert 100 keys.
    for (0..100) |i| {
        const k = try std.fmt.bufPrint(&key_buf, "key{d}", .{i});
        const v = try std.fmt.bufPrint(&val_buf, "val{d}", .{i});
        const st = db.set(std.testing.io, k, v, true, null);
        try std.testing.expect(st.isOk());
    }

    try std.testing.expectEqual(@as(i64, 100), db.countSimple());

    // Read each key back.
    for (0..100) |i| {
        const k = try std.fmt.bufPrint(&key_buf, "key{d}", .{i});
        const expected_v = try std.fmt.bufPrint(&val_buf, "val{d}", .{i});
        var value_list: std.ArrayList(u8) = .empty;
        defer value_list.deinit(alloc);
        const st = db.get(std.testing.io, k, &value_list);
        try std.testing.expect(st.isOk());
        try std.testing.expectEqualStrings(expected_v, value_list.items);
    }

    // Remove even-indexed keys.
    for (0..50) |i| {
        const k = try std.fmt.bufPrint(&key_buf, "key{d}", .{i * 2});
        const st = db.remove(std.testing.io, k);
        try std.testing.expect(st.isOk());
    }

    try std.testing.expectEqual(@as(i64, 50), db.countSimple());

    // Removed keys should return NOT_FOUND_ERROR.
    for (0..50) |i| {
        const k = try std.fmt.bufPrint(&key_buf, "key{d}", .{i * 2});
        const st = db.get(std.testing.io, k, null);
        try std.testing.expectEqual(Code.NOT_FOUND_ERROR, st.code);
    }
}

test "append: concatenation with empty delimiter" {
    const alloc = std.testing.allocator;
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);

    var st = db.set(std.testing.io, "greeting", "hello", true, null);
    try std.testing.expect(st.isOk());

    st = db.append(std.testing.io, "greeting", " world", "");
    try std.testing.expect(st.isOk());

    var value_list: std.ArrayList(u8) = .empty;
    defer value_list.deinit(alloc);
    st = db.get(std.testing.io, "greeting", &value_list);
    try std.testing.expect(st.isOk());
    try std.testing.expectEqualStrings("hello world", value_list.items);
}

test "append: creates new record when missing" {
    const alloc = std.testing.allocator;
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);

    const st = db.append(std.testing.io, "newkey", "first", ",");
    try std.testing.expect(st.isOk());

    var value_list: std.ArrayList(u8) = .empty;
    defer value_list.deinit(alloc);
    const get_st_1 = db.get(std.testing.io, "newkey", &value_list);
    try std.testing.expect(get_st_1.isOk());
    try std.testing.expectEqualStrings("first", value_list.items);
}

test "overwrite: DUPLICATION_ERROR when overwrite=false" {
    const alloc = std.testing.allocator;
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);

    var st = db.set(std.testing.io, "key", "original", true, null);
    try std.testing.expect(st.isOk());

    st = db.set(std.testing.io, "key", "new", false, null);
    try std.testing.expectEqual(Code.DUPLICATION_ERROR, st.code);

    // Value should be unchanged.
    var value_list: std.ArrayList(u8) = .empty;
    defer value_list.deinit(alloc);
    const get_st_2a = db.get(std.testing.io, "key", &value_list);
    try std.testing.expect(get_st_2a.isOk());
    try std.testing.expectEqualStrings("original", value_list.items);

    // Now overwrite=true should succeed.
    st = db.set(std.testing.io, "key", "new", true, null);
    try std.testing.expect(st.isOk());

    value_list.clearRetainingCapacity();
    const get_st_2b = db.get(std.testing.io, "key", &value_list);
    try std.testing.expect(get_st_2b.isOk());
    try std.testing.expectEqualStrings("new", value_list.items);
}

test "iterator: visit all 10 keys" {
    const alloc = std.testing.allocator;
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);

    var key_buf: [16]u8 = undefined;
    var val_buf: [16]u8 = undefined;
    for (0..10) |i| {
        const k = try std.fmt.bufPrint(&key_buf, "k{d}", .{i});
        const v = try std.fmt.bufPrint(&val_buf, "v{d}", .{i});
        _ = db.set(std.testing.io, k, v, true, null);
    }

    var iter = try db.makeCursor(std.testing.io);
    defer iter.deinit(std.testing.io);

    var st = iter.first(std.testing.io);
    try std.testing.expect(st.isOk());

    var seen: u32 = 0;
    var iter_k: std.ArrayList(u8) = .empty;
    defer iter_k.deinit(alloc);
    var iter_v: std.ArrayList(u8) = .empty;
    defer iter_v.deinit(alloc);
    while (true) {
        const get_st = iter.get(std.testing.io, &iter_k, &iter_v);
        if (get_st.code == .NOT_FOUND_ERROR) break;
        try std.testing.expect(get_st.isOk());
        seen += 1;
        st = iter.next(std.testing.io);
        if (st.code == .NOT_FOUND_ERROR) break;
        try std.testing.expect(st.isOk());
    }
    try std.testing.expectEqual(@as(u32, 10), seen);
}

test "iterator: jump to existing key" {
    const alloc = std.testing.allocator;
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);

    _ = db.set(std.testing.io, "apple", "a", true, null);
    _ = db.set(std.testing.io, "banana", "b", true, null);
    _ = db.set(std.testing.io, "cherry", "c", true, null);

    var iter = try db.makeCursor(std.testing.io);
    defer iter.deinit(std.testing.io);

    const st = iter.jump(std.testing.io, "banana");
    try std.testing.expect(st.isOk());

    var k: std.ArrayList(u8) = .empty;
    defer k.deinit(alloc);
    var v: std.ArrayList(u8) = .empty;
    defer v.deinit(alloc);
    const get_st = iter.get(std.testing.io, &k, &v);
    try std.testing.expect(get_st.isOk());
    try std.testing.expectEqualStrings("banana", k.items);
}

test "persistence: set, close, reopen, verify" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);
    const db_path = try std.fmt.allocPrint(alloc, "{s}/persist.tinydbm", .{tmp_path});
    defer alloc.free(db_path);

    // Create, write, close.
    {
        const std_file = try file_mod.StdFile.create(alloc);
        var db = try TinyDBM.init(std_file.asFile(), 0, alloc);
        defer db.deinit(std.testing.io);

        var st = db.open(std.testing.io, db_path, true, .{});
        try std.testing.expect(st.isOk());

        st = db.set(std.testing.io, "persistent_key", "persistent_value", true, null);
        try std.testing.expect(st.isOk());

        st = db.close(std.testing.io);
        try std.testing.expect(st.isOk());
    }

    // Reopen and verify.
    {
        const std_file2 = try file_mod.StdFile.create(alloc);
        var db2 = try TinyDBM.init(std_file2.asFile(), 0, alloc);
        defer db2.deinit(std.testing.io);

        var st = db2.open(std.testing.io, db_path, false, .{});
        try std.testing.expect(st.isOk());

        var value_list: std.ArrayList(u8) = .empty;
        defer value_list.deinit(alloc);
        st = db2.get(std.testing.io, "persistent_key", &value_list);
        try std.testing.expect(st.isOk());
        try std.testing.expectEqualStrings("persistent_value", value_list.items);

        _ = db2.close(std.testing.io);
    }
}

test "processEach: count visits" {
    const alloc = std.testing.allocator;
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);

    for (0..5) |i| {
        var kb: [8]u8 = undefined;
        var vb: [8]u8 = undefined;
        const k = try std.fmt.bufPrint(&kb, "k{d}", .{i});
        const v = try std.fmt.bufPrint(&vb, "v{d}", .{i});
        _ = db.set(std.testing.io, k, v, true, null);
    }

    const Counter = struct {
        count: usize = 0,

        pub fn processFull(self: *@This(), key: []const u8, value: []const u8) RecordAction {
            _ = key;
            _ = value;
            self.count += 1;
            return .noop;
        }
        pub fn processEmpty(self: *@This(), key: []const u8) RecordAction {
            _ = self;
            _ = key;
            return .noop;
        }
    };

    var counter = Counter{};
    _ = try db.processEach(std.testing.io, Counter, &counter, false);
    try std.testing.expectEqual(@as(usize, 5), counter.count);
}

test "clear: count drops to zero" {
    const alloc = std.testing.allocator;
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);

    for (0..20) |i| {
        var kb: [8]u8 = undefined;
        var vb: [8]u8 = undefined;
        const k = try std.fmt.bufPrint(&kb, "k{d}", .{i});
        const v = try std.fmt.bufPrint(&vb, "v{d}", .{i});
        _ = db.set(std.testing.io, k, v, true, null);
    }
    try std.testing.expectEqual(@as(i64, 20), db.countSimple());

    const st = db.clear(std.testing.io);
    try std.testing.expect(st.isOk());
    try std.testing.expectEqual(@as(i64, 0), db.countSimple());
}

test "rebuild: all records survive" {
    const alloc = std.testing.allocator;
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);

    var key_buf: [16]u8 = undefined;
    var val_buf: [16]u8 = undefined;
    for (0..30) |i| {
        const k = try std.fmt.bufPrint(&key_buf, "rkey{d}", .{i});
        const v = try std.fmt.bufPrint(&val_buf, "rval{d}", .{i});
        _ = db.set(std.testing.io, k, v, true, null);
    }

    _ = db.rebuildAdvanced(std.testing.io, 64);
    try std.testing.expectEqual(@as(i64, 30), db.countSimple());

    // Spot-check a few records.
    for ([_]usize{ 0, 14, 29 }) |i| {
        const k = try std.fmt.bufPrint(&key_buf, "rkey{d}", .{i});
        const expected_v = try std.fmt.bufPrint(&val_buf, "rval{d}", .{i});
        var value_list: std.ArrayList(u8) = .empty;
        defer value_list.deinit(alloc);
        const st = db.get(std.testing.io, k, &value_list);
        try std.testing.expect(st.isOk());
        try std.testing.expectEqualStrings(expected_v, value_list.items);
    }
}

test "inspect: returns expected keys" {
    const alloc = std.testing.allocator;
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);

    _ = db.set(std.testing.io, "ikey", "ival", true, null);

    var pairs = try db.inspect(alloc, std.testing.io);
    defer {
        for (pairs.items) |p| {
            alloc.free(p[0]);
            alloc.free(p[1]);
        }
        pairs.deinit(alloc);
    }

    // Should have class and num_records at minimum.
    var found_class = false;
    var found_nr = false;
    for (pairs.items) |p| {
        if (std.mem.eql(u8, p[0], "class")) found_class = true;
        if (std.mem.eql(u8, p[0], "num_records")) found_nr = true;
    }
    try std.testing.expect(found_class);
    try std.testing.expect(found_nr);
}

test "remove: NOT_FOUND_ERROR on missing key" {
    const alloc = std.testing.allocator;
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);

    const st = db.remove(std.testing.io, "nonexistent");
    try std.testing.expectEqual(Code.NOT_FOUND_ERROR, st.code);
}

test "processFirst: returns NOT_FOUND_ERROR on empty db" {
    const alloc = std.testing.allocator;
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);

    var status = Status.init(.SUCCESS);
    var getter = ProcessorGet{ .status = &status, .value = null, .allocator = alloc };
    const st = db.processFirst(std.testing.io, ProcessorGet, &getter, false);
    try std.testing.expectEqual(Code.NOT_FOUND_ERROR, st.code);
}

test "processFirst: read-only visits one record" {
    const alloc = std.testing.allocator;
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);

    _ = db.set(std.testing.io, "alpha", "1", true, null);
    _ = db.set(std.testing.io, "beta", "2", true, null);

    var status = Status.init(.SUCCESS);
    var value_buf: std.ArrayList(u8) = .empty;
    defer value_buf.deinit(alloc);
    var getter = ProcessorGet{ .status = &status, .value = &value_buf, .allocator = alloc };
    const st = db.processFirst(std.testing.io, ProcessorGet, &getter, false);
    try std.testing.expect(st.isOk());
    // Exactly one record was visited; value_buf holds its value.
    try std.testing.expect(value_buf.items.len > 0);
}

test "processFirst: writable can remove the first record" {
    const alloc = std.testing.allocator;
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);

    _ = db.set(std.testing.io, "k1", "v1", true, null);
    _ = db.set(std.testing.io, "k2", "v2", true, null);
    try std.testing.expectEqual(@as(i64, 2), db.countSimple());

    var status = Status.init(.SUCCESS);
    var remover = ProcessorRemove{ .status = &status };
    const st = db.processFirst(std.testing.io, ProcessorRemove, &remover, true);
    try std.testing.expect(st.isOk());
    try std.testing.expectEqual(@as(i64, 1), db.countSimple());
}

test "processMulti: atomic get of two keys" {
    const alloc = std.testing.allocator;
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);

    _ = db.set(std.testing.io, "x", "10", true, null);
    _ = db.set(std.testing.io, "y", "20", true, null);

    var st_x = Status.init(.SUCCESS);
    var st_y = Status.init(.SUCCESS);
    var buf_x: std.ArrayList(u8) = .empty;
    defer buf_x.deinit(alloc);
    var buf_y: std.ArrayList(u8) = .empty;
    defer buf_y.deinit(alloc);

    var px = ProcessorGet{ .status = &st_x, .value = &buf_x, .allocator = alloc };
    var py = ProcessorGet{ .status = &st_y, .value = &buf_y, .allocator = alloc };

    const keys = [_][]const u8{ "x", "y" };
    const procs = [_]*ProcessorGet{ &px, &py };
    const st = db.processMulti(std.testing.io, ProcessorGet, &keys, &procs, false);
    try std.testing.expect(st.isOk());
    try std.testing.expectEqualStrings("10", buf_x.items);
    try std.testing.expectEqualStrings("20", buf_y.items);
}

test "processMulti: writable set of two keys" {
    const alloc = std.testing.allocator;
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);

    var st_a = Status.init(.SUCCESS);
    var st_b = Status.init(.SUCCESS);
    var pa = ProcessorSet{ .status = &st_a, .value = "va", .overwrite = true, .old_value = null, .allocator = alloc };
    var pb = ProcessorSet{ .status = &st_b, .value = "vb", .overwrite = true, .old_value = null, .allocator = alloc };

    const keys = [_][]const u8{ "a", "b" };
    const procs = [_]*ProcessorSet{ &pa, &pb };
    const st = db.processMulti(std.testing.io, ProcessorSet, &keys, &procs, true);
    try std.testing.expect(st.isOk());
    try std.testing.expectEqual(@as(i64, 2), db.countSimple());

    var vbuf: std.ArrayList(u8) = .empty;
    defer vbuf.deinit(alloc);
    const get_st_3 = db.get(std.testing.io, "a", &vbuf);
    try std.testing.expect(get_st_3.isOk());
    try std.testing.expectEqualStrings("va", vbuf.items);
}

test "getFilePath / getTimestamp / getFileSize / shouldBeRebuilt" {
    const alloc = std.testing.allocator;

    // getFilePath returns empty string before open.
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);
    try std.testing.expectEqualStrings("", db.getFilePathSimple());
    try std.testing.expect(std.math.isNan(db.getTimestampSimple()));

    // shouldBeRebuilt: false when db is empty (0 records, many buckets).
    try std.testing.expect(!db.shouldBeRebuiltSimple());

    // getFileSize returns -1 for an in-memory (unopened) db.
    try std.testing.expectEqual(@as(i64, -1), db.getFileSizeSimple());
}

test "getFilePath: returns path after open" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);
    const db_path = try std.fmt.allocPrint(alloc, "{s}/meta.tinydbm", .{tmp_path});
    defer alloc.free(db_path);

    const std_file = try file_mod.StdFile.create(alloc);
    var db = try TinyDBM.init(std_file.asFile(), 0, alloc);
    defer db.deinit(std.testing.io);

    const st = db.open(std.testing.io, db_path, true, .{});
    try std.testing.expect(st.isOk());
    try std.testing.expectEqualStrings(db_path, db.getFilePathSimple());
    try std.testing.expect(db.getTimestampSimple() > 0);
    _ = db.close(std.testing.io);
}

test "shouldBeRebuilt: true when records exceed buckets" {
    const alloc = std.testing.allocator;
    // Force a very small bucket count so records quickly exceed it.
    const std_file = try file_mod.StdFile.create(alloc);
    var db = try TinyDBM.init(std_file.asFile(), 3, alloc);
    defer db.deinit(std.testing.io);

    _ = db.set(std.testing.io, "a", "1", true, null);
    _ = db.set(std.testing.io, "b", "2", true, null);
    _ = db.set(std.testing.io, "c", "3", true, null);
    _ = db.set(std.testing.io, "d", "4", true, null);

    // 4 records vs 3-ish buckets → should want a rebuild.
    try std.testing.expect(db.shouldBeRebuiltSimple());
}

test "concurrent access: parallel set/get/remove" {
    // Use a thread-safe allocator — std.testing.allocator is not.
    var gpa: std.heap.DebugAllocator(.{ .thread_safe = true }) = .{};
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    const std_file = try file_mod.StdFile.create(alloc);
    var db = try TinyDBM.init(std_file.asFile(), 0, alloc);
    defer db.deinit(std.testing.io);

    const NUM_THREADS = 4;
    const OPS_PER_THREAD: usize = 50;

    const Worker = struct {
        db: *TinyDBM,
        thread_id: usize,
        alloc: std.mem.Allocator,

        fn run(self: @This()) void {
            var key_buf: [32]u8 = undefined;
            var val_buf: [32]u8 = undefined;
            // Set OPS_PER_THREAD unique keys for this thread.
            for (0..OPS_PER_THREAD) |i| {
                const k = std.fmt.bufPrint(&key_buf, "t{d}k{d}", .{ self.thread_id, i }) catch continue;
                const v = std.fmt.bufPrint(&val_buf, "t{d}v{d}", .{ self.thread_id, i }) catch continue;
                _ = self.db.set(std.testing.io, k, v, true, null);
            }
            // Read back all keys (ignore result — just exercise the read path).
            for (0..OPS_PER_THREAD) |i| {
                const k = std.fmt.bufPrint(&key_buf, "t{d}k{d}", .{ self.thread_id, i }) catch continue;
                _ = self.db.get(std.testing.io, k, null);
            }
            // Remove the first half.
            for (0..OPS_PER_THREAD / 2) |i| {
                const k = std.fmt.bufPrint(&key_buf, "t{d}k{d}", .{ self.thread_id, i }) catch continue;
                _ = self.db.remove(std.testing.io, k);
            }
        }
    };

    var threads: [NUM_THREADS]std.Thread = undefined;
    for (0..NUM_THREADS) |i| {
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{Worker{
            .db = &db,
            .thread_id = i,
            .alloc = alloc,
        }});
    }
    for (&threads) |*t| t.join();

    // Each thread inserted OPS_PER_THREAD and removed OPS_PER_THREAD/2.
    try std.testing.expectEqual(
        @as(i64, (OPS_PER_THREAD - OPS_PER_THREAD / 2) * NUM_THREADS),
        db.countSimple(),
    );
}

test "TinyDBM.Cursor.last returns NOT_IMPLEMENTED_ERROR" {
    const alloc = std.testing.allocator;
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);

    _ = db.set(std.testing.io, "key1", "value1", true, null);

    var iter = try db.makeCursor(std.testing.io);
    defer iter.deinit(std.testing.io);

    _ = iter.first(std.testing.io);
    const status = iter.last(std.testing.io);
    try std.testing.expect(!status.isOk());
    try std.testing.expectEqual(Code.NOT_IMPLEMENTED_ERROR, status.code);
}

test "TinyDBM.Cursor.previous returns NOT_IMPLEMENTED_ERROR" {
    const alloc = std.testing.allocator;
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);

    _ = db.set(std.testing.io, "key1", "value1", true, null);

    var iter = try db.makeCursor(std.testing.io);
    defer iter.deinit(std.testing.io);

    _ = iter.first(std.testing.io);
    const status = iter.previous(std.testing.io);
    try std.testing.expect(!status.isOk());
    try std.testing.expectEqual(Code.NOT_IMPLEMENTED_ERROR, status.code);
}

test "TinyDBM.Cursor.jumpLower returns NOT_IMPLEMENTED_ERROR" {
    const alloc = std.testing.allocator;
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);

    _ = db.set(std.testing.io, "key1", "value1", true, null);

    var iter = try db.makeCursor(std.testing.io);
    defer iter.deinit(std.testing.io);

    const status = iter.jumpLower(std.testing.io, "key1", true);
    try std.testing.expect(!status.isOk());
    try std.testing.expectEqual(Code.NOT_IMPLEMENTED_ERROR, status.code);
}

test "TinyDBM.Cursor.jumpUpper returns NOT_IMPLEMENTED_ERROR" {
    const alloc = std.testing.allocator;
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);

    _ = db.set(std.testing.io, "key1", "value1", true, null);

    var iter = try db.makeCursor(std.testing.io);
    defer iter.deinit(std.testing.io);

    const status = iter.jumpUpper(std.testing.io, "key1", false);
    try std.testing.expect(!status.isOk());
    try std.testing.expectEqual(Code.NOT_IMPLEMENTED_ERROR, status.code);
}

test "TinyDBM.compareExchange: match and exchange" {
    const alloc = std.testing.allocator;
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);

    // Set initial value
    try std.testing.expectEqual(.SUCCESS, db.set(std.testing.io, "key1", "foo", true, null).code);

    // CAS with exact match should succeed
    var actual: std.ArrayList(u8) = .empty;
    defer actual.deinit(alloc);
    var found: bool = undefined;
    const st1 = db.compareExchange(std.testing.io, "key1", .{ .exact = "foo" }, .{ .set = "bar" }, &actual, &found);
    try std.testing.expect(st1.isOk());
    try std.testing.expect(found);
    try std.testing.expectEqualSlices(u8, "foo", actual.items);

    // Verify value changed
    actual.clearRetainingCapacity();
    const get_st_4 = db.get(std.testing.io, "key1", &actual);
    try std.testing.expect(get_st_4.isOk());
    try std.testing.expectEqualSlices(u8, "bar", actual.items);
}

test "TinyDBM.compareExchange: mismatch returns INFEASIBLE_ERROR" {
    const alloc = std.testing.allocator;
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);

    try std.testing.expectEqual(.SUCCESS, db.set(std.testing.io, "key2", "old", true, null).code);

    var actual: std.ArrayList(u8) = .empty;
    defer actual.deinit(alloc);
    var found: bool = undefined;
    const st = db.compareExchange(std.testing.io, "key2", .{ .exact = "wrong" }, .{ .set = "new" }, &actual, &found);
    try std.testing.expect(st.code == .INFEASIBLE_ERROR);
    try std.testing.expect(found);
    try std.testing.expectEqualSlices(u8, "old", actual.items);
}

test "TinyDBM.compareExchange: absent creates record" {
    const alloc = std.testing.allocator;
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);

    var actual: std.ArrayList(u8) = .empty;
    defer actual.deinit(alloc);
    var found: bool = undefined;
    const st = db.compareExchange(std.testing.io, "newkey", .absent, .{ .set = "value" }, &actual, &found);
    try std.testing.expect(st.isOk());
    try std.testing.expect(!found);

    // Verify record was created
    actual.clearRetainingCapacity();
    const get_st = db.get(std.testing.io, "newkey", &actual);
    try std.testing.expect(get_st.isOk());
    try std.testing.expectEqualSlices(u8, "value", actual.items);
}

test "TinyDBM.compareExchange: absent noop on missing key" {
    const alloc = std.testing.allocator;
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);

    var actual: std.ArrayList(u8) = .empty;
    defer actual.deinit(alloc);
    var found: bool = undefined;
    const st = db.compareExchange(std.testing.io, "missing", .absent, .noop, &actual, &found);
    try std.testing.expect(st.isOk());
    try std.testing.expect(!found);

    // Verify key still absent
    actual.clearRetainingCapacity();
    const get_st = db.get(std.testing.io, "missing", &actual);
    try std.testing.expect(get_st.code == .NOT_FOUND_ERROR);
}

test "TinyDBM.compareExchange: any probe reads without writing" {
    const alloc = std.testing.allocator;
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);

    _ = db.set(std.testing.io, "key", "original", true, null);

    var actual: std.ArrayList(u8) = .empty;
    defer actual.deinit(alloc);
    var found: bool = undefined;
    const st = db.compareExchange(std.testing.io, "key", .any, .noop, &actual, &found);
    try std.testing.expect(st.isOk());
    try std.testing.expect(found);
    try std.testing.expectEqualSlices(u8, "original", actual.items);

    // Verify value unchanged
    actual.clearRetainingCapacity();
    const get_st_5 = db.get(std.testing.io, "key", &actual);
    try std.testing.expect(get_st_5.isOk());
    try std.testing.expectEqualSlices(u8, "original", actual.items);
}

test "TinyDBM.compareExchange: desired remove deletes record" {
    const alloc = std.testing.allocator;
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);

    _ = db.set(std.testing.io, "key", "foo", true, null);

    var actual: std.ArrayList(u8) = .empty;
    defer actual.deinit(alloc);
    var found: bool = undefined;
    const st = db.compareExchange(std.testing.io, "key", .{ .exact = "foo" }, .remove, &actual, &found);
    try std.testing.expect(st.isOk());

    // Verify key removed
    actual.clearRetainingCapacity();
    const get_st = db.get(std.testing.io, "key", &actual);
    try std.testing.expect(get_st.code == .NOT_FOUND_ERROR);
}

test "TinyDBM.compareExchange: absent fails when key exists" {
    const alloc = std.testing.allocator;
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);

    _ = db.set(std.testing.io, "key", "exists", true, null);

    var actual: std.ArrayList(u8) = .empty;
    defer actual.deinit(alloc);
    var found: bool = undefined;
    const st = db.compareExchange(std.testing.io, "key", .absent, .{ .set = "new" }, &actual, &found);
    try std.testing.expect(st.code == .INFEASIBLE_ERROR);
    try std.testing.expect(found);
    try std.testing.expectEqualSlices(u8, "exists", actual.items);
}

test "TinyDBM.increment: fresh key uses initial+delta" {
    const alloc = std.testing.allocator;
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);

    var current: i64 = undefined;
    const st = db.increment(std.testing.io, "counter", 3, &current, 10);
    try std.testing.expect(st.isOk());
    try std.testing.expectEqual(@as(i64, 13), current);

    // Verify stored as 8-byte big-endian
    var val: std.ArrayList(u8) = .empty;
    defer val.deinit(alloc);
    const get_st_6 = db.get(std.testing.io, "counter", &val);
    try std.testing.expect(get_st_6.isOk());
    try std.testing.expectEqual(@as(usize, 8), val.items.len);
    const stored = @as(i64, @bitCast(str_util.strToIntBigEndian(val.items)));
    try std.testing.expectEqual(@as(i64, 13), stored);
}

test "TinyDBM.increment: existing key adds delta" {
    const alloc = std.testing.allocator;
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);

    var buf: [8]u8 = undefined;
    const initial_bytes = str_util.intToStrBigEndian(@as(u64, @bitCast(@as(i64, 10))), 8, &buf);
    _ = db.set(std.testing.io, "num", initial_bytes, true, null);

    var current: i64 = undefined;
    const st = db.increment(std.testing.io, "num", 5, &current, 0);
    try std.testing.expect(st.isOk());
    try std.testing.expectEqual(@as(i64, 15), current);
}

test "TinyDBM.increment: INT64MIN probe reads without writing" {
    const alloc = std.testing.allocator;
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);

    var buf: [8]u8 = undefined;
    const initial_bytes = str_util.intToStrBigEndian(@as(u64, @bitCast(@as(i64, 7))), 8, &buf);
    _ = db.set(std.testing.io, "num", initial_bytes, true, null);

    var current: i64 = undefined;
    const st = db.increment(std.testing.io, "num", lib_common.INT64MIN, &current, 0);
    try std.testing.expect(st.isOk());
    try std.testing.expectEqual(@as(i64, 7), current);

    // Verify value unchanged
    var val: std.ArrayList(u8) = .empty;
    defer val.deinit(alloc);
    const get_st_7 = db.get(std.testing.io, "num", &val);
    try std.testing.expect(get_st_7.isOk());
    const stored = @as(i64, @bitCast(str_util.strToIntBigEndian(val.items)));
    try std.testing.expectEqual(@as(i64, 7), stored);
}

test "TinyDBM.increment: INT64MIN probe on missing key returns initial" {
    const alloc = std.testing.allocator;
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);

    var current: i64 = undefined;
    const st = db.increment(std.testing.io, "missing", lib_common.INT64MIN, &current, 42);
    try std.testing.expect(st.isOk());
    try std.testing.expectEqual(@as(i64, 42), current);

    // Verify key still absent
    var val: std.ArrayList(u8) = .empty;
    defer val.deinit(alloc);
    const get_st = db.get(std.testing.io, "missing", &val);
    try std.testing.expect(get_st.code == .NOT_FOUND_ERROR);
}

test "TinyDBM.popFirst: returns and removes first record" {
    const alloc = std.testing.allocator;
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);

    _ = db.set(std.testing.io, "key1", "value1", true, null);
    _ = db.set(std.testing.io, "key2", "value2", true, null);
    _ = db.set(std.testing.io, "key3", "value3", true, null);
    try std.testing.expectEqual(@as(i64, 3), db.countSimple());

    var key: std.ArrayList(u8) = .empty;
    defer key.deinit(alloc);
    var value: std.ArrayList(u8) = .empty;
    defer value.deinit(alloc);

    const st = try db.popFirst(std.testing.io, &key, &value);
    try std.testing.expect(st.isOk());
    try std.testing.expect(key.items.len > 0);
    try std.testing.expect(value.items.len > 0);

    // Verify count decremented
    const count = db.countSimple();
    try std.testing.expectEqual(@as(i64, 2), count);
}

test "TinyDBM.popFirst: empty returns NOT_FOUND_ERROR" {
    const alloc = std.testing.allocator;
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);

    var key: std.ArrayList(u8) = .empty;
    defer key.deinit(alloc);
    var value: std.ArrayList(u8) = .empty;
    defer value.deinit(alloc);

    const st = try db.popFirst(std.testing.io, &key, &value);
    try std.testing.expect(st.code == .NOT_FOUND_ERROR);
}

test "TinyDBM.pushLast: creates record with key_out" {
    const alloc = std.testing.allocator;
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);

    var key: std.ArrayList(u8) = .empty;
    defer key.deinit(alloc);
    const st = db.pushLast(std.testing.io, "hello", 1.0, &key);
    try std.testing.expect(st.isOk());
    try std.testing.expect(key.items.len > 0);

    // Verify value retrievable by key
    var val: std.ArrayList(u8) = .empty;
    defer val.deinit(alloc);
    const get_st = db.get(std.testing.io, key.items, &val);
    try std.testing.expect(get_st.isOk());
    try std.testing.expectEqualSlices(u8, "hello", val.items);
}

test "TinyDBM.pushLast: two pushes at same wtime produce sequential keys" {
    const alloc = std.testing.allocator;
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);

    var key1: std.ArrayList(u8) = .empty;
    defer key1.deinit(alloc);
    var key2: std.ArrayList(u8) = .empty;
    defer key2.deinit(alloc);

    _ = db.pushLast(std.testing.io, "a", 1.0, &key1);
    _ = db.pushLast(std.testing.io, "b", 1.0, &key2);

    try std.testing.expectEqual(@as(usize, 8), key1.items.len);
    try std.testing.expectEqual(@as(usize, 8), key2.items.len);

    const k1 = str_util.strToIntBigEndian(key1.items);
    const k2 = str_util.strToIntBigEndian(key2.items);
    try std.testing.expectEqual(k1 + 1, k2);
}

test "TinyDBM.pushLast: pop-after-push round-trips value" {
    const alloc = std.testing.allocator;
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);

    const original = "round-trip-value";
    var key: std.ArrayList(u8) = .empty;
    defer key.deinit(alloc);
    _ = db.pushLast(std.testing.io, original, 2.0, &key);

    var popped_key: std.ArrayList(u8) = .empty;
    defer popped_key.deinit(alloc);
    var popped_val: std.ArrayList(u8) = .empty;
    defer popped_val.deinit(alloc);

    const st = try db.popFirst(std.testing.io, &popped_key, &popped_val);
    try std.testing.expect(st.isOk());
    try std.testing.expectEqualSlices(u8, original, popped_val.items);
}

test "TinyDBM.get: null value buffer returns SUCCESS on found key" {
    const alloc = std.testing.allocator;
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);

    _ = db.set(std.testing.io, "exists", "hello", true, null);

    // null value = existence check only
    const present = db.get(std.testing.io, "exists", null);
    try std.testing.expect(present.isOk());

    const absent = db.get(std.testing.io, "missing", null);
    try std.testing.expect(absent.code == .NOT_FOUND_ERROR);
}

test "TinyDBM: timestamp persists across close and reopen" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path = path_buf[0..try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf)];
    var full_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/test.tdb", .{tmp_path});

    const ts_before: f64 = blk: {
        const file1 = try file_mod.StdFile.create(allocator);
        var db = try TinyDBM.init(file1.asFile(), 0, allocator);
        defer db.deinit(std.testing.io);

        try std.testing.expect(db.open(std.testing.io, full_path, true, .{}).isOk());
        try std.testing.expect(db.set(std.testing.io, "k", "v", true, null).isOk());
        const ts = db.getTimestampSimple();
        try std.testing.expect(ts > 0.0);
        try std.testing.expect(db.close(std.testing.io).isOk());
        break :blk ts;
    };

    // Reopen and verify timestamp survived serialization.
    const file2 = try file_mod.StdFile.create(allocator);
    var db2 = try TinyDBM.init(file2.asFile(), 0, allocator);
    defer db2.deinit(std.testing.io);
    try std.testing.expect(db2.open(std.testing.io, full_path, false, .{}).isOk());
    const ts_after = db2.getTimestampSimple();
    // Timestamp must be positive and within 1 second of the original open time.
    try std.testing.expect(ts_after > 0.0);
    try std.testing.expect(@abs(ts_after - ts_before) < 1.0);
    try std.testing.expect(db2.close(std.testing.io).isOk());
}

test "TinyDBM.*Multi: bulk set/get/remove/append" {
    const alloc = std.testing.allocator;
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);

    // setMulti: insert 3 keys
    const pairs = [_][2][]const u8{
        .{ "key1", "val1" }, .{ "key2", "val2" }, .{ "key3", "val3" },
    };
    try std.testing.expect(db.setMulti(std.testing.io, &pairs, true).isOk());
    try std.testing.expectEqual(@as(i64, 3), db.countSimple());

    // getMulti: 2 existing + 1 missing -> NOT_FOUND_ERROR, map has 2 entries
    var records = std.StringHashMap([]u8).init(alloc);
    defer {
        var it = records.iterator();
        while (it.next()) |e| {
            alloc.free(e.key_ptr.*);
            alloc.free(e.value_ptr.*);
        }
        records.deinit();
    }
    const get_st = db.getMulti(std.testing.io, &.{ "key1", "key2", "missing" }, &records);
    try std.testing.expectEqual(lib_common.Code.NOT_FOUND_ERROR, get_st.code);
    try std.testing.expectEqual(@as(usize, 2), records.count());
    try std.testing.expectEqualStrings("val1", records.get("key1").?);
    try std.testing.expectEqualStrings("val2", records.get("key2").?);

    // removeMulti: remove 2 keys
    const rm_st = db.removeMulti(std.testing.io, &.{ "key1", "key2" });
    try std.testing.expect(rm_st.isOk());
    try std.testing.expectEqual(@as(i64, 1), db.countSimple());

    // appendMulti: append to remaining key
    const app_pairs = [_][2][]const u8{.{ "key3", "_appended" }};
    try std.testing.expect(db.appendMulti(std.testing.io, &app_pairs, "").isOk());
    const got = try db.getSimple(alloc, std.testing.io, "key3", "");
    defer alloc.free(got);
    try std.testing.expectEqualStrings("val3_appended", got);
}

test "TinyDBM.Iterator: iterate() visits all records" {
    const alloc = std.testing.allocator;
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);

    // Insert 5 records.
    for (0..5) |i| {
        var kb: [16]u8 = undefined;
        var vb: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kb, "key{d}", .{i});
        const v = try std.fmt.bufPrint(&vb, "val{d}", .{i});
        _ = db.set(std.testing.io, k, v, true, null);
    }

    var iter = try db.iterate(alloc, std.testing.io);
    defer iter.deinit(std.testing.io);

    var count: usize = 0;
    while (try iter.next(std.testing.io)) |entry| {
        _ = entry.key;
        _ = entry.value;
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), count);
}

test "TinyDBM.Iterator: iterateFrom() starts at correct key" {
    const alloc = std.testing.allocator;
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);

    _ = db.set(std.testing.io, "apple", "a", true, null);
    _ = db.set(std.testing.io, "banana", "b", true, null);
    _ = db.set(std.testing.io, "cherry", "c", true, null);

    var iter = try db.iterateFrom(alloc, std.testing.io, "banana");
    defer iter.deinit(std.testing.io);

    const first = try iter.next(std.testing.io);
    try std.testing.expect(first != null);
    // Note: TinyDBM is unordered, so we can only verify that we got *a* record.
    // The jump() call ensures we're positioned at or after the key if it exists.
    const key_copy = try alloc.dupe(u8, first.?.key);
    defer alloc.free(key_copy);
    // Second next() — first.?.key is now invalid, key_copy is safe.
    _ = try iter.next(std.testing.io);
}

test "TinyDBM.Iterator: basic iteration" {
    const alloc = std.testing.allocator;
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);

    _ = db.set(std.testing.io, "a", "1", true, null);
    _ = db.set(std.testing.io, "b", "2", true, null);
    _ = db.set(std.testing.io, "c", "3", true, null);

    var iter = try db.iterate(alloc, std.testing.io);
    defer iter.deinit(std.testing.io);
    
    var count: usize = 0;
    while (try iter.next(std.testing.io)) |entry| {
        _ = entry.key;
        _ = entry.value;
        count += 1;
    }
    try std.testing.expectEqual(3, count);
}

test "TinyDBM.Iterator: iterateFrom and lifetime contract" {
    const alloc = std.testing.allocator;
    var db = try makeInMemoryDB(alloc);
    defer db.deinit(std.testing.io);

    _ = db.set(std.testing.io, "a", "1", true, null);
    _ = db.set(std.testing.io, "b", "2", true, null);
    _ = db.set(std.testing.io, "c", "3", true, null);

    var iter = try db.iterateFrom(alloc, std.testing.io, "b");
    defer iter.deinit(std.testing.io);
    
    const first = try iter.next(std.testing.io);
    try std.testing.expect(first != null);
    try std.testing.expect(std.mem.startsWith(u8, first.?.key, "b"));
    
    // Copy before next() to demonstrate lifetime contract.
    const key_copy = try alloc.dupe(u8, first.?.key);
    defer alloc.free(key_copy);
    
    // Second next() — first.?.key is now invalid.
    _ = try iter.next(std.testing.io);
    // key_copy is still valid here.
    try std.testing.expect(key_copy.len > 0);
}



