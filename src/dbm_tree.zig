/// TreeDBM — file-backed B+ tree database.
///
/// Physical storage is delegated to an embedded HashDBM whose records hold
/// serialized tree nodes (key = 6-byte big-endian node ID, value = node body).
/// Tree structural metadata lives in the HashDBM's 64-byte opaque_metadata field.
const std = @import("std");
const lib_common = @import("lib_common.zig");
const varint = @import("varint.zig");
const thread_util = @import("thread_util.zig");
const str_util = @import("str_util.zig");
const time_util = @import("time_util.zig");
const dbm = @import("dbm.zig");
const file_mod = @import("file.zig");
const dbm_hash = @import("dbm_hash.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;
const AutoHashMap = std.AutoHashMapUnmanaged;
const SpinSharedMutex = thread_util.SpinSharedMutex;
const Status = lib_common.Status;
const Code = lib_common.Code;
const KeyComparator = lib_common.KeyComparator;
const RecordAction = dbm.RecordAction;
const UpdateLogger = dbm.UpdateLogger;
const File = file_mod.File;
const OpenOptions = file_mod.OpenOptions;
const HashDBM = dbm_hash.HashDBM;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Width in bytes of serialized node IDs.
const PAGE_ID_WIDTH: usize = 6;

/// First valid leaf node ID.
const LEAF_NODE_ID_BASE: i64 = 1;

/// First valid inner node ID (upper quarter of 48-bit space).
const INNER_NODE_ID_BASE: i64 = (@as(i64, 1) << (8 * PAGE_ID_WIDTH - 2)) * 3; // 211106232532992

/// Number of cache/lock slots.
const NUM_PAGE_SLOTS: usize = 64;

/// Stack buffer size for serializing nodes before writing to HashDBM.
const WRITE_BUFFER_SIZE: usize = 16384;

/// Maximum depth of the B+ tree during traversal.
const TREE_LEVEL_MAX: usize = 32;

/// Stack buffer size for iterator key storage.
const ITER_BUFFER_SIZE: usize = 128;

/// Inverse frequency of cache-adjustment calls inside processImpl.
const ADJUST_CACHES_INV_FREQ: u32 = 4;

/// Fraction of cached pages allocated to inner nodes.
const INNER_PAGE_CACHE_RATIO: f64 = 0.25;

// Opaque metadata field offsets (within HashDBM's 64-byte opaque_metadata).
const META_MAGIC: []const u8 = "TDB";
const META_OFFSET_NUM_RECORDS: usize = 4;
const META_OFFSET_EFF_DATA_SIZE: usize = 10;
const META_OFFSET_ROOT_ID: usize = 16;
const META_OFFSET_FIRST_ID: usize = 22;
const META_OFFSET_LAST_ID: usize = 28;
const META_OFFSET_NUM_LEAF_NODES: usize = 34;
const META_OFFSET_NUM_INNER_NODES: usize = 40;
const META_OFFSET_MAX_PAGE_SIZE: usize = 46;
const META_OFFSET_MAX_BRANCHES: usize = 49;
const META_OFFSET_TREE_LEVEL: usize = 52;
const META_OFFSET_KEY_COMPARATOR: usize = 53;
const META_OFFSET_OPAQUE: usize = 54;

/// Number of user-visible opaque bytes at the end of tree metadata.
pub const OPAQUE_METADATA_SIZE: usize = 10;

// Public tuning-parameter defaults — match C++ TreeDBM static constexpr values.
pub const DEFAULT_OFFSET_WIDTH: i32 = 4;
pub const DEFAULT_ALIGN_POW: i32 = 10;
pub const DEFAULT_NUM_BUCKETS: i64 = 131101;
pub const DEFAULT_FBP_CAPACITY: i32 = 2048;
pub const DEFAULT_MAX_PAGE_SIZE: i32 = 8130;
pub const DEFAULT_MAX_BRANCHES: i32 = 256;
pub const DEFAULT_MAX_CACHED_PAGES: i32 = 10000;

// ---------------------------------------------------------------------------
// Key-comparator type codes (stored in metadata byte 53).
// ---------------------------------------------------------------------------
const KC_LEXICAL: u8 = 1;
const KC_LEXICAL_CASE: u8 = 2;
const KC_DECIMAL: u8 = 3;
const KC_HEXADECIMAL: u8 = 4;
const KC_REAL_NUMBER: u8 = 5;
const KC_SIGNED_BIG_ENDIAN: u8 = 6;
const KC_FLOAT_BIG_ENDIAN: u8 = 7;
const KC_PAIR_LEXICAL: u8 = 101;
const KC_PAIR_LEXICAL_CASE: u8 = 102;
const KC_PAIR_DECIMAL: u8 = 103;
const KC_PAIR_HEXADECIMAL: u8 = 104;
const KC_PAIR_REAL_NUMBER: u8 = 105;
const KC_PAIR_SIGNED_BIG_ENDIAN: u8 = 106;
const KC_PAIR_FLOAT_BIG_ENDIAN: u8 = 107;
const KC_CUSTOM: u8 = 255;

// ---------------------------------------------------------------------------
// Helper: big-endian fixed-width integer read/write
// ---------------------------------------------------------------------------

/// Write `value` into `buf[0..width]` as a big-endian unsigned integer.
/// Negative values are stored as their two's-complement bit pattern.
fn writeFixNum(buf: []u8, value: i64, width: usize) void {
    var v: u64 = @bitCast(value);
    var i: usize = width;
    while (i > 0) {
        i -= 1;
        buf[i] = @intCast(v & 0xFF);
        v >>= 8;
    }
}

/// Read a big-endian unsigned integer from `buf[0..width]` and return as i64.
fn readFixNum(buf: []const u8, width: usize) i64 {
    var v: u64 = 0;
    for (buf[0..width]) |byte| {
        v = (v << 8) | byte;
    }
    return @bitCast(v);
}

// ---------------------------------------------------------------------------
// PageUpdateMode
// ---------------------------------------------------------------------------

pub const PageUpdateMode = enum(i32) {
    /// Use the HashDBM's default update mode.
    default = 0,
    /// Never update on-disk pages immediately (deferred to flush).
    none = 1,
    /// Always write pages through to the HashDBM immediately.
    write = 2,
};

// ---------------------------------------------------------------------------
// TuningParameters
// ---------------------------------------------------------------------------

/// Tuning parameters for TreeDBM. Mirrors C++ TreeDBM::TuningParameters which
/// inherits from HashDBM::TuningParameters. The HashDBM-derived fields control
/// the underlying hash-file storage layer; the remaining fields control the B+ tree.
pub const TuningParameters = struct {
    // --- HashDBM base fields (passed to the underlying HashDBM.openAdvanced) ---
    update_mode: HashDBM.UpdateMode = .default,
    record_crc_mode: HashDBM.RecordCRCMode = .default,
    record_comp_mode: HashDBM.RecordCompressionMode = .default,
    offset_width: i32 = DEFAULT_OFFSET_WIDTH,
    align_pow: i32 = DEFAULT_ALIGN_POW,
    num_buckets: i64 = DEFAULT_NUM_BUCKETS,
    restore_mode: i32 = 0,
    fbp_capacity: i32 = -1,
    min_read_size: i32 = -1,
    cache_buckets: i32 = -1,
    cipher_key: []const u8 = "",
    // --- TreeDBM-specific fields ---
    /// Maximum serialized byte size of a leaf node's records section.
    max_page_size: i32 = DEFAULT_MAX_PAGE_SIZE,
    /// Maximum number of child links in an inner node.
    max_branches: i32 = DEFAULT_MAX_BRANCHES,
    /// Maximum total number of pages cached in memory.
    max_cached_pages: i32 = DEFAULT_MAX_CACHED_PAGES,
    /// Page update strategy.
    page_update_mode: PageUpdateMode = .default,
    /// Key comparator function (null = use existing/default lexicographic).
    key_comparator: ?KeyComparator = null,
};

// ---------------------------------------------------------------------------
// TreeRecord — a single leaf record
// ---------------------------------------------------------------------------

const TreeRecord = struct {
    key: []u8,
    value: []u8,

    fn create(key: []const u8, value: []const u8, alloc: Allocator) !*TreeRecord {
        const self = try alloc.create(TreeRecord);
        self.key = try alloc.dupe(u8, key);
        self.value = try alloc.dupe(u8, value);
        return self;
    }

    fn deinit(self: *TreeRecord, alloc: Allocator) void {
        alloc.free(self.key);
        alloc.free(self.value);
        alloc.destroy(self);
    }

    fn modifyValue(self: *TreeRecord, new_value: []const u8, alloc: Allocator) !void {
        alloc.free(self.value);
        self.value = try alloc.dupe(u8, new_value);
    }

    fn getSerializedSize(self: *const TreeRecord) usize {
        return varint.sizeVarNum(self.key.len) + self.key.len +
            varint.sizeVarNum(self.value.len) + self.value.len;
    }
};

// ---------------------------------------------------------------------------
// TreeLink — a separator key + child pointer in an inner node
// ---------------------------------------------------------------------------

const TreeLink = struct {
    key: []u8,
    child: i64,

    fn create(key: []const u8, child: i64, alloc: Allocator) !*TreeLink {
        const self = try alloc.create(TreeLink);
        self.key = try alloc.dupe(u8, key);
        self.child = child;
        return self;
    }

    fn deinit(self: *TreeLink, alloc: Allocator) void {
        alloc.free(self.key);
        alloc.destroy(self);
    }

    fn getSerializedSize(self: *const TreeLink) usize {
        return varint.sizeVarNum(self.key.len) + self.key.len + PAGE_ID_WIDTH;
    }
};

// ---------------------------------------------------------------------------
// SimpleCache(T) — per-slot LRU cache
// ---------------------------------------------------------------------------

fn SimpleCache(comptime T: type) type {
    return struct {
        const Self = @This();

        map: AutoHashMap(i64, *T),
        /// LRU order: index 0 = least recently used.
        lru: ArrayList(i64),
        capacity: usize,

        fn init(capacity: usize) Self {
            return .{
                .map = .{},
                .lru = .empty,
                .capacity = capacity,
            };
        }

        fn deinit(self: *Self, alloc: Allocator) void {
            self.map.deinit(alloc);
            self.lru.deinit(alloc);
        }

        fn get(self: *Self, id: i64, promote: bool) ?*T {
            if (self.map.get(id) == null) return null;
            if (promote) {
                // Move to end (MRU position).
                for (self.lru.items, 0..) |lid, i| {
                    if (lid == id) {
                        _ = self.lru.orderedRemove(i);
                        self.lru.appendAssumeCapacity(id);
                        break;
                    }
                }
            }
            return self.map.get(id);
        }

        /// Insert node into cache. Caller guarantees `id` is not already present.
        fn add(self: *Self, id: i64, node: *T, alloc: Allocator) !void {
            try self.map.put(alloc, id, node);
            try self.lru.append(alloc, id);
        }

        fn remove(self: *Self, id: i64, alloc: Allocator) ?*T {
            const node = self.map.fetchRemove(id) orelse return null;
            for (self.lru.items, 0..) |lid, i| {
                if (lid == id) {
                    _ = self.lru.orderedRemove(i);
                    break;
                }
            }
            _ = alloc;
            return node.value;
        }

        /// Remove and return the least-recently-used node without freeing it.
        fn removeLRU(self: *Self, alloc: Allocator) ?*T {
            if (self.lru.items.len == 0) return null;
            const id = self.lru.orderedRemove(0);
            const entry = self.map.fetchRemove(id) orelse return null;
            _ = alloc;
            return entry.value;
        }

        fn isSaturated(self: *const Self) bool {
            return self.map.count() >= self.capacity;
        }

        fn count(self: *const Self) usize {
            return self.map.count();
        }
    };
}

// ---------------------------------------------------------------------------
// TreeLeafNode
// ---------------------------------------------------------------------------

const TreeLeafNode = struct {
    id: i64,
    prev_id: i64,
    next_id: i64,
    /// Sorted records; owned by this node.
    records: ArrayList(*TreeRecord),
    /// Serialized byte size of the records portion (excludes 12-byte header).
    page_size: i32,
    dirty: bool,
    on_disk: bool,
    ref_count: std.atomic.Value(i32),
    mutex: SpinSharedMutex,
    allocator: Allocator,

    fn deinit(self: *TreeLeafNode) void {
        for (self.records.items) |rec| rec.deinit(self.allocator);
        self.records.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

// ---------------------------------------------------------------------------
// TreeInnerNode
// ---------------------------------------------------------------------------

const TreeInnerNode = struct {
    id: i64,
    /// ID of the leftmost child (not covered by any link key).
    heir_id: i64,
    /// Sorted separator links; owned by this node.
    links: ArrayList(*TreeLink),
    dirty: bool,
    on_disk: bool,
    ref_count: std.atomic.Value(i32),
    allocator: Allocator,

    fn deinit(self: *TreeInnerNode) void {
        for (self.links.items) |lnk| lnk.deinit(self.allocator);
        self.links.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

// ---------------------------------------------------------------------------
// Slot structures
// ---------------------------------------------------------------------------

const LeafSlot = struct {
    cache: SimpleCache(TreeLeafNode),
    mutex: SpinSharedMutex,
};

const InnerSlot = struct {
    cache: SimpleCache(TreeInnerNode),
    mutex: SpinSharedMutex,
};

// ---------------------------------------------------------------------------
// TreeDBMIteratorImpl — forward declaration (referenced by TreeDBMImpl)
// ---------------------------------------------------------------------------

const TreeDBMIteratorImpl = struct {
    dbm_impl: ?*TreeDBMImpl,
    /// Short-key stack buffer.
    key_buf: [ITER_BUFFER_SIZE]u8,
    /// Heap buffer for keys longer than ITER_BUFFER_SIZE (owned).
    key_heap: ?[]u8,
    key_size: usize,
    leaf_id: i64,
    allocator: Allocator,

    fn keySlice(self: *const TreeDBMIteratorImpl) ?[]const u8 {
        if (self.leaf_id == 0) return null;
        if (self.key_heap) |h| return h[0..self.key_size];
        return self.key_buf[0..self.key_size];
    }

    fn setPosition(self: *TreeDBMIteratorImpl, leaf_id: i64, key: []const u8) !void {
        self.leaf_id = leaf_id;
        self.key_size = key.len;
        if (key.len <= ITER_BUFFER_SIZE) {
            if (self.key_heap) |h| {
                self.allocator.free(h);
                self.key_heap = null;
            }
            @memcpy(self.key_buf[0..key.len], key);
        } else {
            if (self.key_heap == null or self.key_heap.?.len < key.len) {
                if (self.key_heap) |h| self.allocator.free(h);
                self.key_heap = try self.allocator.alloc(u8, key.len);
            }
            @memcpy(self.key_heap.?[0..key.len], key);
        }
    }

    fn clearPosition(self: *TreeDBMIteratorImpl) void {
        self.leaf_id = 0;
        self.key_size = 0;
        if (self.key_heap) |h| {
            self.allocator.free(h);
            self.key_heap = null;
        }
    }

    fn deinit(self: *TreeDBMIteratorImpl) void {
        if (self.key_heap) |h| self.allocator.free(h);
        self.allocator.destroy(self);
    }
};

// ---------------------------------------------------------------------------
// TreeDBMImpl
// ---------------------------------------------------------------------------

const TreeDBMImpl = struct {
    allocator: Allocator,
    hash_dbm: *HashDBM,
    open: bool,
    writable: bool,
    healthy: bool,
    auto_restored: bool,
    path: ArrayList(u8),
    num_records: std.atomic.Value(i64),
    eff_data_size: std.atomic.Value(i64),
    root_id: i64,
    first_id: i64,
    last_id: i64,
    num_leaf_nodes: i64,
    num_inner_nodes: i64,
    tree_level: i32,
    max_page_size: i32,
    max_branches: i32,
    max_cached_pages: i32,
    page_update_mode: PageUpdateMode,
    key_comparator: KeyComparator,
    update_logger: ?*UpdateLogger,
    mini_opaque: ArrayList(u8),
    /// Leaf IDs queued for divide/merge; value = first key snapshot.
    reorg_ids: AutoHashMap(i64, ArrayList(u8)),
    iterators: ArrayList(*TreeDBMIteratorImpl),
    leaf_slots: [NUM_PAGE_SLOTS]LeafSlot,
    inner_slots: [NUM_PAGE_SLOTS]InnerSlot,
    proc_clock: std.atomic.Value(u32),
    mutex: SpinSharedMutex,

    fn leafSlotIndex(id: i64) usize {
        return @intCast(@mod(id, NUM_PAGE_SLOTS));
    }

    fn innerSlotIndex(id: i64) usize {
        return @intCast(@mod(id - INNER_NODE_ID_BASE, NUM_PAGE_SLOTS));
    }

    fn serializeLeafNode(self: *TreeDBMImpl, node: *const TreeLeafNode, buf: *ArrayList(u8)) !void {
        buf.clearRetainingCapacity();
        var id_buf: [PAGE_ID_WIDTH]u8 = undefined;
        writeFixNum(&id_buf, node.prev_id, PAGE_ID_WIDTH);
        try buf.appendSlice(self.allocator, &id_buf);
        writeFixNum(&id_buf, node.next_id, PAGE_ID_WIDTH);
        try buf.appendSlice(self.allocator, &id_buf);
        for (node.records.items) |rec| {
            var vbuf: [16]u8 = undefined;
            const kl = varint.writeVarNum(&vbuf, rec.key.len);
            try buf.appendSlice(self.allocator, vbuf[0..kl]);
            try buf.appendSlice(self.allocator, rec.key);
            const vl = varint.writeVarNum(&vbuf, rec.value.len);
            try buf.appendSlice(self.allocator, vbuf[0..vl]);
            try buf.appendSlice(self.allocator, rec.value);
        }
    }

    fn deserializeLeafNode(self: *TreeDBMImpl, id: i64, data: []const u8) !*TreeLeafNode {
        const node = try self.allocator.create(TreeLeafNode);
        node.* = .{
            .id = id,
            .prev_id = 0,
            .next_id = 0,
            .records = .empty,
            .page_size = 0,
            .dirty = false,
            .on_disk = true,
            .ref_count = std.atomic.Value(i32).init(0),
            .mutex = SpinSharedMutex{},
            .allocator = self.allocator,
        };
        errdefer node.deinit();
        if (data.len < PAGE_ID_WIDTH * 2) return node;
        node.prev_id = readFixNum(data[0..PAGE_ID_WIDTH], PAGE_ID_WIDTH);
        node.next_id = readFixNum(data[PAGE_ID_WIDTH .. PAGE_ID_WIDTH * 2], PAGE_ID_WIDTH);
        var pos: usize = PAGE_ID_WIDTH * 2;
        var page_size: i32 = 0;
        while (pos < data.len) {
            var key_len: u64 = 0;
            const kl_bytes = varint.readVarNum(data[pos..], &key_len);
            if (kl_bytes == 0) break;
            pos += kl_bytes;
            if (pos + key_len > data.len) break;
            const key = data[pos .. pos + key_len];
            pos += key_len;
            var val_len: u64 = 0;
            const vl_bytes = varint.readVarNum(data[pos..], &val_len);
            if (vl_bytes == 0) break;
            pos += vl_bytes;
            if (pos + val_len > data.len) break;
            const val = data[pos .. pos + val_len];
            pos += val_len;
            const rec = try TreeRecord.create(key, val, self.allocator);
            errdefer rec.deinit(self.allocator);
            try node.records.append(self.allocator, rec);
            page_size += @intCast(varint.sizeVarNum(key_len) + key_len + varint.sizeVarNum(val_len) + val_len);
        }
        node.page_size = page_size;
        return node;
    }

    fn serializeInnerNode(self: *TreeDBMImpl, node: *const TreeInnerNode, buf: *ArrayList(u8)) !void {
        buf.clearRetainingCapacity();
        var id_buf: [PAGE_ID_WIDTH]u8 = undefined;
        writeFixNum(&id_buf, node.heir_id, PAGE_ID_WIDTH);
        try buf.appendSlice(self.allocator, &id_buf);
        for (node.links.items) |lnk| {
            var vbuf: [16]u8 = undefined;
            const kl = varint.writeVarNum(&vbuf, lnk.key.len);
            try buf.appendSlice(self.allocator, vbuf[0..kl]);
            try buf.appendSlice(self.allocator, lnk.key);
            writeFixNum(&id_buf, lnk.child, PAGE_ID_WIDTH);
            try buf.appendSlice(self.allocator, &id_buf);
        }
    }

    fn deserializeInnerNode(self: *TreeDBMImpl, id: i64, data: []const u8) !*TreeInnerNode {
        const node = try self.allocator.create(TreeInnerNode);
        node.* = .{
            .id = id,
            .heir_id = 0,
            .links = .empty,
            .dirty = false,
            .on_disk = true,
            .ref_count = std.atomic.Value(i32).init(0),
            .allocator = self.allocator,
        };
        errdefer node.deinit();
        if (data.len < PAGE_ID_WIDTH) return node;
        node.heir_id = readFixNum(data[0..PAGE_ID_WIDTH], PAGE_ID_WIDTH);
        var pos: usize = PAGE_ID_WIDTH;
        while (pos < data.len) {
            var key_len: u64 = 0;
            const kl_bytes = varint.readVarNum(data[pos..], &key_len);
            if (kl_bytes == 0) break;
            pos += kl_bytes;
            if (pos + key_len + PAGE_ID_WIDTH > data.len) break;
            const key = data[pos .. pos + key_len];
            pos += key_len;
            const child = readFixNum(data[pos .. pos + PAGE_ID_WIDTH], PAGE_ID_WIDTH);
            pos += PAGE_ID_WIDTH;
            const lnk = try TreeLink.create(key, child, self.allocator);
            errdefer lnk.deinit(self.allocator);
            try node.links.append(self.allocator, lnk);
        }
        return node;
    }

    fn keyComparatorCode(kc: KeyComparator) u8 {
        if (kc == lib_common.lexicalKeyComparator) return KC_LEXICAL;
        if (kc == lib_common.lexicalCaseKeyComparator) return KC_LEXICAL_CASE;
        if (kc == lib_common.decimalKeyComparator) return KC_DECIMAL;
        if (kc == lib_common.hexadecimalKeyComparator) return KC_HEXADECIMAL;
        if (kc == lib_common.realNumberKeyComparator) return KC_REAL_NUMBER;
        if (kc == lib_common.signedBigEndianKeyComparator) return KC_SIGNED_BIG_ENDIAN;
        if (kc == lib_common.floatBigEndianKeyComparator) return KC_FLOAT_BIG_ENDIAN;
        return KC_CUSTOM;
    }

    fn keyComparatorFromCode(code: u8) ?KeyComparator {
        return switch (code) {
            KC_LEXICAL => lib_common.lexicalKeyComparator,
            KC_LEXICAL_CASE => lib_common.lexicalCaseKeyComparator,
            KC_DECIMAL => lib_common.decimalKeyComparator,
            KC_HEXADECIMAL => lib_common.hexadecimalKeyComparator,
            KC_REAL_NUMBER => lib_common.realNumberKeyComparator,
            KC_SIGNED_BIG_ENDIAN => lib_common.signedBigEndianKeyComparator,
            KC_FLOAT_BIG_ENDIAN => lib_common.floatBigEndianKeyComparator,
            else => null,
        };
    }

    fn saveMetadata(self: *TreeDBMImpl) Status {
        var meta: [64]u8 = [_]u8{0} ** 64;
        @memcpy(meta[0..3], META_MAGIC);
        meta[3] = 0;
        writeFixNum(meta[META_OFFSET_NUM_RECORDS..], self.num_records.load(.acquire), 6);
        writeFixNum(meta[META_OFFSET_EFF_DATA_SIZE..], self.eff_data_size.load(.acquire), 6);
        writeFixNum(meta[META_OFFSET_ROOT_ID..], self.root_id, 6);
        writeFixNum(meta[META_OFFSET_FIRST_ID..], self.first_id, 6);
        writeFixNum(meta[META_OFFSET_LAST_ID..], self.last_id, 6);
        writeFixNum(meta[META_OFFSET_NUM_LEAF_NODES..], self.num_leaf_nodes, 6);
        writeFixNum(meta[META_OFFSET_NUM_INNER_NODES..], self.num_inner_nodes, 6);
        writeFixNum(meta[META_OFFSET_MAX_PAGE_SIZE..], self.max_page_size, 3);
        writeFixNum(meta[META_OFFSET_MAX_BRANCHES..], self.max_branches, 3);
        meta[META_OFFSET_TREE_LEVEL] = @intCast(self.tree_level);
        meta[META_OFFSET_KEY_COMPARATOR] = keyComparatorCode(self.key_comparator);
        const opaque_src = self.mini_opaque.items;
        const copy_len = @min(opaque_src.len, OPAQUE_METADATA_SIZE);
        @memcpy(meta[META_OFFSET_OPAQUE .. META_OFFSET_OPAQUE + copy_len], opaque_src[0..copy_len]);
        return self.hash_dbm.setOpaqueMetadata(&meta);
    }

    fn loadMetadata(self: *TreeDBMImpl) Status {
        const meta = self.hash_dbm.getOpaqueMetadata();
        if (meta.len < META_OFFSET_OPAQUE or !std.mem.eql(u8, meta[0..3], META_MAGIC)) {
            return Status.init(.BROKEN_DATA_ERROR);
        }
        self.num_records.store(readFixNum(meta[META_OFFSET_NUM_RECORDS..], 6), .release);
        self.eff_data_size.store(readFixNum(meta[META_OFFSET_EFF_DATA_SIZE..], 6), .release);
        self.root_id = readFixNum(meta[META_OFFSET_ROOT_ID..], 6);
        self.first_id = readFixNum(meta[META_OFFSET_FIRST_ID..], 6);
        self.last_id = readFixNum(meta[META_OFFSET_LAST_ID..], 6);
        self.num_leaf_nodes = readFixNum(meta[META_OFFSET_NUM_LEAF_NODES..], 6);
        self.num_inner_nodes = readFixNum(meta[META_OFFSET_NUM_INNER_NODES..], 6);
        if (self.max_page_size == 0)
            self.max_page_size = @intCast(readFixNum(meta[META_OFFSET_MAX_PAGE_SIZE..], 3));
        if (self.max_branches == 0)
            self.max_branches = @intCast(readFixNum(meta[META_OFFSET_MAX_BRANCHES..], 3));
        self.tree_level = @intCast(meta[META_OFFSET_TREE_LEVEL]);
        const kc_code = meta[META_OFFSET_KEY_COMPARATOR];
        if (kc_code != KC_CUSTOM) {
            if (keyComparatorFromCode(kc_code)) |kc| self.key_comparator = kc;
        }
        var opaque_len = @min(meta.len - META_OFFSET_OPAQUE, OPAQUE_METADATA_SIZE);
        // Trim trailing null bytes so callers see exactly what they stored.
        while (opaque_len > 0 and meta[META_OFFSET_OPAQUE + opaque_len - 1] == 0) opaque_len -= 1;
        self.mini_opaque.clearRetainingCapacity();
        self.mini_opaque.appendSlice(self.allocator, meta[META_OFFSET_OPAQUE .. META_OFFSET_OPAQUE + opaque_len]) catch {
            return Status.init(.SYSTEM_ERROR);
        };
        if (self.root_id < LEAF_NODE_ID_BASE or
            self.first_id < LEAF_NODE_ID_BASE or
            self.last_id < LEAF_NODE_ID_BASE)
        {
            return Status.init(.BROKEN_DATA_ERROR);
        }
        return Status.init(.SUCCESS);
    }

    fn initializePageCache(self: *TreeDBMImpl) void {
        const max_cached: usize = @intCast(@max(self.max_cached_pages, 1));
        const inner_cap: usize = @max(1, @as(usize, @trunc(@as(f64, @floatFromInt(max_cached)) * INNER_PAGE_CACHE_RATIO)));
        const leaf_cap = @max(@as(usize, 1), max_cached - inner_cap);
        const leaf_per_slot = @max(@as(usize, 1), leaf_cap / NUM_PAGE_SLOTS);
        const inner_per_slot = @max(@as(usize, 1), inner_cap / NUM_PAGE_SLOTS);
        for (&self.leaf_slots) |*slot| {
            slot.cache = SimpleCache(TreeLeafNode).init(leaf_per_slot);
            slot.mutex = SpinSharedMutex{};
        }
        for (&self.inner_slots) |*slot| {
            slot.cache = SimpleCache(TreeInnerNode).init(inner_per_slot);
            slot.mutex = SpinSharedMutex{};
        }
    }

    fn newLeafNode(self: *TreeDBMImpl, id: i64) !*TreeLeafNode {
        const node = try self.allocator.create(TreeLeafNode);
        node.* = .{
            .id = id,
            .prev_id = 0,
            .next_id = 0,
            .records = .empty,
            .page_size = 0,
            .dirty = true,
            .on_disk = false,
            .ref_count = std.atomic.Value(i32).init(0),
            .mutex = SpinSharedMutex{},
            .allocator = self.allocator,
        };
        return node;
    }

    fn newInnerNode(self: *TreeDBMImpl, id: i64) !*TreeInnerNode {
        const node = try self.allocator.create(TreeInnerNode);
        node.* = .{
            .id = id,
            .heir_id = 0,
            .links = .empty,
            .dirty = true,
            .on_disk = false,
            .ref_count = std.atomic.Value(i32).init(0),
            .allocator = self.allocator,
        };
        return node;
    }

    fn loadLeafNode(self: *TreeDBMImpl, id: i64, promote: bool) !*TreeLeafNode {
        const slot_idx = leafSlotIndex(id);
        const slot = &self.leaf_slots[slot_idx];
        slot.mutex.lock();
        if (slot.cache.get(id, promote)) |node| {
            _ = node.ref_count.fetchAdd(1, .acq_rel);
            slot.mutex.unlock();
            return node;
        }
        // Cache miss — load from HashDBM while holding the slot lock to avoid races.
        var id_buf: [PAGE_ID_WIDTH]u8 = undefined;
        writeFixNum(&id_buf, id, PAGE_ID_WIDTH);
        var loaded_data = ArrayList(u8).empty;
        defer loaded_data.deinit(self.allocator);
        _ = self.hash_dbm.get(&id_buf, &loaded_data);
        var node: *TreeLeafNode = undefined;
        if (loaded_data.items.len > 0) {
            node = self.deserializeLeafNode(id, loaded_data.items) catch {
                slot.mutex.unlock();
                return error.OutOfMemory;
            };
        } else {
            node = self.newLeafNode(id) catch {
                slot.mutex.unlock();
                return error.OutOfMemory;
            };
        }
        _ = node.ref_count.fetchAdd(1, .acq_rel);
        slot.cache.add(id, node, self.allocator) catch {
            node.deinit();
            slot.mutex.unlock();
            return error.OutOfMemory;
        };
        slot.mutex.unlock();
        return node;
    }

    fn releaseLeafNode(self: *TreeDBMImpl, id: i64) void {
        const slot_idx = leafSlotIndex(id);
        const slot = &self.leaf_slots[slot_idx];
        slot.mutex.lock();
        defer slot.mutex.unlock();
        if (slot.cache.get(id, false)) |node| {
            _ = node.ref_count.fetchSub(1, .acq_rel);
        }
    }

    fn saveLeafNodeImpl(self: *TreeDBMImpl, node: *TreeLeafNode) Status {
        var buf = ArrayList(u8).empty;
        defer buf.deinit(self.allocator);
        self.serializeLeafNode(node, &buf) catch return Status.init(.SYSTEM_ERROR);
        var id_buf: [PAGE_ID_WIDTH]u8 = undefined;
        writeFixNum(&id_buf, node.id, PAGE_ID_WIDTH);
        const st = self.hash_dbm.set(&id_buf, buf.items, true, null);
        if (st.isOk()) {
            node.dirty = false;
            node.on_disk = true;
        }
        return st;
    }

    fn removeLeafNode(self: *TreeDBMImpl, node: *TreeLeafNode) Status {
        const id = node.id;
        const slot_idx = leafSlotIndex(id);
        const slot = &self.leaf_slots[slot_idx];
        slot.mutex.lock();
        defer slot.mutex.unlock();
        _ = slot.cache.remove(id, self.allocator);
        if (node.on_disk) {
            var id_buf: [PAGE_ID_WIDTH]u8 = undefined;
            writeFixNum(&id_buf, id, PAGE_ID_WIDTH);
            const st = self.hash_dbm.remove(&id_buf);
            node.deinit();
            return st;
        }
        node.deinit();
        return Status.init(.SUCCESS);
    }

    fn flushLeafCacheOne(self: *TreeDBMImpl, empty: bool, slot_idx: usize) Status {
        const slot = &self.leaf_slots[slot_idx];
        slot.mutex.lock();
        defer slot.mutex.unlock();
        var st = Status.init(.SUCCESS);
        while (true) {
            if (!empty and !slot.cache.isSaturated()) break;
            if (slot.cache.count() == 0) break;
            const node = slot.cache.removeLRU(self.allocator) orelse break;
            if (node.ref_count.load(.acquire) > 0) {
                // Still referenced — put back and stop trying.
                slot.cache.add(node.id, node, self.allocator) catch {};
                break;
            }
            if (node.dirty) {
                const save_st = self.saveLeafNodeImpl(node);
                if (!save_st.isOk()) {
                    st = save_st;
                    slot.cache.add(node.id, node, self.allocator) catch {};
                    break;
                }
            }
            node.deinit();
        }
        return st;
    }

    fn flushLeafCacheAll(self: *TreeDBMImpl, empty: bool) Status {
        var st = Status.init(.SUCCESS);
        for (0..NUM_PAGE_SLOTS) |i| {
            st.mergeFrom(self.flushLeafCacheOne(empty, i));
        }
        return st;
    }

    fn discardLeafCache(self: *TreeDBMImpl) void {
        for (&self.leaf_slots) |*slot| {
            slot.mutex.lock();
            defer slot.mutex.unlock();
            while (slot.cache.removeLRU(self.allocator)) |node| node.deinit();
        }
    }

    fn loadInnerNode(self: *TreeDBMImpl, id: i64, promote: bool) !*TreeInnerNode {
        const slot_idx = innerSlotIndex(id);
        const slot = &self.inner_slots[slot_idx];
        slot.mutex.lock();
        if (slot.cache.get(id, promote)) |node| {
            _ = node.ref_count.fetchAdd(1, .acq_rel);
            slot.mutex.unlock();
            return node;
        }
        var id_buf: [PAGE_ID_WIDTH]u8 = undefined;
        writeFixNum(&id_buf, id, PAGE_ID_WIDTH);
        var loaded_data = ArrayList(u8).empty;
        defer loaded_data.deinit(self.allocator);
        _ = self.hash_dbm.get(&id_buf, &loaded_data);
        var node: *TreeInnerNode = undefined;
        if (loaded_data.items.len > 0) {
            node = self.deserializeInnerNode(id, loaded_data.items) catch {
                slot.mutex.unlock();
                return error.OutOfMemory;
            };
        } else {
            node = self.newInnerNode(id) catch {
                slot.mutex.unlock();
                return error.OutOfMemory;
            };
        }
        _ = node.ref_count.fetchAdd(1, .acq_rel);
        slot.cache.add(id, node, self.allocator) catch {
            node.deinit();
            slot.mutex.unlock();
            return error.OutOfMemory;
        };
        slot.mutex.unlock();
        return node;
    }

    fn releaseInnerNode(self: *TreeDBMImpl, id: i64) void {
        const slot_idx = innerSlotIndex(id);
        const slot = &self.inner_slots[slot_idx];
        slot.mutex.lock();
        defer slot.mutex.unlock();
        if (slot.cache.get(id, false)) |node| {
            _ = node.ref_count.fetchSub(1, .acq_rel);
        }
    }

    fn saveInnerNode(self: *TreeDBMImpl, node: *TreeInnerNode) Status {
        var buf = ArrayList(u8).empty;
        defer buf.deinit(self.allocator);
        self.serializeInnerNode(node, &buf) catch return Status.init(.SYSTEM_ERROR);
        var id_buf: [PAGE_ID_WIDTH]u8 = undefined;
        writeFixNum(&id_buf, node.id, PAGE_ID_WIDTH);
        const st = self.hash_dbm.set(&id_buf, buf.items, true, null);
        if (st.isOk()) {
            node.dirty = false;
            node.on_disk = true;
        }
        return st;
    }

    fn removeInnerNode(self: *TreeDBMImpl, node: *TreeInnerNode) Status {
        const id = node.id;
        const slot_idx = innerSlotIndex(id);
        const slot = &self.inner_slots[slot_idx];
        slot.mutex.lock();
        defer slot.mutex.unlock();
        _ = slot.cache.remove(id, self.allocator);
        if (node.on_disk) {
            var id_buf: [PAGE_ID_WIDTH]u8 = undefined;
            writeFixNum(&id_buf, id, PAGE_ID_WIDTH);
            const st = self.hash_dbm.remove(&id_buf);
            node.deinit();
            return st;
        }
        node.deinit();
        return Status.init(.SUCCESS);
    }

    fn flushInnerCacheAll(self: *TreeDBMImpl, empty: bool) Status {
        var st = Status.init(.SUCCESS);
        for (&self.inner_slots, 0..) |_, i| {
            const slot = &self.inner_slots[i];
            slot.mutex.lock();
            defer slot.mutex.unlock();
            if (!empty and !slot.cache.isSaturated()) continue;
            while (true) {
                if (slot.cache.count() == 0) break;
                const node = slot.cache.removeLRU(self.allocator) orelse break;
                if (node.ref_count.load(.acquire) > 0) {
                    slot.cache.add(node.id, node, self.allocator) catch {};
                    break;
                }
                if (node.dirty) {
                    const save_st = self.saveInnerNode(node);
                    if (!save_st.isOk()) {
                        st = save_st;
                        slot.cache.add(node.id, node, self.allocator) catch {};
                        break;
                    }
                }
                node.deinit();
            }
        }
        return st;
    }

    fn discardInnerCache(self: *TreeDBMImpl) void {
        for (&self.inner_slots) |*slot| {
            slot.mutex.lock();
            defer slot.mutex.unlock();
            while (slot.cache.removeLRU(self.allocator)) |node| node.deinit();
        }
    }

    // -----------------------------------------------------------------------
    // Tree search
    // -----------------------------------------------------------------------

    /// Walk inner nodes from root to leaf; returns a loaded+retained leaf node.
    fn searchTree(self: *TreeDBMImpl, key: []const u8) !*TreeLeafNode {
        var node_id = self.root_id;
        while (node_id >= INNER_NODE_ID_BASE) {
            const inner = try self.loadInnerNode(node_id, true);
            var child = inner.heir_id;
            for (inner.links.items) |lnk| {
                if (self.key_comparator(key, lnk.key) == .lt) break;
                child = lnk.child;
            }
            const next_id = child;
            self.releaseInnerNode(node_id);
            node_id = next_id;
        }
        return self.loadLeafNode(node_id, true);
    }

    /// Like searchTree but records each inner node ID into hist[].
    fn traceTree(
        self: *TreeDBMImpl,
        key: []const u8,
        leaf_id_out: *i64,
        hist: []i64,
        hist_len: *usize,
    ) !void {
        var node_id = self.root_id;
        var depth: usize = 0;
        while (node_id >= INNER_NODE_ID_BASE) {
            if (depth < hist.len) {
                hist[depth] = node_id;
                depth += 1;
            }
            const inner = try self.loadInnerNode(node_id, true);
            var child = inner.heir_id;
            for (inner.links.items) |lnk| {
                if (self.key_comparator(key, lnk.key) == .lt) break;
                child = lnk.child;
            }
            const next_id = child;
            self.releaseInnerNode(node_id);
            node_id = next_id;
        }
        leaf_id_out.* = node_id;
        hist_len.* = depth;
    }

    // -----------------------------------------------------------------------
    // Binary search helpers
    // -----------------------------------------------------------------------

    /// Index of first record whose key >= key (lower bound).
    fn lowerBoundRecords(self: *TreeDBMImpl, records: []*TreeRecord, key: []const u8) usize {
        var lo: usize = 0;
        var hi: usize = records.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.key_comparator(records[mid].key, key) == .lt) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return lo;
    }

    /// Index of first link whose key > key (upper bound).
    fn upperBoundLinks(self: *TreeDBMImpl, links: []*TreeLink, key: []const u8) usize {
        var lo: usize = 0;
        var hi: usize = links.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.key_comparator(key, links[mid].key) != .lt) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return lo;
    }

    // -----------------------------------------------------------------------
    // Reorg queue
    // -----------------------------------------------------------------------

    fn queueReorg(self: *TreeDBMImpl, leaf_id: i64, first_key: []const u8) void {
        if (self.reorg_ids.contains(leaf_id)) return;
        var key_copy = ArrayList(u8).empty;
        key_copy.appendSlice(self.allocator, first_key) catch return;
        self.reorg_ids.put(self.allocator, leaf_id, key_copy) catch {
            key_copy.deinit(self.allocator);
        };
    }

    fn checkLeafNodeToDivide(self: *TreeDBMImpl, node: *const TreeLeafNode) bool {
        return node.page_size > self.max_page_size and node.records.items.len > 1;
    }

    fn checkLeafNodeToMerge(self: *TreeDBMImpl, node: *const TreeLeafNode) bool {
        return node.id != self.root_id and
            node.id != self.first_id and
            node.page_size < @divTrunc(self.max_page_size, 2) and
            node.records.items.len > 0;
    }

    // -----------------------------------------------------------------------
    // Inner node structural helpers
    // -----------------------------------------------------------------------

    fn addLinkToInnerNode(self: *TreeDBMImpl, inner: *TreeInnerNode, key: []const u8, child: i64) !void {
        const pos = self.upperBoundLinks(inner.links.items, key);
        const lnk = try TreeLink.create(key, child, self.allocator);
        inner.links.insert(self.allocator, pos, lnk) catch {
            lnk.deinit(self.allocator);
            return error.OutOfMemory;
        };
        inner.dirty = true;
    }

    /// Remove the link whose child == child_id from the inner node.
    fn joinPrevLinkInInnerNode(_: *TreeDBMImpl, inner: *TreeInnerNode, child_id: i64) void {
        for (inner.links.items, 0..) |lnk, i| {
            if (lnk.child == child_id) {
                lnk.deinit(inner.allocator);
                _ = inner.links.orderedRemove(i);
                inner.dirty = true;
                return;
            }
        }
    }

    /// Absorb the next sibling link into this child's coverage.
    fn joinNextLinkInInnerNode(_: *TreeDBMImpl, inner: *TreeInnerNode, child_id: i64, next_id: i64) void {
        if (inner.heir_id == child_id) {
            inner.heir_id = next_id;
            if (inner.links.items.len > 0) {
                inner.links.items[0].deinit(inner.allocator);
                _ = inner.links.orderedRemove(0);
            }
            inner.dirty = true;
            return;
        }
        for (inner.links.items, 0..) |lnk, i| {
            if (lnk.child == child_id) {
                lnk.child = next_id;
                if (i + 1 < inner.links.items.len) {
                    inner.links.items[i + 1].deinit(inner.allocator);
                    _ = inner.links.orderedRemove(i + 1);
                }
                inner.dirty = true;
                return;
            }
        }
    }

    // -----------------------------------------------------------------------
    // Divide / merge
    // -----------------------------------------------------------------------

    fn divideNodes(self: *TreeDBMImpl, leaf: *TreeLeafNode, node_key: []const u8) !Status {
        const mid = leaf.records.items.len / 2;

        // Allocate the sibling ID from the ever-increasing num_leaf_nodes counter
        // (same as C++: id = num_leaf_nodes_++ + LEAF_NODE_ID_BASE).
        const sibling_id = self.num_leaf_nodes + LEAF_NODE_ID_BASE;
        self.num_leaf_nodes += 1;
        const sibling = try self.newLeafNode(sibling_id);

        // Separator = first key of the upper half.
        const sep_key = try self.allocator.dupe(u8, leaf.records.items[mid].key);
        defer self.allocator.free(sep_key);

        // Move upper half of records into sibling.
        var sib_page_size: i32 = 0;
        for (leaf.records.items[mid..]) |rec| {
            sib_page_size += @intCast(rec.getSerializedSize());
            sibling.records.append(self.allocator, rec) catch {
                sibling.deinit();
                self.num_leaf_nodes -= 1;
                return Status.init(.SYSTEM_ERROR);
            };
        }
        sibling.page_size = sib_page_size;
        leaf.records.items.len = mid;
        var leaf_page: i32 = 0;
        for (leaf.records.items) |r| leaf_page += @intCast(r.getSerializedSize());
        leaf.page_size = leaf_page;

        sibling.prev_id = leaf.id;
        sibling.next_id = leaf.next_id;
        sibling.dirty = true;
        leaf.next_id = sibling_id;
        leaf.dirty = true;

        if (sibling.next_id == 0) {
            self.last_id = sibling_id;
        } else {
            if (self.loadLeafNode(sibling.next_id, false)) |next_leaf| {
                next_leaf.prev_id = sibling_id;
                next_leaf.dirty = true;
                self.releaseLeafNode(next_leaf.id);
            } else |_| {}
        }

        // Insert sibling into leaf cache.
        {
            const slot_idx = leafSlotIndex(sibling_id);
            const slot = &self.leaf_slots[slot_idx];
            slot.mutex.lock();
            defer slot.mutex.unlock();
            slot.cache.add(sibling_id, sibling, self.allocator) catch return Status.init(.SYSTEM_ERROR);
        }

        // Propagate separator up through inner node history.
        var hist: [TREE_LEVEL_MAX]i64 = undefined;
        var hist_len: usize = 0;
        var leaf_id_found: i64 = 0;
        try self.traceTree(node_key, &leaf_id_found, &hist, &hist_len);

        var child_id = sibling_id;
        var heir_id = leaf.id; // left child when growing a new root; updated on inner overflow
        var prop_key = try self.allocator.dupe(u8, sep_key);
        defer self.allocator.free(prop_key);

        var level = hist_len;
        while (true) {
            if (level == 0) {
                // Grow a new root (id = num_inner_nodes + BASE, same as C++ constructor).
                const new_root_id = INNER_NODE_ID_BASE + self.num_inner_nodes;
                const new_root = try self.newInnerNode(new_root_id);
                new_root.heir_id = heir_id;
                // TreeLink.create dups the key, so prop_key is still ours to free.
                const lnk = TreeLink.create(prop_key, child_id, self.allocator) catch {
                    new_root.deinit();
                    return Status.init(.SYSTEM_ERROR);
                };
                new_root.links.append(self.allocator, lnk) catch {
                    lnk.deinit(self.allocator);
                    new_root.deinit();
                    return Status.init(.SYSTEM_ERROR);
                };
                new_root.dirty = true;
                self.root_id = new_root_id;
                self.tree_level += 1;
                self.num_inner_nodes += 1;
                const inner_slot_idx = innerSlotIndex(new_root_id);
                const inner_slot = &self.inner_slots[inner_slot_idx];
                inner_slot.mutex.lock();
                defer inner_slot.mutex.unlock();
                inner_slot.cache.add(new_root_id, new_root, self.allocator) catch {
                    new_root.deinit();
                    return Status.init(.SYSTEM_ERROR);
                };
                break;
            }
            level -= 1;
            const parent_id = hist[level];
            const parent = try self.loadInnerNode(parent_id, false);
            // addLinkToInnerNode dups the key; prop_key is still ours.
            try self.addLinkToInnerNode(parent, prop_key, child_id);
            self.releaseInnerNode(parent_id);

            if (parent.links.items.len <= @as(usize, @intCast(self.max_branches))) break;

            // Inner overflow — split this inner node too.
            const inner_mid = parent.links.items.len / 2;
            const new_inner_id = INNER_NODE_ID_BASE + self.num_inner_nodes;
            self.num_inner_nodes += 1;
            const new_inner = try self.newInnerNode(new_inner_id);
            const pushed_lnk = parent.links.items[inner_mid];
            new_inner.heir_id = pushed_lnk.child;

            // The pushed separator becomes the new prop_key; free the old one first.
            self.allocator.free(prop_key);
            prop_key = try self.allocator.dupe(u8, pushed_lnk.key);
            pushed_lnk.deinit(self.allocator);
            _ = parent.links.orderedRemove(inner_mid);

            // Move links above split point into new_inner.
            for (parent.links.items[inner_mid..]) |lnk| {
                new_inner.links.append(self.allocator, lnk) catch {
                    new_inner.deinit();
                    return Status.init(.SYSTEM_ERROR);
                };
            }
            parent.links.items.len = inner_mid;
            parent.dirty = true;
            new_inner.dirty = true;

            const new_inner_slot_idx = innerSlotIndex(new_inner_id);
            const new_inner_slot = &self.inner_slots[new_inner_slot_idx];
            new_inner_slot.mutex.lock();
            defer new_inner_slot.mutex.unlock();
            new_inner_slot.cache.add(new_inner_id, new_inner, self.allocator) catch {
                new_inner.deinit();
                return Status.init(.SYSTEM_ERROR);
            };
            heir_id = parent_id;
            child_id = new_inner_id;
        }

        // Relocate iterators whose saved key is in the upper half.
        for (self.iterators.items) |it| {
            if (it.leaf_id == leaf.id) {
                if (it.keySlice()) |ik| {
                    if (self.key_comparator(ik, sep_key) != .lt) {
                        it.leaf_id = sibling_id;
                    }
                }
            }
        }

        if (self.page_update_mode == .write) {
            var st = self.saveLeafNodeImpl(leaf);
            st.mergeFrom(self.saveLeafNodeImpl(sibling));
            return st;
        }
        return Status.init(.SUCCESS);
    }

    fn mergeNodes(self: *TreeDBMImpl, leaf: *TreeLeafNode, node_key: []const u8) !Status {
        if (leaf.id == self.root_id) return Status.init(.SUCCESS);

        var hist: [TREE_LEVEL_MAX]i64 = undefined;
        var hist_len: usize = 0;
        var leaf_id_found: i64 = 0;
        try self.traceTree(node_key, &leaf_id_found, &hist, &hist_len);
        if (hist_len == 0) return Status.init(.SUCCESS);

        const merge_with_prev = leaf.prev_id != 0 and leaf.id != self.first_id;
        const sibling_id = if (merge_with_prev) leaf.prev_id else leaf.next_id;
        if (sibling_id == 0) return Status.init(.SUCCESS);

        const sibling = self.loadLeafNode(sibling_id, false) catch return Status.init(.SUCCESS);

        if (merge_with_prev) {
            // Append this leaf's records onto sibling (which precedes it).
            for (leaf.records.items) |rec| {
                sibling.page_size += @intCast(rec.getSerializedSize());
                sibling.records.append(self.allocator, rec) catch {
                    self.releaseLeafNode(sibling_id);
                    return Status.init(.SYSTEM_ERROR);
                };
            }
            leaf.records.items.len = 0;
            sibling.next_id = leaf.next_id;
            sibling.dirty = true;
            if (leaf.next_id != 0) {
                if (self.loadLeafNode(leaf.next_id, false)) |next_leaf| {
                    next_leaf.prev_id = sibling_id;
                    next_leaf.dirty = true;
                    self.releaseLeafNode(next_leaf.id);
                } else |_| {}
            }
            if (self.last_id == leaf.id) self.last_id = sibling_id;
        } else {
            // Prepend sibling's records before this leaf's (sibling is next).
            var combined = ArrayList(*TreeRecord).empty;
            combined.appendSlice(self.allocator, leaf.records.items) catch {
                combined.deinit(self.allocator);
                self.releaseLeafNode(sibling_id);
                return Status.init(.SYSTEM_ERROR);
            };
            combined.appendSlice(self.allocator, sibling.records.items) catch {
                combined.deinit(self.allocator);
                self.releaseLeafNode(sibling_id);
                return Status.init(.SYSTEM_ERROR);
            };
            // Sibling now owns all records; clear leaf.records without freeing them.
            leaf.records.items.len = 0;
            sibling.records.deinit(self.allocator);
            sibling.records = combined;
            var ps: i32 = 0;
            for (sibling.records.items) |r| ps += @intCast(r.getSerializedSize());
            sibling.page_size = ps;
            sibling.prev_id = leaf.prev_id;
            sibling.dirty = true;
            if (leaf.prev_id != 0) {
                if (self.loadLeafNode(leaf.prev_id, false)) |prev_leaf| {
                    prev_leaf.next_id = sibling_id;
                    prev_leaf.dirty = true;
                    self.releaseLeafNode(prev_leaf.id);
                } else |_| {}
            }
            if (self.first_id == leaf.id) self.first_id = sibling_id;
        }

        self.releaseLeafNode(sibling_id);

        // Redirect any iterators from the removed leaf.
        for (self.iterators.items) |it| {
            if (it.leaf_id == leaf.id) it.leaf_id = sibling_id;
        }

        // Save leaf.id before removeLeafNode — that call frees the leaf via
        // node.deinit(), so any subsequent access to leaf.id is use-after-free.
        const removed_leaf_id = leaf.id;
        var st = self.removeLeafNode(leaf);
        // Do not decrement num_leaf_nodes — it is a monotonic counter used for
        // ID allocation, matching C++ behaviour (num_leaf_nodes_++ in constructor).

        // Remove separator from parent inner nodes.
        var level = hist_len;
        while (level > 0) {
            level -= 1;
            const parent_id = hist[level];
            const parent = self.loadInnerNode(parent_id, false) catch break;
            if (merge_with_prev) {
                self.joinPrevLinkInInnerNode(parent, removed_leaf_id);
            } else {
                self.joinNextLinkInInnerNode(parent, removed_leaf_id, sibling_id);
            }
            self.releaseInnerNode(parent_id);
            if (parent.links.items.len >= @as(usize, @intCast(@divTrunc(self.max_branches, 2)))) break;
            if (level == 0 and parent.links.items.len == 0) {
                // Collapse root.
                self.root_id = parent.heir_id;
                self.tree_level -= 1;
                st.mergeFrom(self.removeInnerNode(parent));
                // Do not decrement num_inner_nodes — it is a monotonic ID counter.
                break;
            }
        }
        return st;
    }

    fn reorganizeTree(self: *TreeDBMImpl) Status {
        if (self.reorg_ids.count() == 0) return Status.init(.SUCCESS);
        var st = Status.init(.SUCCESS);

        const Entry = struct { id: i64, key: ArrayList(u8) };
        var to_process = ArrayList(Entry).empty;
        defer {
            for (to_process.items) |*e| e.key.deinit(self.allocator);
            to_process.deinit(self.allocator);
        }

        var it = self.reorg_ids.iterator();
        while (it.next()) |entry| {
            to_process.append(self.allocator, .{
                .id = entry.key_ptr.*,
                .key = entry.value_ptr.*,
            }) catch {
                st = Status.init(.SYSTEM_ERROR);
                break;
            };
        }
        self.reorg_ids.clearRetainingCapacity();

        for (to_process.items) |*entry| {
            const leaf = self.loadLeafNode(entry.id, false) catch continue;
            if (self.checkLeafNodeToDivide(leaf)) {
                const div_st = self.divideNodes(leaf, entry.key.items) catch Status.init(.SYSTEM_ERROR);
                st.mergeFrom(div_st);
            } else if (self.checkLeafNodeToMerge(leaf)) {
                const merge_st = self.mergeNodes(leaf, entry.key.items) catch Status.init(.SYSTEM_ERROR);
                st.mergeFrom(merge_st);
            }
            self.releaseLeafNode(entry.id);
        }
        return st;
    }

    // -----------------------------------------------------------------------
    // processLeaf — apply processor to a record in an already-locked leaf
    // -----------------------------------------------------------------------

    fn processLeaf(
        self: *TreeDBMImpl,
        leaf: *TreeLeafNode,
        key: []const u8,
        proc: anytype,
        writable: bool,
    ) Status {
        const idx = self.lowerBoundRecords(leaf.records.items, key);
        const exists = idx < leaf.records.items.len and
            self.key_comparator(leaf.records.items[idx].key, key) == .eq;
        const action: RecordAction = if (exists)
            proc.processFull(key, leaf.records.items[idx].value)
        else
            proc.processEmpty(key);

        if (!writable) return Status.init(.SUCCESS);
        switch (action) {
            .noop => {},
            .remove => {
                if (exists) {
                    const rec = leaf.records.items[idx];
                    leaf.page_size -= @intCast(rec.getSerializedSize());
                    _ = self.num_records.fetchSub(1, .acq_rel);
                    _ = self.eff_data_size.fetchSub(@intCast(rec.key.len + rec.value.len), .acq_rel);
                    rec.deinit(self.allocator);
                    _ = leaf.records.orderedRemove(idx);
                    leaf.dirty = true;
                    if (self.update_logger) |ul| _ = ul.writeRemove(key);
                    if (self.checkLeafNodeToMerge(leaf)) {
                        const first_key = if (leaf.records.items.len > 0) leaf.records.items[0].key else key;
                        self.queueReorg(leaf.id, first_key);
                    }
                }
            },
            .set => |new_val| {
                if (exists) {
                    const rec = leaf.records.items[idx];
                    const old_sz: i32 = @intCast(rec.getSerializedSize());
                    const old_val_len: i64 = @intCast(rec.value.len);
                    rec.modifyValue(new_val, self.allocator) catch return Status.init(.SYSTEM_ERROR);
                    leaf.page_size += @as(i32, @intCast(rec.getSerializedSize())) - old_sz;
                    _ = self.eff_data_size.fetchAdd(@as(i64, @intCast(rec.value.len)) - old_val_len, .acq_rel);
                } else {
                    const rec = TreeRecord.create(key, new_val, self.allocator) catch return Status.init(.SYSTEM_ERROR);
                    leaf.records.insert(self.allocator, idx, rec) catch {
                        rec.deinit(self.allocator);
                        return Status.init(.SYSTEM_ERROR);
                    };
                    leaf.page_size += @intCast(rec.getSerializedSize());
                    _ = self.num_records.fetchAdd(1, .acq_rel);
                    _ = self.eff_data_size.fetchAdd(@intCast(rec.key.len + rec.value.len), .acq_rel);
                }
                leaf.dirty = true;
                if (self.update_logger) |ul| _ = ul.writeSet(key, new_val);
                if (self.checkLeafNodeToDivide(leaf) or self.checkLeafNodeToMerge(leaf)) {
                    const first_key = if (leaf.records.items.len > 0) leaf.records.items[0].key else key;
                    self.queueReorg(leaf.id, first_key);
                }
            },
        }
        return Status.init(.SUCCESS);
    }

    // -----------------------------------------------------------------------
    // processImpl
    // -----------------------------------------------------------------------

    fn processImpl(self: *TreeDBMImpl, key: []const u8, proc: anytype, writable: bool) Status {
        if (!self.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        if (writable and !self.writable) return Status.initMsg(.PRECONDITION_ERROR, "not writable");
        if (writable and self.reorg_ids.count() > 0) {
            self.mutex.lock();
            const reorg_st = self.reorganizeTree();
            self.mutex.unlock();
            if (!reorg_st.isOk()) return reorg_st;
        }
        self.mutex.lockShared();
        const leaf = self.searchTree(key) catch {
            self.mutex.unlockShared();
            return Status.init(.SYSTEM_ERROR);
        };
        if (writable) leaf.mutex.lock() else leaf.mutex.lockShared();
        const st = self.processLeaf(leaf, key, proc, writable);
        if (writable) leaf.mutex.unlock() else leaf.mutex.unlockShared();
        self.releaseLeafNode(leaf.id);
        self.mutex.unlockShared();
        self.adjustCaches();
        return st;
    }

    fn processFirstImpl(self: *TreeDBMImpl, proc: anytype, writable: bool) Status {
        if (!self.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        self.mutex.lockShared();
        defer self.mutex.unlockShared();
        var node_id = self.first_id;
        while (node_id != 0) {
            const leaf = self.loadLeafNode(node_id, true) catch return Status.init(.SYSTEM_ERROR);
            if (leaf.records.items.len > 0) {
                if (writable) leaf.mutex.lock() else leaf.mutex.lockShared();
                const rec = leaf.records.items[0];
                const action = proc.processFull(rec.key, rec.value);
                if (writable) {
                    switch (action) {
                        .noop => {},
                        .remove => {
                            leaf.page_size -= @intCast(rec.getSerializedSize());
                            _ = self.num_records.fetchSub(1, .acq_rel);
                            _ = self.eff_data_size.fetchSub(@intCast(rec.key.len + rec.value.len), .acq_rel);
                            rec.deinit(self.allocator);
                            _ = leaf.records.orderedRemove(0);
                            leaf.dirty = true;
                        },
                        .set => |new_val| {
                            const old_sz: i32 = @intCast(rec.getSerializedSize());
                            const old_val_len: i64 = @intCast(rec.value.len);
                            rec.modifyValue(new_val, self.allocator) catch {
                                if (writable) leaf.mutex.unlock() else leaf.mutex.unlockShared();
                                self.releaseLeafNode(node_id);
                                return Status.init(.SYSTEM_ERROR);
                            };
                            leaf.page_size += @as(i32, @intCast(rec.getSerializedSize())) - old_sz;
                            _ = self.eff_data_size.fetchAdd(@as(i64, @intCast(rec.value.len)) - old_val_len, .acq_rel);
                            leaf.dirty = true;
                        },
                    }
                }
                if (writable) leaf.mutex.unlock() else leaf.mutex.unlockShared();
                self.releaseLeafNode(node_id);
                return Status.init(.SUCCESS);
            }
            const next = leaf.next_id;
            self.releaseLeafNode(node_id);
            node_id = next;
        }
        return Status.init(.NOT_FOUND_ERROR);
    }

    fn processEachImpl(self: *TreeDBMImpl, proc: anytype, writable: bool) Status {
        if (!self.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        self.mutex.lockShared();
        defer self.mutex.unlockShared();
        // Signal begin.
        _ = proc.processEmpty("");
        var node_id = self.first_id;
        while (node_id != 0) {
            const leaf = self.loadLeafNode(node_id, false) catch return Status.init(.SYSTEM_ERROR);
            if (writable) leaf.mutex.lock() else leaf.mutex.lockShared();
            var i: usize = 0;
            while (i < leaf.records.items.len) {
                const rec = leaf.records.items[i];
                const action = proc.processFull(rec.key, rec.value);
                if (writable) {
                    switch (action) {
                        .noop => { i += 1; },
                        .remove => {
                            leaf.page_size -= @intCast(rec.getSerializedSize());
                            _ = self.num_records.fetchSub(1, .acq_rel);
                            _ = self.eff_data_size.fetchSub(@intCast(rec.key.len + rec.value.len), .acq_rel);
                            rec.deinit(self.allocator);
                            _ = leaf.records.orderedRemove(i);
                            leaf.dirty = true;
                        },
                        .set => |new_val| {
                            const old_sz: i32 = @intCast(rec.getSerializedSize());
                            const old_val_len: i64 = @intCast(rec.value.len);
                            rec.modifyValue(new_val, self.allocator) catch {};
                            leaf.page_size += @as(i32, @intCast(rec.getSerializedSize())) - old_sz;
                            _ = self.eff_data_size.fetchAdd(@as(i64, @intCast(rec.value.len)) - old_val_len, .acq_rel);
                            leaf.dirty = true;
                            i += 1;
                        },
                    }
                } else {
                    i += 1;
                }
            }
            if (writable) leaf.mutex.unlock() else leaf.mutex.unlockShared();
            const next = leaf.next_id;
            self.releaseLeafNode(node_id);
            node_id = next;
        }
        // Signal end.
        _ = proc.processEmpty("");
        return Status.init(.SUCCESS);
    }

    fn adjustCaches(self: *TreeDBMImpl) void {
        const clock = self.proc_clock.fetchAdd(1, .acq_rel);
        if (clock % ADJUST_CACHES_INV_FREQ != 0) return;
        for (0..NUM_PAGE_SLOTS) |i| {
            if (self.leaf_slots[i].cache.isSaturated()) {
                _ = self.flushLeafCacheOne(false, i);
                break;
            }
        }
    }

    // -----------------------------------------------------------------------
    // clear / rebuild / synchronize
    // -----------------------------------------------------------------------

    fn clearImpl(self: *TreeDBMImpl) Status {
        if (self.update_logger) |ul| {
            const log_st = ul.writeClear();
            if (!log_st.isOk()) return log_st;
        }
        self.discardLeafCache();
        self.discardInnerCache();
        {
            var it = self.reorg_ids.iterator();
            while (it.next()) |entry| entry.value_ptr.deinit(self.allocator);
        }
        self.reorg_ids.clearRetainingCapacity();
        const st = self.hash_dbm.clear();
        if (!st.isOk()) return st;
        self.num_records.store(0, .release);
        self.eff_data_size.store(0, .release);
        self.num_leaf_nodes = 0;
        self.num_inner_nodes = 0;
        self.tree_level = 0;
        const root_id = LEAF_NODE_ID_BASE;
        const root_leaf = self.newLeafNode(root_id) catch return Status.init(.SYSTEM_ERROR);
        self.root_id = root_id;
        self.first_id = root_id;
        self.last_id = root_id;
        self.num_leaf_nodes = 1;
        const slot_idx = leafSlotIndex(root_id);
        {
            const slot = &self.leaf_slots[slot_idx];
            slot.mutex.lock();
            defer slot.mutex.unlock();
            slot.cache.add(root_id, root_leaf, self.allocator) catch return Status.init(.SYSTEM_ERROR);
        }
        return self.saveMetadata();
    }

    fn rebuildImpl(self: *TreeDBMImpl, io: std.Io) Status {
        var st = self.flushLeafCacheAll(true);
        st.mergeFrom(self.flushInnerCacheAll(true));
        st.mergeFrom(self.saveMetadata());
        st.mergeFrom(self.hash_dbm.rebuild(io));
        return st;
    }

    fn synchronizeImpl(self: *TreeDBMImpl, hard: bool, io: std.Io) Status {
        var st = self.flushLeafCacheAll(false);
        st.mergeFrom(self.flushInnerCacheAll(false));
        self.mutex.lock();
        if (self.update_logger) |ul| {
            st.mergeFrom(ul.synchronize(hard));
        }
        st.mergeFrom(self.reorganizeTree());
        self.mutex.unlock();
        st.mergeFrom(self.flushLeafCacheAll(false));
        st.mergeFrom(self.flushInnerCacheAll(false));
        st.mergeFrom(self.saveMetadata());
        st.mergeFrom(self.hash_dbm.synchronize(hard, io));
        return st;
    }

    // -----------------------------------------------------------------------
    // open / close
    // -----------------------------------------------------------------------

    fn openImpl(self: *TreeDBMImpl, path: []const u8, writable: bool, opts: OpenOptions, params: TuningParameters, io: std.Io) Status {
        const hash_params = HashDBM.TuningParameters{
            .update_mode = params.update_mode,
            .record_crc_mode = params.record_crc_mode,
            .record_comp_mode = params.record_comp_mode,
            .offset_width = params.offset_width,
            .align_pow = params.align_pow,
            .num_buckets = params.num_buckets,
            .restore_mode = params.restore_mode,
            .fbp_capacity = params.fbp_capacity,
            .min_read_size = params.min_read_size,
            .cache_buckets = params.cache_buckets,
            .cipher_key = params.cipher_key,
        };
        const hash_st = self.hash_dbm.openAdvanced(path, writable, opts, hash_params, io);
        if (!hash_st.isOk()) return hash_st;
        self.writable = writable;
        self.path.clearRetainingCapacity();
        self.path.appendSlice(self.allocator, path) catch return Status.init(.SYSTEM_ERROR);
        if (params.max_page_size > 0) self.max_page_size = params.max_page_size;
        if (params.max_branches > 0) self.max_branches = params.max_branches;
        if (params.max_cached_pages > 0) self.max_cached_pages = params.max_cached_pages;
        if (params.page_update_mode != .default) self.page_update_mode = params.page_update_mode;
        if (params.key_comparator) |kc| self.key_comparator = kc;
        self.initializePageCache();
        self.healthy = self.hash_dbm.isHealthy();
        self.auto_restored = self.hash_dbm.isAutoRestored();
        const is_new = self.hash_dbm.countInternal() == 0;
        if (is_new) {
            const root_id = LEAF_NODE_ID_BASE;
            const root_leaf = self.newLeafNode(root_id) catch return Status.init(.SYSTEM_ERROR);
            self.root_id = root_id;
            self.first_id = root_id;
            self.last_id = root_id;
            self.num_leaf_nodes = 1;
            const slot_idx = leafSlotIndex(root_id);
            const slot = &self.leaf_slots[slot_idx];
            slot.mutex.lock();
            defer slot.mutex.unlock();
            slot.cache.add(root_id, root_leaf, self.allocator) catch return Status.init(.SYSTEM_ERROR);
            if (writable) return self.saveMetadata();
            return Status.init(.SUCCESS);
        }
        return self.loadMetadata();
    }

    fn closeImpl(self: *TreeDBMImpl, io: std.Io) Status {
        for (self.iterators.items) |it| it.dbm_impl = null;
        self.iterators.clearRetainingCapacity();
        var st = Status.init(.SUCCESS);
        if (self.writable) {
            self.mutex.lock();
            st.mergeFrom(self.reorganizeTree());
            self.mutex.unlock();
            st.mergeFrom(self.flushLeafCacheAll(true));
            st.mergeFrom(self.flushInnerCacheAll(true));
            st.mergeFrom(self.saveMetadata());
        } else {
            self.discardLeafCache();
            self.discardInnerCache();
        }
        st.mergeFrom(self.hash_dbm.close(io));
        self.open = false;
        return st;
    }

    fn deinit(self: *TreeDBMImpl) void {
        if (self.open) _ = self.closeImpl(std.Io.failing);
        for (self.iterators.items) |it| it.deinit();
        self.iterators.deinit(self.allocator);
        self.discardLeafCache();
        self.discardInnerCache();
        for (&self.leaf_slots) |*slot| slot.cache.deinit(self.allocator);
        for (&self.inner_slots) |*slot| slot.cache.deinit(self.allocator);
        {
            var it = self.reorg_ids.iterator();
            while (it.next()) |entry| entry.value_ptr.deinit(self.allocator);
        }
        self.reorg_ids.deinit(self.allocator);
        self.mini_opaque.deinit(self.allocator);
        self.path.deinit(self.allocator);
        self.hash_dbm.deinit();
        self.allocator.destroy(self.hash_dbm);
        self.allocator.destroy(self);
    }
};

// ---------------------------------------------------------------------------
// TreeDBMIteratorImpl — methods
// ---------------------------------------------------------------------------

const IteratorStatus = enum { ok, not_found };

/// Helpers on the impl struct that need TreeDBMImpl to be fully defined.
/// (The struct declaration and basic helpers are earlier in the file.)

fn iterSetPositionFirst(it: *TreeDBMIteratorImpl) !Status {
    const impl = it.dbm_impl orelse return Status.initMsg(.PRECONDITION_ERROR, "orphaned iterator");
    var node_id = impl.first_id;
    while (node_id != 0) {
        const leaf = impl.loadLeafNode(node_id, true) catch return Status.init(.SYSTEM_ERROR);
        defer impl.releaseLeafNode(node_id);
        if (leaf.records.items.len > 0) {
            try it.setPosition(node_id, leaf.records.items[0].key);
            return Status.init(.SUCCESS);
        }
        node_id = leaf.next_id;
    }
    it.clearPosition();
    return Status.init(.NOT_FOUND_ERROR);
}

fn iterSetPositionLast(it: *TreeDBMIteratorImpl) !Status {
    const impl = it.dbm_impl orelse return Status.initMsg(.PRECONDITION_ERROR, "orphaned iterator");
    var node_id = impl.last_id;
    while (node_id != 0) {
        const leaf = impl.loadLeafNode(node_id, true) catch return Status.init(.SYSTEM_ERROR);
        defer impl.releaseLeafNode(node_id);
        if (leaf.records.items.len > 0) {
            const last_rec = leaf.records.items[leaf.records.items.len - 1];
            try it.setPosition(node_id, last_rec.key);
            return Status.init(.SUCCESS);
        }
        node_id = leaf.prev_id;
    }
    it.clearPosition();
    return Status.init(.NOT_FOUND_ERROR);
}

fn iterNext(it: *TreeDBMIteratorImpl) !Status {
    const impl = it.dbm_impl orelse return Status.initMsg(.PRECONDITION_ERROR, "orphaned iterator");
    const cur_key = it.keySlice() orelse return Status.init(.NOT_FOUND_ERROR);
    var node_id = it.leaf_id;
    while (node_id != 0) {
        const leaf = impl.loadLeafNode(node_id, true) catch return Status.init(.SYSTEM_ERROR);
        defer impl.releaseLeafNode(node_id);
        const idx = impl.lowerBoundRecords(leaf.records.items, cur_key);
        // If we found the current key, advance past it.
        const start = if (idx < leaf.records.items.len and
            impl.key_comparator(leaf.records.items[idx].key, cur_key) == .eq)
            idx + 1
        else
            idx;
        if (start < leaf.records.items.len) {
            try it.setPosition(node_id, leaf.records.items[start].key);
            return Status.init(.SUCCESS);
        }
        node_id = leaf.next_id;
    }
    it.clearPosition();
    return Status.init(.NOT_FOUND_ERROR);
}

fn iterPrevious(it: *TreeDBMIteratorImpl) !Status {
    const impl = it.dbm_impl orelse return Status.initMsg(.PRECONDITION_ERROR, "orphaned iterator");
    const cur_key = it.keySlice() orelse return Status.init(.NOT_FOUND_ERROR);
    var node_id = it.leaf_id;
    while (node_id != 0) {
        const leaf = impl.loadLeafNode(node_id, true) catch return Status.init(.SYSTEM_ERROR);
        defer impl.releaseLeafNode(node_id);
        const idx = impl.lowerBoundRecords(leaf.records.items, cur_key);
        if (idx > 0) {
            try it.setPosition(node_id, leaf.records.items[idx - 1].key);
            return Status.init(.SUCCESS);
        }
        node_id = leaf.prev_id;
    }
    it.clearPosition();
    return Status.init(.NOT_FOUND_ERROR);
}

fn iterJump(it: *TreeDBMIteratorImpl, key: []const u8) !Status {
    const impl = it.dbm_impl orelse return Status.initMsg(.PRECONDITION_ERROR, "orphaned iterator");
    const leaf = impl.searchTree(key) catch return Status.init(.SYSTEM_ERROR);
    defer impl.releaseLeafNode(leaf.id);
    const idx = impl.lowerBoundRecords(leaf.records.items, key);
    if (idx < leaf.records.items.len) {
        try it.setPosition(leaf.id, leaf.records.items[idx].key);
        return Status.init(.SUCCESS);
    }
    // Key is beyond this leaf — advance to the next leaf's first record.
    var node_id = leaf.next_id;
    while (node_id != 0) {
        const next_leaf = impl.loadLeafNode(node_id, true) catch return Status.init(.SYSTEM_ERROR);
        defer impl.releaseLeafNode(node_id);
        if (next_leaf.records.items.len > 0) {
            try it.setPosition(node_id, next_leaf.records.items[0].key);
            return Status.init(.SUCCESS);
        }
        node_id = next_leaf.next_id;
    }
    it.clearPosition();
    return Status.init(.NOT_FOUND_ERROR);
}

fn iterJumpLower(it: *TreeDBMIteratorImpl, key: []const u8, inclusive: bool) !Status {
    const impl = it.dbm_impl orelse return Status.initMsg(.PRECONDITION_ERROR, "orphaned iterator");
    const leaf = impl.searchTree(key) catch return Status.init(.SYSTEM_ERROR);
    defer impl.releaseLeafNode(leaf.id);
    const idx = impl.lowerBoundRecords(leaf.records.items, key);
    // Find the last record that is strictly less than (or equal to, if inclusive) key.
    var found_idx: ?usize = null;
    var found_leaf_id: i64 = 0;
    var found_key: []const u8 = "";
    if (inclusive and idx < leaf.records.items.len and
        impl.key_comparator(leaf.records.items[idx].key, key) == .eq)
    {
        found_idx = idx;
        found_leaf_id = leaf.id;
        found_key = leaf.records.items[idx].key;
    } else if (idx > 0) {
        found_idx = idx - 1;
        found_leaf_id = leaf.id;
        found_key = leaf.records.items[idx - 1].key;
    }
    if (found_idx != null) {
        try it.setPosition(found_leaf_id, found_key);
        return Status.init(.SUCCESS);
    }
    // Search previous leaves.
    var node_id = leaf.prev_id;
    while (node_id != 0) {
        const prev_leaf = impl.loadLeafNode(node_id, true) catch return Status.init(.SYSTEM_ERROR);
        defer impl.releaseLeafNode(node_id);
        if (prev_leaf.records.items.len > 0) {
            const last_rec = prev_leaf.records.items[prev_leaf.records.items.len - 1];
            try it.setPosition(node_id, last_rec.key);
            return Status.init(.SUCCESS);
        }
        node_id = prev_leaf.prev_id;
    }
    it.clearPosition();
    return Status.init(.NOT_FOUND_ERROR);
}

fn iterJumpUpper(it: *TreeDBMIteratorImpl, key: []const u8, inclusive: bool) !Status {
    const impl = it.dbm_impl orelse return Status.initMsg(.PRECONDITION_ERROR, "orphaned iterator");
    const leaf = impl.searchTree(key) catch return Status.init(.SYSTEM_ERROR);
    defer impl.releaseLeafNode(leaf.id);
    const idx = impl.lowerBoundRecords(leaf.records.items, key);
    var start: usize = idx;
    if (!inclusive and idx < leaf.records.items.len and
        impl.key_comparator(leaf.records.items[idx].key, key) == .eq)
    {
        start = idx + 1;
    }
    if (start < leaf.records.items.len) {
        try it.setPosition(leaf.id, leaf.records.items[start].key);
        return Status.init(.SUCCESS);
    }
    var node_id = leaf.next_id;
    while (node_id != 0) {
        const next_leaf = impl.loadLeafNode(node_id, true) catch return Status.init(.SYSTEM_ERROR);
        defer impl.releaseLeafNode(node_id);
        if (next_leaf.records.items.len > 0) {
            try it.setPosition(node_id, next_leaf.records.items[0].key);
            return Status.init(.SUCCESS);
        }
        node_id = next_leaf.next_id;
    }
    it.clearPosition();
    return Status.init(.NOT_FOUND_ERROR);
}

fn iterGetCurrent(it: *TreeDBMIteratorImpl, key_out: ?*std.ArrayList(u8), value_out: ?*std.ArrayList(u8)) Status {
    const impl = it.dbm_impl orelse return Status.initMsg(.PRECONDITION_ERROR, "orphaned iterator");
    const cur_key = it.keySlice() orelse return Status.init(.NOT_FOUND_ERROR);
    const leaf = impl.loadLeafNode(it.leaf_id, true) catch return Status.init(.SYSTEM_ERROR);
    defer impl.releaseLeafNode(it.leaf_id);
    leaf.mutex.lockShared();
    defer leaf.mutex.unlockShared();
    const idx = impl.lowerBoundRecords(leaf.records.items, cur_key);
    if (idx >= leaf.records.items.len or
        impl.key_comparator(leaf.records.items[idx].key, cur_key) != .eq)
    {
        return Status.init(.NOT_FOUND_ERROR);
    }
    const rec = leaf.records.items[idx];
    const alloc = impl.allocator;
    if (key_out) |k| {
        k.clearRetainingCapacity();
        k.appendSlice(alloc, rec.key) catch return Status.init(.SYSTEM_ERROR);
    }
    if (value_out) |v| {
        v.clearRetainingCapacity();
        v.appendSlice(alloc, rec.value) catch return Status.init(.SYSTEM_ERROR);
    }
    return Status.init(.SUCCESS);
}

fn iterProcess(it: *TreeDBMIteratorImpl, proc: anytype, writable: bool) Status {
    const impl = it.dbm_impl orelse return Status.initMsg(.PRECONDITION_ERROR, "orphaned iterator");
    const cur_key = it.keySlice() orelse return Status.init(.NOT_FOUND_ERROR);
    const leaf = impl.loadLeafNode(it.leaf_id, true) catch return Status.init(.SYSTEM_ERROR);
    defer impl.releaseLeafNode(it.leaf_id);
    if (writable) leaf.mutex.lock() else leaf.mutex.lockShared();
    defer if (writable) leaf.mutex.unlock() else leaf.mutex.unlockShared();
    return impl.processLeaf(leaf, cur_key, proc, writable);
}

// ---------------------------------------------------------------------------
// Public TreeDBM
// ---------------------------------------------------------------------------

pub const TreeDBM = struct {
    impl: *TreeDBMImpl,

    /// Create a TreeDBM with a caller-supplied File backend (matches C++ TreeDBM(unique_ptr<File>)).
    /// For the common case of a standard file, use `StdFile.create(allocator)` and pass `.asFile()`.
    pub fn init(file: File, allocator: Allocator) !TreeDBM {
        const hash_dbm = try allocator.create(HashDBM);
        hash_dbm.* = try HashDBM.initWithOptions(
            file,
            131101, // C++ TreeDBM::DEFAULT_NUM_BUCKETS
            10,     // C++ TreeDBM::DEFAULT_ALIGN_POW
            allocator,
        );
        const impl = try allocator.create(TreeDBMImpl);
        impl.* = TreeDBMImpl{
            .allocator = allocator,
            .hash_dbm = hash_dbm,
            .open = false,
            .writable = false,
            .healthy = false,
            .auto_restored = false,
            .path = .empty,
            .num_records = std.atomic.Value(i64).init(0),
            .eff_data_size = std.atomic.Value(i64).init(0),
            .root_id = LEAF_NODE_ID_BASE,
            .first_id = LEAF_NODE_ID_BASE,
            .last_id = LEAF_NODE_ID_BASE,
            .num_leaf_nodes = 0,
            .num_inner_nodes = 0,
            .tree_level = 0,
            .max_page_size = 8130,
            .max_branches = 256,
            .max_cached_pages = 10000,
            .page_update_mode = .default,
            .key_comparator = lib_common.lexicalKeyComparator,
            .update_logger = null,
            .mini_opaque = .empty,
            .reorg_ids = .{},
            .iterators = .empty,
            .leaf_slots = undefined,
            .inner_slots = undefined,
            .proc_clock = std.atomic.Value(u32).init(0),
            .mutex = SpinSharedMutex{},
        };
        // Zero-init slots.
        for (&impl.leaf_slots) |*slot| {
            slot.cache = SimpleCache(TreeLeafNode).init(1);
            slot.mutex = SpinSharedMutex{};
        }
        for (&impl.inner_slots) |*slot| {
            slot.cache = SimpleCache(TreeInnerNode).init(1);
            slot.mutex = SpinSharedMutex{};
        }
        return .{ .impl = impl };
    }

    pub fn deinit(self: *TreeDBM) void {
        self.impl.deinit();
    }

    pub fn open(self: *TreeDBM, path: []const u8, writable: bool, opts: OpenOptions, io: std.Io) Status {
        return self.openAdvanced(path, writable, opts, .{}, io);
    }

    pub fn openAdvanced(self: *TreeDBM, path: []const u8, writable: bool, opts: OpenOptions, params: TuningParameters, io: std.Io) Status {
        const st = self.impl.openImpl(path, writable, opts, params, io);
        if (st.isOk()) self.impl.open = true;
        return st;
    }

    pub fn close(self: *TreeDBM, io: std.Io) Status {
        return self.impl.closeImpl(io);
    }

    pub fn get(self: *TreeDBM, key: []const u8, value_out: ?*std.ArrayList(u8)) Status {
        const GetProc = struct {
            value: ?*std.ArrayList(u8),
            alloc: Allocator,
            found: bool = false,
            pub fn processFull(p: *@This(), _: []const u8, val: []const u8) RecordAction {
                p.found = true;
                if (p.value) |v| {
                    v.clearRetainingCapacity();
                    v.appendSlice(p.alloc, val) catch {};
                }
                return .noop;
            }
            pub fn processEmpty(p: *@This(), _: []const u8) RecordAction {
                _ = p;
                return .noop;
            }
        };
        var proc = GetProc{ .value = value_out, .alloc = self.impl.allocator };
        const st = self.impl.processImpl(key, &proc, false);
        if (!st.isOk()) return st;
        if (!proc.found) return Status.init(.NOT_FOUND_ERROR);
        return Status.init(.SUCCESS);
    }

    pub fn set(self: *TreeDBM, key: []const u8, value: []const u8, overwrite: bool, old_value: ?*ArrayList(u8)) Status {
        const SetProc = struct {
            value: []const u8,
            overwrite: bool,
            conflict: bool = false,
            old_value: ?*ArrayList(u8),
            allocator: Allocator,
            pub fn processFull(p: *@This(), _: []const u8, v: []const u8) RecordAction {
                if (!p.overwrite) { p.conflict = true; return .noop; }
                if (p.old_value) |ov| {
                    ov.clearRetainingCapacity();
                    ov.appendSlice(p.allocator, v) catch {};
                }
                return .{ .set = p.value };
            }
            pub fn processEmpty(p: *@This(), _: []const u8) RecordAction {
                return .{ .set = p.value };
            }
        };
        var proc = SetProc{
            .value = value,
            .overwrite = overwrite,
            .old_value = old_value,
            .allocator = self.impl.allocator,
        };
        const st = self.impl.processImpl(key, &proc, true);
        if (!st.isOk()) return st;
        if (proc.conflict) return Status.init(.DUPLICATION_ERROR);
        return Status.init(.SUCCESS);
    }

    pub fn remove(self: *TreeDBM, key: []const u8) Status {
        const RemoveProc = struct {
            found: bool = false,
            pub fn processFull(p: *@This(), _: []const u8, _: []const u8) RecordAction {
                p.found = true;
                return .remove;
            }
            pub fn processEmpty(p: *@This(), _: []const u8) RecordAction {
                _ = p;
                return .noop;
            }
        };
        var proc = RemoveProc{};
        const st = self.impl.processImpl(key, &proc, true);
        if (!st.isOk()) return st;
        if (!proc.found) return Status.init(.NOT_FOUND_ERROR);
        return Status.init(.SUCCESS);
    }

    pub fn process(self: *TreeDBM, key: []const u8, proc: anytype, writable: bool) Status {
        return self.impl.processImpl(key, proc, writable);
    }

    pub fn processFirst(self: *TreeDBM, proc: anytype, writable: bool) Status {
        return self.impl.processFirstImpl(proc, writable);
    }

    pub fn processEach(self: *TreeDBM, proc: anytype, writable: bool) Status {
        return self.impl.processEachImpl(proc, writable);
    }

    fn countInternal(self: *TreeDBM) i64 {
        return self.impl.num_records.load(.acquire);
    }

    pub fn getEffectiveDataSize(self: *TreeDBM) i64 {
        return self.impl.eff_data_size.load(.acquire);
    }

    pub fn isOpen(self: *TreeDBM) bool {
        return self.impl.open;
    }

    pub fn isWritable(self: *TreeDBM) bool {
        return self.impl.writable;
    }

    pub fn isHealthy(self: *TreeDBM) bool {
        return self.impl.healthy;
    }

    pub fn isAutoRestored(self: *TreeDBM) bool {
        return self.impl.auto_restored;
    }

    pub fn synchronize(self: *TreeDBM, hard: bool, io: std.Io) Status {
        return self.impl.synchronizeImpl(hard, io);
    }

    pub fn rebuild(self: *TreeDBM, io: std.Io) Status {
        return self.impl.rebuildImpl(io);
    }

    pub fn rebuildAdvanced(self: *TreeDBM, params: TuningParameters, skip_broken_records: bool, sync_hard: bool, io: std.Io) Status {
        _ = skip_broken_records;
        _ = sync_hard;
        if (params.max_page_size > 0) self.impl.max_page_size = params.max_page_size;
        if (params.max_branches > 0) self.impl.max_branches = params.max_branches;
        if (params.max_cached_pages > 0) self.impl.max_cached_pages = params.max_cached_pages;
        return self.impl.rebuildImpl(io);
    }

    pub fn clear(self: *TreeDBM) Status {
        return self.impl.clearImpl();
    }

    pub fn getOpaqueMetadata(self: *TreeDBM) []const u8 {
        return self.impl.mini_opaque.items;
    }

    pub fn setOpaqueMetadata(self: *TreeDBM, data: []const u8) Status {
        const copy_len = @min(data.len, OPAQUE_METADATA_SIZE);
        self.impl.mini_opaque.clearRetainingCapacity();
        self.impl.mini_opaque.appendSlice(self.impl.allocator, data[0..copy_len]) catch return Status.init(.SYSTEM_ERROR);
        return Status.init(.SUCCESS);
    }

    pub fn setUpdateLogger(self: *TreeDBM, logger: ?*UpdateLogger) void {
        self.impl.update_logger = logger;
    }

    pub fn getUpdateLogger(self: *TreeDBM) ?*UpdateLogger {
        return self.impl.update_logger;
    }

    fn getFilePathInternal(self: *TreeDBM) []const u8 {
        return self.impl.path.items;
    }

    fn getTimestampInternal(self: *TreeDBM) f64 {
        return self.impl.hash_dbm.getTimestampInternal();
    }

    fn getFileSizeInternal(self: *TreeDBM) i64 {
        return self.impl.hash_dbm.getFileSizeInternal();
    }

    fn shouldBeRebuiltInternal(self: *TreeDBM) bool {
        return self.impl.hash_dbm.shouldBeRebuiltInternal();
    }

    /// Fills `out` with the number of records. Returns PRECONDITION_ERROR if not open.
    /// Matches C++ DBM::Count(int64_t* count).
    pub fn count(self: *TreeDBM, out: *i64) Status {
        if (!self.impl.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        out.* = self.impl.num_records.load(.acquire);
        return Status.init(.SUCCESS);
    }

    /// Fills `out` with the file size in bytes. Returns PRECONDITION_ERROR if not open.
    /// Matches C++ DBM::GetFileSize(int64_t* size).
    pub fn getFileSize(self: *TreeDBM, out: *i64) Status {
        if (!self.impl.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        out.* = self.impl.hash_dbm.getFileSizeInternal();
        return Status.init(.SUCCESS);
    }

    /// Appends the file path to `out`. Returns PRECONDITION_ERROR if not open.
    /// Matches C++ DBM::GetFilePath(std::string* path).
    pub fn getFilePath(self: *TreeDBM, out: *std.ArrayList(u8)) Status {
        if (!self.impl.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        out.clearRetainingCapacity();
        out.appendSlice(self.impl.allocator, self.impl.path.items) catch return Status.init(.SYSTEM_ERROR);
        return Status.init(.SUCCESS);
    }

    /// Fills `out` with the modification timestamp. Returns PRECONDITION_ERROR if not open.
    /// Matches C++ DBM::GetTimestamp(double* timestamp).
    pub fn getTimestamp(self: *TreeDBM, out: *f64) Status {
        if (!self.impl.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        out.* = self.impl.hash_dbm.getTimestampInternal();
        return Status.init(.SUCCESS);
    }

    /// Sets `out` to whether a rebuild would improve performance. Returns PRECONDITION_ERROR if not open.
    /// Matches C++ DBM::ShouldBeRebuilt(bool* tobe).
    pub fn shouldBeRebuilt(self: *TreeDBM, out: *bool) Status {
        if (!self.impl.open) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        out.* = self.impl.hash_dbm.shouldBeRebuiltInternal();
        return Status.init(.SUCCESS);
    }

    pub fn getInternalFile(self: *TreeDBM) File {
        return self.impl.hash_dbm.getInternalFile();
    }

    /// Returns the database type stored in the underlying HashDBM header.
    pub fn getDatabaseType(self: *TreeDBM) i32 {
        return self.impl.hash_dbm.getDatabaseType();
    }

    /// Sets the database type in the underlying HashDBM header.
    pub fn setDatabaseType(self: *TreeDBM, db_type: u32) Status {
        return self.impl.hash_dbm.setDatabaseType(db_type);
    }

    pub fn isOrdered(_: *TreeDBM) bool {
        return true;
    }

    pub fn getKeyComparator(self: *TreeDBM) KeyComparator {
        return self.impl.key_comparator;
    }

    /// Validates every hash-bucket chain in the underlying HashDBM storage.
    /// Matches C++ TreeDBM::ValidateHashBuckets().
    pub fn validateHashBuckets(self: *TreeDBM) Status {
        return self.impl.hash_dbm.validateHashBuckets();
    }

    /// Scans all underlying HashDBM records for structural integrity.
    /// Pass record_base=0 and end_offset=0 to scan the entire record area.
    /// Matches C++ TreeDBM::ValidateRecords().
    pub fn validateRecords(self: *TreeDBM, record_base: i64, end_offset: i64) Status {
        return self.impl.hash_dbm.validateRecords(record_base, end_offset);
    }

    pub fn append(self: *TreeDBM, key: []const u8, value: []const u8, delim: []const u8) Status {
        const AppendProc = struct {
            value: []const u8,
            delim: []const u8,
            allocator: Allocator,
            combined: ?[]u8 = null,

            pub fn processFull(ap: *@This(), _: []const u8, existing: []const u8) RecordAction {
                const new_buf = ap.allocator.alloc(u8, existing.len + ap.delim.len + ap.value.len) catch return .noop;
                @memcpy(new_buf[0..existing.len], existing);
                @memcpy(new_buf[existing.len .. existing.len + ap.delim.len], ap.delim);
                @memcpy(new_buf[existing.len + ap.delim.len ..], ap.value);
                ap.combined = new_buf;
                return RecordAction{ .set = new_buf };
            }

            pub fn processEmpty(ap: *@This(), _: []const u8) RecordAction {
                return RecordAction{ .set = ap.value };
            }
        };
        var proc = AppendProc{ .value = value, .delim = delim, .allocator = self.impl.allocator };
        defer if (proc.combined) |c| self.impl.allocator.free(c);
        return self.impl.processImpl(key, &proc, true);
    }

    /// Fetches values for each key in `keys`, inserting found entries into `records`.
    ///
    /// Both the key and value are duped into `records.allocator`. The caller is responsible
    /// for freeing the duped slices when the map is done.  The return value is SUCCESS if all
    /// keys were found, or the last non-SUCCESS status if any key was missing.  Iteration is
    /// never stopped early — the C++ `|=` semantics are preserved via Status.mergeFrom.
    pub fn getMulti(
        self: *TreeDBM,
        keys: []const []const u8,
        records: *std.StringHashMap([]u8),
    ) Status {
        var status = Status.init(.SUCCESS);
        for (keys) |key| {
            var val_buf: std.ArrayList(u8) = .empty;
            defer val_buf.deinit(self.impl.allocator);
            const st = self.get(key, &val_buf);
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
        self: *TreeDBM,
        records: []const [2][]const u8,
        overwrite: bool,
    ) Status {
        var status = Status.init(.SUCCESS);
        for (records) |r| {
            const st = self.set(r[0], r[1], overwrite, null);
            status.mergeFrom(st);
            if (!status.isOk() and status.code != .DUPLICATION_ERROR) break;
        }
        return status;
    }

    /// Removes each key in `keys`.
    ///
    /// Stops early on any error other than NOT_FOUND_ERROR (matching C++ RemoveMulti semantics).
    pub fn removeMulti(self: *TreeDBM, keys: []const []const u8) Status {
        var status = Status.init(.SUCCESS);
        for (keys) |key| {
            const st = self.remove(key);
            status.mergeFrom(st);
            if (!status.isOk() and status.code != .NOT_FOUND_ERROR) break;
        }
        return status;
    }

    /// Appends to each key/value pair in `records` using `delim` as separator.
    ///
    /// Stops on the first error (matching C++ AppendMulti semantics).
    pub fn appendMulti(
        self: *TreeDBM,
        records: []const [2][]const u8,
        delim: []const u8,
    ) Status {
        var status = Status.init(.SUCCESS);
        for (records) |r| {
            const st = self.append(r[0], r[1], delim);
            status.mergeFrom(st);
            if (!status.isOk()) break;
        }
        return status;
    }

    pub fn compareExchange(
        self: *TreeDBM,
        key: []const u8,
        expected: dbm.CompareExpected,
        desired: dbm.CompareDesired,
        actual_out: ?*std.ArrayList(u8),
        found_out: ?*bool,
    ) Status {
        const CmpExchProc = struct {
            status: Status = Status.init(.SUCCESS),
            expected: dbm.CompareExpected,
            desired: dbm.CompareDesired,
            allocator: Allocator,
            actual_out: ?*std.ArrayList(u8),
            found_out: ?*bool,

            pub fn processFull(p: *@This(), _: []const u8, value: []const u8) RecordAction {
                if (p.found_out) |f| f.* = true;
                if (p.actual_out) |ao| {
                    ao.clearRetainingCapacity();
                    ao.appendSlice(p.allocator, value) catch {
                        p.status = Status.init(.SYSTEM_ERROR);
                        return .noop;
                    };
                }
                const match = switch (p.expected) {
                    .absent => false,
                    .any => true,
                    .exact => |ev| std.mem.eql(u8, ev, value),
                };
                if (!match) {
                    p.status = Status.init(.INFEASIBLE_ERROR);
                    return .noop;
                }
                return switch (p.desired) {
                    .remove => .remove,
                    .noop => .noop,
                    .set => |s| RecordAction{ .set = s },
                };
            }

            pub fn processEmpty(p: *@This(), _: []const u8) RecordAction {
                if (p.found_out) |f| f.* = false;
                const match = switch (p.expected) {
                    .absent => true,
                    .any => false,
                    .exact => false,
                };
                if (!match) {
                    p.status = Status.init(.INFEASIBLE_ERROR);
                    return .noop;
                }
                return switch (p.desired) {
                    .remove => .noop,
                    .noop => .noop,
                    .set => |s| RecordAction{ .set = s },
                };
            }
        };
        var proc = CmpExchProc{
            .expected = expected,
            .desired = desired,
            .allocator = self.impl.allocator,
            .actual_out = actual_out,
            .found_out = found_out,
        };
        const st = self.impl.processImpl(key, &proc, true);
        if (!st.isOk()) return st;
        return proc.status;
    }

    pub fn increment(self: *TreeDBM, key: []const u8, delta: i64, current_out: ?*i64, initial: i64) Status {
        const IncrProc = struct {
            status: Status = Status.init(.SUCCESS),
            delta: i64,
            current_out: ?*i64,
            initial: i64,
            result_buf: [8]u8 = [_]u8{0} ** 8,
            result_slice: []const u8 = &[_]u8{},

            pub fn processFull(p: *@This(), _: []const u8, value: []const u8) RecordAction {
                const current = @as(i64, @bitCast(str_util.strToIntBigEndian(value)));
                if (p.delta == lib_common.INT64MIN) {
                    if (p.current_out) |c| c.* = current;
                    return .noop;
                }
                const new_val = current +% p.delta;
                const enc = str_util.intToStrBigEndian(@as(u64, @bitCast(new_val)), 8, &p.result_buf);
                p.result_slice = enc;
                if (p.current_out) |c| c.* = new_val;
                return RecordAction{ .set = p.result_slice };
            }

            pub fn processEmpty(p: *@This(), _: []const u8) RecordAction {
                if (p.delta == lib_common.INT64MIN) {
                    if (p.current_out) |c| c.* = p.initial;
                    return .noop;
                }
                const new_val = p.initial +% p.delta;
                const enc = str_util.intToStrBigEndian(@as(u64, @bitCast(new_val)), 8, &p.result_buf);
                p.result_slice = enc;
                if (p.current_out) |c| c.* = new_val;
                return RecordAction{ .set = p.result_slice };
            }
        };
        var proc = IncrProc{ .delta = delta, .current_out = current_out, .initial = initial };
        const st = self.impl.processImpl(key, &proc, true);
        if (!st.isOk()) return st;
        return proc.status;
    }

    pub fn incrementSimple(self: *TreeDBM, key: []const u8, delta: i64, initial: i64) i64 {
        var result: i64 = initial;
        _ = self.increment(key, delta, &result, initial);
        return result;
    }

    pub fn popFirst(self: *TreeDBM, key_out: ?*std.ArrayList(u8), value_out: ?*std.ArrayList(u8)) Status {
        const PopProc = struct {
            status: Status = Status.init(.SUCCESS),
            key_out: ?*std.ArrayList(u8),
            value_out: ?*std.ArrayList(u8),
            allocator: Allocator,

            pub fn processFull(p: *@This(), k: []const u8, v: []const u8) RecordAction {
                if (p.key_out) |ko| {
                    ko.clearRetainingCapacity();
                    ko.appendSlice(p.allocator, k) catch {
                        p.status = Status.init(.SYSTEM_ERROR);
                        return .noop;
                    };
                }
                if (p.value_out) |vo| {
                    vo.clearRetainingCapacity();
                    vo.appendSlice(p.allocator, v) catch {
                        p.status = Status.init(.SYSTEM_ERROR);
                        return .noop;
                    };
                }
                return .remove;
            }

            pub fn processEmpty(_: *@This(), _: []const u8) RecordAction {
                return .noop;
            }
        };
        var proc = PopProc{ .key_out = key_out, .value_out = value_out, .allocator = self.impl.allocator };
        const st = self.impl.processFirstImpl(&proc, true);
        if (!st.isOk()) return st;
        return proc.status;
    }

    pub fn pushLast(self: *TreeDBM, value: []const u8, wtime: f64, key_out: ?*std.ArrayList(u8), io: std.Io) Status {
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
                    ko.appendSlice(self.impl.allocator, key) catch return Status.init(.SYSTEM_ERROR);
                }
                return st;
            }
        }
    }

    pub fn processMulti(
        self: *TreeDBM,
        comptime P: type,
        keys: []const []const u8,
        procs: []const *P,
        writable: bool,
    ) Status {
        var status = Status.init(.SUCCESS);
        for (keys, procs) |key, proc| {
            status.mergeFrom(self.impl.processImpl(key, proc, writable));
        }
        return status;
    }

    pub fn inspect(self: *TreeDBM, allocator: std.mem.Allocator) !std.ArrayList([2][]u8) {
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
        try add(&list, allocator, "class", "TreeDBM");
        if (self.impl.open) {
            try add(&list, allocator, "healthy", if (self.impl.healthy) "true" else "false");
            try add(&list, allocator, "auto_restored", if (self.impl.auto_restored) "true" else "false");
            try add(&list, allocator, "path", self.impl.path.items);
            const nr = try std.fmt.allocPrint(allocator, "{d}", .{self.impl.num_records.load(.acquire)});
            defer allocator.free(nr);
            try add(&list, allocator, "num_records", nr);
            const eds = try std.fmt.allocPrint(allocator, "{d}", .{self.impl.eff_data_size.load(.acquire)});
            defer allocator.free(eds);
            try add(&list, allocator, "eff_data_size", eds);
            const root_id_s = try std.fmt.allocPrint(allocator, "{d}", .{self.impl.root_id});
            defer allocator.free(root_id_s);
            try add(&list, allocator, "root_id", root_id_s);
            const first_id_s = try std.fmt.allocPrint(allocator, "{d}", .{self.impl.first_id});
            defer allocator.free(first_id_s);
            try add(&list, allocator, "first_id", first_id_s);
            const last_id_s = try std.fmt.allocPrint(allocator, "{d}", .{self.impl.last_id});
            defer allocator.free(last_id_s);
            try add(&list, allocator, "last_id", last_id_s);
            const nl = try std.fmt.allocPrint(allocator, "{d}", .{self.impl.num_leaf_nodes});
            defer allocator.free(nl);
            try add(&list, allocator, "num_leaf_nodes", nl);
            const ni = try std.fmt.allocPrint(allocator, "{d}", .{self.impl.num_inner_nodes});
            defer allocator.free(ni);
            try add(&list, allocator, "num_inner_nodes", ni);
            const tl = try std.fmt.allocPrint(allocator, "{d}", .{self.impl.tree_level});
            defer allocator.free(tl);
            try add(&list, allocator, "tree_level", tl);
            const mps = try std.fmt.allocPrint(allocator, "{d}", .{self.impl.max_page_size});
            defer allocator.free(mps);
            try add(&list, allocator, "max_page_size", mps);
            const mb = try std.fmt.allocPrint(allocator, "{d}", .{self.impl.max_branches});
            defer allocator.free(mb);
            try add(&list, allocator, "max_branches", mb);
            const mcp = try std.fmt.allocPrint(allocator, "{d}", .{self.impl.max_cached_pages});
            defer allocator.free(mcp);
            try add(&list, allocator, "max_cached_pages", mcp);
            const kc_name: []const u8 = if (self.impl.key_comparator == lib_common.lexicalKeyComparator)
                "LexicalKeyComparator"
            else if (self.impl.key_comparator == lib_common.lexicalCaseKeyComparator)
                "LexicalCaseKeyComparator"
            else if (self.impl.key_comparator == lib_common.decimalKeyComparator)
                "DecimalKeyComparator"
            else if (self.impl.key_comparator == lib_common.hexadecimalKeyComparator)
                "HexadecimalKeyComparator"
            else if (self.impl.key_comparator == lib_common.realNumberKeyComparator)
                "RealNumberKeyComparator"
            else if (self.impl.key_comparator == lib_common.signedBigEndianKeyComparator)
                "SignedBigEndianKeyComparator"
            else if (self.impl.key_comparator == lib_common.floatBigEndianKeyComparator)
                "FloatBigEndianKeyComparator"
            else if (self.impl.key_comparator == lib_common.pairLexicalKeyComparator)
                "PairLexicalKeyComparator"
            else if (self.impl.key_comparator == lib_common.pairLexicalCaseKeyComparator)
                "PairLexicalCaseKeyComparator"
            else if (self.impl.key_comparator == lib_common.pairDecimalKeyComparator)
                "PairDecimalKeyComparator"
            else if (self.impl.key_comparator == lib_common.pairHexadecimalKeyComparator)
                "PairHexadecimalKeyComparator"
            else if (self.impl.key_comparator == lib_common.pairRealNumberKeyComparator)
                "PairRealNumberKeyComparator"
            else if (self.impl.key_comparator == lib_common.pairSignedBigEndianKeyComparator)
                "PairSignedBigEndianKeyComparator"
            else if (self.impl.key_comparator == lib_common.pairFloatBigEndianKeyComparator)
                "PairFloatBigEndianKeyComparator"
            else
                "custom";
            try add(&list, allocator, "key_comparator", kc_name);

            // Append renamed entries from the underlying HashDBM inspect output.
            var hash_list = try self.impl.hash_dbm.inspect(allocator);
            defer {
                for (hash_list.items) |pair| {
                    allocator.free(pair[0]);
                    allocator.free(pair[1]);
                }
                hash_list.deinit(allocator);
            }
            for (hash_list.items) |pair| {
                const hk = pair[0];
                const hv = pair[1];
                const renamed: ?[]const u8 = if (std.mem.eql(u8, hk, "class"))
                    null
                else if (std.mem.eql(u8, hk, "path"))
                    null
                else if (std.mem.eql(u8, hk, "num_buckets"))
                    "hash_num_buckets"
                else if (std.mem.eql(u8, hk, "num_records"))
                    "hash_num_records"
                else if (std.mem.eql(u8, hk, "eff_data_size"))
                    "hash_eff_data_size"
                else
                    hk;
                if (renamed) |rk| {
                    try add(&list, allocator, rk, hv);
                }
            }
        }
        return list;
    }

    /// Make a cursor; caller must call `cursor.deinit()` when done.
    pub fn makeCursor(self: *TreeDBM) !Cursor {
        const it = try self.impl.allocator.create(TreeDBMIteratorImpl);
        it.* = .{
            .dbm_impl = self.impl,
            .key_buf = undefined,
            .key_heap = null,
            .key_size = 0,
            .leaf_id = 0,
            .allocator = self.impl.allocator,
        };
        try self.impl.iterators.append(self.impl.allocator, it);
        return Cursor{ .impl = it, .dbm_impl = self.impl };
    }

    /// Deprecated: use makeCursor instead.
    pub const makeIterator = makeCursor;

    // -----------------------------------------------------------------------
    // Static methods (Phase 5.3)
    // -----------------------------------------------------------------------

    /// Parses tree structural metadata from the HashDBM opaque_metadata field.
    /// meta_buf must be at least HashDBM.OPAQUE_METADATA_SIZE (64) bytes.
    /// Matches C++ TreeDBM::ParseMetadata().
    pub fn parseMetadata(
        meta_buf: []const u8,
        num_records_out: *i64,
        eff_data_size_out: *i64,
        root_id_out: *i64,
        first_id_out: *i64,
        last_id_out: *i64,
        num_leaf_nodes_out: *i64,
        num_inner_nodes_out: *i64,
        max_page_size_out: *i32,
        max_branches_out: *i32,
        tree_level_out: *i32,
        key_comp_type_out: *i32,
        mini_opaque_out: *[OPAQUE_METADATA_SIZE]u8,
    ) Status {
        if (meta_buf.len < dbm_hash.OPAQUE_METADATA_SIZE)
            return Status.initMsg(.BROKEN_DATA_ERROR, "missing metadata");
        if (!std.mem.eql(u8, meta_buf[0..3], META_MAGIC))
            return Status.initMsg(.BROKEN_DATA_ERROR, "bad magic data");
        num_records_out.* = readFixNum(meta_buf[META_OFFSET_NUM_RECORDS..], 6);
        eff_data_size_out.* = readFixNum(meta_buf[META_OFFSET_EFF_DATA_SIZE..], 6);
        root_id_out.* = readFixNum(meta_buf[META_OFFSET_ROOT_ID..], 6);
        first_id_out.* = readFixNum(meta_buf[META_OFFSET_FIRST_ID..], 6);
        last_id_out.* = readFixNum(meta_buf[META_OFFSET_LAST_ID..], 6);
        num_leaf_nodes_out.* = readFixNum(meta_buf[META_OFFSET_NUM_LEAF_NODES..], 6);
        num_inner_nodes_out.* = readFixNum(meta_buf[META_OFFSET_NUM_INNER_NODES..], 6);
        max_page_size_out.* = @intCast(readFixNum(meta_buf[META_OFFSET_MAX_PAGE_SIZE..], 3));
        max_branches_out.* = @intCast(readFixNum(meta_buf[META_OFFSET_MAX_BRANCHES..], 3));
        tree_level_out.* = meta_buf[META_OFFSET_TREE_LEVEL];
        key_comp_type_out.* = meta_buf[META_OFFSET_KEY_COMPARATOR];
        const avail = meta_buf.len - META_OFFSET_OPAQUE;
        const mini_len = @min(OPAQUE_METADATA_SIZE, avail);
        @memset(mini_opaque_out, 0);
        @memcpy(mini_opaque_out[0..mini_len], meta_buf[META_OFFSET_OPAQUE .. META_OFFSET_OPAQUE + mini_len]);
        return Status.init(.SUCCESS);
    }

    /// Restores a broken TreeDBM by rebuilding from a (possibly restored) source file.
    /// Matches C++ TreeDBM::RestoreDatabase().
    pub fn restoreDatabase(
        allocator: std.mem.Allocator,
        old_path: []const u8,
        new_path: []const u8,
        end_offset: i64,
        cipher_key: []const u8,
        io: std.Io,
    ) Status {
        _ = cipher_key;
        // Use sentinel values to distinguish "skip hash restore" from normal end_offset.
        const min_i64 = std.math.minInt(i64);
        const max_i64 = std.math.maxInt(i64);
        const skip_hash_restore = (end_offset == min_i64 or end_offset == max_i64);

        if (!skip_hash_restore) {
            // First restore the hash layer to a temporary path, then rebuild the tree from it.
            const tmp_path = allocator.alloc(u8, new_path.len + 16) catch return Status.init(.SYSTEM_ERROR);
            defer allocator.free(tmp_path);
            const filled = std.fmt.bufPrint(tmp_path, "{s}.tmp.restore", .{new_path}) catch
                return Status.init(.SYSTEM_ERROR);
            const hash_end: i64 = end_offset;
            const st = HashDBM.restoreDatabase(allocator, old_path, filled, hash_end, "", io);
            if (!st.isOk()) return st;
            const st2 = rebuildTreeFromHashFile(allocator, filled, new_path, io);
            // Clean up temp file regardless of rebuild outcome.
            file_mod.deleteFileAbsolute(filled);
            return st2;
        }

        return rebuildTreeFromHashFile(allocator, old_path, new_path, io);
    }

    fn rebuildTreeFromHashFile(
        allocator: std.mem.Allocator,
        src_path: []const u8,
        new_path: []const u8,
        io: std.Io,
    ) Status {
        // Open source as a TreeDBM to iterate user-visible records.
        const src_sf = file_mod.StdFile.create(allocator) catch return Status.init(.SYSTEM_ERROR);
        var src_db = TreeDBM.init(src_sf.asFile(), allocator) catch {
            src_sf.asFile().deinit(allocator);
            return Status.init(.SYSTEM_ERROR);
        };
        defer src_db.deinit();
        {
            const st = src_db.open(src_path, false, .{ .no_lock = true }, io); // restore source; may be broken/unlocked
            if (!st.isOk()) return st;
        }

        // Read tuning parameters from source metadata.
        const src_opaque = src_db.impl.hash_dbm.getOpaqueMetadata();
        var nr: i64 = 0;
        var eds: i64 = 0;
        var root_id: i64 = 0;
        var first_id: i64 = 0;
        var last_id: i64 = 0;
        var nleaf: i64 = 0;
        var ninner: i64 = 0;
        var max_page: i32 = DEFAULT_MAX_PAGE_SIZE;
        var max_branches: i32 = DEFAULT_MAX_BRANCHES;
        var tree_level: i32 = 0;
        var kc_type: i32 = 0;
        var mini_op: [OPAQUE_METADATA_SIZE]u8 = [_]u8{0} ** OPAQUE_METADATA_SIZE;
        var opaque_buf: [dbm_hash.OPAQUE_METADATA_SIZE]u8 = [_]u8{0} ** dbm_hash.OPAQUE_METADATA_SIZE;
        @memcpy(opaque_buf[0..@min(src_opaque.len, dbm_hash.OPAQUE_METADATA_SIZE)], src_opaque[0..@min(src_opaque.len, dbm_hash.OPAQUE_METADATA_SIZE)]);
        _ = TreeDBM.parseMetadata(&opaque_buf, &nr, &eds, &root_id, &first_id, &last_id,
            &nleaf, &ninner, &max_page, &max_branches, &tree_level, &kc_type, &mini_op);

        // Create destination TreeDBM.
        const new_sf = file_mod.StdFile.create(allocator) catch return Status.init(.SYSTEM_ERROR);
        var new_db = TreeDBM.init(new_sf.asFile(), allocator) catch {
            new_sf.asFile().deinit(allocator);
            return Status.init(.SYSTEM_ERROR);
        };
        defer new_db.deinit();
        {
            const params = TuningParameters{
                .max_page_size = if (max_page > 0) max_page else DEFAULT_MAX_PAGE_SIZE,
                .max_branches = if (max_branches > 0) max_branches else DEFAULT_MAX_BRANCHES,
            };
            const st = new_db.openAdvanced(new_path, true, .{ .truncate = true }, params, io);
            if (!st.isOk()) return st;
        }

        // Copy all user records from source to destination.
        var iter = src_db.makeCursor() catch return Status.init(.SYSTEM_ERROR);
        defer iter.deinit();
        _ = iter.first();
        while (true) {
            var key_list: std.ArrayList(u8) = .empty;
            defer key_list.deinit(allocator);
            var val_list: std.ArrayList(u8) = .empty;
            defer val_list.deinit(allocator);
            const st_get = iter.get(&key_list, &val_list);
            if (!st_get.isOk()) break;
            _ = new_db.set(key_list.items, val_list.items, true, null);
            _ = iter.next();
        }

        return new_db.close(io);
    }

    // -----------------------------------------------------------------------
    // Phase 6: Base class methods
    // -----------------------------------------------------------------------

    /// Creates a new heap-allocated TreeDBM instance.
    pub fn makeDbm(allocator: std.mem.Allocator) !*TreeDBM {
        const sf = try file_mod.StdFile.create(allocator);
        const new_dbm = try allocator.create(TreeDBM);
        errdefer allocator.destroy(new_dbm);
        new_dbm.* = TreeDBM.init(sf.asFile(), allocator) catch |e| {
            // asFile() transfers ownership, so deinit through the File interface.
            sf.asFile().deinit(allocator);
            return e;
        };
        return new_dbm;
    }

    /// Returns the record count or -1 when not open. Matches C++ DBM::CountSimple().
    pub fn countSimple(self: *TreeDBM) i64 {
        if (!self.impl.open) return -1;
        return self.impl.num_records.load(.acquire);
    }

    /// Returns the file size in bytes or -1 when not open. Matches C++ DBM::GetFileSizeSimple().
    pub fn getFileSizeSimple(self: *TreeDBM) i64 {
        if (!self.impl.open) return -1;
        return self.impl.hash_dbm.getFileSizeInternal();
    }

    /// Returns the file path or "" when not open. Matches C++ DBM::GetFilePathSimple().
    pub fn getFilePathSimple(self: *TreeDBM) []const u8 {
        if (!self.impl.open) return "";
        return self.impl.path.items;
    }

    /// Returns the timestamp or NaN when not open. Matches C++ DBM::GetTimestampSimple().
    pub fn getTimestampSimple(self: *TreeDBM) f64 {
        if (!self.impl.open) return std.math.nan(f64);
        return self.impl.hash_dbm.getTimestampInternal();
    }

    /// Returns whether a rebuild would improve performance, or false when not open.
    /// Matches C++ DBM::ShouldBeRebuiltSimple().
    pub fn shouldBeRebuiltSimple(self: *TreeDBM) bool {
        if (!self.impl.open) return false;
        return self.impl.hash_dbm.shouldBeRebuiltInternal();
    }

    /// Copies the database file to dest_path, optionally syncing first.
    pub fn copyFileData(self: *TreeDBM, dest_path: []const u8, sync_hard: bool, io: std.Io) Status {
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

    /// Renames a key. Reads old value, sets under new_key, removes old_key unless copying=true.
    pub fn rekey(self: *TreeDBM, old_key: []const u8, new_key: []const u8, overwrite: bool, copying: bool) Status {
        if (!self.isOpen() or !self.isWritable())
            return Status.initMsg(.PRECONDITION_ERROR, "not writable");

        var value_list: std.ArrayList(u8) = .empty;
        defer value_list.deinit(self.impl.allocator);

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
    pub fn export_(self: *TreeDBM, dest: anytype) Status {
        var iter = self.makeCursor() catch return Status.init(.SYSTEM_ERROR);
        defer iter.deinit();
        var st = iter.first();
        if (st.code == .NOT_FOUND_ERROR) return Status.init(.SUCCESS);
        if (!st.isOk()) return st;
        while (true) {
            var key_list: std.ArrayList(u8) = .empty;
            defer key_list.deinit(self.impl.allocator);
            var val_list: std.ArrayList(u8) = .empty;
            defer val_list.deinit(self.impl.allocator);
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
    pub fn compareExchangeMulti(
        self: *TreeDBM,
        expected: []const struct { key: []const u8, value: dbm.CompareExpected },
        desired: []const struct { key: []const u8, value: dbm.CompareDesired },
    ) Status {
        for (expected) |cond| {
            var val_list: std.ArrayList(u8) = .empty;
            defer val_list.deinit(self.impl.allocator);
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

    // -----------------------------------------------------------------------
    // Cursor (public wrapper around TreeDBMIteratorImpl)
    // -----------------------------------------------------------------------

    pub const Cursor = struct {
        impl: *TreeDBMIteratorImpl,
        dbm_impl: *TreeDBMImpl,

        pub fn deinit(self: *Cursor) void {
            // If close() has run on the DBM, it nulled `impl.dbm_impl` and
            // cleared the iterators list. In that case we must NOT touch
            // `self.dbm_impl.iterators` (which may be mid-teardown in
            // TreeDBMImpl.deinit, or freed if the DBM has been deinited),
            // we only need to free the impl.
            if (self.impl.dbm_impl != null) {
                // Unregister from dbm_impl's iterator list.
                for (self.dbm_impl.iterators.items, 0..) |it, i| {
                    if (it == self.impl) {
                        _ = self.dbm_impl.iterators.orderedRemove(i);
                        break;
                    }
                }
            }
            self.impl.deinit();
        }

        pub fn first(self: *Cursor) Status {
            self.dbm_impl.mutex.lockShared();
            defer self.dbm_impl.mutex.unlockShared();
            return iterSetPositionFirst(self.impl) catch Status.init(.SYSTEM_ERROR);
        }

        pub fn last(self: *Cursor) Status {
            self.dbm_impl.mutex.lockShared();
            defer self.dbm_impl.mutex.unlockShared();
            return iterSetPositionLast(self.impl) catch Status.init(.SYSTEM_ERROR);
        }

        pub fn jump(self: *Cursor, key: []const u8) Status {
            self.dbm_impl.mutex.lockShared();
            defer self.dbm_impl.mutex.unlockShared();
            return iterJump(self.impl, key) catch Status.init(.SYSTEM_ERROR);
        }

        pub fn jumpLower(self: *Cursor, key: []const u8, inclusive: bool) Status {
            self.dbm_impl.mutex.lockShared();
            defer self.dbm_impl.mutex.unlockShared();
            return iterJumpLower(self.impl, key, inclusive) catch Status.init(.SYSTEM_ERROR);
        }

        pub fn jumpUpper(self: *Cursor, key: []const u8, inclusive: bool) Status {
            self.dbm_impl.mutex.lockShared();
            defer self.dbm_impl.mutex.unlockShared();
            return iterJumpUpper(self.impl, key, inclusive) catch Status.init(.SYSTEM_ERROR);
        }

        pub fn next(self: *Cursor) Status {
            self.dbm_impl.mutex.lockShared();
            defer self.dbm_impl.mutex.unlockShared();
            return iterNext(self.impl) catch Status.init(.SYSTEM_ERROR);
        }

        pub fn previous(self: *Cursor) Status {
            self.dbm_impl.mutex.lockShared();
            defer self.dbm_impl.mutex.unlockShared();
            return iterPrevious(self.impl) catch Status.init(.SYSTEM_ERROR);
        }

        pub fn get(self: *Cursor, key_out: ?*std.ArrayList(u8), value_out: ?*std.ArrayList(u8)) Status {
            self.dbm_impl.mutex.lockShared();
            defer self.dbm_impl.mutex.unlockShared();
            return iterGetCurrent(self.impl, key_out, value_out);
        }

        pub fn set(self: *Cursor, value: []const u8, old_key: ?*std.ArrayList(u8), old_value: ?*std.ArrayList(u8)) Status {
            const SetProc = struct {
                value: []const u8,
                old_key: ?*std.ArrayList(u8),
                old_value: ?*std.ArrayList(u8),
                allocator: Allocator,
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
            const alloc = self.dbm_impl.allocator;
            var proc = SetProc{ .value = value, .old_key = old_key, .old_value = old_value, .allocator = alloc };
            const st = self.process(&proc, true);
            if (!st.isOk()) return st;
            return proc.status;
        }

        pub fn remove(self: *Cursor, old_key: ?*std.ArrayList(u8), old_value: ?*std.ArrayList(u8)) Status {
            const RemoveProc = struct {
                old_key: ?*std.ArrayList(u8),
                old_value: ?*std.ArrayList(u8),
                allocator: Allocator,
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
            const alloc = self.dbm_impl.allocator;
            var proc = RemoveProc{ .old_key = old_key, .old_value = old_value, .allocator = alloc };
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

        pub fn process(self: *Cursor, proc: anytype, writable: bool) Status {
            if (writable) {
                self.dbm_impl.mutex.lock();
                defer self.dbm_impl.mutex.unlock();
            } else {
                self.dbm_impl.mutex.lockShared();
                defer self.dbm_impl.mutex.unlockShared();
            }
            return iterProcess(self.impl, proc, writable);
        }
    };

    /// Entry returned by the Zig-style iterator.
    /// Both slices point into internal buffers and are invalidated on the next
    /// call to next() or deinit(). Copy them if you need the data to outlive this call.
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
        pub fn next(self: *Iterator) !?Entry {
            if (self.done) return null;

            // Fill internal buffers from the current cursor position.
            var filled = false;
            const Proc = struct {
                key_buf: *std.ArrayList(u8),
                val_buf: *std.ArrayList(u8),
                alloc: std.mem.Allocator,
                filled: *bool,

                oom: bool = false,
                pub fn processFull(p: *@This(), key: []const u8, val: []const u8) RecordAction {
                    p.key_buf.clearRetainingCapacity();
                    p.val_buf.clearRetainingCapacity();
                    p.key_buf.appendSlice(p.alloc, key) catch { p.oom = true; return .noop; };
                    p.val_buf.appendSlice(p.alloc, val) catch { p.oom = true; return .noop; };
                    p.filled.* = true;
                    return .noop;
                }

                pub fn processEmpty(p: *@This(), _: []const u8) RecordAction {
                    _ = p;
                    return .noop;
                }
            };
            var proc = Proc{
                .key_buf = &self.key_buf,
                .val_buf = &self.value_buf,
                .alloc = self.alloc,
                .filled = &filled,
            };
            _ = self.cursor.process(&proc, false);
            if (proc.oom) return error.OutOfMemory;

            if (!filled) {
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

    /// Return a Zig-style iterator positioned at the first record.
    /// The caller must call deinit() when done.
    pub fn iterate(self: *TreeDBM, alloc: std.mem.Allocator) !Iterator {
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
    pub fn iterateFrom(self: *TreeDBM, key: []const u8, alloc: std.mem.Allocator) !Iterator {
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
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn openTestDB(tmp_path: []const u8, params: TuningParameters) !TreeDBM {
    const sf = try file_mod.StdFile.create(testing.allocator);
    var db = try TreeDBM.init(sf.asFile(), testing.allocator);
    errdefer db.deinit();
    const st = db.openAdvanced(tmp_path, true, .{ .truncate = true }, params, std.testing.io);
    try testing.expect(st.isOk());
    return db;
}

test "TreeDBM: basic set/get/remove" {
    const tmp = "/tmp/tkrzw_tree_basic.tkt";
    var db = try openTestDB(tmp, .{});
    defer db.deinit();

    try testing.expect(db.set("hello", "world", true, null).isOk());
    try testing.expect(db.set("foo", "bar", true, null).isOk());
    try testing.expectEqual(@as(i64, 2), db.countSimple());

    var val = ArrayList(u8).empty;
    defer val.deinit(testing.allocator);
    try testing.expect(db.get("hello", &val).isOk());
    try testing.expectEqualStrings("world", val.items);

    try testing.expect(db.get("missing", null).code == .NOT_FOUND_ERROR);
    try testing.expect(db.remove("hello").isOk());
    try testing.expect(db.get("hello", null).code == .NOT_FOUND_ERROR);
    try testing.expectEqual(@as(i64, 1), db.countSimple());
}

test "TreeDBM: overwrite and duplication" {
    const tmp = "/tmp/tkrzw_tree_overwrite.tkt";
    var db = try openTestDB(tmp, .{});
    defer db.deinit();

    try testing.expect(db.set("k", "v1", true, null).isOk());
    try testing.expect(db.set("k", "v2", true, null).isOk());

    var val = ArrayList(u8).empty;
    defer val.deinit(testing.allocator);
    try testing.expect(db.get("k", &val).isOk());
    try testing.expectEqualStrings("v2", val.items);

    try testing.expectEqual(Code.DUPLICATION_ERROR, db.set("k", "v3", false, null).code);
    try testing.expect(db.get("k", &val).isOk());
    try testing.expectEqualStrings("v2", val.items);
}

test "TreeDBM: sequential insertion and forward scan" {
    const tmp = "/tmp/tkrzw_tree_seq.tkt";
    var db = try openTestDB(tmp, .{ .max_page_size = 512, .max_branches = 4 });
    defer db.deinit();

    const N = 200;
    var key_buf: [32]u8 = undefined;
    var val_buf: [32]u8 = undefined;
    for (0..N) |i| {
        const k = std.fmt.bufPrint(&key_buf, "key{d:04}", .{i}) catch unreachable;
        const v = std.fmt.bufPrint(&val_buf, "val{d:04}", .{i}) catch unreachable;
        try testing.expect(db.set(k, v, true, null).isOk());
    }
    try testing.expectEqual(@as(i64, N), db.countSimple());

    var it = try db.makeCursor();
    defer it.deinit();
    try testing.expect(it.first().isOk());
    var seen: usize = 0;
    while (true) {
        var k = ArrayList(u8).empty;
        defer k.deinit(testing.allocator);
        var v = ArrayList(u8).empty;
        defer v.deinit(testing.allocator);
        const st = it.get(&k, &v);
        if (st.code == .NOT_FOUND_ERROR) break;
        try testing.expect(st.isOk());
        seen += 1;
        try testing.expect(it.next().isOk() or seen == N);
        if (seen == N) break;
    }
    try testing.expectEqual(N, seen);
}

test "TreeDBM: reverse scan" {
    const tmp = "/tmp/tkrzw_tree_rev.tkt";
    var db = try openTestDB(tmp, .{ .max_page_size = 512, .max_branches = 4 });
    defer db.deinit();

    const N = 50;
    var key_buf: [32]u8 = undefined;
    var val_buf: [32]u8 = undefined;
    for (0..N) |i| {
        const k = std.fmt.bufPrint(&key_buf, "key{d:04}", .{i}) catch unreachable;
        const v = std.fmt.bufPrint(&val_buf, "val{d:04}", .{i}) catch unreachable;
        try testing.expect(db.set(k, v, true, null).isOk());
    }

    var it = try db.makeCursor();
    defer it.deinit();
    try testing.expect(it.last().isOk());
    var count: usize = 0;
    while (true) {
        var k = ArrayList(u8).empty;
        defer k.deinit(testing.allocator);
        const st = it.get(&k, null);
        if (st.code == .NOT_FOUND_ERROR) break;
        try testing.expect(st.isOk());
        count += 1;
        if (it.previous().code == .NOT_FOUND_ERROR) break;
    }
    try testing.expectEqual(@as(usize, N), count);
}

test "TreeDBM: jump iterator" {
    const tmp = "/tmp/tkrzw_tree_jump.tkt";
    var db = try openTestDB(tmp, .{});
    defer db.deinit();

    try testing.expect(db.set("a", "1", true, null).isOk());
    try testing.expect(db.set("c", "3", true, null).isOk());
    try testing.expect(db.set("e", "5", true, null).isOk());

    var it = try db.makeCursor();
    defer it.deinit();

    try testing.expect(it.jump("c").isOk());
    var key = ArrayList(u8).empty;
    defer key.deinit(testing.allocator);
    try testing.expect(it.get(&key, null).isOk());
    try testing.expectEqualStrings("c", key.items);

    // Jump to key between existing records.
    try testing.expect(it.jump("b").isOk());
    key.clearRetainingCapacity();
    try testing.expect(it.get(&key, null).isOk());
    try testing.expectEqualStrings("c", key.items);
}

test "TreeDBM: jumpLower / jumpUpper" {
    const tmp = "/tmp/tkrzw_tree_bound.tkt";
    var db = try openTestDB(tmp, .{});
    defer db.deinit();

    for ([_][]const u8{ "a", "c", "e", "g" }) |k| {
        try testing.expect(db.set(k, k, true, null).isOk());
    }

    var it = try db.makeCursor();
    defer it.deinit();
    var key = ArrayList(u8).empty;
    defer key.deinit(testing.allocator);

    // jumpLower inclusive of "c" → "c"
    try testing.expect(it.jumpLower("c", true).isOk());
    key.clearRetainingCapacity();
    try testing.expect(it.get(&key, null).isOk());
    try testing.expectEqualStrings("c", key.items);

    // jumpLower exclusive of "c" → "a"
    try testing.expect(it.jumpLower("c", false).isOk());
    key.clearRetainingCapacity();
    try testing.expect(it.get(&key, null).isOk());
    try testing.expectEqualStrings("a", key.items);

    // jumpUpper inclusive of "c" → "c"
    try testing.expect(it.jumpUpper("c", true).isOk());
    key.clearRetainingCapacity();
    try testing.expect(it.get(&key, null).isOk());
    try testing.expectEqualStrings("c", key.items);

    // jumpUpper exclusive of "c" → "e"
    try testing.expect(it.jumpUpper("c", false).isOk());
    key.clearRetainingCapacity();
    try testing.expect(it.get(&key, null).isOk());
    try testing.expectEqualStrings("e", key.items);
}

test "TreeDBM: processFirst and processEach" {
    const tmp = "/tmp/tkrzw_tree_process.tkt";
    var db = try openTestDB(tmp, .{});
    defer db.deinit();

    try testing.expect(db.set("k1", "v1", true, null).isOk());
    try testing.expect(db.set("k2", "v2", true, null).isOk());

    const GetFirst = struct {
        key: ArrayList(u8),
        pub fn processFull(p: *@This(), k: []const u8, _: []const u8) RecordAction {
            p.key.clearRetainingCapacity();
            p.key.appendSlice(testing.allocator, k) catch {};
            return .noop;
        }
        pub fn processEmpty(_: *@This(), _: []const u8) RecordAction { return .noop; }
    };
    var gf = GetFirst{ .key = ArrayList(u8).empty };
    defer gf.key.deinit(testing.allocator);
    try testing.expect(db.processFirst(&gf, false).isOk());
    try testing.expectEqualStrings("k1", gf.key.items);

    var record_count: usize = 0;
    const Counter = struct {
        count: *usize,
        pub fn processFull(p: *@This(), _: []const u8, _: []const u8) RecordAction {
            p.count.* += 1;
            return .noop;
        }
        pub fn processEmpty(_: *@This(), _: []const u8) RecordAction { return .noop; }
    };
    var counter = Counter{ .count = &record_count };
    try testing.expect(db.processEach(&counter, false).isOk());
    try testing.expectEqual(@as(usize, 2), record_count);
}

test "TreeDBM: clear" {
    const tmp = "/tmp/tkrzw_tree_clear.tkt";
    var db = try openTestDB(tmp, .{});
    defer db.deinit();

    try testing.expect(db.set("x", "y", true, null).isOk());
    try testing.expectEqual(@as(i64, 1), db.countSimple());
    try testing.expect(db.clear().isOk());
    try testing.expectEqual(@as(i64, 0), db.countSimple());
}

test "TreeDBM: synchronize and reopen" {
    const tmp = "/tmp/tkrzw_tree_sync.tkt";
    {
        var db = try openTestDB(tmp, .{});
        defer db.deinit();
        try testing.expect(db.set("persist", "yes", true, null).isOk());
        try testing.expect(db.synchronize(false, std.testing.io).isOk());
    }
    {
        const sf2 = try file_mod.StdFile.create(testing.allocator);
        var db = try TreeDBM.init(sf2.asFile(), testing.allocator);
        defer db.deinit();
        try testing.expect(db.open(tmp, false, .{}, std.testing.io).isOk());
        var val = ArrayList(u8).empty;
        defer val.deinit(testing.allocator);
        try testing.expect(db.get("persist", &val).isOk());
        try testing.expectEqualStrings("yes", val.items);
    }
}

test "TreeDBM: rebuild" {
    const tmp = "/tmp/tkrzw_tree_rebuild.tkt";
    var db = try openTestDB(tmp, .{});
    defer db.deinit();

    for (0..50) |i| {
        var k: [8]u8 = undefined;
        const ks = std.fmt.bufPrint(&k, "k{d:04}", .{i}) catch unreachable;
        try testing.expect(db.set(ks, "v", true, null).isOk());
    }
    try testing.expect(db.rebuild(std.testing.io).isOk());
    try testing.expectEqual(@as(i64, 50), db.countSimple());
}

test "TreeDBM: large values trigger splits" {
    const tmp = "/tmp/tkrzw_tree_split.tkt";
    var db = try openTestDB(tmp, .{ .max_page_size = 256, .max_branches = 4 });
    defer db.deinit();

    const long_val = "x" ** 64;
    var key_buf: [16]u8 = undefined;
    for (0..30) |i| {
        const k = std.fmt.bufPrint(&key_buf, "key{d:03}", .{i}) catch unreachable;
        try testing.expect(db.set(k, long_val, true, null).isOk());
    }
    try testing.expectEqual(@as(i64, 30), db.countSimple());
    // Verify all keys are retrievable.
    var val = ArrayList(u8).empty;
    defer val.deinit(testing.allocator);
    for (0..30) |i| {
        const k = std.fmt.bufPrint(&key_buf, "key{d:03}", .{i}) catch unreachable;
        try testing.expect(db.get(k, &val).isOk());
        try testing.expectEqualStrings(long_val, val.items);
    }
}

test "TreeDBM: getDatabaseType and setDatabaseType" {
    const tmp = "/tmp/tkrzw_tree_dbtype.tkt";
    {
        var db = try openTestDB(tmp, .{});
        defer db.deinit();
        try testing.expectEqual(@as(i32, 0), db.getDatabaseType());
        try testing.expect(db.setDatabaseType(99).isOk());
        try testing.expectEqual(@as(i32, 99), db.getDatabaseType());
        try testing.expect(db.synchronize(false, std.testing.io).isOk());
    }
    {
        const sf2 = try file_mod.StdFile.create(testing.allocator);
        var db = try TreeDBM.init(sf2.asFile(), testing.allocator);
        defer db.deinit();
        try testing.expect(db.open(tmp, false, .{}, std.testing.io).isOk());
        try testing.expectEqual(@as(i32, 99), db.getDatabaseType());
    }
}

test "TreeDBM: opaque metadata" {
    const tmp = "/tmp/tkrzw_tree_opaque.tkt";
    {
        var db = try openTestDB(tmp, .{});
        defer db.deinit();
        try testing.expect(db.setOpaqueMetadata("hello").isOk());
        try testing.expectEqualStrings("hello", db.getOpaqueMetadata());
        try testing.expect(db.synchronize(false, std.testing.io).isOk());
    }
    {
        const sf2 = try file_mod.StdFile.create(testing.allocator);
        var db = try TreeDBM.init(sf2.asFile(), testing.allocator);
        defer db.deinit();
        try testing.expect(db.open(tmp, false, .{}, std.testing.io).isOk());
        try testing.expectEqualStrings("hello", db.getOpaqueMetadata());
    }
}

// ---------------------------------------------------------------------------
// TreeDBM lifecycle, CRUD, iterator, and UpdateLogger tests
// ---------------------------------------------------------------------------

test "TreeDBM: open/close lifecycle and isOpen" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try std.Io.Dir.realPathFile(tmp_dir.dir, std.testing.io, ".", &path_buf)];
    var full_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/lifecycle.tkt", .{dir_path});

    const sf = try file_mod.StdFile.create(testing.allocator);
    var db = try TreeDBM.init(sf.asFile(), testing.allocator);
    defer db.deinit();

    try testing.expect(!db.isOpen());
    try testing.expect(db.open(full_path, true, .{}, std.testing.io).isOk());
    try testing.expect(db.isOpen());
    try testing.expect(db.close(std.testing.io).isOk());
    try testing.expect(!db.isOpen());
}

test "TreeDBM: set, get, remove, countSimple" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try std.Io.Dir.realPathFile(tmp_dir.dir, std.testing.io, ".", &path_buf)];
    var full_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/crud.tkt", .{dir_path});

    const sf = try file_mod.StdFile.create(testing.allocator);
    var db = try TreeDBM.init(sf.asFile(), testing.allocator);
    defer db.deinit();
    try testing.expect(db.open(full_path, true, .{}, std.testing.io).isOk());

    try testing.expect(db.set("alpha", "one", true, null).isOk());
    try testing.expect(db.set("beta", "two", true, null).isOk());
    try testing.expectEqual(@as(i64, 2), db.countSimple());

    var val = ArrayList(u8).empty;
    defer val.deinit(testing.allocator);
    try testing.expect(db.get("alpha", &val).isOk());
    try testing.expectEqualStrings("one", val.items);

    try testing.expect(db.get("missing", null).code == .NOT_FOUND_ERROR);

    try testing.expect(db.remove("alpha").isOk());
    try testing.expect(db.get("alpha", null).code == .NOT_FOUND_ERROR);
    try testing.expectEqual(@as(i64, 1), db.countSimple());

    try testing.expect(db.close(std.testing.io).isOk());
}

test "TreeDBM: iterator forward traversal" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try std.Io.Dir.realPathFile(tmp_dir.dir, std.testing.io, ".", &path_buf)];
    var full_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/iter.tkt", .{dir_path});

    const sf = try file_mod.StdFile.create(testing.allocator);
    var db = try TreeDBM.init(sf.asFile(), testing.allocator);
    defer db.deinit();
    try testing.expect(db.open(full_path, true, .{}, std.testing.io).isOk());

    // Insert keys in lexicographic order so TreeDBM preserves the sequence.
    try testing.expect(db.set("aaa", "v1", true, null).isOk());
    try testing.expect(db.set("bbb", "v2", true, null).isOk());
    try testing.expect(db.set("ccc", "v3", true, null).isOk());

    var iter = try db.makeCursor();
    defer iter.deinit();
    try testing.expect(iter.first().isOk());

    var key = ArrayList(u8).empty;
    defer key.deinit(testing.allocator);
    var value = ArrayList(u8).empty;
    defer value.deinit(testing.allocator);

    // First record.
    try testing.expect(iter.get(&key, &value).isOk());
    try testing.expectEqualStrings("aaa", key.items);
    try testing.expectEqualStrings("v1", value.items);

    // Advance to second.
    try testing.expect(iter.next().isOk());
    key.clearRetainingCapacity();
    value.clearRetainingCapacity();
    try testing.expect(iter.get(&key, &value).isOk());
    try testing.expectEqualStrings("bbb", key.items);

    // Advance to third.
    try testing.expect(iter.next().isOk());
    key.clearRetainingCapacity();
    try testing.expect(iter.get(&key, null).isOk());
    try testing.expectEqualStrings("ccc", key.items);

    // Past end.
    _ = iter.next();
    try testing.expect(iter.get(null, null).code == .NOT_FOUND_ERROR);

    try testing.expect(db.close(std.testing.io).isOk());
}

// Mock UpdateLogger shared by TreeDBM logger tests.
const TreeMockLoggerCtx = struct {
    writeSet_count: i32 = 0,
    writeRemove_count: i32 = 0,
    writeClear_count: i32 = 0,
};

fn treeMockWriteSet(ctx: *anyopaque, _: []const u8, _: []const u8) Status {
    const mock: *TreeMockLoggerCtx = @ptrCast(@alignCast(ctx));
    mock.writeSet_count += 1;
    return Status.init(.SUCCESS);
}

fn treeMockWriteRemove(ctx: *anyopaque, _: []const u8) Status {
    const mock: *TreeMockLoggerCtx = @ptrCast(@alignCast(ctx));
    mock.writeRemove_count += 1;
    return Status.init(.SUCCESS);
}

fn treeMockWriteClear(ctx: *anyopaque) Status {
    const mock: *TreeMockLoggerCtx = @ptrCast(@alignCast(ctx));
    mock.writeClear_count += 1;
    return Status.init(.SUCCESS);
}

test "TreeDBM: UpdateLogger integration" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try std.Io.Dir.realPathFile(tmp_dir.dir, std.testing.io, ".", &path_buf)];
    var full_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/logger.tkt", .{dir_path});

    const sf = try file_mod.StdFile.create(testing.allocator);
    var db = try TreeDBM.init(sf.asFile(), testing.allocator);
    defer db.deinit();
    try testing.expect(db.open(full_path, true, .{}, std.testing.io).isOk());

    var mock_ctx: TreeMockLoggerCtx = .{};
    var mock_logger: UpdateLogger = .{
        .ctx = @ptrCast(@alignCast(&mock_ctx)),
        .vtable = &.{
            .writeSet = treeMockWriteSet,
            .writeRemove = treeMockWriteRemove,
            .writeClear = treeMockWriteClear,
        },
    };
    db.setUpdateLogger(&mock_logger);

    // set fires writeSet
    try testing.expect(db.set("key1", "val1", true, null).isOk());
    try testing.expect(mock_ctx.writeSet_count > 0);

    // remove fires writeRemove
    try testing.expect(db.remove("key1").isOk());
    try testing.expect(mock_ctx.writeRemove_count > 0);

    // clear fires writeClear
    try testing.expect(db.set("key2", "val2", true, null).isOk());
    const pre_clear = mock_ctx.writeClear_count;
    try testing.expect(db.clear().isOk());
    try testing.expect(mock_ctx.writeClear_count > pre_clear);

    try testing.expect(db.close(std.testing.io).isOk());
}

test "TreeDBM.*Multi: bulk set/get/remove/append" {
    const alloc = testing.allocator;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try std.Io.Dir.realPathFile(tmp_dir.dir, std.testing.io, ".", &path_buf)];
    var full_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/multi.tkt", .{dir_path});

    const sf = try file_mod.StdFile.create(alloc);
    var db = try TreeDBM.init(sf.asFile(), alloc);
    defer db.deinit();
    try testing.expect(db.open(full_path, true, .{}, std.testing.io).isOk());

    // setMulti: insert three records.
    const pairs = [_][2][]const u8{
        .{ "key1", "val1" },
        .{ "key2", "val2" },
        .{ "key3", "val3" },
    };
    try testing.expect(db.setMulti(&pairs, true).isOk());
    try testing.expectEqual(@as(i64, 3), db.countSimple());

    // getMulti: two found, one missing — status reflects the missing key.
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
    try testing.expectEqual(lib_common.Code.NOT_FOUND_ERROR, get_st.code);
    try testing.expectEqual(@as(usize, 2), records.count());

    // removeMulti: removes key1 and key2.
    try testing.expect(db.removeMulti(&.{ "key1", "key2" }).isOk());
    try testing.expectEqual(@as(i64, 1), db.countSimple());

    // appendMulti: append to key3.
    const app = [_][2][]const u8{.{ "key3", "_appended" }};
    try testing.expect(db.appendMulti(&app, "").isOk());

    // Verify the appended value.
    var val_buf: ArrayList(u8) = .empty;
    defer val_buf.deinit(alloc);
    try testing.expect(db.get("key3", &val_buf).isOk());
    try testing.expectEqualStrings("val3_appended", val_buf.items);

    try testing.expect(db.close(std.testing.io).isOk());
}

test "TreeDBM: Zig-style iterator iterate()" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try std.Io.Dir.realPathFile(tmp_dir.dir, std.testing.io, ".", &path_buf)];
    var full_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/iter_zig.tkt", .{dir_path});

    const sf = try file_mod.StdFile.create(testing.allocator);
    var db = try TreeDBM.init(sf.asFile(), testing.allocator);
    defer db.deinit();
    try testing.expect(db.open(full_path, true, .{}, std.testing.io).isOk());

    try testing.expect(db.set("a", "1", true, null).isOk());
    try testing.expect(db.set("b", "2", true, null).isOk());
    try testing.expect(db.set("c", "3", true, null).isOk());

    var iter = try db.iterate(testing.allocator);
    defer iter.deinit();

    var count: usize = 0;
    while (try iter.next()) |entry| {
        count += 1;
        if (count == 1) {
            try testing.expectEqualStrings("a", entry.key);
            try testing.expectEqualStrings("1", entry.value);
        } else if (count == 2) {
            try testing.expectEqualStrings("b", entry.key);
            try testing.expectEqualStrings("2", entry.value);
        } else if (count == 3) {
            try testing.expectEqualStrings("c", entry.key);
            try testing.expectEqualStrings("3", entry.value);
        }
    }
    try testing.expectEqual(@as(usize, 3), count);
}

test "TreeDBM: Zig-style iterator iterateFrom()" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try std.Io.Dir.realPathFile(tmp_dir.dir, std.testing.io, ".", &path_buf)];
    var full_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/iter_from_zig.tkt", .{dir_path});

    const sf = try file_mod.StdFile.create(testing.allocator);
    var db = try TreeDBM.init(sf.asFile(), testing.allocator);
    defer db.deinit();
    try testing.expect(db.open(full_path, true, .{}, std.testing.io).isOk());

    try testing.expect(db.set("a", "1", true, null).isOk());
    try testing.expect(db.set("b", "2", true, null).isOk());
    try testing.expect(db.set("c", "3", true, null).isOk());

    var iter = try db.iterateFrom("b", testing.allocator);
    defer iter.deinit();

    const first = try iter.next();
    try testing.expect(first != null);
    try testing.expectEqualStrings("b", first.?.key);
    try testing.expectEqualStrings("2", first.?.value);

    // Demonstrate lifetime contract: copy before next() invalidates.
    const key_copy = try testing.allocator.dupe(u8, first.?.key);
    defer testing.allocator.free(key_copy);

    const second = try iter.next();
    try testing.expect(second != null);
    try testing.expectEqualStrings("c", second.?.key);

    // first.?.key is now invalid, but key_copy is safe.
    try testing.expectEqualStrings("b", key_copy);

    const third = try iter.next();
    try testing.expect(third == null);
}
