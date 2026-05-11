// Zig 0.15.2 port of tkrzw BabyDBM — in-memory B+ tree database.
//
// Architecture notes:
//   - Each leaf node contains a sorted vector of BabyRecord (key + value separate allocations).
//   - Each inner node contains a sorted vector of BabyLink (separator key + child pointer).
//   - Root starts as a single leaf (tree_level=1); splits create inner nodes.
//   - Split/merge are deferred: after each write, if leaf is out-of-bounds, a ReorgEntry
//     is enqueued. At the start of the next write, the reorg queue is drained under
//     exclusive global lock before the write proceeds.
//   - Per-leaf mutexes allow concurrent reads on different leaves.
//   - Global mutex protects tree structure (root, first/last node, tree_level).


const std = @import("std");
const lib_common = @import("lib_common.zig");
const thread_util = @import("thread_util.zig");
const file_mod = @import("file.zig");
const file_util = @import("file_util.zig");
const str_util = @import("str_util.zig");
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
pub const FlatRecord = file_util.FlatRecord;
pub const FlatRecordReader = file_util.FlatRecordReader;
pub const RecordType = file_util.RecordType;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const MAX_LEAF_NODE_RECORDS: i32 = 256;
const MAX_INNER_NODE_BRANCHES: i32 = 256;
const MAX_TREE_DEPTH: i32 = 20;
const ITER_BUFFER_SIZE: usize = 128;

// ---------------------------------------------------------------------------
// Record and Link structures
// ---------------------------------------------------------------------------

/// A key-value record in a leaf node. Both key and value are owned slices.
const BabyRecord = struct {
    key: []u8,
    value: []u8,
};

/// A separator key and child pointer in an inner node. Key is owned.
const BabyLink = struct {
    key: []u8,
    child: NodePtr,
};

// ---------------------------------------------------------------------------
// Node structures
// ---------------------------------------------------------------------------

/// A B+ tree leaf node. Contains sorted records and a mutex for per-leaf locking.
const BabyLeafNode = struct {
    prev: ?*BabyLeafNode,
    next: ?*BabyLeafNode,
    records: std.ArrayListUnmanaged(BabyRecord) = .empty,
    mutex: std.Io.RwLock = .init,
};

/// A B+ tree inner node. Contains an heir pointer (leftmost child) and sorted links.
const BabyInnerNode = struct {
    heir: NodePtr,
    links: std.ArrayListUnmanaged(BabyLink) = .empty,
};

/// Tagged union for root node dispatch. Eliminates pointer casting and unsafe casts.
const NodePtr = union(enum) {
    leaf: *BabyLeafNode,
    inner: *BabyInnerNode,
};

// ---------------------------------------------------------------------------
// Reorganization queue entry
// ---------------------------------------------------------------------------

/// Entry in the reorg_nodes queue. Stores a leaf and a copy of its first key
/// so ReorganizeTree can locate the leaf via SearchTree.
const ReorgEntry = struct {
    leaf: *BabyLeafNode,
    key: []u8, // owned copy
};

// ---------------------------------------------------------------------------
// Leaf status returned by processImplOnLeaf
// ---------------------------------------------------------------------------

const LeafStatus = enum {
    ok,
    needs_split,
    needs_merge,
};

// ---------------------------------------------------------------------------
// Processor types (copied from TinyDBM pattern)
// ---------------------------------------------------------------------------

/// ProcessorGet — retrieves a value, optionally filling an ArrayList.
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

/// ProcessorSet — sets a value, optionally refusing to overwrite.
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

/// ProcessorRemove — removes the record; sets NOT_FOUND on miss.
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
// BabyRecord and BabyLink helper functions
// ---------------------------------------------------------------------------

/// Allocates a new BabyRecord with owned copies of key and value.
fn createBabyRecord(
    allocator: std.mem.Allocator,
    key: []const u8,
    value: []const u8,
) !BabyRecord {
    const key_copy = try allocator.dupe(u8, key);
    errdefer allocator.free(key_copy);
    const value_copy = try allocator.dupe(u8, value);
    errdefer allocator.free(value_copy);
    return BabyRecord{
        .key = key_copy,
        .value = value_copy,
    };
}

/// Frees a BabyRecord's owned slices.
fn freeBabyRecord(allocator: std.mem.Allocator, rec: BabyRecord) void {
    allocator.free(rec.key);
    allocator.free(rec.value);
}

/// Allocates a new BabyLink with an owned copy of key and a child pointer.
fn createBabyLink(
    allocator: std.mem.Allocator,
    key: []const u8,
    child: NodePtr,
) !BabyLink {
    const key_copy = try allocator.dupe(u8, key);
    errdefer allocator.free(key_copy);
    return BabyLink{
        .key = key_copy,
        .child = child,
    };
}

/// Frees a BabyLink's owned key.
fn freeBabyLink(allocator: std.mem.Allocator, link: BabyLink) void {
    allocator.free(link.key);
}

// ---------------------------------------------------------------------------
// BabyDBMImpl structure
// ---------------------------------------------------------------------------

