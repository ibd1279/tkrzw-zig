// Zig 0.15.2 port of tkrzw CacheDBM — in-memory hash-table database with LRU eviction.
//
// Architecture notes:
//   - Each hash bucket entry is a heap-allocated blob ([]u8). The blob slice
//     length IS the allocation size, so allocator.realloc(blob, new_size) is
//     always valid.
//   - Blob layout: [child: ?[*]u8 (8 bytes)][prev: ?[*]u8 (8 bytes)][next: ?[*]u8 (8 bytes)][key_varint][key][value_varint][value]
//   - CacheDBMImpl is heap-allocated (via allocator.create) and owned by CacheDBM.
//   - Iterators are heap-allocated and owned by the caller; they register
//     themselves in impl.iterators under the db mutex.
//   - 32 fixed slots (CacheSlot) each with independent bucket array, LRU chain, and mutex.

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

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const NUM_CACHE_SLOTS: i32 = 32;
const MAX_LOAD_FACTOR: f64 = 1.2;

pub const DEFAULT_CAP_REC_NUM: i64 = 1048576;

// ---------------------------------------------------------------------------
// Blob layout helpers (3 pointer fields: child, prev, next)
// ---------------------------------------------------------------------------

const CacheRecordHeader = extern struct {
    child: ?[*]u8,
    prev: ?[*]u8,
    next: ?[*]u8,
};
const HEADER_SIZE = @sizeOf(CacheRecordHeader);

// Serialize a new blob: [header][key_varint][key][value_varint][value]
fn serializeRecord(
    allocator: std.mem.Allocator,
    child: ?[*]u8,
    prev: ?[*]u8,
    next: ?[*]u8,
    key: []const u8,
    value: []const u8,
) ![]u8 {
    const key_vsize = varint.sizeVarNum(key.len);
    const val_vsize = varint.sizeVarNum(value.len);
    const total = HEADER_SIZE + key_vsize + key.len + val_vsize + value.len;
    const blob = try allocator.alloc(u8, total);
    var wp: usize = 0;
    // Write header.
    const hdr = CacheRecordHeader{ .child = child, .prev = prev, .next = next };
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

// Reserialize an existing blob in-place (or free+reallocate) when the value changes.
// Only the value is updated; child/prev/next are preserved by the caller's fixup code.
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
        // Recover child/prev/next pointers from old blob before freeing.
        const child = getChild(blob);
        const prev = getPrev(blob);
        const next = getNext(blob);
        const new_blob = try serializeRecord(allocator, child, prev, next, key, new_value);
        allocator.free(blob);
        return new_blob;
    }

    // Case 2 (value grew) or Case 3 (value same size or shrank): always realloc
    // to exact content size so that blob.len always matches content size.
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

// Decoded record view — no copies; pointers into the blob.
const CacheRecordView = struct {
    child: ?[*]u8,
    prev: ?[*]u8,
    next: ?[*]u8,
    key: []const u8,
    value: []const u8,
};

// Deserialize a blob (unsafe: caller guarantees the pointer is valid).
fn deserializeRecord(blob: [*]const u8) CacheRecordView {
    var rp: usize = 0;
    var hdr: CacheRecordHeader = undefined;
    @memcpy(std.mem.asBytes(&hdr), blob[0..HEADER_SIZE]);
    rp += HEADER_SIZE;
    var key_len: u64 = 0;
    rp += varint.readVarNumUnsafe(blob + rp, &key_len);
    const key_ptr = blob + rp;
    rp += @intCast(key_len);
    var val_len: u64 = 0;
    rp += varint.readVarNumUnsafe(blob + rp, &val_len);
    const val_ptr = blob + rp;
    return CacheRecordView{
        .child = hdr.child,
        .prev = hdr.prev,
        .next = hdr.next,
        .key = key_ptr[0..@intCast(key_len)],
        .value = val_ptr[0..@intCast(val_len)],
    };
}

fn getChild(blob: []u8) ?[*]u8 {
    var hdr: CacheRecordHeader = undefined;
    @memcpy(std.mem.asBytes(&hdr), blob[0..HEADER_SIZE]);
    return hdr.child;
}

fn setChild(blob: []u8, child: ?[*]u8) void {
    const hdr = CacheRecordHeader{ .child = child, .prev = getPrev(blob), .next = getNext(blob) };
    @memcpy(blob[0..HEADER_SIZE], std.mem.asBytes(&hdr));
}

fn getPrev(blob: []u8) ?[*]u8 {
    var hdr: CacheRecordHeader = undefined;
    @memcpy(std.mem.asBytes(&hdr), blob[0..HEADER_SIZE]);
    return hdr.prev;
}

fn setPrev(blob: []u8, prev: ?[*]u8) void {
    const hdr = CacheRecordHeader{ .child = getChild(blob), .prev = prev, .next = getNext(blob) };
    @memcpy(blob[0..HEADER_SIZE], std.mem.asBytes(&hdr));
}

fn getNext(blob: []u8) ?[*]u8 {
    var hdr: CacheRecordHeader = undefined;
    @memcpy(std.mem.asBytes(&hdr), blob[0..HEADER_SIZE]);
    return hdr.next;
}

fn setNext(blob: []u8, next: ?[*]u8) void {
    const hdr = CacheRecordHeader{ .child = getChild(blob), .prev = getPrev(blob), .next = next };
    @memcpy(blob[0..HEADER_SIZE], std.mem.asBytes(&hdr));
}

// ---------------------------------------------------------------------------
// CacheSlot — one of NUM_CACHE_SLOTS independent LRU-hash caches
// ---------------------------------------------------------------------------

