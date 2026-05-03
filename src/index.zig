// Zig port of tkrzw secondary indices — in-memory MemIndex with BabyDBM backend.
//
// MemIndex stores (key, value) pairs as composite keys in BabyDBM with empty string as the value.
// Thread safety is fully delegated to BabyDBM's internal SpinSharedMutex.

const std = @import("std");
const lib_common = @import("lib_common.zig");
const str_util = @import("str_util.zig");
const dbm_baby = @import("dbm_baby.zig");
const file_mod = @import("file.zig");

pub const Status = lib_common.Status;
pub const Code = lib_common.Code;
pub const KeyComparator = lib_common.KeyComparator;

// Re-export pair comparators.
pub const pairLexicalKeyComparator = lib_common.pairLexicalKeyComparator;
pub const pairLexicalCaseKeyComparator = lib_common.pairLexicalCaseKeyComparator;
pub const pairDecimalKeyComparator = lib_common.pairDecimalKeyComparator;
pub const pairHexadecimalKeyComparator = lib_common.pairHexadecimalKeyComparator;
pub const pairRealNumberKeyComparator = lib_common.pairRealNumberKeyComparator;
pub const pairSignedBigEndianKeyComparator = lib_common.pairSignedBigEndianKeyComparator;
pub const pairFloatBigEndianKeyComparator = lib_common.pairFloatBigEndianKeyComparator;