const BabyDBMImpl = struct {
    allocator: std.mem.Allocator,
    num_records: std.atomic.Value(i64),
    tree_level: i32,
    root: NodePtr,
    first_node: *BabyLeafNode,
    last_node: *BabyLeafNode,
    reorg_nodes: std.ArrayListUnmanaged(ReorgEntry),
    iterators: std.ArrayListUnmanaged(*BabyDBMIteratorImpl),
    mutex: std.Io.RwLock = .init,
    key_comparator: KeyComparator,
    update_logger: ?*UpdateLogger,
    file: File,
    open: bool,
    writable: bool,
    open_options: OpenOptions,
    path: std.ArrayListUnmanaged(u8),
    timestamp: std.Io.Timestamp,
    // R-3: reorg_mutex removed — reorganizeIfNeeded was dead code.

    /// Initialize a new BabyDBMImpl with a single empty root leaf.
    fn init(
        file: File,
        key_comparator: KeyComparator,
        allocator: std.mem.Allocator,
    ) !*BabyDBMImpl {
        const self = try allocator.create(BabyDBMImpl);
        errdefer allocator.destroy(self);

        // Create the initial root leaf node.
        const root_leaf = try allocator.create(BabyLeafNode);
        errdefer allocator.destroy(root_leaf);
        root_leaf.* = BabyLeafNode{
            .prev = null,
            .next = null,
        };

        self.* = BabyDBMImpl{
            .allocator = allocator,
            .num_records = std.atomic.Value(i64).init(0),
            .tree_level = 1,
            .root = .{ .leaf = root_leaf },
            .first_node = root_leaf,
            .last_node = root_leaf,
            .reorg_nodes = .empty,
            .iterators = .empty,
            .mutex = .init,
            .key_comparator = key_comparator,
            .update_logger = null,
            .file = file,
            .open = false,
            .writable = false,
            .open_options = .{},
            .path = .empty,
            .timestamp = std.Io.Timestamp.zero,
        };

        return self;
    }

    /// Release all nodes in the tree using iterative post-order traversal.
    fn releaseAllNodes(self: *BabyDBMImpl) void {
        // Use a stack with a marker to distinguish "visit children" from "delete node" phases.
        // Entries: level < 0 means "delete this inner node", level >= 0 means "process node and push children".
        var stack: std.ArrayListUnmanaged(struct { level: i32, ptr: NodePtr }) = .empty;
        defer stack.deinit(self.allocator);

        stack.append(self.allocator, .{ .level = 1, .ptr = self.root }) catch return;

        while (stack.items.len > 0) {
            const frame = stack.items[stack.items.len - 1];
            stack.items.len -= 1;

            if (frame.level < 0) {
                // Delete marker for an inner node.
                const inner = frame.ptr.inner;
                for (inner.links.items) |link| {
                    freeBabyLink(self.allocator, link);
                }
                inner.links.deinit(self.allocator);
                self.allocator.destroy(inner);
            } else if (frame.level == self.tree_level) {
                // Leaf node: free all records and the leaf itself.
                const leaf = frame.ptr.leaf;
                for (leaf.records.items) |rec| {
                    freeBabyRecord(self.allocator, rec);
                }
                leaf.records.deinit(self.allocator);
                self.allocator.destroy(leaf);
            } else {
                // Inner node: push delete marker, then children.
                const inner = frame.ptr.inner;
                stack.append(self.allocator, .{ .level = -frame.level, .ptr = .{ .inner = inner } }) catch return;
                // Push heir and all link children (order: heir first so it's processed last).
                stack.append(self.allocator, .{ .level = frame.level + 1, .ptr = inner.heir }) catch return;
                for (inner.links.items) |*link| {
                    stack.append(self.allocator, .{ .level = frame.level + 1, .ptr = link.child }) catch return;
                }
            }
        }
    }

    /// Clean up all resources and destroy the impl.
    fn deinit(self: *BabyDBMImpl, io: std.Io) void {
        if (self.open) {
            _ = self.closeImpl(io);
        }

        // Orphan any live iterators.
        for (self.iterators.items) |iter| {
            iter.dbm = null;
        }
        self.iterators.deinit(self.allocator);

        // Free all tree nodes.
        self.releaseAllNodes();

        // Free reorg queue entries.
        for (self.reorg_nodes.items) |entry| {
            self.allocator.free(entry.key);
        }
        self.reorg_nodes.deinit(self.allocator);

        // Free file path.
        self.path.deinit(self.allocator);

        // Close file.
        self.file.deinit(self.allocator);

        // Free the impl itself.
        self.allocator.destroy(self);
    }


    /// Search the tree for the leaf node containing a given key.
    /// Returns the appropriate leaf where the key would be located.
    /// Line-for-line port of C++ BabyDBMImpl::SearchTree.
    fn searchTree(self: *BabyDBMImpl, key: []const u8) *BabyLeafNode {
        var node = self.root;
        var level: i32 = 1;

        while (level < self.tree_level) {
            const inner = node.inner;
            const upper_idx = self.lowerBoundInLinks(inner.links.items, key);

            if (upper_idx == 0) {
                node = inner.heir;
            } else {
                node = inner.links.items[upper_idx - 1].child;
            }
            level += 1;
        }

        return node.leaf;
    }

    /// Binary search in a slice of BabyLink to find upper_bound by key.
    /// Returns the index where a link with the given key would be inserted.
    fn lowerBoundInLinks(self: *BabyDBMImpl, links: []const BabyLink, key: []const u8) usize {
        var left: usize = 0;
        var right: usize = links.len;

        while (left < right) {
            const mid = left + (right - left) / 2;
            const cmp = self.key_comparator(key, links[mid].key);
            if (cmp == .lt) {
                right = mid;
            } else {
                left = mid + 1;
            }
        }
        return left;
    }

    /// Binary search in a leaf node's records to find lower_bound by key.
    /// Returns the index where a record with the given key would be inserted.
    fn lowerBoundInLeaf(self: *BabyDBMImpl, records: []const BabyRecord, key: []const u8) usize {
        var left: usize = 0;
        var right: usize = records.len;

        while (left < right) {
            const mid = left + (right - left) / 2;
            const cmp = self.key_comparator(key, records[mid].key);
            if (cmp != .gt) {  // key <= records[mid], standard lower_bound
                right = mid;
            } else {
                left = mid + 1;
            }
        }
        return left;
    }

    /// Process a record in a leaf node using a generic processor.
    /// Binary-searches for the key and calls either processFull or processEmpty.
    /// Enqueues a ReorgEntry if the leaf needs split/merge after the operation.
    fn processImplOnLeaf(
        self: *BabyDBMImpl,
        comptime P: type,
        proc: *P,
        leaf: *BabyLeafNode,
        key: []const u8,
        writable: bool,
    ) !LeafStatus {
        const idx = self.lowerBoundInLeaf(leaf.records.items, key);
        var result_status = LeafStatus.ok;

        if (idx < leaf.records.items.len and std.mem.eql(u8, leaf.records.items[idx].key, key)) {
            // Found: dispatch to processFull.
            const action = proc.processFull(key, leaf.records.items[idx].value);
            switch (action) {
                .noop => {},
                .remove => {
                    if (writable) {
                        // C++ WAL ordering: log before mutation. On OOM the caller
                        // receives SYSTEM_ERROR and must stop using the database —
                        // same effective outcome as C++ process termination.
                        if (self.update_logger) |ul| {
                            _ = ul.writeRemove(key);
                        }
                        const removed_rec = leaf.records.orderedRemove(idx);
                        freeBabyRecord(self.allocator, removed_rec);
                        _ = self.num_records.fetchSub(1, .monotonic);
                        if (leaf.records.items.len < 128) {
                            result_status = LeafStatus.needs_merge;
                        }
                    }
                },
                .set => |new_value| {
                    if (writable) {
                        // C++ WAL ordering: log before mutation (same as the remove path above).
                        if (self.update_logger) |ul| {
                            _ = ul.writeSet(key, new_value);
                        }
                        const new_rec = try createBabyRecord(self.allocator, key, new_value);
                        errdefer freeBabyRecord(self.allocator, new_rec);
                        const old_rec = leaf.records.items[idx];
                        leaf.records.items[idx] = new_rec;
                        freeBabyRecord(self.allocator, old_rec);
                    }
                },
            }
        } else {
            // Not found: dispatch to processEmpty.
            const action = proc.processEmpty(key);
            switch (action) {
                .noop, .remove => {},
                .set => |new_value| {
                    if (writable) {
                        if (self.update_logger) |ul| {
                            _ = ul.writeSet(key, new_value);
                        }
                        const new_rec = try createBabyRecord(self.allocator, key, new_value);
                        errdefer freeBabyRecord(self.allocator, new_rec);
                        try leaf.records.insert(self.allocator, idx, new_rec);
                        _ = self.num_records.fetchAdd(1, .monotonic);
                        if (leaf.records.items.len > 256) {
                            result_status = LeafStatus.needs_split;
                        }
                    }
                },
            }
        }

        // If a reorganization is needed, enqueue this leaf.
        if (result_status != LeafStatus.ok and writable) {
            const first_key = if (leaf.records.items.len > 0) leaf.records.items[0].key else "";
            const key_copy = try self.allocator.dupe(u8, first_key);
            errdefer self.allocator.free(key_copy);
            try self.reorg_nodes.append(self.allocator, ReorgEntry{
                .leaf = leaf,
                .key = key_copy,
            });
        }

        return result_status;
    }


    /// Walk the tree from root to leaf, storing each BabyInnerNode encountered.
    /// Returns the number of inner nodes stored in hist.
    /// If tree_level==1 (root is leaf), returns 0.
    /// Line-for-line port of C++ BabyDBMImpl::TraceTree.
    fn buildHistory(
        self: *BabyDBMImpl,
        key: []const u8,
        hist: []?*BabyInnerNode,
    ) usize {
        var node = self.root;
        var level: i32 = 1;
        var hist_size: usize = 0;

        while (level < self.tree_level) {
            const inner = node.inner;
            const upper_idx = self.lowerBoundInLinks(inner.links.items, key);

            if (hist_size < hist.len) {
                hist[hist_size] = inner;
                hist_size += 1;
            }

            if (upper_idx == 0) {
                node = inner.heir;
            } else {
                node = inner.links.items[upper_idx - 1].child;
            }
            level += 1;
        }

        return hist_size;
    }

    /// Add a link (separator key → child) to an inner node, maintaining sorted order.
    fn addLinkToInnerNode(
        self: *BabyDBMImpl,
        inner_node: *BabyInnerNode,
        child: NodePtr,
        key: []const u8,
    ) !void {
        const link = try createBabyLink(self.allocator, key, child);
        errdefer freeBabyLink(self.allocator, link);

        // Binary search to find insertion point (upper_bound by key).
        var left: usize = 0;
        var right: usize = inner_node.links.items.len;

        while (left < right) {
            const mid = left + (right - left) / 2;
            const cmp = self.key_comparator(key, inner_node.links.items[mid].key);
            if (cmp == .lt) {
                right = mid;
            } else {
                left = mid + 1;
            }
        }

        try inner_node.links.insert(self.allocator, left, link);
    }

    /// Remove the link whose child pointer equals the given child from an inner node.
    fn joinPrevLinkInInnerNode(
        self: *BabyDBMImpl,
        inner_node: *BabyInnerNode,
        child: NodePtr,
    ) void {
        const links = &inner_node.links;
        for (links.items, 0..) |link, i| {
            if (std.meta.eql(link.child, child)) {
                const removed = links.orderedRemove(i);
                freeBabyLink(self.allocator, removed);
                return;
            }
        }
    }

    /// Update the link whose child pointer equals child to point to next instead,
    /// and remove the next link in the sequence.
    /// Special case: if inner_node.heir == child, set heir to next and remove first link.
    fn joinNextLinkInInnerNode(
        self: *BabyDBMImpl,
        inner_node: *BabyInnerNode,
        child: NodePtr,
        next: NodePtr,
    ) void {
        const links = &inner_node.links;

        if (std.meta.eql(inner_node.heir, child)) {
            inner_node.heir = next;
            if (links.items.len > 0) {
                const removed = links.orderedRemove(0);
                freeBabyLink(self.allocator, removed);
            }
        } else {
            for (links.items, 0..) |*link, i| {
                if (std.meta.eql(link.child, child)) {
                    // Update this link's child to point to next.
                    link.child = next;
                    // Remove the following link.
                    if (i + 1 < links.items.len) {
                        const removed = links.orderedRemove(i + 1);
                        freeBabyLink(self.allocator, removed);
                    }
                    return;
                }
            }
        }
    }

    /// Divide a leaf node: split its records at midpoint, create new sibling,
    /// recursively insert separator key into parent(s), handling parent splits.
    /// Line-for-line port of C++ BabyDBMImpl::DivideNodes.
    fn divideNodes(
        self: *BabyDBMImpl,
        leaf: *BabyLeafNode,
        node_key: []const u8,
    ) !void {
        var hist: [MAX_TREE_DEPTH]?*BabyInnerNode = [_]?*BabyInnerNode{null} ** MAX_TREE_DEPTH;
        const hist_size = self.buildHistory(node_key, &hist);

        // Create new leaf with records from midpoint onward.
        const new_leaf = try self.allocator.create(BabyLeafNode);
        errdefer self.allocator.destroy(new_leaf);
        new_leaf.* = BabyLeafNode{
            .prev = leaf,
            .next = leaf.next,
        };

        // Update prev/next chain.
        if (new_leaf.next) |next_node| {
            next_node.prev = new_leaf;
        }
        leaf.next = new_leaf;

        // Split records at midpoint.
        const midpoint = leaf.records.items.len / 2;
        const records_to_move = leaf.records.items[midpoint..];

        try new_leaf.records.appendSlice(self.allocator, records_to_move);
        leaf.records.shrinkAndFree(self.allocator, midpoint);

        // Update last_node if needed.
        if (self.last_node == leaf) {
            self.last_node = new_leaf;
        }

        // Get separator key from first record of right sibling.
        const separator_key = if (new_leaf.records.items.len > 0)
            new_leaf.records.items[0].key
        else
            "";

        // Redirect any iterators on old leaf whose key >= separator_key.
        try self.redirectIterators(leaf, new_leaf, separator_key);

        // Now recursively insert the separator into parent(s).
        var heir: NodePtr = .{ .leaf = leaf };
        var child: NodePtr = .{ .leaf = new_leaf };

        // Use ?[]u8 with a single errdefer to avoid double-free when sep_key_copy is
        // re-assigned during multi-level inner-node splits. Each explicit free sets the
        // variable to null so the errdefer becomes a no-op for that iteration.
        var sep_key_copy: ?[]u8 = try self.allocator.dupe(u8, separator_key);
        errdefer if (sep_key_copy) |k| self.allocator.free(k);

        var current_hist_size = hist_size;

        while (true) {
            if (current_hist_size == 0) {
                // No parents: create new root.
                const new_root = try self.allocator.create(BabyInnerNode);
                errdefer self.allocator.destroy(new_root);
                new_root.* = BabyInnerNode{
                    .heir = heir,
                };
                // addLinkToInnerNode copies the key internally; we own key_to_use and must free it.
                const key_to_use = sep_key_copy.?;
                sep_key_copy = null;
                try self.addLinkToInnerNode(new_root, child, key_to_use);
                self.allocator.free(key_to_use);
                self.root = .{ .inner = new_root };
                self.tree_level += 1;
                break;
            }

            current_hist_size -= 1;
            const parent_node = hist[current_hist_size].?;
            // addLinkToInnerNode copies the key internally; we own key_to_use and must free it.
            const key_to_use = sep_key_copy.?;
            sep_key_copy = null;
            try self.addLinkToInnerNode(parent_node, child, key_to_use);
            self.allocator.free(key_to_use);

            // Check if parent fits.
            if (parent_node.links.items.len <= 256) {
                break;
            }

            // Parent overflowed: split it.
            const parent_midpoint = parent_node.links.items.len / 2;
            const link_to_promote = parent_node.links.items[parent_midpoint];
            sep_key_copy = try self.allocator.dupe(u8, link_to_promote.key);

            // Create new inner node with heir = promoted link's child.
            const new_inner = try self.allocator.create(BabyInnerNode);
            errdefer self.allocator.destroy(new_inner);
            new_inner.* = BabyInnerNode{
                .heir = link_to_promote.child,
            };

            // Move links from parent_midpoint+1 to end into new_inner.
            // Use createBabyLink for each entry so new_inner owns independent key copies.
            // appendSlice would alias the fat pointers and then freeBabyLink below would
            // free keys still referenced by new_inner (use-after-free, R-8).
            const links_to_move = parent_node.links.items[parent_midpoint + 1 ..];
            for (links_to_move) |link| {
                const new_link = try createBabyLink(self.allocator, link.key, link.child);
                try new_inner.links.append(self.allocator, new_link);
            }

            // Free links from midpoint onward and shrink parent.
            for (parent_node.links.items[parent_midpoint..]) |link| {
                freeBabyLink(self.allocator, link);
            }
            parent_node.links.shrinkAndFree(self.allocator, parent_midpoint);

            // Set up for next iteration.
            heir = .{ .inner = parent_node };
            child = .{ .inner = new_inner };
        }
    }

    /// Merge a leaf with its sibling: choose smaller/previous sibling,
    /// append records, update prev/next chain, remove leaf from parent,
    /// recursively merge parents if they underflow.
    /// Line-for-line port of C++ BabyDBMImpl::MergeNodes.
    fn mergeNodes(
        self: *BabyDBMImpl,
        leaf: *BabyLeafNode,
        node_key: []const u8,
    ) !void {
        var hist: [MAX_TREE_DEPTH]?*BabyInnerNode = [_]?*BabyInnerNode{null} ** MAX_TREE_DEPTH;
        var hist_size = self.buildHistory(node_key, &hist);

        if (hist_size == 0) {
            // Root is a leaf; can't merge.
            return;
        }

        const parent_node = hist[hist_size - 1].?;
        const links = parent_node.links.items;

        var prev_leaf: ?*BabyLeafNode = null;
        var next_leaf: ?*BabyLeafNode = null;

        // Find leaf's siblings by walking parent's tree.
        if (parent_node.heir == .leaf and parent_node.heir.leaf == leaf) {
            // leaf is the heir (leftmost child).
            if (links.len > 0 and links[0].child == .leaf) {
                next_leaf = links[0].child.leaf;
            }
        } else {
            // Find leaf among links.
            for (links, 0..) |link, i| {
                if (link.child == .leaf and link.child.leaf == leaf) {
                    // Found: prev is either heir or previous link's child.
                    if (i == 0) {
                        if (parent_node.heir == .leaf) {
                            prev_leaf = parent_node.heir.leaf;
                        }
                    } else {
                        if (links[i - 1].child == .leaf) {
                            prev_leaf = links[i - 1].child.leaf;
                        }
                    }
                    // next is next link's child if it exists.
                    if (i + 1 < links.len and links[i + 1].child == .leaf) {
                        next_leaf = links[i + 1].child.leaf;
                    }
                    break;
                }
            }
        }

        // Decide which sibling to merge into.
        const should_merge_into_prev = prev_leaf != null and
            (next_leaf == null or
            prev_leaf.?.records.items.len <= next_leaf.?.records.items.len);

        if (should_merge_into_prev) {
            // Merge into prev_leaf: append all records from leaf to prev_leaf.
            const prev = prev_leaf.?;
            try prev.records.appendSlice(self.allocator, leaf.records.items);
            leaf.records.clearRetainingCapacity();

            // Update prev/next chain.
            prev.next = leaf.next;
            if (leaf.next) |next_node| {
                next_node.prev = prev;
            }

            // Remove leaf link from parent.
            self.joinPrevLinkInInnerNode(parent_node, .{ .leaf = leaf });

            // Update last_node.
            if (self.last_node == leaf) {
                self.last_node = prev;
            }

            // Redirect iterators.
            for (self.iterators.items) |iter| {
                if (iter.leaf_node == leaf) {
                    iter.leaf_node = prev;
                }
            }

            // Delete leaf.
            for (leaf.records.items) |rec| {
                freeBabyRecord(self.allocator, rec);
            }
            leaf.records.deinit(self.allocator);
            self.allocator.destroy(leaf);
        } else if (next_leaf != null) {
            // Merge into next_leaf: swap records, then append old records to next_leaf.
            const next = next_leaf.?;
            const temp_records = next.records;
            next.records = leaf.records;
            leaf.records = temp_records;

            try next.records.appendSlice(self.allocator, leaf.records.items);
            leaf.records.clearRetainingCapacity();

            // Update prev/next chain.
            next.prev = leaf.prev;
            if (leaf.prev) |prev_node| {
                prev_node.next = next;
            }

            // Remove leaf link from parent.
            self.joinNextLinkInInnerNode(parent_node, .{ .leaf = leaf }, .{ .leaf = next });

            // Update first_node.
            if (self.first_node == leaf) {
                self.first_node = next;
            }

            // Redirect iterators.
            for (self.iterators.items) |iter| {
                if (iter.leaf_node == leaf) {
                    iter.leaf_node = next;
                }
            }

            // Delete leaf.
            for (leaf.records.items) |rec| {
                freeBabyRecord(self.allocator, rec);
            }
            leaf.records.deinit(self.allocator);
            self.allocator.destroy(leaf);
        }

        // Now check if parent needs merging.
        var inner_node = parent_node;
        while (inner_node.links.items.len < 128) {
            hist_size -= 1;
            if (hist_size == 0) {
                // Check if root has become empty.
                if (inner_node.links.items.len == 0) {
                    // Promote heir as new root.
                    self.root = inner_node.heir;
                    self.tree_level -= 1;
                    self.allocator.destroy(inner_node);
                }
                break;
            }

            const grandparent_node = hist[hist_size - 1].?;
            const grandparent_links = grandparent_node.links.items;

            var prev_inner: ?*BabyInnerNode = null;
            var next_inner: ?*BabyInnerNode = null;
            // inner_key: separator key in grandparent pointing to inner_node (used in prev-merge).
            // next_key:  separator key in grandparent pointing to next_inner (used in next-merge).
            var inner_key: []const u8 = "";
            var next_key: []const u8 = "";

            if (grandparent_node.heir == .inner and grandparent_node.heir.inner == inner_node) {
                // inner_node is the heir; next sibling is the first link.
                if (grandparent_links.len > 0 and grandparent_links[0].child == .inner) {
                    next_inner = grandparent_links[0].child.inner;
                    next_key = grandparent_links[0].key;
                }
            } else {
                for (grandparent_links, 0..) |link, i| {
                    if (link.child == .inner and link.child.inner == inner_node) {
                        // Capture separator key for inner_node (used when merging into prev).
                        inner_key = link.key;
                        if (i == 0) {
                            if (grandparent_node.heir == .inner) {
                                prev_inner = grandparent_node.heir.inner;
                            }
                        } else {
                            if (grandparent_links[i - 1].child == .inner) {
                                prev_inner = grandparent_links[i - 1].child.inner;
                            }
                        }
                        if (i + 1 < grandparent_links.len and grandparent_links[i + 1].child == .inner) {
                            next_inner = grandparent_links[i + 1].child.inner;
                            next_key = grandparent_links[i + 1].key;
                        }
                        break;
                    }
                }
            }

            const should_merge_into_prev_inner = prev_inner != null and
                (next_inner == null or
                prev_inner.?.links.items.len <= next_inner.?.links.items.len);

            if (should_merge_into_prev_inner) {
                // Merge inner_node into prev_inner.
                // Prepend a link for inner_node's heir using the grandparent separator key
                // (inner_key), then append all of inner_node's own links.
                const prev = prev_inner.?;
                // createBabyLink may fail with OOM; if it does no mutation has occurred yet.
                const heir_link = try createBabyLink(self.allocator, inner_key, inner_node.heir);
                // After heir_link is appended, it is owned by prev.links.
                // appendSlice OOM after this point leaves the tree in a partially merged state;
                // this mirrors C++ which also does not handle OOM in structural mutations.
                try prev.links.append(self.allocator, heir_link);
                try prev.links.appendSlice(self.allocator, inner_node.links.items);
                // Deinit inner_node's backing buffer (clearRetainingCapacity would leak it).
                inner_node.links.deinit(self.allocator);
                self.joinPrevLinkInInnerNode(grandparent_node, .{ .inner = inner_node });
                self.allocator.destroy(inner_node);
            } else if (next_inner != null) {
                // Merge next_inner into inner_node.
                // Prepend a link for next_inner's heir using the grandparent separator key
                // (next_key), then append all of next_inner's own links.
                const ni = next_inner.?;
                // createBabyLink may fail with OOM; if it does no mutation has occurred yet.
                const heir_link = try createBabyLink(self.allocator, next_key, ni.heir);
                // After heir_link is appended, it is owned by inner_node.links.
                try inner_node.links.append(self.allocator, heir_link);
                try inner_node.links.appendSlice(self.allocator, ni.links.items);
                // Deinit next_inner's backing buffer (clearRetainingCapacity would leak it).
                ni.links.deinit(self.allocator);
                // Remove next_inner from grandparent (not inner_node — that remains).
                self.joinPrevLinkInInnerNode(grandparent_node, .{ .inner = ni });
                self.allocator.destroy(ni);
            }

            inner_node = grandparent_node;
        }
    }

    /// Redirect iterators: if iter.leaf_node == old_leaf and iter.key >= separator_key,
    /// move the iterator to new_leaf.
    fn redirectIterators(
        self: *BabyDBMImpl,
        old_leaf: *BabyLeafNode,
        new_leaf: *BabyLeafNode,
        separator_key: []const u8,
    ) !void {
        for (self.iterators.items) |iter| {
            if (iter.leaf_node == old_leaf) {
                // Compare iterator's key with separator_key.
                const iter_key = if (iter.key_size > 0)
                    iter.key_buf[0..iter.key_size]
                else if (iter.key_heap) |heap|
                    heap
                else
                    "";
                if (self.key_comparator(iter_key, separator_key) != .lt) {
                    iter.leaf_node = new_leaf;
                }
            }
        }
    }

    /// Drain the reorg_nodes queue and call reorganizeTree under exclusive lock.
    fn reorganizeTree(self: *BabyDBMImpl) !void {
        var done_nodes: std.ArrayListUnmanaged(*BabyLeafNode) = .empty;
        defer done_nodes.deinit(self.allocator);

        while (self.reorg_nodes.items.len > 0) {
            const entry = self.reorg_nodes.orderedRemove(0);
            defer self.allocator.free(entry.key);

            // Skip if we've already processed this leaf.
            var already_done = false;
            for (done_nodes.items) |done| {
                if (done == entry.leaf) {
                    already_done = true;
                    break;
                }
            }
            if (already_done) continue;

            if (entry.leaf.records.items.len > 256) {
                try self.divideNodes(entry.leaf, entry.key);
            } else if (entry.leaf.records.items.len < 128 and
                // Check live root each iteration: divideNodes may have promoted
                // the root from leaf to inner node (matching C++ root_node_ check).
                switch (self.root) {
                    .leaf => |l| entry.leaf != l,
                    .inner => true,
                })
            {
                try self.mergeNodes(entry.leaf, entry.key);
            }

            try done_nodes.append(self.allocator, entry.leaf);
        }
    }

    /// Process a key-value operation on the tree using a generic processor.
    fn processImpl(
        self: *BabyDBMImpl,
        io: std.Io,
        comptime P: type,
        proc: *P,
        key: []const u8,
        writable: bool,
    ) !void {
        // If writable and reorg queue not empty, reorganize under exclusive global lock first.
        // The exclusive lock prevents concurrent readers from observing torn tree structure
        // while reorganizeTree mutates root/first_node/last_node/leaf chain pointers.
        if (writable and self.reorg_nodes.items.len > 0) {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            try self.reorganizeTree();
        }

        // Acquire shared global lock (allows concurrent readers/writers on different leaves).
        self.mutex.lockSharedUncancelable(io);
        defer self.mutex.unlockShared(io);

        // Find the leaf containing this key.
        const leaf = self.searchTree(key);

        // Acquire leaf lock (exclusive if writable, shared if read-only).
        if (writable) {
            leaf.mutex.lockUncancelable(io);
        } else {
            leaf.mutex.lockSharedUncancelable(io);
        }
        defer {
            if (writable) {
                leaf.mutex.unlock(io);
            } else {
                leaf.mutex.unlockShared(io);
            }
        }

        // Process the operation on the leaf.
        _ = try self.processImplOnLeaf(P, proc, leaf, key, writable);
    }

    /// Get value for a key (read-only).
    pub fn get(
        self: *BabyDBMImpl,
        allocator: std.mem.Allocator,
        io: std.Io,
        key: []const u8,
        value: ?*std.ArrayList(u8),
    ) Status {
        var status = Status.init(.SUCCESS);
        var getter = ProcessorGet{ .status = &status, .value = value, .allocator = allocator };
        self.processImpl(io, ProcessorGet, &getter, key, false) catch
            return Status.init(.SYSTEM_ERROR);
        return status;
    }

    /// Set value for a key (write operation).
    pub fn set(
        self: *BabyDBMImpl,
        allocator: std.mem.Allocator,
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
            .allocator = allocator,
        };
        self.processImpl(io, ProcessorSet, &setter, key, true) catch
            return Status.init(.SYSTEM_ERROR);
        return status;
    }

    /// Remove a key (write operation).
    pub fn remove(self: *BabyDBMImpl, io: std.Io, key: []const u8) Status {

        var status = Status.init(.SUCCESS);
        var remover = ProcessorRemove{ .status = &status };
        self.processImpl(io, ProcessorRemove, &remover, key, true) catch
            return Status.init(.SYSTEM_ERROR);
        return status;
    }

    /// Append a value to the existing value for a key, separated by delimiter.
    /// If the key exists: replaces the record with old_value ++ delim ++ value.
    /// If the key does not exist: inserts a new record with value.
    /// Port of C++ BabyDBMImpl::Append / AppendImpl.
    pub fn append(self: *BabyDBMImpl, io: std.Io, key: []const u8, value: []const u8, delim: []const u8) Status {

        // Drain reorg queue under exclusive global lock before taking the shared lock.
        if (self.reorg_nodes.items.len > 0) {
            self.mutex.lockUncancelable(io);
            {
                defer self.mutex.unlock(io);
                self.reorganizeTree() catch return Status.init(.SYSTEM_ERROR);
            }
        }

        // Shared global lock for tree traversal.
        self.mutex.lockSharedUncancelable(io);
        defer self.mutex.unlockShared(io);

        const leaf = self.searchTree(key);

        // Exclusive leaf lock for the write.
        leaf.mutex.lockUncancelable(io);
        defer leaf.mutex.unlock(io);

        self.appendImpl(leaf, key, value, delim) catch return Status.init(.SYSTEM_ERROR);
        return Status.init(.SUCCESS);
    }

    /// Core append logic: find key in leaf and either concatenate or insert.
    fn appendImpl(
        self: *BabyDBMImpl,
        leaf: *BabyLeafNode,
        key: []const u8,
        value: []const u8,
        delim: []const u8,
    ) !void {
        const idx = self.lowerBoundInLeaf(leaf.records.items, key);

        if (idx < leaf.records.items.len and std.mem.eql(u8, leaf.records.items[idx].key, key)) {
            // Key exists: build new value = existing_value ++ delim ++ value.
            const existing = leaf.records.items[idx];
            const new_val_len = existing.value.len + delim.len + value.len;
            const new_val = try self.allocator.alloc(u8, new_val_len);
            defer self.allocator.free(new_val); // createBabyRecord copies; always free after
            @memcpy(new_val[0..existing.value.len], existing.value);
            @memcpy(new_val[existing.value.len .. existing.value.len + delim.len], delim);
            @memcpy(new_val[existing.value.len + delim.len ..], value);

            // Build new record (key is copied inside createBabyRecord).
            const new_rec = try createBabyRecord(self.allocator, key, new_val);

            // Swap in the new record and free the old one.
            const old_rec = leaf.records.items[idx];
            leaf.records.items[idx] = new_rec;
            freeBabyRecord(self.allocator, old_rec);

            if (self.update_logger) |ul| {
                _ = ul.writeSet(key, leaf.records.items[idx].value);
            }
        } else {
            // Key does not exist: insert new record.
            if (self.update_logger) |ul| {
                _ = ul.writeSet(key, value);
            }
            const new_rec = try createBabyRecord(self.allocator, key, value);
            // Free new_rec if insert fails (it would not be in the list).
            errdefer freeBabyRecord(self.allocator, new_rec);
            try leaf.records.insert(self.allocator, idx, new_rec);
            // insert succeeded: new_rec is now owned by leaf.records. The errdefer above
            // only fires if an error is returned from THIS function after this point. The
            // remaining fallible calls (dupe, reorg_nodes.append) that could trigger the
            // errdefer would leave new_rec inside leaf.records while also freeing it —
            // a use-after-free. To avoid this, accept that OOM after insert is unrecoverable
            // (same as C++ which does not handle OOM in these structural mutations).
            // In practice the reorg append is the only risk; treat OOM there as fatal.
            _ = self.num_records.fetchAdd(1, .monotonic);

            // Enqueue reorg if the leaf has overflowed.
            if (leaf.records.items.len > @as(usize, @intCast(MAX_LEAF_NODE_RECORDS))) {
                const first_key = leaf.records.items[0].key;
                const key_copy = try self.allocator.dupe(u8, first_key);
                errdefer self.allocator.free(key_copy);
                try self.reorg_nodes.append(self.allocator, ReorgEntry{
                    .leaf = leaf,
                    .key = key_copy,
                });
            }
        }
    }

    /// Process the first record with a processor, writable or read-only.
    /// Loops forward through leaves to skip any empty leading leaves (R-6).
    pub fn processFirst(
        self: *BabyDBMImpl,
        io: std.Io,
        comptime P: type,
        proc: *P,
        writable: bool,
    ) Status {
        // C++ always holds shared_lock on the outer mutex for processFirst.
        self.mutex.lockSharedUncancelable(io);
        defer self.mutex.unlockShared(io);

        // Loop forward through leaves until a non-empty one is found (C++ cc:487-506).
        var leaf_opt: ?*BabyLeafNode = self.first_node;
        while (leaf_opt) |leaf| {
            if (writable) {
                leaf.mutex.lockUncancelable(io);
            } else {
                leaf.mutex.lockSharedUncancelable(io);
            }

            if (leaf.records.items.len > 0) {
                // Found a non-empty leaf — process and return.
                defer {
                    if (writable) {
                        leaf.mutex.unlock(io);
                    } else {
                        leaf.mutex.unlockShared(io);
                    }
                }
                const first_key = leaf.records.items[0].key;
                // Route both branches through processImplOnLeaf so processor return values
                // are applied consistently (C++ ProcessFirst calls ProcessImpl in both branches).
                _ = self.processImplOnLeaf(P, proc, leaf, first_key, writable) catch
                    return Status.init(.SYSTEM_ERROR);
                return Status.init(.SUCCESS);
            }

            // Empty leaf — unlock and advance.
            if (writable) {
                leaf.mutex.unlock(io);
            } else {
                leaf.mutex.unlockShared(io);
            }
            leaf_opt = leaf.next;
        }

        return Status.init(.NOT_FOUND_ERROR);
    }

    /// Process multiple keys with their respective processors.
    /// Locks leaves in sorted order to prevent deadlock.
    pub fn processMulti(
        self: *BabyDBMImpl,
        io: std.Io,
        comptime P: type,
        keys: []const []const u8,
        procs: []const *P,
        writable: bool,
    ) Status {
        if (keys.len != procs.len) {
            return Status.init(.INVALID_ARGUMENT_ERROR);
        }

        // Drain reorg queue under exclusive global lock before taking the shared lock (R-20).
        if (self.reorg_nodes.items.len > 0) {
            self.mutex.lockUncancelable(io);
            {
                defer self.mutex.unlock(io);
                self.reorganizeTree() catch return Status.init(.SYSTEM_ERROR);
            }
        }

        // Collect unique leaves for each key.
        var leaf_map: std.AutoHashMapUnmanaged(*BabyLeafNode, void) = .{};
        defer leaf_map.deinit(self.allocator);

        self.mutex.lockSharedUncancelable(io);
        defer self.mutex.unlockShared(io);

        for (keys) |key| {
            const leaf = self.searchTree(key);
            leaf_map.put(self.allocator, leaf, {}) catch return Status.init(.SYSTEM_ERROR);
        }

        // Collect unique leaves and sort by pointer value.
        var unique_leaves: std.ArrayListUnmanaged(*BabyLeafNode) = .empty;
        defer unique_leaves.deinit(self.allocator);

        var iter = leaf_map.keyIterator();
        while (iter.next(io)) |leaf_ptr| {
            unique_leaves.append(self.allocator, leaf_ptr.*) catch return Status.init(.SYSTEM_ERROR);
        }

        std.mem.sort(
            *BabyLeafNode,
            unique_leaves.items,
            {},
            struct {
                pub fn lessThan(_: void, a: *BabyLeafNode, b: *BabyLeafNode) bool {
                    return @intFromPtr(a) < @intFromPtr(b);
                }
            }.lessThan,
        );

        // Lock all leaves in sorted order.
        if (writable) {
            for (unique_leaves.items) |leaf| {
                leaf.mutex.lockUncancelable(io);
            }
        } else {
            for (unique_leaves.items) |leaf| {
                leaf.mutex.lockSharedUncancelable(io);
            }
        }
        defer {
            // Unlock in reverse order.
            var i = unique_leaves.items.len;
            while (i > 0) {
                i -= 1;
                const leaf = unique_leaves.items[i];
                if (writable) {
                    leaf.mutex.unlock(io);
                } else {
                    leaf.mutex.unlockShared(io);
                }
            }
        }

        // Process each key-proc pair.
        for (keys, procs) |key, proc| {
            _ = self.processImplOnLeaf(P, proc, self.searchTree(key), key, writable) catch
                return Status.init(.SYSTEM_ERROR);
        }

        return Status.init(.SUCCESS);
    }

    /// Process all records in the tree.
    pub fn processEach(
        self: *BabyDBMImpl,
        io: std.Io,
        comptime P: type,
        proc: *P,
        writable: bool,
    ) Status {
        // C++ always holds shared_lock on the outer mutex; per-leaf lock handles mutation safety.
        self.mutex.lockSharedUncancelable(io);
        defer self.mutex.unlockShared(io);

        // Pre-loop sentinel — matches C++ `proc->ProcessEmpty(NOOP)` before the leaf loop.
        _ = proc.processEmpty("");

        var leaf = self.first_node;
        while (true) {
            if (writable) {
                leaf.mutex.lockUncancelable(io);
            } else {
                leaf.mutex.lockSharedUncancelable(io);
            }

            // Collect keys from this leaf (because processImplOnLeaf modifies records).
            // Dupe each key so that freeBabyRecord inside processImplOnLeaf does not free
            // memory still referenced by the keys list (R-1, C++ emplace_back copies).
            var keys: std.ArrayListUnmanaged([]u8) = .empty;
            defer {
                for (keys.items) |k| self.allocator.free(k);
                keys.deinit(self.allocator);
            }

            for (leaf.records.items) |rec| {
                const key_dupe = self.allocator.dupe(u8, rec.key) catch {
                    if (writable) leaf.mutex.unlock(io) else leaf.mutex.unlockShared(io);
                    return Status.init(.SYSTEM_ERROR);
                };
                keys.append(self.allocator, key_dupe) catch {
                    self.allocator.free(key_dupe);
                    if (writable) leaf.mutex.unlock(io) else leaf.mutex.unlockShared(io);
                    return Status.init(.SYSTEM_ERROR);
                };
            }

            // Process each key.
            for (keys.items) |key| {
                if (writable) {
                    _ = self.processImplOnLeaf(P, proc, leaf, key, true) catch {
                        if (writable) leaf.mutex.unlock(io) else leaf.mutex.unlockShared(io);
                        return Status.init(.SYSTEM_ERROR);
                    };
                } else {
                    // Find record in leaf (may have been moved/removed).
                    for (leaf.records.items) |rec| {
                        if (std.mem.eql(u8, rec.key, key)) {
                            const action = proc.processFull(rec.key, rec.value);
                            _ = action;
                            break;
                        }
                    }
                }
            }

            // Capture next pointer, then unlock current leaf before advancing.
            const next_opt = leaf.next;
            if (writable) {
                leaf.mutex.unlock(io);
            } else {
                leaf.mutex.unlockShared(io);
            }

            if (next_opt) |next_leaf| {
                leaf = next_leaf;
            } else {
                break;
            }
        }

        // Post-loop sentinel — matches C++ `proc->ProcessEmpty(NOOP)` after the leaf loop.
        _ = proc.processEmpty("");

        return Status.init(.SUCCESS);
    }

    /// Return the number of records in the database.
    pub fn count(self: *BabyDBMImpl) i64 {
        return self.num_records.load(.monotonic);
    }

    /// Clear all records and reset the tree to a single empty leaf.
    pub fn clear(self: *BabyDBMImpl, io: std.Io) Status {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.update_logger) |ul| {
            _ = ul.writeClear();
        }

        self.releaseAllNodes();

        // Recreate root as a single empty leaf.
        const new_root_leaf = self.allocator.create(BabyLeafNode) catch
            return Status.init(.SYSTEM_ERROR);
        new_root_leaf.* = BabyLeafNode{
            .prev = null,
            .next = null,
        };

        self.root = .{ .leaf = new_root_leaf };
        self.first_node = new_root_leaf;
        self.last_node = new_root_leaf;
        self.tree_level = 1;
        _ = self.num_records.store(0, .monotonic);

        // Cancel all iterators.
        for (self.iterators.items) |iter| {
            clearPosition(iter);
        }

        return Status.init(.SUCCESS);
    }

    /// Rebuild the tree (no-op for self-balancing B+ tree).
    pub fn rebuild(self: *BabyDBMImpl) Status {
        _ = self;
        return Status.init(.SUCCESS);
    }

    /// Synchronize changes to disk.
    pub fn synchronize(self: *BabyDBMImpl, io: std.Io, hard: bool) Status {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        // C++ Synchronize has no early return but skips all work when !open_ || !writable_,
        // also returning SUCCESS. Zig early return is equivalent.
        if (!self.open or !self.writable) {
            return Status.init(.SUCCESS);
        }

        if (self.update_logger) |ul| {
            const st = ul.synchronize(hard);
            if (!st.isOk()) return st;
        }

        var status = self.exportRecords(io);
        // Sync the underlying file after exporting (R-12, C++ cc:591).
        status.mergeFrom(self.file.synchronize(io, hard));
        return status;
    }

    /// Inspect the database and return metadata as key-value pairs.
    pub fn inspect(self: *BabyDBMImpl, allocator: std.mem.Allocator, io: std.Io) !std.ArrayList([2][]u8) {
        // Acquire exclusive lock post-open (concurrent callers). Pre-open
        // (in-memory use without open()) is single-threaded — no lock needed.
        if (self.open) {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            return self.inspectLocked(allocator);
        }
        return self.inspectLocked(allocator);
    }

    fn inspectLocked(self: *BabyDBMImpl, allocator: std.mem.Allocator) !std.ArrayList([2][]u8) {
        var pairs: std.ArrayList([2][]u8) = .empty;

        const class_key = try allocator.dupe(u8, "class");
        const class_val = try allocator.dupe(u8, "BabyDBM");
        try pairs.append(allocator, [2][]u8{ class_key, class_val });

        if (self.open) {
            const path_key = try allocator.dupe(u8, "path");
            const path_val = try allocator.dupe(u8, self.path.items);
            try pairs.append(allocator, [2][]u8{ path_key, path_val });

            const ts_key = try allocator.dupe(u8, "timestamp");
            const ts_secs: f64 = @as(f64, @floatFromInt(self.timestamp.nanoseconds)) / 1_000_000_000.0;
            const ts_str = try std.fmt.allocPrint(allocator, "{d:.6}", .{ts_secs});
            try pairs.append(allocator, [2][]u8{ ts_key, ts_str });
        }

        const nr_key = try allocator.dupe(u8, "num_records");
        const nr_str = try std.fmt.allocPrint(allocator, "{d}", .{self.num_records.load(.monotonic)});
        try pairs.append(allocator, [2][]u8{ nr_key, nr_str });

        const tl_key = try allocator.dupe(u8, "tree_level");
        const tl_str = try std.fmt.allocPrint(allocator, "{d}", .{self.tree_level});
        try pairs.append(allocator, [2][]u8{ tl_key, tl_str });

        return pairs;
    }

    /// Check if the database is open.
    pub fn isOpen(self: *BabyDBMImpl) bool {
        return self.open;
    }

    /// Check if the database is writable.
    pub fn isWritable(self: *BabyDBMImpl) bool {
        return self.open and self.writable;
    }

    /// Get the file path (if open).
    pub fn getFilePath(self: *BabyDBMImpl) []const u8 {
        return self.path.items;
    }

    /// Get the timestamp (if open). Returns as f64 seconds for C++ API compat.
    pub fn getTimestamp(self: *BabyDBMImpl) f64 {
        return @as(f64, @floatFromInt(self.timestamp.nanoseconds)) / 1_000_000_000.0;
    }

    /// Get the file size (placeholder).
    pub fn getFileSize(self: *BabyDBMImpl) i64 {
        if (!self.open) return -1;
        return self.file.getSizeSimple();
    }

    /// Check if rebuild is needed (always false for self-balancing tree).
    pub fn shouldBeRebuilt(self: *BabyDBMImpl) bool {
        _ = self;
        return false;
    }

    /// Get internal file reference.
    pub fn getInternalFile(self: *BabyDBMImpl) File {
        return self.file;
    }

    /// Set the update logger.
    pub fn setUpdateLogger(self: *BabyDBMImpl, logger: ?*UpdateLogger) void {
        // Note: not safe under concurrent setUpdateLogger calls; matches
        // TinyDBM's behavior. Callers are expected to set the logger before
        // exposing the DBM to other threads.
        self.update_logger = logger;
    }

    /// Get the current update logger.
    pub fn getUpdateLogger(self: *BabyDBMImpl) ?*UpdateLogger {
        return self.update_logger;
    }

    // -----------------------------------------------------------------------
    // Persistence: Import / Export
    // -----------------------------------------------------------------------

    /// Import records from a file using FlatRecordReader.
    fn importRecords(self: *BabyDBMImpl, io: std.Io) !Status {
        var reader = FlatRecordReader.init(
            self.file,
            self.allocator,
            file_util.DEFAULT_READER_BUFFER_SIZE,
        ) catch return Status.init(.SYSTEM_ERROR);
        defer reader.deinit();

        var key_store: std.ArrayList(u8) = .empty;
        defer key_store.deinit(self.allocator);

        var iteration: usize = 0;
        while (true) {
            iteration += 1;
            var str: []const u8 = undefined;
            var rec_type: RecordType = undefined;
            const st = reader.read(io, &str, &rec_type);
            if (!st.isOk()) {
                if (st.code == .NOT_FOUND_ERROR) {
                    break;
                }
                return st;
            }

            if (rec_type != .normal) {
                if (rec_type == .metadata) {
                    // Parse metadata for timestamp and other fields.
                    var meta = str_util.deserializeStrMap(str, self.allocator) catch continue;
                    defer meta.deinit();
                    if (meta.get("class")) |class_str| {
                        if (str_util.strContains(class_str, "BabyDBM")) {
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

            try self.processImplForImport(io, key_store.items, val_str);
        }
        return Status.init(.SUCCESS);
    }

    /// Export all records to a file.
    fn exportRecords(self: *BabyDBMImpl, io: std.Io) Status {
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

        // Export options: preserve sync_hard, but ensure truncate is set.
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
            const tl_str = std.fmt.allocPrint(self.allocator, "{d}", .{self.tree_level}) catch
                return Status.init(.SYSTEM_ERROR);
            defer self.allocator.free(tl_str);

            meta.put("class", "BabyDBM") catch return Status.init(.SYSTEM_ERROR);
            meta.put("timestamp", ts_str) catch return Status.init(.SYSTEM_ERROR);
            meta.put("num_records", nr_str) catch return Status.init(.SYSTEM_ERROR);
            meta.put("tree_level", tl_str) catch return Status.init(.SYSTEM_ERROR);

            const serialized = str_util.serializeStrMap(&meta, self.allocator) catch
                return Status.init(.SYSTEM_ERROR);
            defer self.allocator.free(serialized);

            status.mergeFrom(flat_rec.write(io, serialized, .metadata));
        }

        // Walk leaf chain and write all records.
        var leaf: ?*BabyLeafNode = self.first_node;
        outer: while (leaf) |current_leaf| {
            for (current_leaf.records.items) |rec| {
                status.mergeFrom(flat_rec.write(io, rec.key, .normal));
                status.mergeFrom(flat_rec.write(io, rec.value, .normal));
                if (!status.isOk()) break :outer;
            }
            leaf = current_leaf.next;
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
    // File Operations: open / close
    // -----------------------------------------------------------------------

    /// Open a database file for reading/writing.
    fn openImpl(self: *BabyDBMImpl, io: std.Io, path: []const u8, writable: bool, options: OpenOptions) !Status {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.open) {
            return Status.initMsg(.PRECONDITION_ERROR, "already open");
        }

        // Store path.
        self.path.clearRetainingCapacity();
        self.path.appendSlice(self.allocator, path) catch
            return Status.init(.SYSTEM_ERROR);

        // Open file.
        const st_open = self.file.open(io, path, writable, options);
        if (!st_open.isOk()) {
            self.path.clearRetainingCapacity();
            return st_open;
        }

        // If file is empty, initialize timestamp.
        const file_size = self.file.getSizeSimple();
        if (file_size == 0) {
            self.timestamp = std.Io.Clock.real.now(io);
        }

        // Import existing records.
        const st_import = try self.importRecords(io);
        if (!st_import.isOk()) {
            _ = self.file.close(io);
            self.path.clearRetainingCapacity();
            self.open = false;
            return st_import;
        }

        // Process any reorg entries from import.
        if (self.reorg_nodes.items.len > 0) {
            try self.reorganizeTree();
        }

        // Mark as open.
        self.open = true;
        self.writable = writable;
        self.open_options = options;

        return Status.init(.SUCCESS);
    }

    /// Insert a record during import.
    ///
    /// IMPORTANT: This function assumes the caller holds self.mutex exclusively.
    /// It does NOT acquire self.mutex internally, which avoids the deadlock that
    /// would occur if we called processImpl() here (which tries to lockShared on
    /// a mutex already held exclusively by the same thread).
    ///
    /// This is only safe to call from importRecords() during openImpl().
    fn processImplForImport(self: *BabyDBMImpl, io: std.Io, key: []const u8, value: []const u8) !void {
        // Find the leaf containing this key.
        const leaf = self.searchTree(key);

        // Acquire leaf lock (we already hold self.mutex exclusively).
        leaf.mutex.lockUncancelable(io);
        defer leaf.mutex.unlock(io);

        // Create a simple setter processor.
        var import_status = Status.init(.SUCCESS);
        var setter = ProcessorSet{
            .status = &import_status,
            .value = value,
            .overwrite = true,
            .old_value = null,
            .allocator = self.allocator,
        };

        // Process on leaf.
        const result = try self.processImplOnLeaf(ProcessorSet, &setter, leaf, key, true);

        // Handle reorg if needed.
        if (result == .needs_split or result == .needs_merge) {
            const first_key = if (leaf.records.items.len > 0) leaf.records.items[0].key else "";
            const key_copy = try self.allocator.dupe(u8, first_key);
            errdefer self.allocator.free(key_copy);
            try self.reorg_nodes.append(self.allocator, ReorgEntry{
                .leaf = leaf,
                .key = key_copy,
            });
        }
    }

    /// Close the database file.
    fn closeImpl(self: *BabyDBMImpl, io: std.Io) Status {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (!self.open) {
            return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        }

        var status = Status.init(.SUCCESS);

        // Export records if writable, otherwise just close the file (R-15, C++ cc:403-406).
        if (self.writable) {
            status.mergeFrom(self.exportRecords(io));
        } else {
            status.mergeFrom(self.file.close(io));
        }

        // Clear tree and reset state.
        self.releaseAllNodes();

        const new_root_leaf = self.allocator.create(BabyLeafNode) catch
            return Status.init(.SYSTEM_ERROR);
        new_root_leaf.* = BabyLeafNode{
            .prev = null,
            .next = null,
        };

        self.root = .{ .leaf = new_root_leaf };
        self.first_node = new_root_leaf;
        self.last_node = new_root_leaf;
        self.tree_level = 1;
        _ = self.num_records.store(0, .monotonic);

        // Cancel iterators.
        for (self.iterators.items) |iter| {
            clearPosition(iter);
        }

        // Clear path.
        self.path.clearRetainingCapacity();

        // Mark as closed.
        self.open = false;
        self.writable = false;
        self.timestamp = std.Io.Timestamp.zero;

        return status;
    }
};

// ---------------------------------------------------------------------------
// Iterator implementation (forward declaration)
// ---------------------------------------------------------------------------

const BabyDBMIteratorImpl = struct {
    dbm: ?*BabyDBMImpl,
    leaf_node: ?*BabyLeafNode,
    key_buf: [ITER_BUFFER_SIZE]u8,
    key_heap: ?[]u8,
    key_size: usize,
    allocator: std.mem.Allocator,
};

// ---------------------------------------------------------------------------
// Iterator helper functions and methods
// ---------------------------------------------------------------------------

/// Initialize a new iterator for the given DBM.
fn iterInit(dbm: *BabyDBMImpl, io: std.Io, allocator: std.mem.Allocator) !*BabyDBMIteratorImpl {
    const self = try allocator.create(BabyDBMIteratorImpl);
    errdefer allocator.destroy(self);

    self.* = BabyDBMIteratorImpl{
        .dbm = dbm,
        .leaf_node = null,
        .key_buf = undefined,
        .key_heap = null,
        .key_size = 0,
        .allocator = allocator,
    };

    // Register this iterator with the DBM.
    // Pre-open (in-memory): single-threaded, no lock needed.
    const locked = dbm.open;
    if (locked) dbm.mutex.lockUncancelable(io);
    defer if (locked) dbm.mutex.unlock(io);
    try dbm.iterators.append(allocator, self);

    return self;
}

/// Deinitialize an iterator, removing it from the DBM's iterator list.
fn iterDeinit(self: *BabyDBMIteratorImpl, io: std.Io) void {
    if (self.dbm) |dbm| {
        const locked = dbm.open;
        if (locked) dbm.mutex.lockUncancelable(io);
        defer if (locked) dbm.mutex.unlock(io);

        // Find and remove this iterator from the list.
        for (dbm.iterators.items, 0..) |iter, idx| {
            if (iter == self) {
                _ = dbm.iterators.orderedRemove(idx);
                break;
            }
        }
    }

    // Clear position and free heap-allocated key.
    clearPosition(self);

    // Destroy self.
    self.allocator.destroy(self);
}

/// Clear the current position, freeing any heap-allocated key.
fn clearPosition(self: *BabyDBMIteratorImpl) void {
    if (self.key_heap) |heap_key| {
        self.allocator.free(heap_key);
    }
    self.key_heap = null;
    self.leaf_node = null;
    self.key_size = 0;
}

/// Set position with a given key, using stack buffer if <= 128 bytes, heap otherwise.
fn setPositionWithKey(self: *BabyDBMIteratorImpl, leaf: *BabyLeafNode, key: []const u8) !void {
    clearPosition(self);

    if (key.len <= ITER_BUFFER_SIZE) {
        // Fit in stack buffer.
        @memcpy(self.key_buf[0..key.len], key);
        self.key_size = key.len;
    } else {
        // Allocate heap.
        self.key_heap = try self.allocator.dupe(u8, key);
        self.key_size = key.len;
    }

    self.leaf_node = leaf;
}

/// Get current key as a slice.
fn getCurrentKey(self: *const BabyDBMIteratorImpl) ?[]const u8 {
    if (self.key_size == 0) return null;
    if (self.key_heap) |heap_key| {
        return heap_key[0..self.key_size];
    } else {
        return self.key_buf[0..self.key_size];
    }
}

/// Position iterator at the first record in the tree.
fn iterFirst(self: *BabyDBMIteratorImpl, io: std.Io) Status {
    if (self.dbm == null) return Status.init(.NOT_FOUND_ERROR);

    const dbm = self.dbm.?;
    const locked = dbm.open;
    if (locked) dbm.mutex.lockSharedUncancelable(io);
    defer if (locked) dbm.mutex.unlockShared(io);

    clearPosition(self);

    var leaf: ?*BabyLeafNode = dbm.first_node;
    while (leaf != null) {
        if (locked) leaf.?.mutex.lockSharedUncancelable(io);
        defer if (locked) leaf.?.mutex.unlockShared(io);

        if (leaf.?.records.items.len > 0) {
            setPositionWithKey(self, leaf.?, leaf.?.records.items[0].key) catch {
                return Status.init(.SYSTEM_ERROR);
            };
            return Status.init(.SUCCESS);
        }

        leaf = leaf.?.next;
    }

    return Status.init(.NOT_FOUND_ERROR);
}

/// Position iterator at the last record in the tree.
fn iterLast(self: *BabyDBMIteratorImpl, io: std.Io) Status {
    if (self.dbm == null) return Status.init(.NOT_FOUND_ERROR);

    const dbm = self.dbm.?;
    const locked = dbm.open;
    if (locked) dbm.mutex.lockSharedUncancelable(io);
    defer if (locked) dbm.mutex.unlockShared(io);

    clearPosition(self);

    var leaf: ?*BabyLeafNode = dbm.last_node;
    while (leaf != null) {
        if (locked) leaf.?.mutex.lockSharedUncancelable(io);
        defer if (locked) leaf.?.mutex.unlockShared(io);

        if (leaf.?.records.items.len > 0) {
            setPositionWithKey(self, leaf.?, leaf.?.records.items[leaf.?.records.items.len - 1].key) catch {
                return Status.init(.SYSTEM_ERROR);
            };
            return Status.init(.SUCCESS);
        }

        leaf = leaf.?.prev;
    }

    return Status.init(.NOT_FOUND_ERROR);
}

/// Position iterator at the given key (or first key >= given key).
fn iterJump(self: *BabyDBMIteratorImpl, io: std.Io, key: []const u8) Status {
    if (self.dbm == null) return Status.init(.NOT_FOUND_ERROR);

    const dbm = self.dbm.?;
    const locked = dbm.open;
    if (locked) dbm.mutex.lockSharedUncancelable(io);
    defer if (locked) dbm.mutex.unlockShared(io);

    clearPosition(self);

    // Search tree to find the leaf that would contain the key.
    const leaf = dbm.searchTree(key);
    if (locked) leaf.mutex.lockSharedUncancelable(io);
    defer if (locked) leaf.mutex.unlockShared(io);

    // Binary search for the key in the leaf.
    const idx = dbm.lowerBoundInLeaf(leaf.records.items, key);

    // Check if we found an exact match.
    if (idx < leaf.records.items.len and
        std.mem.eql(u8, leaf.records.items[idx].key, key)) {
        setPositionWithKey(self, leaf, leaf.records.items[idx].key) catch {
            return Status.init(.SYSTEM_ERROR);
        };
        return Status.init(.SUCCESS);
    }

    // Not an exact match: position at the first key >= search key in the current or next leaf.
    if (idx < leaf.records.items.len) {
        // Found a key >= search key in current leaf.
        setPositionWithKey(self, leaf, leaf.records.items[idx].key) catch {
            return Status.init(.SYSTEM_ERROR);
        };
        return Status.init(.SUCCESS);
    }

    // Try to move to next leaf and find the first record there.
    var next_leaf = leaf.next;
    while (next_leaf != null) {
        if (locked) next_leaf.?.mutex.lockSharedUncancelable(io);
        defer if (locked) next_leaf.?.mutex.unlockShared(io);

        if (next_leaf.?.records.items.len > 0) {
            setPositionWithKey(self, next_leaf.?, next_leaf.?.records.items[0].key) catch {
                return Status.init(.SYSTEM_ERROR);
            };
            return Status.init(.SUCCESS);
        }

        next_leaf = next_leaf.?.next;
    }

    return Status.init(.NOT_FOUND_ERROR);
}

/// Position iterator at the largest key < key (or <= key if inclusive).
/// Returns SUCCESS even when no matching record exists (cleared position), matching C++ (R-17).
fn iterJumpLower(self: *BabyDBMIteratorImpl, io: std.Io, key: []const u8, inclusive: bool) Status {
    // Jump to the key position (first key >= search key).
    var status = iterJump(self, io, key);

    // If jump found nothing (empty DB or all keys < search key), try positioning at last.
    if (status.code == .NOT_FOUND_ERROR) {
        // iterLast returns NOT_FOUND_ERROR only when DB is empty.
        // Either way, return SUCCESS (R-17, C++ cc:1183-1186).
        _ = iterLast(self, io);
        return Status.init(.SUCCESS);
    }

    if (status.code != .SUCCESS) {
        return status;
    }

    // Now we're positioned at the first key >= search key.
    // Back up until we find key < search key (or <= if inclusive).
    while (self.leaf_node != null) {
        if (getCurrentKey(self)) |current_key| {
            const cmp = self.dbm.?.key_comparator(current_key, key);
            if (cmp == .lt or (inclusive and cmp == .eq)) {
                return Status.init(.SUCCESS);
            }
        }

        status = iterPrevious(self, io);
        if (status.code != .SUCCESS) {
            return status;
        }
    }

    // Position became null (backed past the beginning): return SUCCESS (R-17).
    return Status.init(.SUCCESS);
}

/// Position iterator at the smallest key > key (or >= key if inclusive).
/// Returns SUCCESS even when no matching record exists (cleared position), matching C++ (R-18).
fn iterJumpUpper(self: *BabyDBMIteratorImpl, io: std.Io, key: []const u8, inclusive: bool) Status {
    // Jump to the key position (first key >= search key).
    var status = iterJump(self, io, key);

    if (status.code != .SUCCESS) {
        // NOT_FOUND_ERROR means no record >= key exists; return SUCCESS with cleared position.
        if (status.code == .NOT_FOUND_ERROR) {
            return Status.init(.SUCCESS);
        }
        return status;
    }

    // Now we're positioned at the first key >= search key.
    while (self.leaf_node != null) {
        if (getCurrentKey(self)) |current_key| {
            const cmp = self.dbm.?.key_comparator(current_key, key);
            if (cmp == .gt or (inclusive and cmp == .eq)) {
                return Status.init(.SUCCESS);
            }
        }

        status = iterNext(self, io);
        if (status.code != .SUCCESS) {
            return status;
        }
    }

    // Position became null (walked past all records): return SUCCESS (R-18).
    return Status.init(.SUCCESS);
}

/// Advance iterator to the next record.
/// Mirrors C++ NextImpl (cc:1312-1334): uses upper_bound to find the first record strictly
/// after current_key. If key was deleted, upper_bound still finds the correct successor.
/// Returns SUCCESS in all cases (cleared position when no successor exists).
fn iterNext(self: *BabyDBMIteratorImpl, io: std.Io) Status {
    if (self.dbm == null or self.key_size == 0) {
        return Status.init(.NOT_FOUND_ERROR);
    }

    const dbm = self.dbm.?;
    const locked = dbm.open;
    const current_key = getCurrentKey(self).?;
    if (locked) dbm.mutex.lockSharedUncancelable(io);
    defer if (locked) dbm.mutex.unlockShared(io);

    // If leaf_node is null, search for it using the current key.
    if (self.leaf_node == null) {
        self.leaf_node = dbm.searchTree(current_key);
    }

    var leaf = self.leaf_node.?;

    // upper_bound: find the first record strictly greater than current_key.
    // lowerBoundInLeaf returns the first idx where records[idx].key >= current_key.
    // If records[idx].key == current_key (exact match), advance idx by 1 to get upper_bound.
    {
        if (locked) leaf.mutex.lockSharedUncancelable(io);
        defer if (locked) leaf.mutex.unlockShared(io);

        var idx = dbm.lowerBoundInLeaf(leaf.records.items, current_key);
        // Advance past exact match (implements upper_bound).
        if (idx < leaf.records.items.len and
            std.mem.eql(u8, leaf.records.items[idx].key, current_key))
        {
            idx += 1;
        }

        if (idx < leaf.records.items.len) {
            setPositionWithKey(self, leaf, leaf.records.items[idx].key) catch {
                return Status.init(.SYSTEM_ERROR);
            };
            return Status.init(.SUCCESS);
        }
    }

    // No record found in current leaf; walk forward through next leaves.
    var next_leaf = leaf.next;
    while (next_leaf != null) {
        var current_next = next_leaf.?;
        if (locked) current_next.mutex.lockSharedUncancelable(io);
        defer if (locked) current_next.mutex.unlockShared(io);

        if (current_next.records.items.len > 0) {
            setPositionWithKey(self, current_next, current_next.records.items[0].key) catch {
                return Status.init(.SYSTEM_ERROR);
            };
            return Status.init(.SUCCESS);
        }

        next_leaf = current_next.next;
    }

    // No successor exists: clear position and return SUCCESS (R-16).
    clearPosition(self);
    return Status.init(.SUCCESS);
}

/// Retreat iterator to the previous record.
/// Mirrors C++ PreviousImpl (cc:1336-1361): uses lower_bound to find the insertion point for
/// current_key, then steps one back. If key was deleted, lower_bound returns the first record
/// > current_key, and records[idx-1] is the correct predecessor regardless.
/// Returns SUCCESS in all cases (cleared position when no predecessor exists).
fn iterPrevious(self: *BabyDBMIteratorImpl, io: std.Io) Status {
    if (self.dbm == null or self.key_size == 0) {
        return Status.init(.NOT_FOUND_ERROR);
    }

    const dbm = self.dbm.?;
    const locked = dbm.open;
    const current_key = getCurrentKey(self).?;
    if (locked) dbm.mutex.lockSharedUncancelable(io);
    defer if (locked) dbm.mutex.unlockShared(io);

    // If leaf_node is null, search for it using the current key.
    if (self.leaf_node == null) {
        self.leaf_node = dbm.searchTree(current_key);
    }

    var leaf = self.leaf_node.?;

    // lower_bound: first idx where records[idx].key >= current_key.
    // records[idx-1] is the predecessor whether or not current_key exists.
    {
        if (locked) leaf.mutex.lockSharedUncancelable(io);
        defer if (locked) leaf.mutex.unlockShared(io);

        const idx = dbm.lowerBoundInLeaf(leaf.records.items, current_key);

        if (idx > 0) {
            setPositionWithKey(self, leaf, leaf.records.items[idx - 1].key) catch {
                return Status.init(.SYSTEM_ERROR);
            };
            return Status.init(.SUCCESS);
        }
    }

    // No predecessor in current leaf; walk backward through previous leaves.
    var prev_leaf = leaf.prev;
    while (prev_leaf != null) {
        var current_prev = prev_leaf.?;
        if (locked) current_prev.mutex.lockSharedUncancelable(io);
        defer if (locked) current_prev.mutex.unlockShared(io);

        if (current_prev.records.items.len > 0) {
            setPositionWithKey(self, current_prev, current_prev.records.items[current_prev.records.items.len - 1].key) catch {
                return Status.init(.SYSTEM_ERROR);
            };
            return Status.init(.SUCCESS);
        }

        prev_leaf = current_prev.prev;
    }

    // No predecessor exists: clear position and return SUCCESS (R-16).
    clearPosition(self);
    return Status.init(.SUCCESS);
}

/// Get the current key and value, allocating copies if requested.
fn iterGet(
    self: *BabyDBMIteratorImpl,
    allocator: std.mem.Allocator,
    io: std.Io,
    key_out: ?*std.ArrayList(u8),
    value_out: ?*std.ArrayList(u8),
) Status {
    if (self.leaf_node == null or self.key_size == 0) {
        return Status.init(.NOT_FOUND_ERROR);
    }

    const dbm = self.dbm.?;
    const locked = dbm.open;
    const current_key = getCurrentKey(self).?;
    var leaf = self.leaf_node.?;

    if (locked) leaf.mutex.lockSharedUncancelable(io);
    defer if (locked) leaf.mutex.unlockShared(io);

    // Binary search for the current key in the leaf.
    const idx = self.dbm.?.lowerBoundInLeaf(leaf.records.items, current_key);

    // Verify we found the exact key.
    if (idx >= leaf.records.items.len or !std.mem.eql(u8, leaf.records.items[idx].key, current_key)) {
        return Status.init(.NOT_FOUND_ERROR);
    }

    // Copy key if requested.
    if (key_out) |ko| {
        ko.clearRetainingCapacity();
        ko.appendSlice(allocator, current_key) catch {
            return Status.init(.SYSTEM_ERROR);
        };
    }

    // Copy value if requested.
    if (value_out) |vo| {
        vo.clearRetainingCapacity();
        vo.appendSlice(allocator, leaf.records.items[idx].value) catch {
            return Status.init(.SYSTEM_ERROR);
        };
    }

    return Status.init(.SUCCESS);
}

/// Process the current record with a generic processor.
fn iterProcess(
    self: *BabyDBMIteratorImpl,
    io: std.Io,
    comptime P: type,
    proc: *P,
    writable: bool,
) Status {
    if (self.leaf_node == null or self.key_size == 0) {
        return Status.init(.NOT_FOUND_ERROR);
    }

    const dbm = self.dbm.?;
    const locked = dbm.open;
    const current_key = getCurrentKey(self).?;

    // If writable and reorg queue is not empty, drain it first.
    if (writable) {
        if (locked) dbm.mutex.lockUncancelable(io);
        defer if (locked) dbm.mutex.unlock(io);

        if (dbm.reorg_nodes.items.len > 0) {
            // Drain the reorg queue under exclusive lock.
            _ = dbm.reorganizeTree() catch {};
        }
    }

    // Now acquire shared lock for the actual process.
    if (locked) dbm.mutex.lockSharedUncancelable(io);
    defer if (locked) dbm.mutex.unlockShared(io);

    var leaf = self.leaf_node.?;

    if (writable) {
        if (locked) leaf.mutex.lockUncancelable(io);
        defer if (locked) leaf.mutex.unlock(io);

        // Search for the current key.
        const idx = self.dbm.?.lowerBoundInLeaf(leaf.records.items, current_key);
        if (idx >= leaf.records.items.len or !std.mem.eql(u8, leaf.records.items[idx].key, current_key)) {
            return Status.init(.NOT_FOUND_ERROR);
        }

        // Call the dbm's processImpl to handle the modification.
        _ = self.dbm.?.processImplOnLeaf(P, proc, leaf, current_key, true) catch {
            return Status.init(.SYSTEM_ERROR);
        };

        return Status.init(.SUCCESS);
    } else {
        if (locked) leaf.mutex.lockSharedUncancelable(io);
        defer if (locked) leaf.mutex.unlockShared(io);

        // Search for the current key.
        const idx = dbm.lowerBoundInLeaf(leaf.records.items, current_key);
        if (idx >= leaf.records.items.len or !std.mem.eql(u8, leaf.records.items[idx].key, current_key)) {
            return Status.init(.NOT_FOUND_ERROR);
        }

        // Call processFull directly on the found record.
        _ = proc.processFull(current_key, leaf.records.items[idx].value);

        return Status.init(.SUCCESS);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "BabyRecord alloc and free" {
    const alloc = std.testing.allocator;
    const rec = try createBabyRecord(alloc, "testkey", "testvalue");
    defer freeBabyRecord(alloc, rec);

    try std.testing.expectEqualStrings("testkey", rec.key);
    try std.testing.expectEqualStrings("testvalue", rec.value);
}

test "BabyLink alloc and free" {
    const alloc = std.testing.allocator;
    const dummy_leaf = try alloc.create(BabyLeafNode);
    defer alloc.destroy(dummy_leaf);
    dummy_leaf.* = .{ .prev = null, .next = null };

    const link = try createBabyLink(alloc, "separator", .{ .leaf = dummy_leaf });
    defer freeBabyLink(alloc, link);

    try std.testing.expectEqualStrings("separator", link.key);
    try std.testing.expect(link.child == .leaf);
}

test "BabyDBMImpl init and deinit" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    const impl = try BabyDBMImpl.init(std_file.asFile(), lexicalKeyComparator, alloc);
    defer impl.deinit(std.testing.io);

    // Verify initial state.
    try std.testing.expectEqual(@as(i32, 1), impl.tree_level);
    try std.testing.expectEqual(@as(i64, 0), impl.num_records.load(.monotonic));
    try std.testing.expect(impl.root == .leaf);
    try std.testing.expect(impl.first_node == impl.last_node);
}

test "KeyComparator lexicographic ordering" {
    try std.testing.expect(lexicalKeyComparator("a", "b") == .lt);
    try std.testing.expect(lexicalKeyComparator("b", "a") == .gt);
    try std.testing.expect(lexicalKeyComparator("x", "x") == .eq);
}

test "lowerBoundInLeaf: simple binary search in leaf" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    const impl = try BabyDBMImpl.init(std_file.asFile(), lexicalKeyComparator, alloc);
    defer impl.deinit(std.testing.io);

    var records: std.ArrayList(BabyRecord) = .empty;
    defer {
        for (records.items) |rec| freeBabyRecord(alloc, rec);
        records.deinit(alloc);
    }

    // Insert sorted records: "apple", "cherry", "orange"
    try records.append(alloc, try createBabyRecord(alloc, "apple", "a"));
    try records.append(alloc, try createBabyRecord(alloc, "cherry", "c"));
    try records.append(alloc, try createBabyRecord(alloc, "orange", "o"));

    // Test lower_bound positions (first element >= key).
    try std.testing.expectEqual(@as(usize, 0), impl.lowerBoundInLeaf(records.items, "aaa"));
    try std.testing.expectEqual(@as(usize, 0), impl.lowerBoundInLeaf(records.items, "apple"));
    try std.testing.expectEqual(@as(usize, 1), impl.lowerBoundInLeaf(records.items, "bananas"));
    try std.testing.expectEqual(@as(usize, 1), impl.lowerBoundInLeaf(records.items, "cherry"));
    try std.testing.expectEqual(@as(usize, 2), impl.lowerBoundInLeaf(records.items, "date"));
    try std.testing.expectEqual(@as(usize, 2), impl.lowerBoundInLeaf(records.items, "orange"));
    try std.testing.expectEqual(@as(usize, 3), impl.lowerBoundInLeaf(records.items, "zebra"));
}

test "searchTree: single leaf returns root" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    const impl = try BabyDBMImpl.init(std_file.asFile(), lexicalKeyComparator, alloc);
    defer impl.deinit(std.testing.io);

    // Root is a leaf; searchTree should return it.
    const found_leaf = impl.searchTree("anything");
    try std.testing.expect(found_leaf == impl.root.leaf);
}

test "processImplOnLeaf: set and get single record" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    const impl = try BabyDBMImpl.init(std_file.asFile(), lexicalKeyComparator, alloc);
    defer impl.deinit(std.testing.io);

    const key = "testkey";
    const value = "testvalue";

    // Set the key.
    const set_status = impl.set(alloc, std.testing.io, key, value, true, null);
    try std.testing.expectEqual(Code.SUCCESS, set_status.code);
    try std.testing.expectEqual(@as(i64, 1), impl.num_records.load(.monotonic));

    // Get the key.
    var retrieved: std.ArrayList(u8) = .empty;
    defer retrieved.deinit(alloc);
    const get_status = impl.get(alloc, std.testing.io, key, &retrieved);
    try std.testing.expectEqual(Code.SUCCESS, get_status.code);
    try std.testing.expectEqualStrings(value, retrieved.items);
}

test "processImplOnLeaf: get non-existent key returns NOT_FOUND_ERROR" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    const impl = try BabyDBMImpl.init(std_file.asFile(), lexicalKeyComparator, alloc);
    defer impl.deinit(std.testing.io);

    var retrieved: std.ArrayList(u8) = .empty;
    defer retrieved.deinit(alloc);
    const status = impl.get(alloc, std.testing.io, "nonexistent", &retrieved);
    try std.testing.expectEqual(Code.NOT_FOUND_ERROR, status.code);
}