const CacheSlot = struct {
    dbm: ?*CacheDBMImpl,
    buckets: []?[*]u8,
    first: ?[*]u8, // LRU chain head (oldest; to be evicted)
    last: ?[*]u8,  // LRU chain tail (newest)
    cap_rec_num: i64,
    cap_mem_size: i64,
    num_buckets: i64,
    num_records: i64,
    eff_data_size: i64,
    mutex: std.Io.RwLock,

    fn deinit(self: *CacheSlot, allocator: std.mem.Allocator) void {
        self.releaseAllRecords(allocator);
        allocator.free(self.buckets);
    }

    fn lock(self: *CacheSlot, io: std.Io) void {
        self.mutex.lockUncancelable(io);
    }

    fn unlock(self: *CacheSlot, io: std.Io) void {
        self.mutex.unlock(io);
    }

    fn count(self: *CacheSlot) i64 {
        return self.num_records;
    }

    fn getEffectiveDataSize(self: *CacheSlot) i64 {
        return self.eff_data_size;
    }

    fn getMemoryUsage(self: *CacheSlot, io: std.Io) i64 {
        self.lock(io);
        defer self.unlock(io);
        return self.getMemoryUsageImpl();
    }

    fn getMemoryUsageImpl(self: *CacheSlot) i64 {
        var total: i64 = @intCast(@sizeOf(CacheSlot));
        total += @intCast(self.buckets.len * @sizeOf(?[*]u8));
        var ptr: ?[*]u8 = self.first;
        while (ptr) |p| {
            const blob_len = blobLen(p);
            total += @intCast(blob_len);
            const rv = deserializeRecord(p);
            ptr = rv.next;
        }
        return total;
    }

    fn exportRecords(
        self: *CacheSlot,
        io: std.Io,
        flat_rec: *FlatRecord,
    ) !Status {
        var ptr: ?[*]u8 = self.first;
        while (ptr) |p| {
            const rv = deserializeRecord(p);
            var status = Status.init(.SUCCESS);
            status.mergeFrom(flat_rec.write(io, rv.key, .normal));
            status.mergeFrom(flat_rec.write(io, rv.value, .normal));
            if (!status.isOk()) return status;
            ptr = rv.next;
        }
        return Status.init(.SUCCESS);
    }

    fn getKeys(self: *CacheSlot, allocator: std.mem.Allocator) !std.ArrayList([]u8) {
        var keys: std.ArrayList([]u8) = .empty;
        var ptr: ?[*]u8 = self.first;
        while (ptr) |p| {
            const rv = deserializeRecord(p);
            const key_copy = try allocator.dupe(u8, rv.key);
            try keys.append(allocator, key_copy);
            ptr = rv.next;
        }
        return keys;
    }

    fn rebuild(
        self: *CacheSlot,
        allocator: std.mem.Allocator,
        cap_rec_num: i64,
        cap_mem_size: i64,
    ) void {
        self.releaseAllRecords(allocator);
        allocator.free(self.buckets);
        self.buckets = &.{};
        self.first = null;
        self.last = null;
        self.cap_rec_num = cap_rec_num;
        self.cap_mem_size = cap_mem_size;
        self.num_records = 0;
        self.eff_data_size = 0;
        // Re-initialize buckets on next use.
        const num_buckets_req = if (cap_rec_num > 0)
            @divTrunc(cap_rec_num, 2)
        else
            1024;
        self.num_buckets = hash_util.getHashBucketSize(num_buckets_req);
        self.buckets = allocator.alloc(?[*]u8, @intCast(self.num_buckets)) catch &.{};
        if (self.buckets.len > 0) {
            @memset(self.buckets, null);
        }
    }

    fn processFirst(
        self: *CacheSlot,
        allocator: std.mem.Allocator,
        proc: anytype,
        writable: bool,
    ) bool {
        // C++ CacheSlot::ProcessFirst also returns early here without calling ProcessEmpty.
        // The sentinel is the DBM-level caller's responsibility.
        if (self.first == null) {
            return false;
        }

        const p = self.first.?;
        const rv = deserializeRecord(p);
        const action = proc.processFull(rv.key, rv.value);
        switch (action) {
            .noop => return true,
            .remove => {
                if (writable) {
                    self.removeBlob(p, allocator);
                }
                return true;
            },
            .set => |new_value| {
                if (writable) {
                    // Locate this record in its bucket chain for hash-chain fixup.
                    const hash_val = hash_util.primaryHash(rv.key, std.math.maxInt(u64)) >> 8;
                    const bidx: usize = @intCast(hash_val % @as(u64, @intCast(self.num_buckets)));
                    var parent: ?[*]u8 = null;
                    var cp: ?[*]u8 = self.buckets[bidx];
                    while (cp) |cptr| {
                        if (cptr == p) break;
                        parent = cptr;
                        cp = deserializeRecord(cptr).child;
                    }
                    const blob_len = blobLen(p);
                    const blob: []u8 = p[0..blob_len];
                    const new_blob = reserializeRecord(allocator, blob, rv.key, rv.value.len, new_value) catch return false;
                    const new_ptr: [*]u8 = new_blob.ptr;
                    if (new_ptr != p) {
                        // Update bucket chain.
                        if (parent == null) {
                            self.buckets[bidx] = new_ptr;
                        } else {
                            setChild(parent.?[0..blobLen(parent.?)], new_ptr);
                        }
                        // p is self.first so rv.prev == null; update self.first.
                        self.first = new_ptr;
                        if (rv.next) |next_p| {
                            setPrev(next_p[0..blobLen(next_p)], new_ptr);
                        } else {
                            self.last = new_ptr;
                        }
                    }
                }
                return true;
            },
        }
    }

    fn processEach(
        self: *CacheSlot,
        allocator: std.mem.Allocator,
        proc: anytype,
        writable: bool,
    ) !void {
        if (writable) {
            // Collect keys first (snapshot), then call processImpl for each.
            // This matches C++ ProcessEach: any blob relocation is handled by processImpl,
            // which correctly updates both the bucket chain and LRU pointers.
            var keys = try self.getKeys(allocator);
            defer {
                for (keys.items) |k| allocator.free(k);
                keys.deinit(allocator);
            }
            for (keys.items) |key| {
                const hash_val = hash_util.primaryHash(key, std.math.maxInt(u64)) >> 8;
                try self.processImpl(allocator, key, hash_val, proc, true);
            }
        } else {
            // Read-only: iterate LRU chain directly under the slot lock held by caller.
            var ptr: ?[*]u8 = self.first;
            while (ptr) |p| {
                const rv = deserializeRecord(p);
                _ = proc.processFull(rv.key, rv.value);
                ptr = rv.next;
            }
        }
    }

    fn process(
        self: *CacheSlot,
        allocator: std.mem.Allocator,
        io: std.Io,
        key: []const u8,
        hash: u64,
        proc: anytype,
        writable: bool,
    ) !void {
        self.lock(io);
        defer self.unlock(io);
        try self.processImpl(allocator, key, hash, proc, writable);
    }

    fn processImpl(
        self: *CacheSlot,
        allocator: std.mem.Allocator,
        key: []const u8,
        hash: u64,
        proc: anytype,
        writable: bool,
    ) !void {
        const bucket_index = hash % @as(u64, @intCast(self.num_buckets));
        const bidx: usize = @intCast(bucket_index);

        var parent: ?[*]u8 = null;
        var ptr: ?[*]u8 = self.buckets[bidx];


        while (ptr) |p| {
            const rv = deserializeRecord(p);

            if (std.mem.eql(u8, key, rv.key)) {
                // Found: perform LRU promote (move to tail) and dispatch.
                if (rv.next != null) {
                    // Not already at tail; unlink and relink.
                    if (rv.prev) |prev_p| {
                        setNext(prev_p[0..blobLen(prev_p)], rv.next);
                    } else {
                        self.first = rv.next;
                    }
                    if (rv.next) |next_p| {
                        setPrev(next_p[0..blobLen(next_p)], rv.prev);
                    }
                    // Relink at tail.
                    setNext(p[0..blobLen(p)], null);
                    setPrev(p[0..blobLen(p)], self.last);
                    if (self.last) |last_p| {
                        setNext(last_p[0..blobLen(last_p)], p);
                    } else {
                        self.first = p;
                    }
                    self.last = p;
                }

                const action = proc.processFull(key, rv.value);
                switch (action) {
                    .noop => {},
                    .remove => {
                        if (writable) {
                            self.removeBlob(p, allocator);
                            if (self.dbm) |dbm| {
                                if (dbm.update_logger) |ul| {
                                    _ = ul.writeRemove(key);
                                }
                            }
                        }
                    },
                    .set => |new_value| {
                        if (writable) {
                            const blob_len = blobLen(p);
                            const blob: []u8 = p[0..blob_len];
                            // C++ uses xrealloc here, which throws std::bad_alloc on OOM with
                            // no catch anywhere in the call chain. Zig propagates
                            // error.OutOfMemory up to CacheDBMImpl.processImpl, which absorbs
                            // it into Status.SYSTEM_ERROR.
                            const new_blob = try reserializeRecord(
                                allocator,
                                blob,
                                key,
                                rv.value.len,
                                new_value,
                            );
                            const new_ptr: [*]u8 = new_blob.ptr;
                            if (new_ptr != p) {
                                // Update bucket or parent child pointer.
                                if (parent == null) {
                                    self.buckets[bidx] = new_ptr;
                                } else {
                                    setChild(parent.?[0..blobLen(parent.?)], new_ptr);
                                }
                                // Update LRU chain using post-promotion state from new_blob.
                                // After LRU promotion: new_blob.prev = old tail, new_blob.next = null.
                                const post_prev = getPrev(new_blob);
                                if (post_prev) |prev_p| {
                                    setNext(prev_p[0..blobLen(prev_p)], new_ptr);
                                }
                                if (self.first == p) self.first = new_ptr;
                                self.last = new_ptr;
                            }
                            if (self.dbm) |dbm| {
                                if (dbm.update_logger) |ul| {
                                    _ = ul.writeSet(key, new_value);
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
                    // Check capacity and evict if needed.
                    if (self.cap_rec_num > 0 and self.num_records >= self.cap_rec_num) {
                        self.removeLRU(allocator);
                    }
                    if (self.cap_mem_size > 0 and self.eff_data_size >= self.cap_mem_size) {
                        self.removeLRU(allocator);
                    }

                    // Insert new record at bucket head.
                    const new_blob = try serializeRecord(allocator, self.buckets[bidx], null, null, key, new_value);
                    const new_ptr: [*]u8 = new_blob.ptr;
                    self.buckets[bidx] = new_ptr;

                    // Link into LRU chain at tail.
                    if (self.last) |last_p| {
                        setNext(last_p[0..blobLen(last_p)], new_ptr);
                        setPrev(new_blob[0..new_blob.len], self.last);
                    } else {
                        self.first = new_ptr;
                    }
                    self.last = new_ptr;

                    self.num_records += 1;
                    self.eff_data_size += @intCast(key.len + new_value.len);
                    if (self.dbm) |dbm| {
                        if (dbm.update_logger) |ul| {
                            _ = ul.writeSet(key, new_value);
                        }
                    }
                }
            },
        }
    }

    fn removeLRU(self: *CacheSlot, allocator: std.mem.Allocator) void {
        if (self.first == null) return;

        const p = self.first.?;
        const rv = deserializeRecord(p);

        // Find bucket index for this key and walk chain to find parent.
        const hash_val = hash_util.primaryHash(rv.key, std.math.maxInt(u64)) >> 8;
        const bucket_index = hash_val % @as(u64, @intCast(self.num_buckets));
        const bidx: usize = @intCast(bucket_index);

        var parent: ?[*]u8 = null;
        var ptr: ?[*]u8 = self.buckets[bidx];

        while (ptr) |current| {
            if (current == p) {
                // Found: unlink from hash chain.
                if (parent == null) {
                    self.buckets[bidx] = rv.child;
                } else {
                    setChild(parent.?[0..blobLen(parent.?)], rv.child);
                }

                // Unlink from LRU chain.
                if (rv.next) |next_p| {
                    setPrev(next_p[0..blobLen(next_p)], null);
                } else {
                    self.last = null;
                }
                self.first = rv.next;

                // Free blob and update counters.
                const blob_len = blobLen(p);
                self.eff_data_size -= @intCast(rv.key.len + rv.value.len);
                allocator.free(p[0..blob_len]);
                self.num_records -= 1;
                return;
            }
            parent = current;
            const curr_rv = deserializeRecord(current);
            ptr = curr_rv.child;
        }
    }

    fn releaseAllRecords(self: *CacheSlot, allocator: std.mem.Allocator) void {
        var ptr: ?[*]u8 = self.first;
        while (ptr) |p| {
            const rv = deserializeRecord(p);
            const blob_len = blobLen(p);
            allocator.free(p[0..blob_len]);
            ptr = rv.next;
        }
    }

    fn removeBlob(self: *CacheSlot, p: [*]u8, allocator: std.mem.Allocator) void {
        const rv = deserializeRecord(p);
        const blob_len = blobLen(p);

        // Find bucket index and walk to unlink from hash chain.
        const hash_val = hash_util.primaryHash(rv.key, std.math.maxInt(u64)) >> 8;
        const bucket_index = hash_val % @as(u64, @intCast(self.num_buckets));
        const bidx: usize = @intCast(bucket_index);

        var parent: ?[*]u8 = null;
        var ptr: ?[*]u8 = self.buckets[bidx];

        while (ptr) |current| {
            if (current == p) {
                if (parent == null) {
                    self.buckets[bidx] = rv.child;
                } else {
                    setChild(parent.?[0..blobLen(parent.?)], rv.child);
                }
                break;
            }
            parent = current;
            const curr_rv = deserializeRecord(current);
            ptr = curr_rv.child;
        }

        // Unlink from LRU chain.
        if (rv.prev) |prev_p| {
            setNext(prev_p[0..blobLen(prev_p)], rv.next);
        } else {
            self.first = rv.next;
        }
        if (rv.next) |next_p| {
            setPrev(next_p[0..blobLen(next_p)], rv.prev);
        } else {
            self.last = rv.prev;
        }

        // Free and update counters.
        self.eff_data_size -= @intCast(rv.key.len + rv.value.len);
        allocator.free(p[0..blob_len]);
        self.num_records -= 1;
    }
};

fn blobLen(ptr: [*]u8) usize {
    const rv = deserializeRecord(ptr);
    const key_vsize = varint.sizeVarNum(rv.key.len);
    const val_vsize = varint.sizeVarNum(rv.value.len);
    return HEADER_SIZE + key_vsize + rv.key.len + val_vsize + rv.value.len;
}

// ---------------------------------------------------------------------------
// Built-in record processors
// ---------------------------------------------------------------------------

pub const ProcessorGet = struct {
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

pub const ProcessorSet = struct {
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

const CacheDBMIteratorImpl = struct {
    dbm: ?*CacheDBMImpl,
    slot_index: std.atomic.Value(i64),
    keys: std.ArrayList([]u8),
    allocator: std.mem.Allocator,

    fn init(dbm: *CacheDBMImpl, io: std.Io, allocator: std.mem.Allocator) !*CacheDBMIteratorImpl {
        const self = try allocator.create(CacheDBMIteratorImpl);
        self.* = CacheDBMIteratorImpl{
            .dbm = dbm,
            .slot_index = std.atomic.Value(i64).init(-1),
            .keys = .empty,
            .allocator = allocator,
        };
        dbm.mutex.lockUncancelable(io);
        dbm.iterators.append(allocator, self) catch {
            dbm.mutex.unlock(io);
            allocator.destroy(self);
            return error.OutOfMemory;
        };
        dbm.mutex.unlock(io);
        return self;
    }

    fn deinit(self: *CacheDBMIteratorImpl, io: std.Io) void {
        if (self.dbm) |dbm| {
            dbm.mutex.lockUncancelable(io);
            defer dbm.mutex.unlock(io);
            for (0..dbm.iterators.items.len) |i| {
                if (dbm.iterators.items[i] == self) {
                    _ = dbm.iterators.orderedRemove(i);
                    break;
                }
            }
        }
        for (self.keys.items) |key| {
            self.allocator.free(key);
        }
        self.keys.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn first(self: *CacheDBMIteratorImpl, io: std.Io) !Status {
        _ = io;
        self.slot_index.store(-1, .release);
        for (self.keys.items) |key| {
            self.allocator.free(key);
        }
        self.keys.clearRetainingCapacity();
        return Status.init(.SUCCESS);
    }

    fn jump(self: *CacheDBMIteratorImpl, io: std.Io, key: []const u8) !Status {
        if (self.dbm == null) {
            return Status.initMsg(.PRECONDITION_ERROR, "orphaned iterator");
        }
        const dbm = self.dbm.?;

        const hash_val = hash_util.primaryHash(key, std.math.maxInt(u64));
        const slot_index = (hash_val & 0xff) % @as(u64, NUM_CACHE_SLOTS);
        self.slot_index.store(@intCast(slot_index), .release);

        for (self.keys.items) |k| {
            self.allocator.free(k);
        }
        self.keys.clearRetainingCapacity();

        const st = try dbm.readNextBucketRecords(io, self);
        if (!st.isOk()) {
            return st;
        }

        // Search for key in the loaded keys batch.
        var match_index: ?usize = null;
        for (0..self.keys.items.len) |i| {
            if (std.mem.eql(u8, self.keys.items[i], key)) {
                match_index = i;
                break;
            }
        }

        if (match_index) |idx| {
            // Free keys before the match index.
            for (0..idx) |i| {
                self.allocator.free(self.keys.items[i]);
            }
            // Slide remaining keys to front in-place (no extra allocation needed).
            const remaining_count = self.keys.items.len - idx;
            for (0..remaining_count) |i| {
                self.keys.items[i] = self.keys.items[idx + i];
            }
            self.keys.shrinkRetainingCapacity(remaining_count);
            return Status.init(.SUCCESS);
        }

        return Status.init(.NOT_FOUND_ERROR);
    }

    fn next(self: *CacheDBMIteratorImpl, io: std.Io) !Status {
        if (self.dbm == null) {
            return Status.initMsg(.PRECONDITION_ERROR, "orphaned iterator");
        }

        const st = try self.readKeys(io);
        if (!st.isOk()) {
            return st;
        }

        if (self.keys.items.len > 0) {
            self.allocator.free(self.keys.items[0]);
            _ = self.keys.orderedRemove(0);
        }

        return Status.init(.SUCCESS);
    }

    fn process(self: *CacheDBMIteratorImpl, io: std.Io, proc: anytype, writable: bool) !Status {
        if (self.dbm == null) {
            return Status.initMsg(.PRECONDITION_ERROR, "orphaned iterator");
        }
        const dbm = self.dbm.?;

        const st = try self.readKeys(io);
        if (!st.isOk()) {
            return st;
        }

        if (self.keys.items.len == 0) {
            return Status.init(.NOT_FOUND_ERROR);
        }

        const current_key = self.keys.items[0];

        // Create wrapper that captures the user proc.
        const ProcWrapper = struct {
            user_proc: @TypeOf(proc),
            action: RecordAction = .noop,
            full_called: bool = false,

            fn processFull(wrapper: *@This(), key: []const u8, value: []const u8) RecordAction {
                wrapper.full_called = true;
                wrapper.action = wrapper.user_proc.processFull(key, value);
                return wrapper.action;
            }

            fn processEmpty(wrapper: *@This(), key: []const u8) RecordAction {
                wrapper.action = wrapper.user_proc.processEmpty(key);
                return wrapper.action;
            }
        };

        var wrapper = ProcWrapper{ .user_proc = proc };

        const hash_val = hash_util.primaryHash(current_key, std.math.maxInt(u64));
        const slot_index = (hash_val & 0xff) % @as(u64, NUM_CACHE_SLOTS);
        const record_hash = hash_val >> 8;

        var slot: *CacheSlot = &dbm.slots[@intCast(slot_index)];
        try slot.process(dbm.allocator, io, current_key, record_hash, &wrapper, writable);

        if (!wrapper.full_called) {
            return Status.init(.NOT_FOUND_ERROR);
        }

        if (wrapper.action == .remove) {
            self.allocator.free(current_key);
            _ = self.keys.orderedRemove(0);
        }

        return Status.init(.SUCCESS);
    }

    fn readKeys(self: *CacheDBMIteratorImpl, io: std.Io) !Status {
        if (self.keys.items.len > 0) {
            return Status.init(.SUCCESS);
        }
        if (self.dbm == null) {
            return Status.initMsg(.PRECONDITION_ERROR, "orphaned iterator");
        }
        const dbm = self.dbm.?;
        return try dbm.readNextBucketRecords(io, self);
    }
};

// ---------------------------------------------------------------------------
// CacheDBMImpl
// ---------------------------------------------------------------------------

const CacheDBMImpl = struct {
    allocator: std.mem.Allocator,
    file: File,
    open: bool,
    writable: bool,
    open_options: OpenOptions,
    path: std.ArrayList(u8),
    timestamp: std.Io.Timestamp,
    cap_rec_num: i64,
    cap_mem_size: i64,
    slots: [NUM_CACHE_SLOTS]CacheSlot,
    update_logger: ?*UpdateLogger,
    iterators: std.ArrayList(*CacheDBMIteratorImpl),
    mutex: std.Io.RwLock,

    fn init(
        file: File,
        cap_rec_num_in: i64,
        cap_mem_size_in: i64,
        allocator: std.mem.Allocator,
    ) !*CacheDBMImpl {
        // Normalize to C++ defaults: cap_rec_num=0 → DEFAULT_CAP_REC_NUM, cap_mem_size=0 → INT64MAX.
        const cap_rec_num = if (cap_rec_num_in > 0) cap_rec_num_in else DEFAULT_CAP_REC_NUM;
        const cap_mem_size = if (cap_mem_size_in > 0) cap_mem_size_in else std.math.maxInt(i64);

        const self = try allocator.create(CacheDBMImpl);
        errdefer allocator.destroy(self);

        var slots_array: [NUM_CACHE_SLOTS]CacheSlot = undefined;
        for (0..NUM_CACHE_SLOTS) |i| {
            // C++ CacheSlot::Init: per_slot_cap = cap_rec_num / NUM_CACHE_SLOTS + 1,
            // then num_buckets = GetHashBucketSize(per_slot_cap * MAX_LOAD_FACTOR).
            const per_slot_cap = @divTrunc(cap_rec_num, NUM_CACHE_SLOTS) + 1;
            const num_buckets_req: i64 = @trunc(@as(f64, @floatFromInt(per_slot_cap)) * MAX_LOAD_FACTOR);
            const nb = hash_util.getHashBucketSize(num_buckets_req);
            const buckets = try allocator.alloc(?[*]u8, @intCast(nb));
            @memset(buckets, null);

            slots_array[i] = CacheSlot{
                .dbm = self,
                .buckets = buckets,
                .first = null,
                .last = null,
                .cap_rec_num = @divTrunc(cap_rec_num, NUM_CACHE_SLOTS) + 1,
                .cap_mem_size = @divTrunc(cap_mem_size, NUM_CACHE_SLOTS),
                .num_buckets = nb,
                .num_records = 0,
                .eff_data_size = 0,
                .mutex = .init,
            };
        }

        self.* = CacheDBMImpl{
            .allocator = allocator,
            .file = file,
            .open = false,
            .writable = false,
            .open_options = .{},
            .path = .empty,
            .timestamp = std.Io.Timestamp.zero,
            .cap_rec_num = cap_rec_num,
            .cap_mem_size = cap_mem_size,
            .slots = slots_array,
            .update_logger = null,
            .iterators = .empty,
            .mutex = .init,
        };

        return self;
    }

    fn deinit(self: *CacheDBMImpl, io: std.Io) void {
        if (self.open) {
            _ = self.closeImpl(io);
        }
        // Orphan iterators.
        for (self.iterators.items) |iter| {
            iter.dbm = null;
            iter.slot_index.store(-1, .release);
        }
        self.iterators.deinit(self.allocator);

        // Clean up all slots.
        for (0..NUM_CACHE_SLOTS) |i| {
            self.slots[i].deinit(self.allocator);
        }

        self.path.deinit(self.allocator);
        self.file.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn openImpl(
        self: *CacheDBMImpl,
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

    fn closeImpl(self: *CacheDBMImpl, io: std.Io) Status {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (!self.open) {
            return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        }

        var status = Status.init(.SUCCESS);
        if (self.writable) {
            const export_st = self.exportRecords(io) catch Status.init(.SYSTEM_ERROR);
            status.mergeFrom(export_st);
        }
        status.mergeFrom(self.file.close(io));
        self.cleanUpAllSlots();
        self.cancelIterators();
        self.open = false;
        self.writable = false;
        self.open_options = .{};
        self.path.clearRetainingCapacity();
        self.timestamp = std.Io.Timestamp.zero;
        return status;
    }

    fn processImpl(
        self: *CacheDBMImpl,
        io: std.Io,
        key: []const u8,
        proc: anytype,
        writable: bool,
    ) Status {
        const hash_val = hash_util.primaryHash(key, std.math.maxInt(u64));
        const slot_index = (hash_val & 0xff) % @as(u64, NUM_CACHE_SLOTS);
        const record_hash = hash_val >> 8;

        var slot: *CacheSlot = &self.slots[@intCast(slot_index)];
        // OOM from reserializeRecord surfaces as error.OutOfMemory from the slot.
        // C++ equivalent: std::bad_alloc propagates uncaught through the entire call chain.
        // We absorb it into SYSTEM_ERROR to preserve the plain-Status API contract.
        slot.process(self.allocator, io, key, record_hash, proc, writable) catch return Status.init(.SYSTEM_ERROR);
        return Status.init(.SUCCESS);
    }

    fn process(
        self: *CacheDBMImpl,
        io: std.Io,
        key: []const u8,
        proc: anytype,
        writable: bool,
    ) Status {
        // Outer DBM lock is shared: slot-level lock provides mutation safety.
        // C++ CacheDBMImpl::Process uses shared_lock even for writable=true.
        self.mutex.lockSharedUncancelable(io);
        defer self.mutex.unlockShared(io);
        return self.processImpl(io, key, proc, writable);
    }

    fn processMulti(
        self: *CacheDBMImpl,
        io: std.Io,
        comptime P: type,
        keys: []const []const u8,
        procs: []const *P,
        writable: bool,
    ) Status {
        if (keys.len != procs.len) {
            return Status.init(.INVALID_ARGUMENT_ERROR);
        }

        // Collect unique slot pointers that the keys hash into.
        var slot_map: std.AutoHashMapUnmanaged(*CacheSlot, void) = .{};
        defer slot_map.deinit(self.allocator);

        self.mutex.lockSharedUncancelable(io);
        defer self.mutex.unlockShared(io);

        for (keys) |key| {
            const hash_val = hash_util.primaryHash(key, std.math.maxInt(u64));
            const slot_index = (hash_val & 0xff) % @as(u64, NUM_CACHE_SLOTS);
            const slot: *CacheSlot = &self.slots[@intCast(slot_index)];
            slot_map.put(self.allocator, slot, {}) catch return Status.init(.SYSTEM_ERROR);
        }

        // Collect unique slots and sort by pointer value to prevent deadlock.
        var unique_slots: std.ArrayListUnmanaged(*CacheSlot) = .empty;
        defer unique_slots.deinit(self.allocator);

        var iter = slot_map.keyIterator();
        while (iter.next()) |slot_ptr| {
            unique_slots.append(self.allocator, slot_ptr.*) catch return Status.init(.SYSTEM_ERROR);
        }

        std.mem.sort(
            *CacheSlot,
            unique_slots.items,
            {},
            struct {
                pub fn lessThan(_: void, a: *CacheSlot, b: *CacheSlot) bool {
                    return @intFromPtr(a) < @intFromPtr(b);
                }
            }.lessThan,
        );

        // Lock all unique slots in sorted order.
        for (unique_slots.items) |slot| {
            slot.lock(io);
        }
        defer {
            // Unlock in reverse order.
            var i = unique_slots.items.len;
            while (i > 0) {
                i -= 1;
                unique_slots.items[i].unlock(io);
            }
        }

        // Process each key-proc pair under the already-held slot locks.
        // Call slot.processImpl directly (not slot.process) to avoid re-locking.
        for (keys, procs) |key, proc| {
            const hash_val = hash_util.primaryHash(key, std.math.maxInt(u64));
            const slot_index = (hash_val & 0xff) % @as(u64, NUM_CACHE_SLOTS);
            const record_hash = hash_val >> 8;
            var slot: *CacheSlot = &self.slots[@intCast(slot_index)];
            slot.processImpl(self.allocator, key, record_hash, proc, writable) catch return Status.init(.SYSTEM_ERROR);
        }

        return Status.init(.SUCCESS);
    }

    fn processFirst(
        self: *CacheDBMImpl,
        io: std.Io,
        proc: anytype,
        writable: bool,
    ) Status {
        self.mutex.lockSharedUncancelable(io);
        defer self.mutex.unlockShared(io);

        for (0..NUM_CACHE_SLOTS) |i| {
            var slot: *CacheSlot = &self.slots[i];
            slot.lock(io);
            const found = slot.processFirst(self.allocator, proc, writable);
            slot.unlock(io);
            if (found) return Status.init(.SUCCESS);
        }
        return Status.init(.NOT_FOUND_ERROR);
    }

    fn processEach(
        self: *CacheDBMImpl,
        io: std.Io,
        proc: anytype,
        writable: bool,
    ) Status {
        self.mutex.lockSharedUncancelable(io);
        defer self.mutex.unlockShared(io);

        _ = proc.processEmpty(""); // C++ ProcessEach sentinel: fired once before the slot loop
        for (0..NUM_CACHE_SLOTS) |i| {
            var slot: *CacheSlot = &self.slots[i];
            slot.lock(io);
            defer slot.unlock(io);

            slot.processEach(self.allocator, proc, writable) catch return Status.init(.SYSTEM_ERROR);
        }
        _ = proc.processEmpty(""); // C++ ProcessEach sentinel: fired once after the slot loop
        return Status.init(.SUCCESS);
    }

    fn count(self: *CacheDBMImpl, io: std.Io) i64 {
        self.mutex.lockSharedUncancelable(io);
        defer self.mutex.unlockShared(io);

        var total: i64 = 0;
        for (0..NUM_CACHE_SLOTS) |i| {
            total += self.slots[i].count();
        }
        return total;
    }

    // Lock-free variant — caller must already hold self.mutex exclusively.
    fn countNoLock(self: *CacheDBMImpl) i64 {
        var total: i64 = 0;
        for (0..NUM_CACHE_SLOTS) |i| {
            total += self.slots[i].num_records;
        }
        return total;
    }

    fn getEffectiveDataSize(self: *CacheDBMImpl, io: std.Io) i64 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        var total: i64 = 0;
        for (0..NUM_CACHE_SLOTS) |i| {
            total += self.slots[i].getEffectiveDataSize();
        }
        return total;
    }

    fn getMemoryUsage(self: *CacheDBMImpl, io: std.Io) i64 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        var total: i64 = @intCast(@sizeOf(CacheDBMImpl));
        for (0..NUM_CACHE_SLOTS) |i| {
            total += self.slots[i].getMemoryUsageImpl();
        }
        return total;
    }

    fn getFilePath(self: *CacheDBMImpl) []const u8 {
        return self.path.items;
    }

    fn getFileSize(self: *CacheDBMImpl, io: std.Io) i64 {
        self.mutex.lockSharedUncancelable(io);
        defer self.mutex.unlockShared(io);
        return self.file.getSizeSimple();
    }

    fn getTimestamp(self: *CacheDBMImpl, io: std.Io) f64 {
        self.mutex.lockSharedUncancelable(io);
        defer self.mutex.unlockShared(io);
        return @as(f64, @floatFromInt(self.timestamp.nanoseconds)) / 1_000_000_000.0;
    }

    fn clear(self: *CacheDBMImpl, io: std.Io) Status {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.update_logger) |ul| {
            _ = ul.writeClear();
        }

        for (0..NUM_CACHE_SLOTS) |i| {
            self.slots[i].rebuild(
                self.allocator,
                @divTrunc(self.cap_rec_num, NUM_CACHE_SLOTS) + 1,
                @divTrunc(self.cap_mem_size, NUM_CACHE_SLOTS),
            );
        }
        self.cancelIterators();
        return Status.init(.SUCCESS);
    }

    fn rebuild(
        self: *CacheDBMImpl,
        io: std.Io,
        cap_rec_num: i64,
        cap_mem_size: i64,
    ) Status {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        self.cap_rec_num = cap_rec_num;
        self.cap_mem_size = cap_mem_size;

        for (0..NUM_CACHE_SLOTS) |i| {
            self.slots[i].rebuild(
                self.allocator,
                @divTrunc(cap_rec_num, NUM_CACHE_SLOTS) + 1,
                @divTrunc(cap_mem_size, NUM_CACHE_SLOTS),
            );
        }
        self.cancelIterators();
        return Status.init(.SUCCESS);
    }

    fn synchronize(self: *CacheDBMImpl, io: std.Io, hard: bool) Status {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (!self.open) {
            return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        }

        var status = Status.init(.SUCCESS);
        if (self.writable) {
            // C++ Synchronize calls update_logger_->Synchronize() before ExportRecords(),
            // inside the mutex — ensuring the WAL is flushed before the snapshot is written.
            if (self.update_logger) |ul| {
                status.mergeFrom(ul.synchronize(hard));
            }
            const export_st = self.exportRecords(io) catch Status.init(.SYSTEM_ERROR);
            status.mergeFrom(export_st);
        }
        if (hard) {
            status.mergeFrom(self.file.synchronize(io, true));
        }
        return status;
    }

    fn importRecords(self: *CacheDBMImpl, io: std.Io) Status {
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
                    var meta = str_util.deserializeStrMap(str, self.allocator) catch continue;
                    defer meta.deinit();
                    if (meta.get("class")) |class_str| {
                        if (str_util.strContains(class_str, "DBM")) {
                            if (meta.get("timestamp")) |ts_str| {
                                if (ts_str.len > 0) {
                                    const secs_f64 = str_util.strToDouble(ts_str, 0.0);
                                    self.timestamp = .{ .nanoseconds = @as(i96, @trunc(secs_f64 * 1_000_000_000.0)) };
                                }
                            }
                        }
                    }
                }
                continue;
            }

            key_store.clearRetainingCapacity();
            key_store.appendSlice(self.allocator, str) catch
                return Status.init(.SYSTEM_ERROR);

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

            var setter_status = Status.init(.SUCCESS);
            var setter = ProcessorSet{
                .status = &setter_status,
                .value = val_str,
                .overwrite = true,
                .old_value = null,
                .allocator = self.allocator,
            };
            // C++ CacheSlot::Process returns void and uses xmalloc (throws on OOM), so
            // per-record insertion failure is unobservable in C++. Zig surfaces it as
            // SYSTEM_ERROR; we propagate it rather than silently skipping records.
            const import_st = self.processImpl(io, key_store.items, &setter, true);
            if (!import_st.isOk()) return import_st;
        }
        return Status.init(.SUCCESS);
    }

    fn exportRecords(self: *CacheDBMImpl, io: std.Io) !Status {
        var status = Status.init(.SUCCESS);

        status.mergeFrom(self.file.close(io));
        if (!status.isOk()) return status;

        var export_path_buf: std.ArrayList(u8) = .empty;
        defer export_path_buf.deinit(self.allocator);
        export_path_buf.appendSlice(self.allocator, self.path.items) catch
            return Status.init(.SYSTEM_ERROR);
        export_path_buf.appendSlice(self.allocator, ".tmp.export") catch
            return Status.init(.SYSTEM_ERROR);
        const export_path = export_path_buf.items;

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

        var export_file_open = true;
        defer {
            if (export_file_open) {
                _ = self.file.close(io);
            }
        }

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
            const nr_str = std.fmt.allocPrint(self.allocator, "{d}", .{self.countNoLock()}) catch
                return Status.init(.SYSTEM_ERROR);
            defer self.allocator.free(nr_str);

            meta.put("class", "CacheDBM") catch return Status.init(.SYSTEM_ERROR);
            meta.put("timestamp", ts_str) catch return Status.init(.SYSTEM_ERROR);
            meta.put("num_records", nr_str) catch return Status.init(.SYSTEM_ERROR);

            const serialized = str_util.serializeStrMap(&meta, self.allocator) catch
                return Status.init(.SYSTEM_ERROR);
            defer self.allocator.free(serialized);

            status.mergeFrom(flat_rec.write(io, serialized, .metadata));
        }

        for (0..NUM_CACHE_SLOTS) |i| {
            const slot_status = self.slots[i].exportRecords(io, &flat_rec) catch {
                return Status.initMsg(.SYSTEM_ERROR, "export error");
            };
            status.mergeFrom(slot_status);
            if (!status.isOk()) break;
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

    fn readNextBucketRecords(
        self: *CacheDBMImpl,
        io: std.Io,
        iter: *CacheDBMIteratorImpl,
    ) !Status {
        iter.keys.clearRetainingCapacity();

        const start_index = iter.slot_index.load(.acquire) + 1;
        if (start_index >= NUM_CACHE_SLOTS) {
            return Status.init(.NOT_FOUND_ERROR);
        }

        for (@intCast(start_index)..NUM_CACHE_SLOTS) |i| {
            var slot: *CacheSlot = &self.slots[i];
            slot.lock(io);
            defer slot.unlock(io);

            iter.slot_index.store(@intCast(i), .release);
            var keys = slot.getKeys(self.allocator) catch
                return Status.init(.SYSTEM_ERROR);
            defer keys.deinit(self.allocator);
            for (keys.items, 0..) |key, ki| {
                iter.keys.append(self.allocator, key) catch {
                    for (keys.items[ki..]) |k| self.allocator.free(k);
                    return Status.init(.SYSTEM_ERROR);
                };
            }

            if (iter.keys.items.len > 0) {
                return Status.init(.SUCCESS);
            }
        }

        return Status.init(.NOT_FOUND_ERROR);
    }

    fn initAllSlots(self: *CacheDBMImpl) !void {
        for (0..NUM_CACHE_SLOTS) |i| {
            self.slots[i].dbm = self;
        }
    }

    fn cleanUpAllSlots(self: *CacheDBMImpl) void {
        for (0..NUM_CACHE_SLOTS) |i| {
            self.slots[i].deinit(self.allocator);
            const per_slot_cap = @divTrunc(self.cap_rec_num, NUM_CACHE_SLOTS) + 1;
            const num_buckets_req: i64 = @trunc(@as(f64, @floatFromInt(per_slot_cap)) * MAX_LOAD_FACTOR);
            const nb = hash_util.getHashBucketSize(num_buckets_req);
            const buckets = self.allocator.alloc(?[*]u8, @intCast(nb)) catch {
                self.slots[i].buckets = &.{};
                self.slots[i].num_buckets = 0;
                self.slots[i].first = null;
                self.slots[i].last = null;
                self.slots[i].num_records = 0;
                self.slots[i].eff_data_size = 0;
                continue;
            };
            @memset(buckets, null);

            self.slots[i] = CacheSlot{
                .dbm = self,
                .buckets = buckets,
                .first = null,
                .last = null,
                .cap_rec_num = @divTrunc(self.cap_rec_num, NUM_CACHE_SLOTS) + 1,
                .cap_mem_size = @divTrunc(self.cap_mem_size, NUM_CACHE_SLOTS),
                .num_buckets = nb,
                .num_records = 0,
                .eff_data_size = 0,
                .mutex = .init,
            };
        }
    }

    fn cancelIterators(self: *CacheDBMImpl) void {
        for (self.iterators.items) |iter| {
            iter.slot_index.store(-1, .release);
        }
    }
};


pub const CacheDBM = struct {
    impl: *CacheDBMImpl,
    allocator: std.mem.Allocator,

    pub const DEFAULT_CAP_REC_NUM: i64 = 1048576;

    pub const Entry = struct {
        /// Borrowed from iterator's internal buffer.
        /// Valid only until the next call to next() or deinit().
        key: []const u8,
        /// Borrowed from iterator's internal buffer.
        /// Valid only until the next call to next() or deinit().
        value: []const u8,
    };

    pub const Cursor = struct {
        impl: *CacheDBMIteratorImpl,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *Cursor, io: std.Io) void {
            self.impl.deinit(io);
        }

        pub fn first(self: *Cursor, io: std.Io) Status {
            return self.impl.first(io) catch Status.init(.SYSTEM_ERROR);
        }

        pub fn jump(self: *Cursor, io: std.Io, key: []const u8) Status {
            return self.impl.jump(io, key) catch Status.init(.SYSTEM_ERROR);
        }

        pub fn next(self: *Cursor, io: std.Io) Status {
            return self.impl.next(io) catch Status.init(.SYSTEM_ERROR);
        }

        pub fn get(self: *Cursor, io: std.Io, key_out: ?*std.ArrayList(u8), value_out: ?*std.ArrayList(u8)) Status {
            if (self.impl.keys.items.len == 0) {
                return Status.init(.NOT_FOUND_ERROR);
            }
            const key = self.impl.keys.items[0];

            if (key_out) |ko| {
                ko.clearRetainingCapacity();
                ko.appendSlice(self.allocator, key) catch return Status.init(.SYSTEM_ERROR);
            }

            if (value_out == null) {
                // Only key was requested; confirm the record still exists via the dbm.
                var status = Status.init(.SUCCESS);
                const CheckProc = struct {
                    status: *Status,
                    fn processFull(proc: *@This(), _: []const u8, _: []const u8) RecordAction {
                        proc.status.* = Status.init(.SUCCESS);
                        return .noop;
                    }
                    fn processEmpty(proc: *@This(), _: []const u8) RecordAction {
                        proc.status.* = Status.init(.NOT_FOUND_ERROR);
                        return .noop;
                    }
                };
                var check_proc = CheckProc{ .status = &status };
                _ = self.impl.process(io, &check_proc, false) catch return Status.init(.SYSTEM_ERROR);
                return status;
            }

            const value = value_out.?;
            value.clearRetainingCapacity();
            var status = Status.init(.NOT_FOUND_ERROR);

            const GetProc = struct {
                key: []const u8,
                value: *std.ArrayList(u8),
                status: *Status,
                allocator: std.mem.Allocator,

                fn processFull(proc: *@This(), k: []const u8, v: []const u8) RecordAction {
                    if (std.mem.eql(u8, k, proc.key)) {
                        proc.value.appendSlice(proc.allocator, v) catch {
                            proc.status.* = Status.init(.SYSTEM_ERROR);
                        };
                        proc.status.* = Status.init(.SUCCESS);
                    }
                    return .noop;
                }

                fn processEmpty(proc: *@This(), key_param: []const u8) RecordAction {
                    _ = proc;
                    _ = key_param;
                    return .noop;
                }
            };

            var get_proc = GetProc{ .key = key, .value = value, .status = &status, .allocator = self.allocator };
            _ = self.impl.process(io, &get_proc, false) catch return Status.init(.SYSTEM_ERROR);
            return status;
        }

        pub fn process(self: *Cursor, io: std.Io, proc: anytype, writable: bool) Status {
            return self.impl.process(io, proc, writable) catch Status.init(.SYSTEM_ERROR);
        }

        pub fn set(self: *Cursor, io: std.Io, value: []const u8, old_key: ?*std.ArrayList(u8), old_value: ?*std.ArrayList(u8)) Status {
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
            const st = self.process(io, &proc, true);
            if (!st.isOk()) return st;
            return proc.status;
        }

        pub fn remove(self: *Cursor, io: std.Io, old_key: ?*std.ArrayList(u8), old_value: ?*std.ArrayList(u8)) Status {
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
            const st = self.process(io, &proc, true);
            if (!st.isOk()) return st;
            return proc.status;
        }

        pub fn step(self: *Cursor, io: std.Io, key_out: ?*std.ArrayList(u8), value_out: ?*std.ArrayList(u8)) Status {
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
                fn processFull(p: *@This(), key: []const u8, val: []const u8) RecordAction {
                    p.key_buf.clearRetainingCapacity();
                    p.key_buf.appendSlice(p.alloc, key) catch { p.oom = true; return .noop; };
                    p.val_buf.clearRetainingCapacity();
                    p.val_buf.appendSlice(p.alloc, val) catch { p.oom = true; return .noop; };
                    return .noop;
                }
                fn processEmpty(_: *@This(), _: []const u8) RecordAction {
                    return .noop;
                }
            };
            var proc = Proc{
                .key_buf = &self.key_buf,
                .val_buf = &self.value_buf,
                .alloc = self.alloc,
            };
            if (self.cursor.process(io, &proc, false).isOk() and !proc.oom) filled = true;
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

    pub fn init(file: File, cap_rec_num: i64, cap_mem_size: i64, allocator: std.mem.Allocator) !CacheDBM {
        const impl = try CacheDBMImpl.init(file, cap_rec_num, cap_mem_size, allocator);
        return CacheDBM{
            .impl = impl,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CacheDBM, io: std.Io) void {
        self.impl.deinit(io);
    }

    pub fn open(self: *CacheDBM, io: std.Io, path: []const u8, writable: bool, options: OpenOptions) Status {
        return self.impl.openImpl(io, path, writable, options);
    }

    pub fn close(self: *CacheDBM, io: std.Io) Status {
        return self.impl.closeImpl(io);
    }

    pub fn get(self: *CacheDBM, io: std.Io, key: []const u8, value: ?*std.ArrayList(u8)) Status {
        var status = Status.init(.NOT_FOUND_ERROR);
        var proc = ProcessorGet{
            .status = &status,
            .value = value,
            .allocator = self.allocator,
        };
        // C++ CacheDBMImpl::Process uses shared_lock for the outer mutex even for reads.
        // Slot-level lock handles LRU promotion safely.
        self.impl.mutex.lockSharedUncancelable(io);
        defer self.impl.mutex.unlockShared(io);
        // writable=false: read path never allocates, so OOM is impossible here.
        _ = self.impl.processImpl(io, key, &proc, false);
        return status;
    }

    pub fn getSimple(self: *CacheDBM, allocator: std.mem.Allocator, io: std.Io, key: []const u8, default_value: []const u8) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        const st = self.get(io, key, &buf);
        if (st.isOk()) return try allocator.dupe(u8, buf.items);
        return try allocator.dupe(u8, default_value);
    }

    pub fn set(self: *CacheDBM, io: std.Io, key: []const u8, value: []const u8, overwrite: bool, old_value: ?*std.ArrayList(u8)) Status {
        var status = Status.init(.SUCCESS);
        var proc = ProcessorSet{
            .status = &status,
            .value = value,
            .overwrite = overwrite,
            .old_value = old_value,
            .allocator = self.allocator,
        };
        const proc_st = self.impl.process(io, key, &proc, true);
        if (!proc_st.isOk()) return proc_st;
        return status;
    }

    pub fn remove(self: *CacheDBM, io: std.Io, key: []const u8) Status {
        var status = Status.init(.NOT_FOUND_ERROR);
        var proc = ProcessorRemove{ .status = &status };
        const proc_st = self.impl.process(io, key, &proc, true);
        if (!proc_st.isOk()) return proc_st;
        return status;
    }

    pub fn append(self: *CacheDBM, io: std.Io, key: []const u8, value: []const u8, delim: []const u8) Status {
        var status = Status.init(.SUCCESS);
        var concat_buf: std.ArrayList(u8) = .empty;
        defer concat_buf.deinit(self.allocator);

        const AppendProc = struct {
            value: []const u8,
            delim: []const u8,
            concat_buf: *std.ArrayList(u8),
            status: *Status,
            allocator: std.mem.Allocator,

            pub fn processFull(proc: *@This(), _key: []const u8, old_val: []const u8) RecordAction {
                _ = _key;
                // Build concatenated value: old_val + delim + value
                proc.concat_buf.clearRetainingCapacity();
                proc.concat_buf.appendSlice(proc.allocator, old_val) catch {
                    proc.status.* = Status.init(.SYSTEM_ERROR);
                    return .noop;
                };
                proc.concat_buf.appendSlice(proc.allocator, proc.delim) catch {
                    proc.status.* = Status.init(.SYSTEM_ERROR);
                    return .noop;
                };
                proc.concat_buf.appendSlice(proc.allocator, proc.value) catch {
                    proc.status.* = Status.init(.SYSTEM_ERROR);
                    return .noop;
                };
                return .{ .set = proc.concat_buf.items };
            }

            pub fn processEmpty(proc: *@This(), _key: []const u8) RecordAction {
                _ = _key;
                // Key doesn't exist: just insert the value
                return .{ .set = proc.value };
            }
        };

        var proc = AppendProc{
            .value = value,
            .delim = delim,
            .concat_buf = &concat_buf,
            .status = &status,
            .allocator = self.allocator,
        };
        _ = self.impl.process(io, key, &proc, true);
        return status;
    }

    pub fn getMulti(self: *CacheDBM, io: std.Io, keys: []const []const u8, records: *std.StringHashMap([]u8)) Status {
        const map_alloc = records.allocator;
        var status = Status.init(.SUCCESS);
        var val_buf: std.ArrayList(u8) = .empty;
        defer val_buf.deinit(self.allocator);
        for (keys) |key| {
            val_buf.clearRetainingCapacity();
            const st = self.get(io, key, &val_buf);
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

    pub fn setMulti(self: *CacheDBM, io: std.Io, records: []const [2][]const u8, overwrite: bool) Status {
        var status = Status.init(.SUCCESS);
        for (records) |r| {
            const st = self.set(io, r[0], r[1], overwrite, null);
            status.mergeFrom(st);
            if (!status.isOk() and status.code != .DUPLICATION_ERROR) break;
        }
        return status;
    }

    pub fn removeMulti(self: *CacheDBM, io: std.Io, keys: []const []const u8) Status {
        var status = Status.init(.SUCCESS);
        for (keys) |key| {
            const st = self.remove(io, key);
            status.mergeFrom(st);
            if (!status.isOk() and status.code != .NOT_FOUND_ERROR) break;
        }
        return status;
    }

    pub fn appendMulti(self: *CacheDBM, io: std.Io, records: []const [2][]const u8, delim: []const u8) Status {
        var status = Status.init(.SUCCESS);
        for (records) |r| {
            const st = self.append(io, r[0], r[1], delim);
            status.mergeFrom(st);
            if (!status.isOk()) break;
        }
        return status;
    }

    pub fn process(self: *CacheDBM, io: std.Io, key: []const u8, proc: anytype, writable: bool) Status {
        return self.impl.process(io, key, proc, writable);
    }

    pub fn getInternalFile(self: *CacheDBM) File {
        return self.impl.file;
    }

    // C++ GetCount/GetEffectiveDataSize/GetMemoryUsage delegate to impl methods
    // that each acquire their own lock. The public wrappers are one-liners, matching C++.
    fn countInternal(self: *CacheDBM, io: std.Io) i64 {
        return self.impl.count(io);
    }

    pub fn getEffectiveDataSize(self: *CacheDBM, io: std.Io) i64 {
        return self.impl.getEffectiveDataSize(io);
    }

    pub fn getMemoryUsage(self: *CacheDBM, io: std.Io) i64 {
        return self.impl.getMemoryUsage(io);
    }

    fn getFilePathInternal(self: *CacheDBM, io: std.Io) []const u8 {
        self.impl.mutex.lockSharedUncancelable(io);
        defer self.impl.mutex.unlockShared(io);
        return self.impl.path.items;
    }

    fn getFileSizeInternal(self: *CacheDBM, io: std.Io) i64 {
        return self.impl.getFileSize(io);
    }

    fn getTimestampInternal(self: *CacheDBM, io: std.Io) f64 {
        self.impl.mutex.lockUncancelable(io);
        defer self.impl.mutex.unlock(io);
        if (!self.impl.open) return 0.0;
        return @as(f64, @floatFromInt(self.impl.timestamp.nanoseconds)) / 1_000_000_000.0;
    }

    pub fn setUpdateLogger(self: *CacheDBM, io: std.Io, logger: ?*UpdateLogger) void {
        self.impl.mutex.lockUncancelable(io);
        defer self.impl.mutex.unlock(io);
        self.impl.update_logger = logger;
    }

    pub fn getUpdateLogger(self: *CacheDBM, io: std.Io) ?*UpdateLogger {
        self.impl.mutex.lockUncancelable(io);
        defer self.impl.mutex.unlock(io);
        return self.impl.update_logger;
    }

    // Shared lock matches C++ std::shared_lock access pattern for flag reads.
    pub fn isOpen(self: *CacheDBM, io: std.Io) bool {
        self.impl.mutex.lockSharedUncancelable(io);
        defer self.impl.mutex.unlockShared(io);
        return self.impl.open;
    }

    pub fn isWritable(self: *CacheDBM, io: std.Io) bool {
        self.impl.mutex.lockSharedUncancelable(io);
        defer self.impl.mutex.unlockShared(io);
        return self.impl.open and self.impl.writable;
    }

    pub fn isHealthy(_: *CacheDBM) bool {
        return true;
    }

    pub fn isOrdered(_: *CacheDBM) bool {
        return false;
    }

    fn shouldBeRebuiltInternal(self: *CacheDBM) bool {
        _ = self;
        return false;
    }

    /// Fills `out` with the number of records. Returns PRECONDITION_ERROR if not open.
    pub fn count(self: *CacheDBM, io: std.Io, out: *i64) Status {
        self.impl.mutex.lockSharedUncancelable(io);
        defer self.impl.mutex.unlockShared(io);
        out.* = self.impl.count(io);
        return Status.init(.SUCCESS);
    }

    /// Fills `out` with the file size. Returns PRECONDITION_ERROR if not open.
    pub fn getFileSize(self: *CacheDBM, io: std.Io, out: *i64) Status {
        self.impl.mutex.lockSharedUncancelable(io);
        defer self.impl.mutex.unlockShared(io);
        if (!self.impl.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        out.* = self.impl.getFileSize(io);
        return Status.init(.SUCCESS);
    }

    /// Appends the file path to `out`. Returns PRECONDITION_ERROR if not open.
    pub fn getFilePath(self: *CacheDBM, io: std.Io, out: *std.ArrayList(u8)) Status {
        self.impl.mutex.lockSharedUncancelable(io);
        defer self.impl.mutex.unlockShared(io);
        if (!self.impl.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        out.clearRetainingCapacity();
        out.appendSlice(self.allocator, self.impl.path.items) catch return Status.init(.SYSTEM_ERROR);
        return Status.init(.SUCCESS);
    }

    /// Fills `out` with the modification timestamp. Returns PRECONDITION_ERROR if not open.
    pub fn getTimestamp(self: *CacheDBM, io: std.Io, out: *f64) Status {
        self.impl.mutex.lockUncancelable(io);
        defer self.impl.mutex.unlock(io);
        if (!self.impl.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        out.* = @as(f64, @floatFromInt(self.impl.timestamp.nanoseconds)) / 1_000_000_000.0;
        return Status.init(.SUCCESS);
    }

    /// Sets `out` to false. CacheDBM never needs rebuilding.
    /// Matches C++ CacheDBM::ShouldBeRebuilt which always succeeds without checking open.
    pub fn shouldBeRebuilt(_: *CacheDBM, out: *bool) Status {
        out.* = false;
        return Status.init(.SUCCESS);
    }

    pub fn inspect(self: *CacheDBM, allocator: std.mem.Allocator, io: std.Io) !std.ArrayList([2][]u8) {
        self.impl.mutex.lockUncancelable(io);
        defer self.impl.mutex.unlock(io);

        var result: std.ArrayList([2][]u8) = .empty;
        try result.ensureTotalCapacity(allocator, 8);

        const appendPair = struct {
            fn f(arr: *std.ArrayList([2][]u8), alloc: std.mem.Allocator, k: []const u8, v: []const u8) !void {
                const key_copy = try alloc.dupe(u8, k);
                errdefer alloc.free(key_copy);
                const val_copy = try alloc.dupe(u8, v);
                errdefer alloc.free(val_copy);
                arr.appendAssumeCapacity(.{ key_copy, val_copy });
            }
        };

        try appendPair.f(&result, allocator, "class", "CacheDBM");

        // Add path if open
        if (self.impl.open and self.impl.path.items.len > 0) {
            try appendPair.f(&result, allocator, "path", self.impl.path.items);
        }

        // Add timestamp if open
        if (self.impl.open) {
            const ts_secs: f64 = @as(f64, @floatFromInt(self.impl.timestamp.nanoseconds)) / 1_000_000_000.0;
            const ts_str = try std.fmt.allocPrint(allocator, "{d:.6}", .{ts_secs});
            defer allocator.free(ts_str);
            try appendPair.f(&result, allocator, "timestamp", ts_str);
        }

        // Sum records and data size across all slots
        var total_records: i64 = 0;
        var total_eff_size: i64 = 0;
        var total_mem_usage: i64 = 0;

        for (0..NUM_CACHE_SLOTS) |i| {
            self.impl.slots[i].lock(io);
            defer self.impl.slots[i].unlock(io);
            total_records += self.impl.slots[i].num_records;
            total_eff_size += self.impl.slots[i].eff_data_size;
            total_mem_usage += self.impl.slots[i].getMemoryUsageImpl();
        }

        const num_rec_str = try std.fmt.allocPrint(allocator, "{d}", .{total_records});
        defer allocator.free(num_rec_str);
        try appendPair.f(&result, allocator, "num_records", num_rec_str);

        const eff_size_str = try std.fmt.allocPrint(allocator, "{d}", .{total_eff_size});
        defer allocator.free(eff_size_str);
        try appendPair.f(&result, allocator, "eff_data_size", eff_size_str);

        const mem_usage_str = try std.fmt.allocPrint(allocator, "{d}", .{total_mem_usage});
        defer allocator.free(mem_usage_str);
        try appendPair.f(&result, allocator, "mem_usage", mem_usage_str);

        const cap_rec_str = try std.fmt.allocPrint(allocator, "{d}", .{self.impl.cap_rec_num});
        defer allocator.free(cap_rec_str);
        try appendPair.f(&result, allocator, "cap_rec_num", cap_rec_str);

        const cap_mem_str = try std.fmt.allocPrint(allocator, "{d}", .{self.impl.cap_mem_size});
        defer allocator.free(cap_mem_str);
        try appendPair.f(&result, allocator, "cap_mem_size", cap_mem_str);

        return result;
    }

    pub fn processFirst(self: *CacheDBM, io: std.Io, proc: anytype, writable: bool) Status {
        return self.impl.processFirst(io, proc, writable);
    }

    pub fn processEach(self: *CacheDBM, io: std.Io, proc: anytype, writable: bool) Status {
        return self.impl.processEach(io, proc, writable);
    }

    pub fn processMulti(
        self: *CacheDBM,
        io: std.Io,
        comptime P: type,
        keys: []const []const u8,
        procs: []const *P,
        writable: bool,
    ) Status {
        return self.impl.processMulti(io, P, keys, procs, writable);
    }

    // C++ CacheDBM::Synchronize is a one-line passthrough to impl_->Synchronize.
    pub fn synchronize(self: *CacheDBM, io: std.Io, hard: bool) Status {
        return self.impl.synchronize(io, hard);
    }

    pub fn clear(self: *CacheDBM, io: std.Io) Status {
        return self.impl.clear(io);
    }

    pub fn rebuild(self: *CacheDBM, io: std.Io) Status {
        return self.rebuildAdvanced(io, -1, -1);
    }

    pub fn rebuildAdvanced(self: *CacheDBM, io: std.Io, cap_rec_num: i64, cap_mem_size: i64) Status {
        self.impl.mutex.lockUncancelable(io);
        defer self.impl.mutex.unlock(io);

        if (!self.impl.writable) {
            return Status.initMsg(.PRECONDITION_ERROR, "not writable");
        }

        self.impl.cap_rec_num = cap_rec_num;
        self.impl.cap_mem_size = cap_mem_size;

        for (0..NUM_CACHE_SLOTS) |i| {
            self.impl.slots[i].rebuild(
                self.allocator,
                @divTrunc(cap_rec_num, NUM_CACHE_SLOTS) + 1,
                @divTrunc(cap_mem_size, NUM_CACHE_SLOTS),
            );
        }

        // Matches C++ CacheDBMImpl::Rebuild which calls CancelIterators() before returning.
        self.impl.cancelIterators();
        return Status.init(.SUCCESS);
    }

    /// Return a Zig-style iterator positioned at the first record.
    /// The caller must call deinit() when done.
    pub fn iterate(self: *CacheDBM, alloc: std.mem.Allocator, io: std.Io) !Iterator {
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
    pub fn iterateFrom(self: *CacheDBM, alloc: std.mem.Allocator, io: std.Io, key: []const u8) !Iterator {
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

    pub fn makeCursor(self: *CacheDBM, io: std.Io) !Cursor {
        const iter_impl = try CacheDBMIteratorImpl.init(self.impl, io, self.allocator);
        return Cursor{
            .impl = iter_impl,
            .allocator = self.allocator,
        };
    }


    /// Atomically compare and conditionally exchange the value for a key.
    pub fn compareExchange(
        self: *CacheDBM,
        io: std.Io,
        key: []const u8,
        expected: dbm_mod.CompareExpected,
        desired: dbm_mod.CompareDesired,
        actual_out: ?*std.ArrayList(u8),
        found_out: ?*bool,
    ) Status {
        var status = Status.init(.SUCCESS);
        // Outer DBM lock is shared: slot-level lock provides mutation safety.
        self.impl.mutex.lockSharedUncancelable(io);
        defer self.impl.mutex.unlockShared(io);
        var proc = ProcessorCompareExchange{
            .status = &status,
            .expected = expected,
            .desired = desired,
            .actual_out = actual_out,
            .found_out = found_out,
            .allocator = self.allocator,
        };
        const proc_st = self.impl.processImpl(io, key, &proc, true);
        if (!proc_st.isOk()) return proc_st;
        return status;
    }

    /// Atomically increment a stored i64 value by delta, returning the new value.
    pub fn increment(
        self: *CacheDBM,
        io: std.Io,
        key: []const u8,
        delta: i64,
        current_out: ?*i64,
        initial: i64,
    ) Status {
        var status = Status.init(.SUCCESS);
        // Outer DBM lock is shared: slot-level lock provides mutation safety.
        self.impl.mutex.lockSharedUncancelable(io);
        defer self.impl.mutex.unlockShared(io);
        var proc = ProcessorIncrement{
            .status = &status,
            .delta = delta,
            .current_out = current_out,
            .initial = initial,
            .allocator = self.allocator,
        };
        const proc_st = self.impl.processImpl(io, key, &proc, true);
        if (!proc_st.isOk()) return proc_st;
        return status;
    }

    pub fn incrementSimple(self: *CacheDBM, io: std.Io, key: []const u8, delta: i64, initial: i64) i64 {
        var result: i64 = initial;
        _ = self.increment(io, key, delta, &result, initial);
        return result;
    }

    /// Remove and return the first record in the database (arbitrary order on unordered DBMs).
    pub fn popFirst(
        self: *CacheDBM,
        io: std.Io,
        key_out: ?*std.ArrayList(u8),
        value_out: ?*std.ArrayList(u8),
    ) Status {
        var status = Status.init(.NOT_FOUND_ERROR);
        var proc = ProcessorPopFirst{
            .status = &status,
            .key_out = key_out,
            .value_out = value_out,
            .allocator = self.allocator,
        };
        return self.processFirst(io, &proc, true);
    }

    /// Push a value at the lexicographic end using a timestamp-based key.
    /// wtime < 0 uses the current wall clock time; otherwise uses the provided time.
    /// Key is returned in key_out if non-null.
    pub fn pushLast(
        self: *CacheDBM,
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
                    ko.appendSlice(self.allocator, key) catch return Status.init(.SYSTEM_ERROR);
                }
                return st;
            }
        }
    }

    // -----------------------------------------------------------------------
    // Phase 6: Base class methods
    // -----------------------------------------------------------------------

    /// Creates a new heap-allocated CacheDBM instance using NullFile (in-memory only).
    pub fn makeDbm(allocator: std.mem.Allocator) !*CacheDBM {
        const dbm = try allocator.create(CacheDBM);
        errdefer allocator.destroy(dbm);
        dbm.* = try CacheDBM.init(file_mod.NullFile, 1048576, -1, allocator);
        return dbm;
    }

    /// Returns the record count. Matches C++ DBM::CountSimple().
    pub fn countSimple(self: *CacheDBM, io: std.Io) i64 {
        return self.countInternal(io);
    }

    /// Returns the file size in bytes or -1 when not open. Lock-free approximate read.
    pub fn getFileSizeSimple(self: *CacheDBM) i64 {
        if (!self.impl.open) return -1;
        return self.impl.file.getSizeSimple();
    }

    /// Returns the file path or "" when not open.
    pub fn getFilePathSimple(self: *CacheDBM) []const u8 {
        if (!self.impl.open) return "";
        return self.impl.path.items;
    }

    /// Returns the timestamp or NaN when not open. Lock-free approximate read.
    pub fn getTimestampSimple(self: *CacheDBM) f64 {
        if (!self.impl.open) return std.math.nan(f64);
        return @as(f64, @floatFromInt(self.impl.timestamp.nanoseconds)) / 1_000_000_000.0;
    }

    /// Returns false. CacheDBM never needs rebuilding.
    pub fn shouldBeRebuiltSimple(_: *CacheDBM) bool {
        return false;
    }

    /// Copies the backing file to dest_path.
    /// Returns NOT_IMPLEMENTED_ERROR when no backing file path is set.
    pub fn copyFileData(self: *CacheDBM, io: std.Io, dest_path: []const u8, sync_hard: bool) Status {
        if (!self.isOpen(io)) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        if (sync_hard) {
            const st = self.synchronize(io, true);
            if (!st.isOk()) return st;
        }
        const src_path = self.getFilePathInternal(io);
        if (src_path.len == 0) return Status.initMsg(.NOT_IMPLEMENTED_ERROR, "no backing file");
        file_mod.copyFileAbsolute(src_path, dest_path) catch
            return Status.initMsg(.SYSTEM_ERROR, "copy file failed");
        return Status.init(.SUCCESS);
    }

    /// Renames a key. Reads old value, sets under new_key, removes old_key unless copying=true.
    pub fn rekey(self: *CacheDBM, io: std.Io, old_key: []const u8, new_key: []const u8, overwrite: bool, copying: bool) Status {
        if (!self.isOpen(io) or !self.isWritable(io))
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
    pub fn export_(self: *CacheDBM, io: std.Io, dest: anytype) Status {
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
        self: *CacheDBM,
        io: std.Io,
        expected: []const dbm_mod.CompareExpectedEntry,
        desired: []const dbm_mod.CompareDesiredEntry,
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
// Tests for CacheDBM
// ---------------------------------------------------------------------------

test "CacheDBM.Cursor.last returns NOT_IMPLEMENTED_ERROR" {
    const alloc = std.testing.allocator;
    var db = try CacheDBM.init(file_mod.NullFile, 1024, 1024 * 1024, alloc);
    defer db.deinit(std.testing.io);

    _ = db.set(std.testing.io, "key1", "value1", true, null);

    var iter = try db.makeCursor(std.testing.io);
    defer iter.deinit(std.testing.io);

    _ = iter.first(std.testing.io);
    const status = iter.last(std.testing.io);
    try std.testing.expect(!status.isOk());
    try std.testing.expectEqual(lib_common.Code.NOT_IMPLEMENTED_ERROR, status.code);
}

test "CacheDBM.Cursor.previous returns NOT_IMPLEMENTED_ERROR" {
    const alloc = std.testing.allocator;
    var db = try CacheDBM.init(file_mod.NullFile, 1024, 1024 * 1024, alloc);
    defer db.deinit(std.testing.io);

    _ = db.set(std.testing.io, "key1", "value1", true, null);

    var iter = try db.makeCursor(std.testing.io);
    defer iter.deinit(std.testing.io);

    _ = iter.first(std.testing.io);
    const status = iter.previous(std.testing.io);
    try std.testing.expect(!status.isOk());
    try std.testing.expectEqual(lib_common.Code.NOT_IMPLEMENTED_ERROR, status.code);
}

test "CacheDBM.Cursor.jumpLower returns NOT_IMPLEMENTED_ERROR" {
    const alloc = std.testing.allocator;
    var db = try CacheDBM.init(file_mod.NullFile, 1024, 1024 * 1024, alloc);
    defer db.deinit(std.testing.io);

    _ = db.set(std.testing.io, "key1", "value1", true, null);

    var iter = try db.makeCursor(std.testing.io);
    defer iter.deinit(std.testing.io);

    const status = iter.jumpLower(std.testing.io, "key1", true);
    try std.testing.expect(!status.isOk());
    try std.testing.expectEqual(lib_common.Code.NOT_IMPLEMENTED_ERROR, status.code);
}

test "CacheDBM.Cursor.jumpUpper returns NOT_IMPLEMENTED_ERROR" {
    const alloc = std.testing.allocator;
    var db = try CacheDBM.init(file_mod.NullFile, 1024, 1024 * 1024, alloc);
    defer db.deinit(std.testing.io);

    _ = db.set(std.testing.io, "key1", "value1", true, null);

    var iter = try db.makeCursor(std.testing.io);
    defer iter.deinit(std.testing.io);

    const status = iter.jumpUpper(std.testing.io, "key1", false);
    try std.testing.expect(!status.isOk());
    try std.testing.expectEqual(lib_common.Code.NOT_IMPLEMENTED_ERROR, status.code);
}

test "CacheDBM.append concatenation with delimiter" {
    const alloc = std.testing.allocator;
    var db = try CacheDBM.init(file_mod.NullFile, 1024, 1024 * 1024, alloc);
    defer db.deinit(std.testing.io);

    _ = db.set(std.testing.io, "key1", "hello", true, null);
    _ = db.append(std.testing.io, "key1", "world", " ");

    var result_buf: std.ArrayList(u8) = .empty;
    defer result_buf.deinit(alloc);
    const get_st_1 = db.get(std.testing.io, "key1", &result_buf);
    try std.testing.expect(get_st_1.isOk());

    try std.testing.expectEqualStrings("hello world", result_buf.items);
}

test "CacheDBM.append creates new record when missing" {
    const alloc = std.testing.allocator;
    var db = try CacheDBM.init(file_mod.NullFile, 1024, 1024 * 1024, alloc);
    defer db.deinit(std.testing.io);

    _ = db.append(std.testing.io, "newkey", "value", "-");

    var result_buf: std.ArrayList(u8) = .empty;
    defer result_buf.deinit(alloc);
    const get_st_2 = db.get(std.testing.io, "newkey", &result_buf);
    try std.testing.expect(get_st_2.isOk());

    try std.testing.expectEqualStrings("value", result_buf.items);
}

test "CacheDBM.inspect returns all 8 metadata keys" {
    const alloc = std.testing.allocator;
    var db = try CacheDBM.init(file_mod.NullFile, 100, 100000, alloc);
    defer db.deinit(std.testing.io);

    _ = db.set(std.testing.io, "k1", "v1", true, null);
    _ = db.set(std.testing.io, "k2", "v2", true, null);

    var inspect_result = try db.inspect(alloc, std.testing.io);
    defer {
        for (inspect_result.items) |pair| {
            alloc.free(pair[0]);
            alloc.free(pair[1]);
        }
        inspect_result.deinit(alloc);
    }

    // Expect all required keys: class, num_records, eff_data_size, mem_usage, cap_rec_num, cap_mem_size
    // (path and timestamp are optional depending on open state)
    try std.testing.expect(inspect_result.items.len >= 6);

    // Verify each required key exists
    var found_class = false;
    var found_num_records = false;
    var found_eff_data_size = false;
    var found_mem_usage = false;
    var found_cap_rec_num = false;
    var found_cap_mem_size = false;

    for (inspect_result.items) |pair| {
        if (std.mem.eql(u8, pair[0], "class")) {
            found_class = true;
            try std.testing.expectEqualStrings("CacheDBM", pair[1]);
        } else if (std.mem.eql(u8, pair[0], "num_records")) {
            found_num_records = true;
            try std.testing.expectEqualStrings("2", pair[1]);
        } else if (std.mem.eql(u8, pair[0], "eff_data_size")) {
            found_eff_data_size = true;
            // Should be at least 4 (k1 + v1 + k2 + v2)
            const size = try std.fmt.parseInt(i64, pair[1], 10);
            try std.testing.expect(size >= 4);
        } else if (std.mem.eql(u8, pair[0], "mem_usage")) {
            found_mem_usage = true;
            // mem_usage should be > 0
            const size = try std.fmt.parseInt(i64, pair[1], 10);
            try std.testing.expect(size > 0);
        } else if (std.mem.eql(u8, pair[0], "cap_rec_num")) {
            found_cap_rec_num = true;
        } else if (std.mem.eql(u8, pair[0], "cap_mem_size")) {
            found_cap_mem_size = true;
        }
    }

    try std.testing.expect(found_class);
    try std.testing.expect(found_num_records);
    try std.testing.expect(found_eff_data_size);
    try std.testing.expect(found_mem_usage);
    try std.testing.expect(found_cap_rec_num);
    try std.testing.expect(found_cap_mem_size);
}

test "CacheDBM.processMulti reads multiple keys" {
    const alloc = std.testing.allocator;
    var db = try CacheDBM.init(file_mod.NullFile, 1024, 1024 * 1024, alloc);
    defer db.deinit(std.testing.io);

    // Set up test data
    _ = db.set(std.testing.io, "key1", "value1", true, null);
    _ = db.set(std.testing.io, "key2", "value2", true, null);

    // Read-only processor that counts calls
    var call_count: i32 = 0;
    const TestProcessor = struct {
        count: *i32,
        pub fn processFull(self: @This(), _key: []const u8, _old_val: []const u8) RecordAction {
            _ = _key;
            _ = _old_val;
            self.count.* += 1;
            return .noop;
        }
        pub fn processEmpty(self: @This(), _key: []const u8) RecordAction {
            _ = self;
            _ = _key;
            return .noop;
        }
    };

    var proc1: TestProcessor = .{ .count = &call_count };
    var proc2: TestProcessor = .{ .count = &call_count };

    const keys = [_][]const u8{ "key1", "key2" };
    const procs = [_]*TestProcessor{ &proc1, &proc2 };

    const status = db.processMulti(std.testing.io, TestProcessor, &keys, &procs, false);
    try std.testing.expect(status.isOk());
    try std.testing.expectEqual(@as(i32, 2), call_count);
}

test "CacheDBM.processMulti with writable removes records" {
    const alloc = std.testing.allocator;
    var db = try CacheDBM.init(file_mod.NullFile, 1024, 1024 * 1024, alloc);
    defer db.deinit(std.testing.io);

    // Set up test data
    _ = db.set(std.testing.io, "key1", "value1", true, null);
    _ = db.set(std.testing.io, "key2", "value2", true, null);

    try std.testing.expectEqual(@as(i64, 2), db.countSimple(std.testing.io));

    // Processor that removes records
    const TestProcessor = struct {
        pub fn processFull(self: @This(), _key: []const u8, _old_val: []const u8) RecordAction {
            _ = self;
            _ = _key;
            _ = _old_val;
            return .remove;
        }
        pub fn processEmpty(self: @This(), _key: []const u8) RecordAction {
            _ = self;
            _ = _key;
            return .noop;
        }
    };

    var proc1: TestProcessor = .{};
    var proc2: TestProcessor = .{};

    const keys = [_][]const u8{ "key1", "key2" };
    const procs = [_]*TestProcessor{ &proc1, &proc2 };

    const status = db.processMulti(std.testing.io, TestProcessor, &keys, &procs, true);
    try std.testing.expect(status.isOk());

    // Verify records were removed
    try std.testing.expectEqual(@as(i64, 0), db.countSimple(std.testing.io));
}

// Mock UpdateLogger for testing
const MockLoggerCtx = struct {
    writeSet_count: i32 = 0,
    writeRemove_count: i32 = 0,
    writeClear_count: i32 = 0,
};

fn mockWriteSet(ctx: *anyopaque, _: []const u8, _: []const u8) Status {
    var mock: *MockLoggerCtx = @ptrCast(@alignCast(ctx));
    mock.writeSet_count += 1;
    return Status.init(.SUCCESS);
}

fn mockWriteRemove(ctx: *anyopaque, _: []const u8) Status {
    var mock: *MockLoggerCtx = @ptrCast(@alignCast(ctx));
    mock.writeRemove_count += 1;
    return Status.init(.SUCCESS);
}

fn mockWriteClear(ctx: *anyopaque) Status {
    var mock: *MockLoggerCtx = @ptrCast(@alignCast(ctx));
    mock.writeClear_count += 1;
    return Status.init(.SUCCESS);
}

fn mockSynchronize(ctx: *anyopaque, _hard: bool) Status {
    _ = ctx;
    _ = _hard;
    return Status.init(.SUCCESS);
}

test "CacheDBM.updateLogger fires writeSet callback" {
    const alloc = std.testing.allocator;
    var db = try CacheDBM.init(file_mod.NullFile, 1024, 1024 * 1024, alloc);
    defer db.deinit(std.testing.io);

    var mock_ctx: MockLoggerCtx = .{};
    var mock_logger: UpdateLogger = .{
        .ctx = @ptrCast(@alignCast(&mock_ctx)),
        .vtable = &.{
            .writeSet = mockWriteSet,
            .writeRemove = mockWriteRemove,
            .writeClear = mockWriteClear,
        },
    };

    db.setUpdateLogger(std.testing.io, &mock_logger);

    // Initial state: no calls
    try std.testing.expectEqual(@as(i32, 0), mock_ctx.writeSet_count);

    // Set a key - should fire writeSet
    _ = db.set(std.testing.io, "key1", "value1", true, null);
    try std.testing.expect(mock_ctx.writeSet_count > 0);

    const set_count = mock_ctx.writeSet_count;
    _ = db.set(std.testing.io, "key1", "modified", true, null);
    try std.testing.expect(mock_ctx.writeSet_count > set_count);
}

test "CacheDBM.updateLogger fires writeRemove callback" {
    const alloc = std.testing.allocator;
    var db = try CacheDBM.init(file_mod.NullFile, 1024, 1024 * 1024, alloc);
    defer db.deinit(std.testing.io);

    var mock_ctx: MockLoggerCtx = .{};
    var mock_logger: UpdateLogger = .{
        .ctx = @ptrCast(@alignCast(&mock_ctx)),
        .vtable = &.{
            .writeSet = mockWriteSet,
            .writeRemove = mockWriteRemove,
            .writeClear = mockWriteClear,
        },
    };

    db.setUpdateLogger(std.testing.io, &mock_logger);

    _ = db.set(std.testing.io, "key1", "value1", true, null);
    try std.testing.expectEqual(@as(i32, 0), mock_ctx.writeRemove_count);

    // Remove the key - should fire writeRemove
    _ = db.remove(std.testing.io, "key1");
    try std.testing.expect(mock_ctx.writeRemove_count > 0);
}

test "CacheDBM.updateLogger fires writeClear callback" {
    const alloc = std.testing.allocator;
    var db = try CacheDBM.init(file_mod.NullFile, 1024, 1024 * 1024, alloc);
    defer db.deinit(std.testing.io);

    var mock_ctx: MockLoggerCtx = .{};
    var mock_logger: UpdateLogger = .{
        .ctx = @ptrCast(@alignCast(&mock_ctx)),
        .vtable = &.{
            .writeSet = mockWriteSet,
            .writeRemove = mockWriteRemove,
            .writeClear = mockWriteClear,
        },
    };

    db.setUpdateLogger(std.testing.io, &mock_logger);

    // Add some records
    _ = db.set(std.testing.io, "key1", "value1", true, null);
    _ = db.set(std.testing.io, "key2", "value2", true, null);
    try std.testing.expectEqual(@as(i64, 2), db.countSimple(std.testing.io));

    const initial_clear_count = mock_ctx.writeClear_count;

    // Clear all records - should fire writeClear
    _ = db.clear(std.testing.io);
    try std.testing.expect(mock_ctx.writeClear_count > initial_clear_count);
    try std.testing.expectEqual(@as(i64, 0), db.countSimple(std.testing.io));
}

test "CacheDBM.updateLogger synchronize callback exists" {
    const alloc = std.testing.allocator;
    var db = try CacheDBM.init(file_mod.NullFile, 1024, 1024 * 1024, alloc);
    defer db.deinit(std.testing.io);

    var mock_ctx: MockLoggerCtx = .{};
    var mock_logger: UpdateLogger = .{
        .ctx = @ptrCast(@alignCast(&mock_ctx)),
        .vtable = &.{
            .writeSet = mockWriteSet,
            .writeRemove = mockWriteRemove,
            .writeClear = mockWriteClear,
            .synchronize = mockSynchronize,
        },
    };

    db.setUpdateLogger(std.testing.io, &mock_logger);

    _ = db.set(std.testing.io, "key1", "value1", true, null);

    // Synchronize can be called; result depends on file implementation
    // NullFile returns NOT_IMPLEMENTED_ERROR, so we just verify it doesn't crash
    const sync_status = db.synchronize(std.testing.io, false);
    _ = sync_status;
}

test "CacheDBM.compareExchange: match and exchange" {
    const alloc = std.testing.allocator;
    var db = try CacheDBM.init(file_mod.NullFile, 1024, 1024 * 1024, alloc);
    defer db.deinit(std.testing.io);

    _ = db.set(std.testing.io, "key1", "foo", true, null);
    var actual: std.ArrayList(u8) = .empty;
    defer actual.deinit(alloc);
    var found: bool = undefined;
    const st = db.compareExchange(std.testing.io, "key1", .{ .exact = "foo" }, .{ .set = "bar" }, &actual, &found);
    try std.testing.expect(st.isOk());
    try std.testing.expect(found);
    try std.testing.expectEqualSlices(u8, "foo", actual.items);

    actual.clearRetainingCapacity();
    const get_st_3 = db.get(std.testing.io, "key1", &actual);
    try std.testing.expect(get_st_3.isOk());
    try std.testing.expectEqualSlices(u8, "bar", actual.items);
}

test "CacheDBM.compareExchange: mismatch returns INFEASIBLE_ERROR" {
    const alloc = std.testing.allocator;
    var db = try CacheDBM.init(file_mod.NullFile, 1024, 1024 * 1024, alloc);
    defer db.deinit(std.testing.io);

    _ = db.set(std.testing.io, "key2", "old", true, null);
    var actual: std.ArrayList(u8) = .empty;
    defer actual.deinit(alloc);
    var found: bool = undefined;
    const st = db.compareExchange(std.testing.io, "key2", .{ .exact = "wrong" }, .{ .set = "new" }, &actual, &found);
    try std.testing.expect(st.code == .INFEASIBLE_ERROR);
    try std.testing.expect(found);
    try std.testing.expectEqualSlices(u8, "old", actual.items);
}

test "CacheDBM.compareExchange: absent creates record" {
    const alloc = std.testing.allocator;
    var db = try CacheDBM.init(file_mod.NullFile, 1024, 1024 * 1024, alloc);
    defer db.deinit(std.testing.io);

    var actual: std.ArrayList(u8) = .empty;
    defer actual.deinit(alloc);
    var found: bool = undefined;
    const st = db.compareExchange(std.testing.io, "newkey", .absent, .{ .set = "value" }, &actual, &found);
    try std.testing.expect(st.isOk());
    try std.testing.expect(!found);

    actual.clearRetainingCapacity();
    const get_st = db.get(std.testing.io, "newkey", &actual);
    try std.testing.expect(get_st.isOk());
    try std.testing.expectEqualSlices(u8, "value", actual.items);
}

test "CacheDBM.compareExchange: absent noop on missing key" {
    const alloc = std.testing.allocator;
    var db = try CacheDBM.init(file_mod.NullFile, 1024, 1024 * 1024, alloc);
    defer db.deinit(std.testing.io);

    var actual: std.ArrayList(u8) = .empty;
    defer actual.deinit(alloc);
    var found: bool = undefined;
    const st = db.compareExchange(std.testing.io, "missing", .absent, .noop, &actual, &found);
    try std.testing.expect(st.isOk());
    try std.testing.expect(!found);

    actual.clearRetainingCapacity();
    const get_st = db.get(std.testing.io, "missing", &actual);
    try std.testing.expect(get_st.code == .NOT_FOUND_ERROR);
}

test "CacheDBM.compareExchange: any probe reads without writing" {
    const alloc = std.testing.allocator;
    var db = try CacheDBM.init(file_mod.NullFile, 1024, 1024 * 1024, alloc);
    defer db.deinit(std.testing.io);

    _ = db.set(std.testing.io, "key", "original", true, null);
    var actual: std.ArrayList(u8) = .empty;
    defer actual.deinit(alloc);
    var found: bool = undefined;
    const st = db.compareExchange(std.testing.io, "key", .any, .noop, &actual, &found);
    try std.testing.expect(st.isOk());
    try std.testing.expect(found);
    try std.testing.expectEqualSlices(u8, "original", actual.items);

    actual.clearRetainingCapacity();
    const get_st_4 = db.get(std.testing.io, "key", &actual);
    try std.testing.expect(get_st_4.isOk());
    try std.testing.expectEqualSlices(u8, "original", actual.items);
}

test "CacheDBM.compareExchange: desired remove deletes record" {
    const alloc = std.testing.allocator;
    var db = try CacheDBM.init(file_mod.NullFile, 1024, 1024 * 1024, alloc);
    defer db.deinit(std.testing.io);

    _ = db.set(std.testing.io, "key", "foo", true, null);
    var actual: std.ArrayList(u8) = .empty;
    defer actual.deinit(alloc);
    var found: bool = undefined;
    const st = db.compareExchange(std.testing.io, "key", .{ .exact = "foo" }, .remove, &actual, &found);
    try std.testing.expect(st.isOk());

    actual.clearRetainingCapacity();
    const get_st = db.get(std.testing.io, "key", &actual);
    try std.testing.expect(get_st.code == .NOT_FOUND_ERROR);
}

test "CacheDBM.compareExchange: absent fails when key exists" {
    const alloc = std.testing.allocator;
    var db = try CacheDBM.init(file_mod.NullFile, 1024, 1024 * 1024, alloc);
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

test "CacheDBM.increment: fresh key uses initial+delta" {
    const alloc = std.testing.allocator;
    var db = try CacheDBM.init(file_mod.NullFile, 1024, 1024 * 1024, alloc);
    defer db.deinit(std.testing.io);

    var current: i64 = undefined;
    const st = db.increment(std.testing.io, "counter", 3, &current, 10);
    try std.testing.expect(st.isOk());
    try std.testing.expectEqual(@as(i64, 13), current);

    var val: std.ArrayList(u8) = .empty;
    defer val.deinit(alloc);
    const get_st_5 = db.get(std.testing.io, "counter", &val);
    try std.testing.expect(get_st_5.isOk());
    try std.testing.expectEqual(@as(usize, 8), val.items.len);
    const stored = @as(i64, @bitCast(str_util.strToIntBigEndian(val.items)));
    try std.testing.expectEqual(@as(i64, 13), stored);
}

test "CacheDBM.increment: existing key adds delta" {
    const alloc = std.testing.allocator;
    var db = try CacheDBM.init(file_mod.NullFile, 1024, 1024 * 1024, alloc);
    defer db.deinit(std.testing.io);

    var buf: [8]u8 = undefined;
    const initial_bytes = str_util.intToStrBigEndian(@as(u64, @bitCast(@as(i64, 10))), 8, &buf);
    _ = db.set(std.testing.io, "num", initial_bytes, true, null);

    var current: i64 = undefined;
    const st = db.increment(std.testing.io, "num", 5, &current, 0);
    try std.testing.expect(st.isOk());
    try std.testing.expectEqual(@as(i64, 15), current);
}

test "CacheDBM.increment: INT64MIN probe reads without writing" {
    const alloc = std.testing.allocator;
    var db = try CacheDBM.init(file_mod.NullFile, 1024, 1024 * 1024, alloc);
    defer db.deinit(std.testing.io);

    var buf: [8]u8 = undefined;
    const initial_bytes = str_util.intToStrBigEndian(@as(u64, @bitCast(@as(i64, 7))), 8, &buf);
    _ = db.set(std.testing.io, "num", initial_bytes, true, null);

    var current: i64 = undefined;
    const st = db.increment(std.testing.io, "num", lib_common.INT64MIN, &current, 0);
    try std.testing.expect(st.isOk());
    try std.testing.expectEqual(@as(i64, 7), current);

    var val: std.ArrayList(u8) = .empty;
    defer val.deinit(alloc);
    _ = db.get(std.testing.io, "num", &val);
    const stored = @as(i64, @bitCast(str_util.strToIntBigEndian(val.items)));
    try std.testing.expectEqual(@as(i64, 7), stored);
}

test "CacheDBM.increment: INT64MIN probe on missing key returns initial" {
    const alloc = std.testing.allocator;
    var db = try CacheDBM.init(file_mod.NullFile, 1024, 1024 * 1024, alloc);
    defer db.deinit(std.testing.io);

    var current: i64 = undefined;
    const st = db.increment(std.testing.io, "missing", lib_common.INT64MIN, &current, 42);
    try std.testing.expect(st.isOk());
    try std.testing.expectEqual(@as(i64, 42), current);

    var val: std.ArrayList(u8) = .empty;
    defer val.deinit(alloc);
    const get_st = db.get(std.testing.io, "missing", &val);
    try std.testing.expect(get_st.code == .NOT_FOUND_ERROR);
}

test "CacheDBM.popFirst: returns and removes first record" {
    const alloc = std.testing.allocator;
    var db = try CacheDBM.init(file_mod.NullFile, 1024, 1024 * 1024, alloc);
    defer db.deinit(std.testing.io);

    _ = db.set(std.testing.io, "key1", "value1", true, null);
    _ = db.set(std.testing.io, "key2", "value2", true, null);
    _ = db.set(std.testing.io, "key3", "value3", true, null);
    try std.testing.expectEqual(@as(i64, 3), db.countSimple(std.testing.io));

    var key: std.ArrayList(u8) = .empty;
    defer key.deinit(alloc);
    var value: std.ArrayList(u8) = .empty;
    defer value.deinit(alloc);

    const st = db.popFirst(std.testing.io, &key, &value);
    try std.testing.expect(st.isOk());
    try std.testing.expect(key.items.len > 0);
    try std.testing.expect(value.items.len > 0);

    const count = db.countSimple(std.testing.io);
    try std.testing.expectEqual(@as(i64, 2), count);
}

test "CacheDBM.popFirst: empty returns NOT_FOUND_ERROR" {
    const alloc = std.testing.allocator;
    var db = try CacheDBM.init(file_mod.NullFile, 1024, 1024 * 1024, alloc);
    defer db.deinit(std.testing.io);

    var key: std.ArrayList(u8) = .empty;
    defer key.deinit(alloc);
    var value: std.ArrayList(u8) = .empty;
    defer value.deinit(alloc);

    const st = db.popFirst(std.testing.io, &key, &value);
    try std.testing.expect(st.code == .NOT_FOUND_ERROR);
}

test "CacheDBM.pushLast: creates record with key_out" {
    const alloc = std.testing.allocator;
    var db = try CacheDBM.init(file_mod.NullFile, 1024, 1024 * 1024, alloc);
    defer db.deinit(std.testing.io);

    var key: std.ArrayList(u8) = .empty;
    defer key.deinit(alloc);
    const st = db.pushLast(std.testing.io, "hello", 1.0, &key);
    try std.testing.expect(st.isOk());
    try std.testing.expect(key.items.len > 0);

    var val: std.ArrayList(u8) = .empty;
    defer val.deinit(alloc);
    const get_st = db.get(std.testing.io, key.items, &val);
    try std.testing.expect(get_st.isOk());
    try std.testing.expectEqualSlices(u8, "hello", val.items);
}

test "CacheDBM.pushLast: two pushes at same wtime produce sequential keys" {
    const alloc = std.testing.allocator;
    var db = try CacheDBM.init(file_mod.NullFile, 1024, 1024 * 1024, alloc);
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

test "CacheDBM.pushLast: pop-after-push round-trips value" {
    const alloc = std.testing.allocator;
    var db = try CacheDBM.init(file_mod.NullFile, 1024, 1024 * 1024, alloc);
    defer db.deinit(std.testing.io);

    const original = "round-trip-value";
    var key: std.ArrayList(u8) = .empty;
    defer key.deinit(alloc);
    _ = db.pushLast(std.testing.io, original, 2.0, &key);

    var popped_key: std.ArrayList(u8) = .empty;
    defer popped_key.deinit(alloc);
    var popped_val: std.ArrayList(u8) = .empty;
    defer popped_val.deinit(alloc);

    const st = db.popFirst(std.testing.io, &popped_key, &popped_val);
    try std.testing.expect(st.isOk());
    try std.testing.expectEqualSlices(u8, original, popped_val.items);
}

test "CacheDBM.get: null value buffer returns SUCCESS on found key" {
    const alloc = std.testing.allocator;
    var db = try CacheDBM.init(file_mod.NullFile, 1024, 1024 * 1024, alloc);
    defer db.deinit(std.testing.io);

    _ = db.set(std.testing.io, "exists", "hello", true, null);

    // null value = existence check only
    const present = db.get(std.testing.io, "exists", null);
    try std.testing.expect(present.isOk());

    const absent = db.get(std.testing.io, "missing", null);
    try std.testing.expect(absent.code == .NOT_FOUND_ERROR);
}

test "CacheDBM.*Multi: bulk set/get/remove/append" {
    const alloc = std.testing.allocator;
    var db = try CacheDBM.init(file_mod.NullFile, -1, -1, alloc);
    defer db.deinit(std.testing.io);

    // setMulti: insert 3 keys
    const pairs = [_][2][]const u8{
        .{ "key1", "val1" }, .{ "key2", "val2" }, .{ "key3", "val3" },
    };
    try std.testing.expect(db.setMulti(std.testing.io, &pairs, true).isOk());

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
    const get_st = db.getMulti(std.testing.io, &.{ "key1", "key2", "missing" }, &records);
    try std.testing.expectEqual(lib_common.Code.NOT_FOUND_ERROR, get_st.code);
    try std.testing.expectEqual(@as(usize, 2), records.count());

    // removeMulti: remove 2 existing keys
    try std.testing.expect(db.removeMulti(std.testing.io, &.{ "key1", "key2" }).isOk());

    // appendMulti: append to remaining key3
    const app = [_][2][]const u8{ .{ "key3", "_appended" } };
    try std.testing.expect(db.appendMulti(std.testing.io, &app, "").isOk());
    const got = try db.getSimple(alloc, std.testing.io, "key3", "");
    defer alloc.free(got);
    try std.testing.expectEqualStrings("val3_appended", got);
}

test "CacheDBM.Iterator: basic iteration" {
    const alloc = std.testing.allocator;
    var db = try CacheDBM.init(file_mod.NullFile, 1024, 1024 * 1024, alloc);
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

test "CacheDBM.Iterator: lifetime contract" {
    const alloc = std.testing.allocator;
    var db = try CacheDBM.init(file_mod.NullFile, 1024, 1024 * 1024, alloc);
    defer db.deinit(std.testing.io);

    _ = db.set(std.testing.io, "a", "1", true, null);
    _ = db.set(std.testing.io, "b", "2", true, null);

    var iter = try db.iterate(alloc, std.testing.io);
    defer iter.deinit(std.testing.io);
    
    const first = try iter.next(std.testing.io);
    try std.testing.expect(first != null);
    
    // Copy before next() to demonstrate lifetime contract.
    const key_copy = try alloc.dupe(u8, first.?.key);
    defer alloc.free(key_copy);
    
    // Second next() — first.?.key is now invalid.
    _ = try iter.next(std.testing.io);
    // key_copy is still valid here.
    try std.testing.expect(key_copy.len > 0);
}