/// In-memory secondary index backed by BabyDBM (B+ tree).
/// Stores (primary_key, secondary_key) pairs as composite keys in the tree.
/// Thread-safe; all locking is delegated to BabyDBM.
pub const MemIndex = struct {
    dbm: dbm_baby.BabyDBM,
    allocator: std.mem.Allocator,

    pub const Cursor = struct {
        it: dbm_baby.BabyDBM.Cursor,
        allocator: std.mem.Allocator,

        /// Destructor. Call when done iterating.
        pub fn deinit(self: *Cursor) void {
            self.it.deinit();
        }

        /// Move iterator to first record.
        pub fn first(self: *Cursor) void {
            _ = self.it.first();
        }

        /// Move iterator to last record.
        pub fn last(self: *Cursor) void {
            _ = self.it.last();
        }

        /// Jump to the first record with the given (key, value) pair.
        /// If exact match doesn't exist, jumps to the next entry in order.
        pub fn jump(self: *Cursor, key: []const u8, value: []const u8) !void {
            const composite = try str_util.serializeStrPair(key, value, self.allocator);
            defer self.allocator.free(composite);
            const status = self.it.jump(composite);
            // Status is returned but we discard it, matching C++ behavior.
            _ = status;
        }

        /// Move iterator to next record.
        pub fn next(self: *Cursor) void {
            _ = self.it.next();
        }

        /// Move iterator to previous record.
        pub fn previous(self: *Cursor) void {
            _ = self.it.previous();
        }

        /// Get the key and value of the current record.
        /// Returns false if iterator is exhausted. Allocates into key_out and value_out.
        pub fn get(
            self: *Cursor,
            key_out: ?*std.ArrayList(u8),
            value_out: ?*std.ArrayList(u8),
        ) !bool {
            var record_buf: std.ArrayList(u8) = .empty;
            defer record_buf.deinit(self.allocator);
            if (!self.it.get(&record_buf, null).isOk()) return false;

            const pair = str_util.deserializeStrPair(record_buf.items);
            if (key_out) |k| {
                try k.appendSlice(self.allocator, pair.first);
            }
            if (value_out) |v| {
                try v.appendSlice(self.allocator, pair.second);
            }
            return true;
        }
    };

    /// Initialize a MemIndex with the given key comparator.
    /// Default comparator is pairLexicalKeyComparator.
    pub fn init(key_comparator: KeyComparator, allocator: std.mem.Allocator) !MemIndex {
        const dbm = try dbm_baby.BabyDBM.init(file_mod.NullFile, key_comparator, allocator);
        return MemIndex{ .dbm = dbm, .allocator = allocator };
    }

    /// Destructor. Must be called when done.
    pub fn deinit(self: *MemIndex) void {
        self.dbm.deinit();
    }

    /// Check whether a (key, value) pair exists in the index.
    pub fn check(self: *MemIndex, key: []const u8, value: []const u8) !bool {
        const composite = try str_util.serializeStrPair(key, value, self.allocator);
        defer self.allocator.free(composite);
        return self.dbm.get(composite, null).isOk();
    }

    /// Get all values for a given key, optionally limiting the count.
    /// Returns an owned list; caller must free each entry and call .deinit(allocator).
    pub fn getValues(self: *MemIndex, key: []const u8, max: usize) !std.ArrayList([]u8) {
        var values: std.ArrayList([]u8) = .empty;
        errdefer {
            for (values.items) |v| self.allocator.free(v);
            values.deinit(self.allocator);
        }

        var iter = try self.makeCursor();
        defer iter.deinit();

        // Jump to the first entry for this key.
        try iter.jump(key, "");

        // Iterate forward, collecting values while the key matches.
        var record_buf: std.ArrayList(u8) = .empty;
        defer record_buf.deinit(self.allocator);

        while (true) {
            if (max > 0 and values.items.len >= max) break;

            record_buf.clearRetainingCapacity();
            if (!(try iter.get(&record_buf, null))) break;

            const pair = str_util.deserializeStrPair(record_buf.items);
            if (!std.mem.eql(u8, pair.first, key)) break;

            const value_copy = try self.allocator.dupe(u8, pair.second);
            try values.append(self.allocator, value_copy);

            iter.next();
        }

        return values;
    }

    /// Add a (key, value) pair to the index. Idempotent (duplicate adds are silently no-ops).
    pub fn add(self: *MemIndex, key: []const u8, value: []const u8) !void {
        const composite = try str_util.serializeStrPair(key, value, self.allocator);
        defer self.allocator.free(composite);
        const status = self.dbm.set(composite, "", true, null);
        _ = status;  // C++ returns void; we discard status.
    }

    /// Remove a (key, value) pair from the index. Silently succeeds if not found.
    pub fn remove(self: *MemIndex, key: []const u8, value: []const u8) !void {
        const composite = try str_util.serializeStrPair(key, value, self.allocator);
        defer self.allocator.free(composite);
        const status = self.dbm.remove(composite);
        _ = status;  // C++ returns void; we discard status.
    }

    /// Return the total number of pairs in the index.
    pub fn count(self: *MemIndex) usize {
        return @intCast(self.dbm.countSimple());
    }

    /// Remove all pairs from the index.
    pub fn clear(self: *MemIndex) void {
        const status = self.dbm.clear();
        _ = status;  // C++ returns void; we discard status.
    }

    /// Returns a pointer to the underlying BabyDBM. Matches C++ GetInternalDBM().
    pub fn getInternalDBM(self: *MemIndex) *dbm_baby.BabyDBM {
        return &self.dbm;
    }

    /// Create an iterator for the index.
    pub fn makeCursor(self: *MemIndex) !Cursor {
        const it = try self.dbm.makeCursor();
        return Cursor{ .it = it, .allocator = self.allocator };
    }

    /// Deprecated: use makeCursor instead.
    pub const makeIterator = makeCursor;
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "MemIndex init and deinit" {
    const allocator = std.testing.allocator;
    var index = try MemIndex.init(pairLexicalKeyComparator, allocator);
    defer index.deinit();
    try std.testing.expectEqual(@as(usize, 0), index.count());
}

test "MemIndex add and check" {
    const allocator = std.testing.allocator;
    var index = try MemIndex.init(pairLexicalKeyComparator, allocator);
    defer index.deinit();

    try index.add("key1", "value1");
    try std.testing.expect(try index.check("key1", "value1"));
    try std.testing.expect(!(try index.check("key1", "value2")));
    try std.testing.expect(!(try index.check("key2", "value1")));
}

test "MemIndex remove" {
    const allocator = std.testing.allocator;
    var index = try MemIndex.init(pairLexicalKeyComparator, allocator);
    defer index.deinit();

    try index.add("key1", "value1");
    try std.testing.expect(try index.check("key1", "value1"));

    try index.remove("key1", "value1");
    try std.testing.expect(!(try index.check("key1", "value1")));
}

test "MemIndex count" {
    const allocator = std.testing.allocator;
    var index = try MemIndex.init(pairLexicalKeyComparator, allocator);
    defer index.deinit();

    try std.testing.expectEqual(@as(usize, 0), index.count());
    try index.add("key1", "value1");
    try std.testing.expectEqual(@as(usize, 1), index.count());
    try index.add("key1", "value2");
    try std.testing.expectEqual(@as(usize, 2), index.count());
    try index.remove("key1", "value1");
    try std.testing.expectEqual(@as(usize, 1), index.count());
}

test "MemIndex clear" {
    const allocator = std.testing.allocator;
    var index = try MemIndex.init(pairLexicalKeyComparator, allocator);
    defer index.deinit();

    try index.add("key1", "value1");
    try index.add("key2", "value2");
    try std.testing.expectEqual(@as(usize, 2), index.count());

    index.clear();
    try std.testing.expectEqual(@as(usize, 0), index.count());
}

test "MemIndex iterator" {
    const allocator = std.testing.allocator;
    var index = try MemIndex.init(pairLexicalKeyComparator, allocator);
    defer index.deinit();

    try index.add("key1", "value1");
    try index.add("key1", "value2");
    try index.add("key2", "value3");

    var iter = try index.makeCursor();
    defer iter.deinit();

    iter.first();
    var key_buf: std.ArrayList(u8) = .empty;
    defer key_buf.deinit(allocator);
    var value_buf: std.ArrayList(u8) = .empty;
    defer value_buf.deinit(allocator);

    var count: usize = 0;
    while (try iter.get(&key_buf, &value_buf)) {
        count += 1;
        key_buf.clearRetainingCapacity();
        value_buf.clearRetainingCapacity();
        iter.next();
    }

    try std.testing.expectEqual(@as(usize, 3), count);
}