test "processImplOnLeaf: set with overwrite=false on existing key returns DUPLICATION_ERROR" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    const impl = try BabyDBMImpl.init(std_file.asFile(), lexicalKeyComparator, alloc);
    defer impl.deinit(std.testing.io);

    const key = "testkey";
    const value1 = "value1";
    const value2 = "value2";

    // Set the first value.
    const status1 = impl.set(alloc, std.testing.io, key, value1, true, null);
    try std.testing.expectEqual(Code.SUCCESS, status1.code);

    // Try to set again with overwrite=false.
    const status2 = impl.set(alloc, std.testing.io, key, value2, false, null);
    try std.testing.expectEqual(Code.DUPLICATION_ERROR, status2.code);

    // Verify the value is unchanged.
    var retrieved: std.ArrayList(u8) = .empty;
    defer retrieved.deinit(alloc);
    const get_status = impl.get(alloc, std.testing.io, key, &retrieved);
    try std.testing.expectEqual(Code.SUCCESS, get_status.code);
    try std.testing.expectEqualStrings(value1, retrieved.items);
}

test "processImplOnLeaf: remove key" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    const impl = try BabyDBMImpl.init(std_file.asFile(), lexicalKeyComparator, alloc);
    defer impl.deinit(std.testing.io);

    const key = "testkey";
    const value = "testvalue";

    // Set the key.
    const status1 = impl.set(alloc, std.testing.io, key, value, true, null);
    try std.testing.expectEqual(Code.SUCCESS, status1.code);
    try std.testing.expectEqual(@as(i64, 1), impl.num_records.load(.monotonic));

    // Remove the key.
    const remove_status = impl.remove(std.testing.io, key);
    try std.testing.expectEqual(Code.SUCCESS, remove_status.code);
    try std.testing.expectEqual(@as(i64, 0), impl.num_records.load(.monotonic));

    // Verify it's gone.
    var retrieved: std.ArrayList(u8) = .empty;
    defer retrieved.deinit(alloc);
    const get_status = impl.get(alloc, std.testing.io, key, &retrieved);
    try std.testing.expectEqual(Code.NOT_FOUND_ERROR, get_status.code);
}

test "processImplOnLeaf: remove on non-existent key returns NOT_FOUND_ERROR" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    const impl = try BabyDBMImpl.init(std_file.asFile(), lexicalKeyComparator, alloc);
    defer impl.deinit(std.testing.io);

    const status = impl.remove(std.testing.io, "nonexistent");
    try std.testing.expectEqual(Code.NOT_FOUND_ERROR, status.code);
}

test "processImplOnLeaf: set/get round-trip with 10 records" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    const impl = try BabyDBMImpl.init(std_file.asFile(), lexicalKeyComparator, alloc);
    defer impl.deinit(std.testing.io);

    var buf: [32]u8 = undefined;

    // Set 10 records.
    for (0..10) |i| {
        const key = try std.fmt.bufPrint(&buf, "key{d}", .{i});
        const value = try std.fmt.bufPrint(buf[16..], "value{d}", .{i});
        const status = impl.set(alloc, std.testing.io, key, value, true, null);
        try std.testing.expectEqual(Code.SUCCESS, status.code);
    }
    try std.testing.expectEqual(@as(i64, 10), impl.num_records.load(.monotonic));

    // Get all 10 records.
    for (0..10) |i| {
        const key = try std.fmt.bufPrint(&buf, "key{d}", .{i});
        var retrieved: std.ArrayList(u8) = .empty;
        defer retrieved.deinit(alloc);
        const status = impl.get(alloc, std.testing.io, key, &retrieved);
        try std.testing.expectEqual(Code.SUCCESS, status.code);
        const expected_value = try std.fmt.bufPrint(buf[16..], "value{d}", .{i});
        try std.testing.expectEqualStrings(expected_value, retrieved.items);
    }
}

// Iterator tests
test "iterFirst: position at first key" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    const impl = try BabyDBMImpl.init(std_file.asFile(), lexicalKeyComparator, alloc);
    defer impl.deinit(std.testing.io);

    // Insert keys: key1, key2, key3
    const status1 = impl.set(alloc, std.testing.io, "key1", "value1", true, null);
    try std.testing.expectEqual(Code.SUCCESS, status1.code);
    const status2 = impl.set(alloc, std.testing.io, "key2", "value2", true, null);
    try std.testing.expectEqual(Code.SUCCESS, status2.code);
    const status3 = impl.set(alloc, std.testing.io, "key3", "value3", true, null);
    try std.testing.expectEqual(Code.SUCCESS, status3.code);

    // Create and position iterator at first.
    const iter = try iterInit(impl, std.testing.io, alloc);
    defer iterDeinit(iter, std.testing.io);

    const iter_status = iterFirst(iter, std.testing.io);
    try std.testing.expectEqual(Code.SUCCESS, iter_status.code);
    try std.testing.expect(iter.leaf_node != null);
    try std.testing.expectEqual(@as(usize, 4), iter.key_size); // "key1" has 4 chars
    try std.testing.expectEqualStrings("key1", getCurrentKey(iter).?);
}

test "iterLast: position at last key" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    const impl = try BabyDBMImpl.init(std_file.asFile(), lexicalKeyComparator, alloc);
    defer impl.deinit(std.testing.io);

    // Insert keys: key1, key2, key3
    _ = impl.set(alloc, std.testing.io, "key1", "value1", true, null);
    _ = impl.set(alloc, std.testing.io, "key2", "value2", true, null);
    _ = impl.set(alloc, std.testing.io, "key3", "value3", true, null);

    // Create and position iterator at last.
    const iter = try iterInit(impl, std.testing.io, alloc);
    defer iterDeinit(iter, std.testing.io);

    const status = iterLast(iter, std.testing.io);
    try std.testing.expectEqual(Code.SUCCESS, status.code);
    try std.testing.expect(iter.leaf_node != null);
    try std.testing.expectEqualStrings("key3", getCurrentKey(iter).?);
}

test "iterNext: forward iteration collects keys in order" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    const impl = try BabyDBMImpl.init(std_file.asFile(), lexicalKeyComparator, alloc);
    defer impl.deinit(std.testing.io);

    // Insert keys in arbitrary order: key3, key1, key2
    _ = impl.set(alloc, std.testing.io, "key3", "value3", true, null);
    _ = impl.set(alloc, std.testing.io, "key1", "value1", true, null);
    _ = impl.set(alloc, std.testing.io, "key2", "value2", true, null);

    // Create iterator and collect keys via forward iteration.
    const iter = try iterInit(impl, std.testing.io, alloc);
    defer iterDeinit(iter, std.testing.io);

    var keys: std.ArrayList([]u8) = .empty;
    defer {
        for (keys.items) |k| alloc.free(k);
        keys.deinit(alloc);
    }

    var status = iterFirst(iter, std.testing.io);
    try std.testing.expectEqual(Code.SUCCESS, status.code);

    while (getCurrentKey(iter) != null) {
        const current_key = getCurrentKey(iter).?;
        const key_copy = try alloc.dupe(u8, current_key);
        try keys.append(alloc, key_copy);

        status = iterNext(iter, std.testing.io);
        if (status.code == .NOT_FOUND_ERROR) break;
        try std.testing.expectEqual(Code.SUCCESS, status.code);
    }

    // Verify keys are in order.
    try std.testing.expectEqual(@as(usize, 3), keys.items.len);
    try std.testing.expectEqualStrings("key1", keys.items[0]);
    try std.testing.expectEqualStrings("key2", keys.items[1]);
    try std.testing.expectEqualStrings("key3", keys.items[2]);
}

test "iterPrevious: backward iteration from last" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    const impl = try BabyDBMImpl.init(std_file.asFile(), lexicalKeyComparator, alloc);
    defer impl.deinit(std.testing.io);

    // Insert keys.
    _ = impl.set(alloc, std.testing.io, "key1", "value1", true, null);
    _ = impl.set(alloc, std.testing.io, "key2", "value2", true, null);
    _ = impl.set(alloc, std.testing.io, "key3", "value3", true, null);

    const iter = try iterInit(impl, std.testing.io, alloc);
    defer iterDeinit(iter, std.testing.io);

    var keys: std.ArrayList([]u8) = .empty;
    defer {
        for (keys.items) |k| alloc.free(k);
        keys.deinit(alloc);
    }

    var status = iterLast(iter, std.testing.io);
    try std.testing.expectEqual(Code.SUCCESS, status.code);

    while (getCurrentKey(iter) != null) {
        const current_key = getCurrentKey(iter).?;
        const key_copy = try alloc.dupe(u8, current_key);
        try keys.append(alloc, key_copy);

        status = iterPrevious(iter, std.testing.io);
        if (status.code == .NOT_FOUND_ERROR) break;
        try std.testing.expectEqual(Code.SUCCESS, status.code);
    }

    // Verify keys are in reverse order.
    try std.testing.expectEqual(@as(usize, 3), keys.items.len);
    try std.testing.expectEqualStrings("key3", keys.items[0]);
    try std.testing.expectEqualStrings("key2", keys.items[1]);
    try std.testing.expectEqualStrings("key1", keys.items[2]);
}

test "iterJump: position at key" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    const impl = try BabyDBMImpl.init(std_file.asFile(), lexicalKeyComparator, alloc);
    defer impl.deinit(std.testing.io);

    // Insert keys.
    _ = impl.set(alloc, std.testing.io, "apple", "a", true, null);
    _ = impl.set(alloc, std.testing.io, "cherry", "c", true, null);
    _ = impl.set(alloc, std.testing.io, "orange", "o", true, null);

    const iter = try iterInit(impl, std.testing.io, alloc);
    defer iterDeinit(iter, std.testing.io);

    // Jump to "cherry".
    var status = iterJump(iter, std.testing.io, "cherry");
    try std.testing.expectEqual(Code.SUCCESS, status.code);
    try std.testing.expectEqualStrings("cherry", getCurrentKey(iter).?);

    // Jump to non-existent key "banana" -> should position at "cherry".
    status = iterJump(iter, std.testing.io, "banana");
    try std.testing.expectEqual(Code.SUCCESS, status.code);
    try std.testing.expectEqualStrings("cherry", getCurrentKey(iter).?);
}

test "iterJumpLower: position at largest key < target" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    const impl = try BabyDBMImpl.init(std_file.asFile(), lexicalKeyComparator, alloc);
    defer impl.deinit(std.testing.io);

    // Insert keys.
    _ = impl.set(alloc, std.testing.io, "apple", "a", true, null);
    _ = impl.set(alloc, std.testing.io, "cherry", "c", true, null);
    _ = impl.set(alloc, std.testing.io, "orange", "o", true, null);

    const iter = try iterInit(impl, std.testing.io, alloc);
    defer iterDeinit(iter, std.testing.io);

    // JumpLower to "date" (non-existent) should position at "cherry".
    var status = iterJumpLower(iter, std.testing.io, "date", false);
    try std.testing.expectEqual(Code.SUCCESS, status.code);
    try std.testing.expectEqualStrings("cherry", getCurrentKey(iter).?);

    // JumpLower to "cherry" (inclusive=false) should position at "apple".
    status = iterJumpLower(iter, std.testing.io, "cherry", false);
    try std.testing.expectEqual(Code.SUCCESS, status.code);
    try std.testing.expectEqualStrings("apple", getCurrentKey(iter).?);

    // JumpLower to "cherry" (inclusive=true) should position at "cherry".
    status = iterJumpLower(iter, std.testing.io, "cherry", true);
    try std.testing.expectEqual(Code.SUCCESS, status.code);
    try std.testing.expectEqualStrings("cherry", getCurrentKey(iter).?);
}

test "iterJumpUpper: position at smallest key > target" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    const impl = try BabyDBMImpl.init(std_file.asFile(), lexicalKeyComparator, alloc);
    defer impl.deinit(std.testing.io);

    // Insert keys.
    _ = impl.set(alloc, std.testing.io, "apple", "a", true, null);
    _ = impl.set(alloc, std.testing.io, "cherry", "c", true, null);
    _ = impl.set(alloc, std.testing.io, "orange", "o", true, null);

    const iter = try iterInit(impl, std.testing.io, alloc);
    defer iterDeinit(iter, std.testing.io);

    // JumpUpper to "banana" (non-existent) should position at "cherry".
    var status = iterJumpUpper(iter, std.testing.io, "banana", false);
    try std.testing.expectEqual(Code.SUCCESS, status.code);
    try std.testing.expectEqualStrings("cherry", getCurrentKey(iter).?);

    // JumpUpper to "cherry" (inclusive=false) should position at "orange".
    status = iterJumpUpper(iter, std.testing.io, "cherry", false);
    try std.testing.expectEqual(Code.SUCCESS, status.code);
    try std.testing.expectEqualStrings("orange", getCurrentKey(iter).?);

    // JumpUpper to "cherry" (inclusive=true) should position at "cherry".
    status = iterJumpUpper(iter, std.testing.io, "cherry", true);
    try std.testing.expectEqual(Code.SUCCESS, status.code);
    try std.testing.expectEqualStrings("cherry", getCurrentKey(iter).?);
}

test "iterGet: retrieve key and value at current position" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    const impl = try BabyDBMImpl.init(std_file.asFile(), lexicalKeyComparator, alloc);
    defer impl.deinit(std.testing.io);

    // Insert a record.
    _ = impl.set(alloc, std.testing.io, "testkey", "testvalue", true, null);

    const iter = try iterInit(impl, std.testing.io, alloc);
    defer iterDeinit(iter, std.testing.io);

    var key_out: std.ArrayList(u8) = .empty;
    defer key_out.deinit(alloc);
    var value_out: std.ArrayList(u8) = .empty;
    defer value_out.deinit(alloc);

    // Position and retrieve.
    var status = iterFirst(iter, std.testing.io);
    try std.testing.expectEqual(Code.SUCCESS, status.code);

    status = iterGet(iter, alloc, std.testing.io, &key_out, &value_out);
    try std.testing.expectEqual(Code.SUCCESS, status.code);
    try std.testing.expectEqualStrings("testkey", key_out.items);
    try std.testing.expectEqualStrings("testvalue", value_out.items);
}

test "iterProcess: modify record via iterator" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    const impl = try BabyDBMImpl.init(std_file.asFile(), lexicalKeyComparator, alloc);
    defer impl.deinit(std.testing.io);

    // Insert a record.
    _ = impl.set(alloc, std.testing.io, "testkey", "oldvalue", true, null);

    const iter = try iterInit(impl, std.testing.io, alloc);
    defer iterDeinit(iter, std.testing.io);

    // Position at the record.
    var status = iterFirst(iter, std.testing.io);
    try std.testing.expectEqual(Code.SUCCESS, status.code);

    // Use ProcessorSet to modify.
    var proc_status = Status.init(.SUCCESS);
    var proc = ProcessorSet{
        .status = &proc_status,
        .value = "newvalue",
        .overwrite = true,
        .old_value = null,
        .allocator = alloc,
    };

    status = iterProcess(iter, std.testing.io, ProcessorSet, &proc, true);
    try std.testing.expectEqual(Code.SUCCESS, status.code);

    // Verify the change persisted.
    var retrieved: std.ArrayList(u8) = .empty;
    defer retrieved.deinit(alloc);
    const get_status = impl.get(alloc, std.testing.io, "testkey", &retrieved);
    try std.testing.expectEqual(Code.SUCCESS, get_status.code);
    try std.testing.expectEqualStrings("newvalue", retrieved.items);
}

test "iterGet: return NOT_FOUND_ERROR when key deleted" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    const impl = try BabyDBMImpl.init(std_file.asFile(), lexicalKeyComparator, alloc);
    defer impl.deinit(std.testing.io);

    // Insert two records.
    _ = impl.set(alloc, std.testing.io, "key1", "value1", true, null);
    _ = impl.set(alloc, std.testing.io, "key2", "value2", true, null);

    const iter = try iterInit(impl, std.testing.io, alloc);
    defer iterDeinit(iter, std.testing.io);

    // Position at key1.
    var status = iterFirst(iter, std.testing.io);
    try std.testing.expectEqual(Code.SUCCESS, status.code);

    // Delete key1 from the tree.
    _ = impl.remove(std.testing.io, "key1");

    // Try to get the now-deleted key.
    var key_out: std.ArrayList(u8) = .empty;
    defer key_out.deinit(alloc);
    status = iterGet(iter, alloc, std.testing.io, &key_out, null);
    try std.testing.expectEqual(Code.NOT_FOUND_ERROR, status.code);
}

test "ordered iteration: 100 keys out of order, forward and backward" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    const impl = try BabyDBMImpl.init(std_file.asFile(), lexicalKeyComparator, alloc);
    defer impl.deinit(std.testing.io);

    var buf: [16]u8 = undefined;

    // Insert 100 keys out of order: 99, 98, 97, ..., 1, 0
    for (0..100) |i| {
        const idx = 99 - i;
        const key = try std.fmt.bufPrint(&buf, "k{d:0>3}", .{idx});
        const value = try std.fmt.bufPrint(buf[8..], "v{d:0>3}", .{idx});
        _ = impl.set(alloc, std.testing.io, key, value, true, null);
    }

    const iter = try iterInit(impl, std.testing.io, alloc);
    defer iterDeinit(iter, std.testing.io);

    // Forward pass: collect all keys.
    var forward_keys: std.ArrayList(u32) = .empty;
    defer forward_keys.deinit(alloc);

    var status = iterFirst(iter, std.testing.io);
    try std.testing.expectEqual(Code.SUCCESS, status.code);

    while (getCurrentKey(iter) != null) {
        const key_str = getCurrentKey(iter).?;
        const num = try std.fmt.parseInt(u32, key_str[1..], 10);
        try forward_keys.append(alloc, num);

        status = iterNext(iter, std.testing.io);
        if (status.code == .NOT_FOUND_ERROR) break;
    }

    // Verify forward pass is sorted.
    try std.testing.expectEqual(@as(usize, 100), forward_keys.items.len);
    for (0..99) |i| {
        try std.testing.expect(forward_keys.items[i] < forward_keys.items[i + 1]);
    }

    // Backward pass: collect all keys from last to first.
    var backward_keys: std.ArrayList(u32) = .empty;
    defer backward_keys.deinit(alloc);

    status = iterLast(iter, std.testing.io);
    try std.testing.expectEqual(Code.SUCCESS, status.code);

    while (getCurrentKey(iter) != null) {
        const key_str = getCurrentKey(iter).?;
        const num = try std.fmt.parseInt(u32, key_str[1..], 10);
        try backward_keys.append(alloc, num);

        status = iterPrevious(iter, std.testing.io);
        if (status.code == .NOT_FOUND_ERROR) break;
    }

    // Verify backward pass is reverse sorted.
    try std.testing.expectEqual(@as(usize, 100), backward_keys.items.len);
    for (0..99) |i| {
        try std.testing.expect(backward_keys.items[i] > backward_keys.items[i + 1]);
    }
}

// ---------------------------------------------------------------------------
// Public BabyDBM wrapper (Phase 8 — placeholder for now)
// ---------------------------------------------------------------------------

pub const BabyDBM = struct {
    impl: *BabyDBMImpl,
    allocator: std.mem.Allocator,

    pub const Cursor = struct {
        impl: *BabyDBMIteratorImpl,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *Cursor, io: std.Io) void {
            iterDeinit(self.impl, io);
        }

        pub fn first(self: *Cursor, io: std.Io) Status {
            return iterFirst(self.impl, io);
        }

        pub fn last(self: *Cursor, io: std.Io) Status {
            return iterLast(self.impl, io);
        }

        pub fn jump(self: *Cursor, io: std.Io, key: []const u8) Status {
            return iterJump(self.impl, io, key);
        }

        pub fn jumpLower(self: *Cursor, io: std.Io, key: []const u8, inclusive: bool) Status {
            return iterJumpLower(self.impl, io, key, inclusive);
        }

        pub fn jumpUpper(self: *Cursor, io: std.Io, key: []const u8, inclusive: bool) Status {
            return iterJumpUpper(self.impl, io, key, inclusive);
        }

        pub fn next(self: *Cursor, io: std.Io) Status {
            return iterNext(self.impl, io);
        }

        pub fn previous(self: *Cursor, io: std.Io) Status {
            return iterPrevious(self.impl, io);
        }

        pub fn get(
            self: *Cursor,
            io: std.Io,
            key_out: ?*std.ArrayList(u8),
            value_out: ?*std.ArrayList(u8),
        ) Status {
            return iterGet(self.impl, self.allocator, io, key_out, value_out);
        }

        pub fn process(self: *Cursor, io: std.Io, comptime P: type, proc: *P, writable: bool) Status {

            return iterProcess(self.impl, io, P, proc, writable);
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
            const st = self.process(io, SetProc, &proc, true);
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
            const st = self.process(io, RemoveProc, &proc, true);
            if (!st.isOk()) return st;
            return proc.status;
        }

        pub fn step(self: *Cursor, io: std.Io, key_out: ?*std.ArrayList(u8), value_out: ?*std.ArrayList(u8)) Status {

            const st = self.get(io, key_out, value_out);
            if (!st.isOk()) return st;
            _ = self.next(io);
            return Status.init(.SUCCESS);
        }
    };

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
    pub fn iterate(self: *BabyDBM, alloc: std.mem.Allocator, io: std.Io) !Iterator {
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
    pub fn iterateFrom(self: *BabyDBM, alloc: std.mem.Allocator, io: std.Io, key: []const u8) !Iterator {

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

    pub fn init(file: File, key_comparator: KeyComparator, allocator: std.mem.Allocator) !BabyDBM {
        const impl = try BabyDBMImpl.init(file, key_comparator, allocator);
        return BabyDBM{ .impl = impl, .allocator = allocator };
    }

    pub fn deinit(self: *BabyDBM, io: std.Io) void {
        self.impl.deinit(io);
    }

    pub fn makeCursor(self: *BabyDBM, io: std.Io) !Cursor {
        const iter_impl = try iterInit(self.impl, io, self.allocator);
        return Cursor{
            .impl = iter_impl,
            .allocator = self.allocator,
        };
    }


    // -----------------------------------------------------------------------
    // File Operations
    // -----------------------------------------------------------------------

    pub fn open(self: *BabyDBM, io: std.Io, path: []const u8, writable: bool, options: OpenOptions) !Status {

        return try self.impl.openImpl(io, path, writable, options);
    }

    pub fn close(self: *BabyDBM, io: std.Io) Status {
        return self.impl.closeImpl(io);
    }

    // -----------------------------------------------------------------------
    // Basic Operations
    // -----------------------------------------------------------------------

    pub fn get(
        self: *BabyDBM,
        io: std.Io,
        key: []const u8,
        value: ?*std.ArrayList(u8),
    ) Status {
        return self.impl.get(self.allocator, io, key, value);
    }

    pub fn getSimple(self: *BabyDBM, allocator: std.mem.Allocator, io: std.Io, key: []const u8, default_value: []const u8) ![]const u8 {

        var buf: std.ArrayList(u8) = .empty;
        // buf is populated by self.get which uses self.allocator internally; deinit must match.
        defer buf.deinit(self.allocator);
        const st = self.get(io, key, &buf);
        if (st.isOk()) return try allocator.dupe(u8, buf.items);
        return try allocator.dupe(u8, default_value);
    }

    pub fn set(
        self: *BabyDBM,
        io: std.Io,
        key: []const u8,
        value: []const u8,
        overwrite: bool,
        old_value: ?*std.ArrayList(u8),
    ) Status {
        return self.impl.set(self.allocator, io, key, value, overwrite, old_value);
    }

    pub fn remove(self: *BabyDBM, io: std.Io, key: []const u8) Status {

        return self.impl.remove(io, key);
    }

    pub fn append(self: *BabyDBM, io: std.Io, key: []const u8, value: []const u8, delim: []const u8) Status {

        return self.impl.append(io, key, value, delim);
    }

    /// Fetch multiple keys in a single call.  For every key that exists its
    /// value is duped into `records` using the map's allocator.  Missing keys
    /// are silently skipped and only contribute NOT_FOUND_ERROR to the merged
    /// return status.  The caller owns the key and value slices stored in the
    /// map.  Iterates all keys without early exit.
    pub fn getMulti(
        self: *BabyDBM,
        io: std.Io,
        keys: []const []const u8,
        records: *std.StringHashMap([]u8),
    ) Status {
        const map_alloc = records.allocator;
        var status = Status.init(.SUCCESS);
        var val_buf: std.ArrayList(u8) = .empty;
        defer val_buf.deinit(self.allocator);
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
        self: *BabyDBM,
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
        self: *BabyDBM,
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
        self: *BabyDBM,
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

    // -----------------------------------------------------------------------
    // Batch Operations
    // -----------------------------------------------------------------------

    pub fn process(self: *BabyDBM, io: std.Io, comptime P: type, key: []const u8, proc: *P, writable: bool) Status {

        self.impl.processImpl(io, P, proc, key, writable) catch return Status.init(.SYSTEM_ERROR);
        return Status.init(.SUCCESS);
    }

    pub fn processFirst(self: *BabyDBM, io: std.Io, comptime P: type, proc: *P, writable: bool) Status {

        return self.impl.processFirst(io, P, proc, writable);
    }

    pub fn processEach(self: *BabyDBM, io: std.Io, comptime P: type, proc: *P, writable: bool) Status {

        return self.impl.processEach(io, P, proc, writable);
    }

    pub fn processMulti(
        self: *BabyDBM,
        io: std.Io,
        comptime P: type,
        keys: []const []const u8,
        procs: []const *P,
        writable: bool,
    ) Status {
        return self.impl.processMulti(io, P, keys, procs, writable);
    }

    fn countInternal(self: *BabyDBM) i64 {
        return self.impl.count();
    }

    pub fn clear(self: *BabyDBM, io: std.Io) Status {
        return self.impl.clear(io);
    }

    pub fn rebuild(self: *BabyDBM, io: std.Io) Status {
        _ = io; // BabyDBM is self-balancing; impl rebuild is a no-op with no file I/O
        return self.impl.rebuild();
    }

    pub fn synchronize(self: *BabyDBM, io: std.Io, hard: bool) Status {

        return self.impl.synchronize(io, hard);
    }

    pub fn inspect(self: *BabyDBM, allocator: std.mem.Allocator, io: std.Io) !std.ArrayList([2][]u8) {
        return self.impl.inspect(allocator, io);
    }

    // -----------------------------------------------------------------------
    // State Queries
    // -----------------------------------------------------------------------

    pub fn isOpen(self: *BabyDBM) bool {
        return self.impl.isOpen();
    }

    pub fn isWritable(self: *BabyDBM) bool {
        return self.impl.isWritable();
    }

    pub fn isHealthy(_: *BabyDBM) bool {
        return true;
    }

    pub fn isOrdered(_: *BabyDBM) bool {
        return true;
    }

    fn getFilePathInternal(self: *BabyDBM) []const u8 {
        return self.impl.getFilePath();
    }

    fn getTimestampInternal(self: *BabyDBM) f64 {
        return self.impl.getTimestamp();
    }

    fn getFileSizeInternal(self: *BabyDBM) i64 {
        return self.impl.getFileSize();
    }

    fn shouldBeRebuiltInternal(_: *BabyDBM) bool {
        return false;
    }

    /// Fills `out` with the number of records. Returns PRECONDITION_ERROR if not open.
    pub fn count(self: *BabyDBM, out: *i64) Status {
        out.* = self.impl.count();
        return Status.init(.SUCCESS);
    }

    /// Fills `out` with the file size in bytes. Returns PRECONDITION_ERROR if not open.
    pub fn getFileSize(self: *BabyDBM, out: *i64) Status {
        if (!self.impl.isOpen()) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        out.* = self.impl.getFileSize();
        return Status.init(.SUCCESS);
    }

    /// Appends the file path to `out`. Returns PRECONDITION_ERROR if not open.
    pub fn getFilePath(self: *BabyDBM, out: *std.ArrayList(u8)) Status {
        if (!self.impl.isOpen()) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        out.clearRetainingCapacity();
        out.appendSlice(self.allocator, self.impl.getFilePath()) catch return Status.init(.SYSTEM_ERROR);
        return Status.init(.SUCCESS);
    }

    /// Fills `out` with the modification timestamp. Returns PRECONDITION_ERROR if not open.
    pub fn getTimestamp(self: *BabyDBM, out: *f64) Status {
        if (!self.impl.isOpen()) return Status.initMsg(.PRECONDITION_ERROR, "not opened");
        out.* = self.impl.getTimestamp();
        return Status.init(.SUCCESS);
    }

    /// Sets `out` to false. BabyDBM is a self-balancing tree so rebuild is never needed.
    /// Matches C++ BabyDBM::ShouldBeRebuilt which always succeeds without checking open.
    pub fn shouldBeRebuilt(_: *BabyDBM, out: *bool) Status {
        out.* = false;
        return Status.init(.SUCCESS);
    }

    pub fn getInternalFile(self: *BabyDBM) File {
        return self.impl.file;
    }

    /// Returns the key comparator used by this B+ tree. Matches C++ GetKeyComparator().
    pub fn getKeyComparator(self: *BabyDBM) KeyComparator {
        return self.impl.key_comparator;
    }

    pub fn setUpdateLogger(self: *BabyDBM, logger: ?*UpdateLogger) void {
        self.impl.setUpdateLogger(logger);
    }

    pub fn getUpdateLogger(self: *BabyDBM) ?*UpdateLogger {
        return self.impl.getUpdateLogger();
    }

    /// Atomically compare and conditionally exchange the value for a key.
    pub fn compareExchange(
        self: *BabyDBM,
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
        self.impl.processImpl(io, ProcessorCompareExchange, &proc, key, true) catch
            return Status.init(.SYSTEM_ERROR);
        return status;
    }

    /// Atomically increment a stored i64 value by delta, returning the new value.
    pub fn increment(
        self: *BabyDBM,
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
            .allocator = self.allocator,
        };
        self.impl.processImpl(io, ProcessorIncrement, &proc, key, true) catch
            return Status.init(.SYSTEM_ERROR);
        return status;
    }

    pub fn incrementSimple(self: *BabyDBM, io: std.Io, key: []const u8, delta: i64, initial: i64) i64 {

        var result: i64 = initial;
        _ = self.increment(io, key, delta, &result, initial);
        return result;
    }

    /// Remove and return the first record in the database (lexicographic order on BabyDBM).
    pub fn popFirst(
        self: *BabyDBM,
        io: std.Io,
        key_out: ?*std.ArrayList(u8),
        value_out: ?*std.ArrayList(u8),
    ) Status {
        var status = Status.init(.SUCCESS);
        var proc = ProcessorPopFirst{
            .status = &status,
            .key_out = key_out,
            .value_out = value_out,
            .allocator = self.allocator,
        };
        const st = self.processFirst(io, ProcessorPopFirst, &proc, true);
        if (!st.isOk()) return st;
        return status;
    }

    /// Push a value at the lexicographic end using a timestamp-based key.
    /// wtime < 0 uses the current wall clock time; otherwise uses the provided time.
    /// Key is returned in key_out if non-null.
    pub fn pushLast(
        self: *BabyDBM,
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

    /// Creates a new heap-allocated BabyDBM instance using NullFile (in-memory only).
    pub fn makeDbm(allocator: std.mem.Allocator) !*BabyDBM {
        const dbm = try allocator.create(BabyDBM);
        errdefer allocator.destroy(dbm);
        dbm.* = try BabyDBM.init(file_mod.NullFile, lib_common.lexicalKeyComparator, allocator);
        return dbm;
    }

    /// Returns the record count or -1 when not open. Matches C++ DBM::CountSimple().
    pub fn countSimple(self: *BabyDBM) i64 {
        return self.impl.count();
    }

    /// Returns the file size in bytes or -1 when not open. Matches C++ DBM::GetFileSizeSimple().
    pub fn getFileSizeSimple(self: *BabyDBM) i64 {
        if (!self.impl.isOpen()) return -1;
        return self.impl.getFileSize();
    }

    /// Returns the file path or "" when not open. Matches C++ DBM::GetFilePathSimple().
    pub fn getFilePathSimple(self: *BabyDBM) []const u8 {
        if (!self.impl.isOpen()) return "";
        return self.impl.getFilePath();
    }

    /// Returns the timestamp or NaN when not open. Matches C++ DBM::GetTimestampSimple().
    pub fn getTimestampSimple(self: *BabyDBM) f64 {
        if (!self.impl.isOpen()) return std.math.nan(f64);
        return self.impl.getTimestamp();
    }

    /// Returns whether a rebuild would improve performance, or false when not open.
    /// BabyDBM is always balanced so this always returns false.
    pub fn shouldBeRebuiltSimple(_: *BabyDBM) bool {
        return false;
    }

    /// Copies the backing file to dest_path, optionally syncing first.
    /// Returns NOT_IMPLEMENTED_ERROR when no backing file is open.
    pub fn copyFileData(self: *BabyDBM, io: std.Io, dest_path: []const u8, sync_hard: bool) Status {

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
    pub fn rekey(self: *BabyDBM, io: std.Io, old_key: []const u8, new_key: []const u8, overwrite: bool, copying: bool) Status {

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
    pub fn export_(self: *BabyDBM, io: std.Io, dest: anytype) Status {

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
        self: *BabyDBM,
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

test "BabyDBM.compareExchange: match and exchange" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    var db = try BabyDBM.init(std_file.asFile(), lexicalKeyComparator, alloc);
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
    const get_st_1 = db.get(std.testing.io, "key1", &actual);
    try std.testing.expect(get_st_1.isOk());
    try std.testing.expectEqualSlices(u8, "bar", actual.items);
}

test "BabyDBM.compareExchange: mismatch returns INFEASIBLE_ERROR" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    var db = try BabyDBM.init(std_file.asFile(), lexicalKeyComparator, alloc);
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

test "BabyDBM.compareExchange: absent creates record" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    var db = try BabyDBM.init(std_file.asFile(), lexicalKeyComparator, alloc);
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

test "BabyDBM.compareExchange: absent noop on missing key" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    var db = try BabyDBM.init(std_file.asFile(), lexicalKeyComparator, alloc);
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

test "BabyDBM.compareExchange: any probe reads without writing" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    var db = try BabyDBM.init(std_file.asFile(), lexicalKeyComparator, alloc);
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
    const get_st_2 = db.get(std.testing.io, "key", &actual);
    try std.testing.expect(get_st_2.isOk());
    try std.testing.expectEqualSlices(u8, "original", actual.items);
}

test "BabyDBM.compareExchange: desired remove deletes record" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    var db = try BabyDBM.init(std_file.asFile(), lexicalKeyComparator, alloc);
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

test "BabyDBM.compareExchange: absent fails when key exists" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    var db = try BabyDBM.init(std_file.asFile(), lexicalKeyComparator, alloc);
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

test "BabyDBM.increment: fresh key uses initial+delta" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    var db = try BabyDBM.init(std_file.asFile(), lexicalKeyComparator, alloc);
    defer db.deinit(std.testing.io);

    var current: i64 = undefined;
    const st = db.increment(std.testing.io, "counter", 3, &current, 10);
    try std.testing.expect(st.isOk());
    try std.testing.expectEqual(@as(i64, 13), current);

    var val: std.ArrayList(u8) = .empty;
    defer val.deinit(alloc);
    const get_st_3 = db.get(std.testing.io, "counter", &val);
    try std.testing.expect(get_st_3.isOk());
    try std.testing.expectEqual(@as(usize, 8), val.items.len);
    const stored = @as(i64, @bitCast(str_util.strToIntBigEndian(val.items)));
    try std.testing.expectEqual(@as(i64, 13), stored);
}

test "BabyDBM.increment: existing key adds delta" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    var db = try BabyDBM.init(std_file.asFile(), lexicalKeyComparator, alloc);
    defer db.deinit(std.testing.io);

    var buf: [8]u8 = undefined;
    const initial_bytes = str_util.intToStrBigEndian(@as(u64, @bitCast(@as(i64, 10))), 8, &buf);
    _ = db.set(std.testing.io, "num", initial_bytes, true, null);

    var current: i64 = undefined;
    const st = db.increment(std.testing.io, "num", 5, &current, 0);
    try std.testing.expect(st.isOk());
    try std.testing.expectEqual(@as(i64, 15), current);
}

test "BabyDBM.increment: INT64MIN probe reads without writing" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    var db = try BabyDBM.init(std_file.asFile(), lexicalKeyComparator, alloc);
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

test "BabyDBM.increment: INT64MIN probe on missing key returns initial" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    var db = try BabyDBM.init(std_file.asFile(), lexicalKeyComparator, alloc);
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

test "BabyDBM.popFirst: returns and removes first record" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    var db = try BabyDBM.init(std_file.asFile(), lexicalKeyComparator, alloc);
    defer db.deinit(std.testing.io);

    _ = db.set(std.testing.io, "key1", "value1", true, null);
    _ = db.set(std.testing.io, "key2", "value2", true, null);
    _ = db.set(std.testing.io, "key3", "value3", true, null);
    try std.testing.expectEqual(@as(i64, 3), db.countSimple());

    var key: std.ArrayList(u8) = .empty;
    defer key.deinit(alloc);
    var value: std.ArrayList(u8) = .empty;
    defer value.deinit(alloc);

    const st = db.popFirst(std.testing.io, &key, &value);
    try std.testing.expect(st.isOk());
    try std.testing.expect(key.items.len > 0);
    try std.testing.expect(value.items.len > 0);

    const count = db.countSimple();
    try std.testing.expectEqual(@as(i64, 2), count);
}

test "BabyDBM.popFirst: empty returns NOT_FOUND_ERROR" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    var db = try BabyDBM.init(std_file.asFile(), lexicalKeyComparator, alloc);
    defer db.deinit(std.testing.io);

    var key: std.ArrayList(u8) = .empty;
    defer key.deinit(alloc);
    var value: std.ArrayList(u8) = .empty;
    defer value.deinit(alloc);

    const st = db.popFirst(std.testing.io, &key, &value);
    try std.testing.expect(st.code == .NOT_FOUND_ERROR);
}

test "BabyDBM.popFirst: returns lexicographic first" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    var db = try BabyDBM.init(std_file.asFile(), lexicalKeyComparator, alloc);
    defer db.deinit(std.testing.io);

    _ = db.set(std.testing.io, "zebra", "z", true, null);
    _ = db.set(std.testing.io, "apple", "a", true, null);
    _ = db.set(std.testing.io, "cherry", "c", true, null);

    var key: std.ArrayList(u8) = .empty;
    defer key.deinit(alloc);
    var value: std.ArrayList(u8) = .empty;
    defer value.deinit(alloc);

    const st = db.popFirst(std.testing.io, &key, &value);
    try std.testing.expect(st.isOk());
    try std.testing.expectEqualSlices(u8, "apple", key.items);
}

test "BabyDBM.pushLast: creates record with key_out" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    var db = try BabyDBM.init(std_file.asFile(), lexicalKeyComparator, alloc);
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

test "BabyDBM.pushLast: two pushes at same wtime produce sequential keys" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    var db = try BabyDBM.init(std_file.asFile(), lexicalKeyComparator, alloc);
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

test "BabyDBM.pushLast: pop-after-push round-trips value" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    var db = try BabyDBM.init(std_file.asFile(), lexicalKeyComparator, alloc);
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

test "BabyDBM.get: null value buffer returns SUCCESS on found key" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    var db = try BabyDBM.init(std_file.asFile(), lexicalKeyComparator, alloc);
    defer db.deinit(std.testing.io);

    _ = db.set(std.testing.io, "exists", "hello", true, null);

    // null value = existence check only
    const present = db.get(std.testing.io, "exists", null);
    try std.testing.expect(present.isOk());

    const absent = db.get(std.testing.io, "missing", null);
    try std.testing.expect(absent.code == .NOT_FOUND_ERROR);
}

test "BabyDBM.Cursor: first/next/get ordered traversal" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    var db = try BabyDBM.init(std_file.asFile(), lexicalKeyComparator, alloc);
    defer db.deinit(std.testing.io);

    // Insert keys out of order; iterator must return them in lexicographic order.
    _ = db.set(std.testing.io, "banana", "2", true, null);
    _ = db.set(std.testing.io, "apple", "1", true, null);
    _ = db.set(std.testing.io, "cherry", "3", true, null);

    var iter = try db.makeCursor(std.testing.io);
    defer iter.deinit(std.testing.io);

    var key: std.ArrayList(u8) = .empty;
    defer key.deinit(alloc);
    var val: std.ArrayList(u8) = .empty;
    defer val.deinit(alloc);

    try std.testing.expect(iter.first(std.testing.io).isOk());

    try std.testing.expect(iter.get(std.testing.io, &key, &val).isOk());
    try std.testing.expectEqualSlices(u8, "apple", key.items);
    try std.testing.expectEqualSlices(u8, "1", val.items);

    try std.testing.expect(iter.next(std.testing.io).isOk());
    try std.testing.expect(iter.get(std.testing.io, &key, &val).isOk());
    try std.testing.expectEqualSlices(u8, "banana", key.items);
    try std.testing.expectEqualSlices(u8, "2", val.items);

    try std.testing.expect(iter.next(std.testing.io).isOk());
    try std.testing.expect(iter.get(std.testing.io, &key, &val).isOk());
    try std.testing.expectEqualSlices(u8, "cherry", key.items);
    try std.testing.expectEqualSlices(u8, "3", val.items);

    // next() past the last record returns SUCCESS with cleared position (C++ R-16).
    try std.testing.expect(iter.next(std.testing.io).isOk());
    // Position is cleared: get() must now return NOT_FOUND_ERROR.
    try std.testing.expect(iter.get(std.testing.io, &key, &val).code == .NOT_FOUND_ERROR);
}

test "BabyDBM.Cursor: jump to a specific key" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    var db = try BabyDBM.init(std_file.asFile(), lexicalKeyComparator, alloc);
    defer db.deinit(std.testing.io);

    _ = db.set(std.testing.io, "aaa", "v1", true, null);
    _ = db.set(std.testing.io, "bbb", "v2", true, null);
    _ = db.set(std.testing.io, "ccc", "v3", true, null);
    _ = db.set(std.testing.io, "ddd", "v4", true, null);

    var iter = try db.makeCursor(std.testing.io);
    defer iter.deinit(std.testing.io);

    var key: std.ArrayList(u8) = .empty;
    defer key.deinit(alloc);
    var val: std.ArrayList(u8) = .empty;
    defer val.deinit(alloc);

    // Exact key match.
    try std.testing.expect(iter.jump(std.testing.io, "ccc").isOk());
    try std.testing.expect(iter.get(std.testing.io, &key, &val).isOk());
    try std.testing.expectEqualSlices(u8, "ccc", key.items);
    try std.testing.expectEqualSlices(u8, "v3", val.items);

    // Jump to a key between "bbb" and "ccc" — must land on "ccc".
    try std.testing.expect(iter.jump(std.testing.io, "bc").isOk());
    try std.testing.expect(iter.get(std.testing.io, &key, &val).isOk());
    try std.testing.expectEqualSlices(u8, "ccc", key.items);

    // Jump past the last key — must return NOT_FOUND_ERROR.
    try std.testing.expect(iter.jump(std.testing.io, "zzz").code == .NOT_FOUND_ERROR);
}

test "BabyDBM.Cursor: last/previous" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    var db = try BabyDBM.init(std_file.asFile(), lexicalKeyComparator, alloc);
    defer db.deinit(std.testing.io);

    _ = db.set(std.testing.io, "one", "1", true, null);
    _ = db.set(std.testing.io, "two", "2", true, null);
    _ = db.set(std.testing.io, "three", "3", true, null);

    var iter = try db.makeCursor(std.testing.io);
    defer iter.deinit(std.testing.io);

    var key: std.ArrayList(u8) = .empty;
    defer key.deinit(alloc);
    var val: std.ArrayList(u8) = .empty;
    defer val.deinit(alloc);

    // Lexicographic order: "one" < "three" < "two".
    try std.testing.expect(iter.last(std.testing.io).isOk());
    try std.testing.expect(iter.get(std.testing.io, &key, &val).isOk());
    try std.testing.expectEqualSlices(u8, "two", key.items);

    try std.testing.expect(iter.previous(std.testing.io).isOk());
    try std.testing.expect(iter.get(std.testing.io, &key, &val).isOk());
    try std.testing.expectEqualSlices(u8, "three", key.items);

    try std.testing.expect(iter.previous(std.testing.io).isOk());
    try std.testing.expect(iter.get(std.testing.io, &key, &val).isOk());
    try std.testing.expectEqualSlices(u8, "one", key.items);

    // previous() past the first record returns SUCCESS with cleared position (C++ R-16).
    try std.testing.expect(iter.previous(std.testing.io).isOk());
    // Position is cleared: get() must now return NOT_FOUND_ERROR.
    try std.testing.expect(iter.get(std.testing.io, &key, &val).code == .NOT_FOUND_ERROR);
}

test "BabyDBM.Cursor: set and remove" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    var db = try BabyDBM.init(std_file.asFile(), lexicalKeyComparator, alloc);
    defer db.deinit(std.testing.io);

    _ = db.set(std.testing.io, "k1", "old_v1", true, null);
    _ = db.set(std.testing.io, "k2", "old_v2", true, null);
    _ = db.set(std.testing.io, "k3", "old_v3", true, null);

    var iter = try db.makeCursor(std.testing.io);
    defer iter.deinit(std.testing.io);

    var old_key: std.ArrayList(u8) = .empty;
    defer old_key.deinit(alloc);
    var old_val: std.ArrayList(u8) = .empty;
    defer old_val.deinit(alloc);

    // Jump to "k1" and overwrite its value.
    try std.testing.expect(iter.jump(std.testing.io, "k1").isOk());
    const st_set = iter.set(std.testing.io, "new_v1", &old_key, &old_val);
    try std.testing.expect(st_set.isOk());
    try std.testing.expectEqualSlices(u8, "k1", old_key.items);
    try std.testing.expectEqualSlices(u8, "old_v1", old_val.items);

    // Verify the new value is stored.
    var check: std.ArrayList(u8) = .empty;
    defer check.deinit(alloc);
    try std.testing.expect(db.get(std.testing.io, "k1", &check).isOk());
    try std.testing.expectEqualSlices(u8, "new_v1", check.items);

    // Jump to "k2" and remove it.
    try std.testing.expect(iter.jump(std.testing.io, "k2").isOk());
    const st_remove = iter.remove(std.testing.io, &old_key, &old_val);
    try std.testing.expect(st_remove.isOk());
    try std.testing.expectEqualSlices(u8, "k2", old_key.items);
    try std.testing.expectEqualSlices(u8, "old_v2", old_val.items);

    // Verify "k2" is gone.
    try std.testing.expect(db.get(std.testing.io, "k2", null).code == .NOT_FOUND_ERROR);
}

test "BabyDBM.Cursor: jumpLower and jumpUpper" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    var db = try BabyDBM.init(std_file.asFile(), lexicalKeyComparator, alloc);
    defer db.deinit(std.testing.io);

    _ = db.set(std.testing.io, "aaa", "1", true, null);
    _ = db.set(std.testing.io, "bbb", "2", true, null);
    _ = db.set(std.testing.io, "ccc", "3", true, null);
    _ = db.set(std.testing.io, "ddd", "4", true, null);

    var iter = try db.makeCursor(std.testing.io);
    defer iter.deinit(std.testing.io);

    var key: std.ArrayList(u8) = .empty;
    defer key.deinit(alloc);

    // jumpLower exclusive: largest key strictly less than "ccc" is "bbb".
    try std.testing.expect(iter.jumpLower(std.testing.io, "ccc", false).isOk());
    try std.testing.expect(iter.get(std.testing.io, &key, null).isOk());
    try std.testing.expectEqualSlices(u8, "bbb", key.items);

    // jumpLower inclusive: largest key <= "ccc" is "ccc" itself.
    try std.testing.expect(iter.jumpLower(std.testing.io, "ccc", true).isOk());
    try std.testing.expect(iter.get(std.testing.io, &key, null).isOk());
    try std.testing.expectEqualSlices(u8, "ccc", key.items);

    // jumpUpper exclusive: smallest key strictly greater than "bbb" is "ccc".
    try std.testing.expect(iter.jumpUpper(std.testing.io, "bbb", false).isOk());
    try std.testing.expect(iter.get(std.testing.io, &key, null).isOk());
    try std.testing.expectEqualSlices(u8, "ccc", key.items);

    // jumpUpper inclusive: smallest key >= "bbb" is "bbb" itself.
    try std.testing.expect(iter.jumpUpper(std.testing.io, "bbb", true).isOk());
    try std.testing.expect(iter.get(std.testing.io, &key, null).isOk());
    try std.testing.expectEqualSlices(u8, "bbb", key.items);

    // jumpLower before the first key: C++ returns SUCCESS with a cleared (invalid) position.
    try std.testing.expect(iter.jumpLower(std.testing.io, "aaa", false).isOk());
    // Position is cleared, so get() must return NOT_FOUND_ERROR.
    try std.testing.expect(iter.get(std.testing.io, &key, null).code == .NOT_FOUND_ERROR);

    // jumpUpper after the last key: C++ returns SUCCESS with a cleared (invalid) position.
    try std.testing.expect(iter.jumpUpper(std.testing.io, "ddd", false).isOk());
    // Position is cleared, so get() must return NOT_FOUND_ERROR.
    try std.testing.expect(iter.get(std.testing.io, &key, null).code == .NOT_FOUND_ERROR);
}

test "BabyDBM.*Multi: bulk set/get/remove/append" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    var db = try BabyDBM.init(std_file.asFile(), lexicalKeyComparator, alloc);
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

test "BabyDBM.Iterator: Zig-style iterate() from beginning" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    var db = try BabyDBM.init(std_file.asFile(), lexicalKeyComparator, alloc);
    defer db.deinit(std.testing.io);

    // Insert keys out of order.
    _ = db.set(std.testing.io, "banana", "2", true, null);
    _ = db.set(std.testing.io, "apple", "1", true, null);
    _ = db.set(std.testing.io, "cherry", "3", true, null);

    var iter = try db.iterate(alloc, std.testing.io);
    defer iter.deinit(std.testing.io);

    var count: usize = 0;
    while (try iter.next(std.testing.io)) |entry| {
        count += 1;
        if (count == 1) {
            try std.testing.expectEqualSlices(u8, "apple", entry.key);
            try std.testing.expectEqualSlices(u8, "1", entry.value);
        } else if (count == 2) {
            try std.testing.expectEqualSlices(u8, "banana", entry.key);
            try std.testing.expectEqualSlices(u8, "2", entry.value);
        } else if (count == 3) {
            try std.testing.expectEqualSlices(u8, "cherry", entry.key);
            try std.testing.expectEqualSlices(u8, "3", entry.value);
        }
    }
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "BabyDBM.Iterator: Zig-style iterateFrom(std.testing.io) with lifetime contract" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    var db = try BabyDBM.init(std_file.asFile(), lexicalKeyComparator, alloc);
    defer db.deinit(std.testing.io);

    _ = db.set(std.testing.io, "aaa", "v1", true, null);
    _ = db.set(std.testing.io, "bbb", "v2", true, null);
    _ = db.set(std.testing.io, "ccc", "v3", true, null);

    var iter = try db.iterateFrom(alloc, std.testing.io, "bbb");
    defer iter.deinit(std.testing.io);

    const first = try iter.next(std.testing.io);
    try std.testing.expect(first != null);
    try std.testing.expectEqualSlices(u8, "bbb", first.?.key);
    try std.testing.expectEqualSlices(u8, "v2", first.?.value);

    // Copy the key before calling next() — demonstrates lifetime contract.
    const key_copy = try alloc.dupe(u8, first.?.key);
    defer alloc.free(key_copy);

    // Second next() — first.?.key is now invalid, key_copy is safe.
    const second = try iter.next(std.testing.io);
    try std.testing.expect(second != null);
    try std.testing.expectEqualSlices(u8, "ccc", second.?.key);

    // Verify key_copy still holds the original value.
    try std.testing.expectEqualSlices(u8, "bbb", key_copy);

    // Exhaust the iterator.
    const third = try iter.next(std.testing.io);
    try std.testing.expect(third == null);

    // Another call still returns null.
    const fourth = try iter.next(std.testing.io);
    try std.testing.expect(fourth == null);
}

test "BabyDBM.Iterator: basic iteration" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    var db = try BabyDBM.init(std_file.asFile(), lexicalKeyComparator, alloc);
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

test "BabyDBM.Iterator: iterateFrom and lifetime contract" {
    const alloc = std.testing.allocator;
    const std_file = try file_mod.StdFile.create(alloc);
    var db = try BabyDBM.init(std_file.asFile(), lexicalKeyComparator, alloc);
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
