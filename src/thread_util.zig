const std = @import("std");
const hash_util = @import("hash_util.zig");

/// The sentinel value used for an exclusive (writer) lock.
/// Matches C++ INT32MAX = 2147483647.
pub const WRITER_LOCK: u32 = std.math.maxInt(i32);

// ---------------------------------------------------------------------------
// SpinSharedMutex
// ---------------------------------------------------------------------------

/// A spin-based shared mutex with reader/writer semantics.
///
/// The internal `count` field encodes lock state:
///   0              — unlocked
///   1..WRITER_LOCK-1 — N shared readers hold the lock
///   WRITER_LOCK    — an exclusive writer holds the lock
///
/// This is a faithful port of tkrzw's SpinSharedMutex.
/// Private — only used internally by HashMutex for per-bucket slot locking.
/// Not part of the public API; use std.Io.RwLock for application-level locking.
const SpinSharedMutex = struct {
    count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// Acquire an exclusive (writer) lock. Spins until the lock is free.
    pub fn lock(self: *SpinSharedMutex) void {
        var old_value: u32 = 0;
        // Fast path: attempt a weak CAS from 0 → WRITER_LOCK.
        while (self.count.cmpxchgWeak(old_value, WRITER_LOCK, .acquire, .monotonic) != null) {
            old_value = 0;
            // Strong CAS retry before yielding — avoids spurious yield on the
            // first contended attempt.
            if (self.count.cmpxchgStrong(old_value, WRITER_LOCK, .acquire, .monotonic) == null) break;
            std.Thread.yield() catch {};
            old_value = 0;
        }
    }

    /// Attempt to acquire an exclusive (writer) lock without spinning.
    /// Returns true if the lock was acquired.
    pub fn tryLock(self: *SpinSharedMutex) bool {
        const old_value: u32 = 0;
        return self.count.cmpxchgStrong(old_value, WRITER_LOCK, .acquire, .monotonic) == null;
    }

    /// Release an exclusive (writer) lock.
    pub fn unlock(self: *SpinSharedMutex) void {
        self.count.store(0, .release);
    }

    /// Acquire a shared (reader) lock. Spins if an exclusive writer holds the lock.
    pub fn lockShared(self: *SpinSharedMutex) void {
        while (self.count.fetchAdd(1, .acquire) >= WRITER_LOCK) {
            // A writer holds the lock (or count overflowed past WRITER_LOCK).
            // Try to correct the count back to WRITER_LOCK, then yield.
            const old_value: u32 = self.count.load(.monotonic);
            if (old_value > WRITER_LOCK) {
                _ = self.count.cmpxchgWeak(old_value, WRITER_LOCK, .monotonic, .monotonic);
            }
            std.Thread.yield() catch {};
        }
    }

    /// Attempt to acquire a shared (reader) lock without spinning.
    /// Returns true if the lock was acquired.
    pub fn tryLockShared(self: *SpinSharedMutex) bool {
        if (self.count.fetchAdd(1, .acquire) < WRITER_LOCK) return true;
        // A writer holds the lock. Correct any overshoot back to WRITER_LOCK
        // so the count does not drift unboundedly.  The writer releases with
        // store(0), so the exact value while locked does not matter for
        // correctness; this only keeps counts tidy.
        const old_value: u32 = self.count.load(.monotonic);
        if (old_value > WRITER_LOCK) {
            _ = self.count.cmpxchgWeak(old_value, WRITER_LOCK, .monotonic, .monotonic);
        }
        return false;
    }

    /// Release a shared (reader) lock.
    pub fn unlockShared(self: *SpinSharedMutex) void {
        _ = self.count.fetchSub(1, .release);
    }

    /// Attempt to upgrade a shared (reader) lock to an exclusive (writer) lock.
    ///
    /// Spins while a concurrent writer holds the lock (count == WRITER_LOCK).
    /// Returns false immediately if count != 1 and count != WRITER_LOCK
    /// (i.e. other readers are present, so the upgrade cannot proceed).
    ///
    /// The `wait` parameter is accepted for API compatibility but the loop
    /// behaviour matches the C++ reference implementation, which always retries
    /// when a writer is detected regardless of `wait`.
    ///
    /// Returns true on success.
    pub fn tryUpgrade(self: *SpinSharedMutex, wait: bool) bool {
        _ = wait;
        while (true) {
            const old_value: u32 = 1;
            // cmpxchgStrong returns null on success, or the current value on failure.
            if (self.count.cmpxchgStrong(old_value, WRITER_LOCK, .acquire, .monotonic)) |current| {
                // CAS failed. current holds the actual value that was observed.
                if (current < WRITER_LOCK) return false;
                // current == WRITER_LOCK: a writer holds the lock — retry.
                std.Thread.yield() catch {};
            } else {
                // CAS succeeded.
                return true;
            }
        }
    }

    /// Downgrade an exclusive (writer) lock to a shared (reader) lock.
    pub fn downgrade(self: *SpinSharedMutex) void {
        self.count.store(1, .release);
    }
};

// ---------------------------------------------------------------------------
// HashMutex
// ---------------------------------------------------------------------------

/// A striped mutex that maps keys to a fixed set of slots via a hash function.
///
/// Equivalent to tkrzw's HashMutex template, specialised for runtime-determined
/// `num_slots` and `num_buckets`.
pub const HashMutex = struct {
    slots: []SpinSharedMutex,
    num_buckets: std.atomic.Value(i64),
    hash_func: *const fn ([]const u8, u64) u64,
    allocator: std.mem.Allocator,

    /// Initialise a HashMutex.
    ///
    /// `num_slots`   — number of mutex slots (striping factor).
    /// `num_buckets` — initial number of hash buckets.
    /// `hash_func`   — key → bucket-index function.
    /// `allocator`   — used to allocate the slots slice.
    pub fn init(
        num_slots: i32,
        num_buckets_init: i64,
        hash_func: *const fn ([]const u8, u64) u64,
        allocator: std.mem.Allocator,
    ) !HashMutex {
        const n: usize = @intCast(num_slots);
        const slots = try allocator.alloc(SpinSharedMutex, n);
        for (slots) |*s| s.* = .{};
        return HashMutex{
            .slots = slots,
            .num_buckets = std.atomic.Value(i64).init(num_buckets_init),
            .hash_func = hash_func,
            .allocator = allocator,
        };
    }

    /// Free the slots slice.
    pub fn deinit(self: *HashMutex) void {
        self.allocator.free(self.slots);
    }

    /// Return the number of mutex slots.
    pub fn getNumSlots(self: *const HashMutex) i32 {
        return @intCast(self.slots.len);
    }

    /// Return the current number of hash buckets.
    pub fn getNumBuckets(self: *const HashMutex) i64 {
        return self.num_buckets.load(.monotonic);
    }

    /// Atomically update the number of hash buckets (rehash).
    pub fn rehash(self: *HashMutex, new_num_buckets: i64) void {
        self.num_buckets.store(new_num_buckets, .release);
    }

    /// Compute the bucket index for `data` given the current `num_buckets`.
    pub fn getBucketIndex(self: *const HashMutex, data: []const u8) i64 {
        const nb: u64 = @intCast(self.num_buckets.load(.monotonic));
        return @intCast(self.hash_func(data, nb));
    }

    /// Map a bucket index to a slot index.
    fn slotIndexFor(self: *const HashMutex, bucket_index: i64) usize {
        return @intCast(@mod(bucket_index, @as(i64, @intCast(self.slots.len))));
    }

    // --- exclusive single-key operations ---

    /// Lock the slot for `data` exclusively.
    /// Returns the bucket index. Retries if `num_buckets` changes while locking.
    pub fn lockOne(self: *HashMutex, data: []const u8) i64 {
        while (true) {
            const nb: u64 = @intCast(self.num_buckets.load(.monotonic));
            const bucket_index: i64 = @intCast(self.hash_func(data, nb));
            const slot_index = self.slotIndexFor(bucket_index);
            self.slots[slot_index].lock();
            // Verify num_buckets did not change while we were locking.
            if (self.num_buckets.load(.monotonic) == @as(i64, @intCast(nb))) {
                return bucket_index;
            }
            self.slots[slot_index].unlock();
        }
    }

    /// Lock the slot for `bucket_index` exclusively.
    /// Returns false if `bucket_index` is out of range.
    pub fn lockOneByIndex(self: *HashMutex, bucket_index: i64) bool {
        if (bucket_index >= self.num_buckets.load(.monotonic)) return false;
        const slot_index = self.slotIndexFor(bucket_index);
        self.slots[slot_index].lock();
        return true;
    }

    /// Unlock the slot for `bucket_index` (exclusive).
    pub fn unlockOne(self: *HashMutex, bucket_index: i64) void {
        const slot_index = self.slotIndexFor(bucket_index);
        self.slots[slot_index].unlock();
    }

    // --- shared single-key operations ---

    /// Lock the slot for `data` in shared (reader) mode.
    /// Returns the bucket index. Retries if `num_buckets` changes while locking.
    pub fn lockOneShared(self: *HashMutex, data: []const u8) i64 {
        while (true) {
            const nb: u64 = @intCast(self.num_buckets.load(.monotonic));
            const bucket_index: i64 = @intCast(self.hash_func(data, nb));
            const slot_index = self.slotIndexFor(bucket_index);
            self.slots[slot_index].lockShared();
            if (self.num_buckets.load(.monotonic) == @as(i64, @intCast(nb))) {
                return bucket_index;
            }
            self.slots[slot_index].unlockShared();
        }
    }

    /// Lock the slot for `bucket_index` in shared (reader) mode.
    /// Returns false if `bucket_index` is out of range.
    pub fn lockOneSharedByIndex(self: *HashMutex, bucket_index: i64) bool {
        if (bucket_index >= self.num_buckets.load(.monotonic)) return false;
        const slot_index = self.slotIndexFor(bucket_index);
        self.slots[slot_index].lockShared();
        return true;
    }

    /// Unlock the slot for `bucket_index` (shared).
    pub fn unlockOneShared(self: *HashMutex, bucket_index: i64) void {
        const slot_index = self.slotIndexFor(bucket_index);
        self.slots[slot_index].unlockShared();
    }

    // --- all-slots operations ---

    /// Lock all slots exclusively (in index order).
    pub fn lockAll(self: *HashMutex) void {
        for (self.slots) |*s| s.lock();
    }

    /// Unlock all slots (exclusive), in reverse index order.
    pub fn unlockAll(self: *HashMutex) void {
        var i: usize = self.slots.len;
        while (i > 0) {
            i -= 1;
            self.slots[i].unlock();
        }
    }

    /// Lock all slots in shared (reader) mode (in index order).
    pub fn lockAllShared(self: *HashMutex) void {
        for (self.slots) |*s| s.lockShared();
    }

    /// Unlock all slots (shared), in reverse index order.
    pub fn unlockAllShared(self: *HashMutex) void {
        var i: usize = self.slots.len;
        while (i > 0) {
            i -= 1;
            self.slots[i].unlockShared();
        }
    }

    // --- multi-key exclusive operations ---

    /// Lock the slots for all keys in `data_list` exclusively.
    ///
    /// Returns a heap-allocated slice of bucket indices (one per key, in the
    /// same order as `data_list`).  The caller owns the slice and must free it
    /// with `allocator.free`.
    ///
    /// Internally the method:
    ///   1. Locks slot 0 as a guard while computing bucket indices.
    ///   2. Collects the unique slot indices, sorted ascending.
    ///   3. Locks each slot (except slot 0 which is already held).
    ///   4. Releases the slot 0 guard if slot 0 is not in the working set.
    pub fn lockMulti(self: *HashMutex, data_list: []const []const u8, allocator: std.mem.Allocator) ![]i64 {
        const n = data_list.len;

        // Pre-allocate both output slices before acquiring any lock so that
        // all allocations happen before we enter the critical section.
        const bucket_indices = try allocator.alloc(i64, n);
        errdefer allocator.free(bucket_indices);

        const slot_buf = try allocator.alloc(i64, n);
        defer allocator.free(slot_buf);

        // Acquire slot 0 as a guard while we compute bucket and slot indices.
        self.slots[0].lock();
        errdefer self.slots[0].unlock();

        const nb: u64 = @intCast(self.num_buckets.load(.monotonic));
        const num_slots_i64: i64 = @intCast(self.slots.len);

        for (data_list, 0..) |data, i| {
            const bucket_index: i64 = @intCast(self.hash_func(data, nb));
            bucket_indices[i] = bucket_index;
            slot_buf[i] = @mod(bucket_index, num_slots_i64);
        }

        // Sort and deduplicate slot indices (mirrors std::set<int32_t>).
        std.sort.pdq(i64, slot_buf, {}, std.sort.asc(i64));
        const unique_slots = deduplicateSorted(i64, slot_buf);

        // Lock each unique slot, skipping slot 0 (already held).
        var has_zero = false;
        for (unique_slots) |slot_index| {
            if (slot_index == 0) {
                has_zero = true;
            } else {
                self.slots[@intCast(slot_index)].lock();
            }
        }

        // Release the slot 0 guard if it is not part of the working set.
        if (!has_zero) self.slots[0].unlock();

        return bucket_indices;
    }

    /// Unlock the slots for the given bucket indices (exclusive).
    ///
    /// `bucket_indices` must be the slice returned by `lockMulti`.
    /// Unlocks in reverse order of unique slot indices (mirrors C++).
    pub fn unlockMulti(self: *HashMutex, bucket_indices: []const i64) void {
        const num_slots_i64: i64 = @intCast(self.slots.len);
        // Boolean presence array: after modulo, slot indices are in [0, slots.len).
        // This handles any number of keys without truncation — after modulo reduction
        // there are at most slots.len unique slot indices regardless of key count.
        var seen: [512]bool = undefined;
        @memset(&seen, false);
        std.debug.assert(self.slots.len <= seen.len);
        for (bucket_indices) |bi| {
            seen[@intCast(@mod(bi, num_slots_i64))] = true;
        }
        // Unlock in reverse order of slot index.
        var i: usize = self.slots.len;
        while (i > 0) {
            i -= 1;
            if (seen[i]) self.slots[i].unlock();
        }
    }

    // --- multi-key shared operations ---

    /// Lock the slots for all keys in `data_list` in shared (reader) mode.
    ///
    /// Same semantics as `lockMulti` but acquires shared locks.
    pub fn lockMultiShared(self: *HashMutex, data_list: []const []const u8, allocator: std.mem.Allocator) ![]i64 {
        const n = data_list.len;

        const bucket_indices = try allocator.alloc(i64, n);
        errdefer allocator.free(bucket_indices);

        const slot_buf = try allocator.alloc(i64, n);
        defer allocator.free(slot_buf);

        self.slots[0].lockShared();
        // No try-able calls follow the lock, so this errdefer is a safety net
        // for future changes but cannot fire in the current code.
        errdefer self.slots[0].unlockShared();

        const nb: u64 = @intCast(self.num_buckets.load(.monotonic));
        const num_slots_i64: i64 = @intCast(self.slots.len);

        for (data_list, 0..) |data, i| {
            const bucket_index: i64 = @intCast(self.hash_func(data, nb));
            bucket_indices[i] = bucket_index;
            slot_buf[i] = @mod(bucket_index, num_slots_i64);
        }

        std.sort.pdq(i64, slot_buf, {}, std.sort.asc(i64));
        const unique_slots = deduplicateSorted(i64, slot_buf);

        var has_zero = false;
        for (unique_slots) |slot_index| {
            if (slot_index == 0) {
                has_zero = true;
            } else {
                self.slots[@intCast(slot_index)].lockShared();
            }
        }

        if (!has_zero) self.slots[0].unlockShared();

        return bucket_indices;
    }

    /// Unlock the slots for the given bucket indices (shared).
    ///
    /// `bucket_indices` must be the slice returned by `lockMultiShared`.
    /// Unlocks in reverse order of unique slot indices.
    pub fn unlockMultiShared(self: *HashMutex, bucket_indices: []const i64) void {
        const num_slots_i64: i64 = @intCast(self.slots.len);
        var seen: [512]bool = undefined;
        @memset(&seen, false);
        std.debug.assert(self.slots.len <= seen.len);
        for (bucket_indices) |bi| {
            seen[@intCast(@mod(bi, num_slots_i64))] = true;
        }
        var i: usize = self.slots.len;
        while (i > 0) {
            i -= 1;
            if (seen[i]) self.slots[i].unlockShared();
        }
    }
};

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Return the deduplicated prefix of a sorted slice (in-place).
/// Equivalent to std::unique on a sorted range.
fn deduplicateSorted(comptime T: type, slice: []T) []T {
    if (slice.len == 0) return slice;
    var write: usize = 1;
    for (slice[1..]) |v| {
        if (v != slice[write - 1]) {
            slice[write] = v;
            write += 1;
        }
    }
    return slice[0..write];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "SpinSharedMutex: lock and unlock" {
    var mu: SpinSharedMutex = .{};
    mu.lock();
    try std.testing.expectEqual(WRITER_LOCK, mu.count.load(.monotonic));
    mu.unlock();
    try std.testing.expectEqual(@as(u32, 0), mu.count.load(.monotonic));
}

test "SpinSharedMutex: lockShared and unlockShared" {
    var mu: SpinSharedMutex = .{};
    mu.lockShared();
    mu.lockShared();
    try std.testing.expectEqual(@as(u32, 2), mu.count.load(.monotonic));
    mu.unlockShared();
    try std.testing.expectEqual(@as(u32, 1), mu.count.load(.monotonic));
    mu.unlockShared();
    try std.testing.expectEqual(@as(u32, 0), mu.count.load(.monotonic));
}

test "SpinSharedMutex: tryLock succeeds on unlocked, fails on locked" {
    var mu: SpinSharedMutex = .{};
    try std.testing.expect(mu.tryLock());
    try std.testing.expectEqual(WRITER_LOCK, mu.count.load(.monotonic));
    try std.testing.expect(!mu.tryLock());
    mu.unlock();
    try std.testing.expect(mu.tryLock());
    mu.unlock();
}

test "SpinSharedMutex: tryUpgrade and downgrade" {
    var mu: SpinSharedMutex = .{};
    // Acquire a shared lock first.
    mu.lockShared();
    try std.testing.expectEqual(@as(u32, 1), mu.count.load(.monotonic));
    // Upgrade to exclusive — should succeed because we are the only reader.
    try std.testing.expect(mu.tryUpgrade(false));
    try std.testing.expectEqual(WRITER_LOCK, mu.count.load(.monotonic));
    // Downgrade back to shared.
    mu.downgrade();
    try std.testing.expectEqual(@as(u32, 1), mu.count.load(.monotonic));
    mu.unlockShared();
    try std.testing.expectEqual(@as(u32, 0), mu.count.load(.monotonic));
}

test "SpinSharedMutex: tryUpgrade fails when multiple readers" {
    var mu: SpinSharedMutex = .{};
    mu.lockShared();
    mu.lockShared();
    try std.testing.expectEqual(@as(u32, 2), mu.count.load(.monotonic));
    // Cannot upgrade: count is 2, not 1.
    try std.testing.expect(!mu.tryUpgrade(false));
    mu.unlockShared();
    mu.unlockShared();
}

test "HashMutex: init and basic properties" {
    var hm = try HashMutex.init(16, 1000, hash_util.primaryHash, std.testing.allocator);
    defer hm.deinit();
    try std.testing.expectEqual(@as(i32, 16), hm.getNumSlots());
    try std.testing.expectEqual(@as(i64, 1000), hm.getNumBuckets());
}

test "HashMutex: getBucketIndex is in range" {
    var hm = try HashMutex.init(16, 1000, hash_util.primaryHash, std.testing.allocator);
    defer hm.deinit();
    const idx = hm.getBucketIndex("hello");
    try std.testing.expect(idx >= 0);
    try std.testing.expect(idx < 1000);
}

test "HashMutex: lockOne and unlockOne round-trip" {
    var hm = try HashMutex.init(16, 1000, hash_util.primaryHash, std.testing.allocator);
    defer hm.deinit();
    const bucket = hm.lockOne("mykey");
    try std.testing.expect(bucket >= 0 and bucket < 1000);
    hm.unlockOne(bucket);
    // Verify all slots are back to unlocked.
    for (hm.slots) |s| {
        try std.testing.expectEqual(@as(u32, 0), s.count.load(.monotonic));
    }
}

test "HashMutex: lockAll and unlockAll round-trip" {
    var hm = try HashMutex.init(8, 500, hash_util.primaryHash, std.testing.allocator);
    defer hm.deinit();
    hm.lockAll();
    for (hm.slots) |s| {
        try std.testing.expectEqual(WRITER_LOCK, s.count.load(.monotonic));
    }
    hm.unlockAll();
    for (hm.slots) |s| {
        try std.testing.expectEqual(@as(u32, 0), s.count.load(.monotonic));
    }
}

test "HashMutex: lockMulti deduplicates slots" {
    // Use a small number of slots to force collisions.
    var hm = try HashMutex.init(2, 1000, hash_util.primaryHash, std.testing.allocator);
    defer hm.deinit();

    // Two keys that we don't know will hit the same slot, but with only 2
    // slots the maximum number of distinct slots is 2.  We verify that after
    // lockMulti every locked slot is locked exactly once (WRITER_LOCK, not
    // 2*WRITER_LOCK or similar).
    const keys = [_][]const u8{ "alpha", "beta", "gamma" };
    const bucket_indices = try hm.lockMulti(&keys, std.testing.allocator);
    defer std.testing.allocator.free(bucket_indices);

    try std.testing.expectEqual(@as(usize, 3), bucket_indices.len);

    // Each locked slot must be in exactly the writer-lock state.
    for (hm.slots) |s| {
        const v = s.count.load(.monotonic);
        try std.testing.expect(v == 0 or v == WRITER_LOCK);
    }

    hm.unlockMulti(bucket_indices);
    for (hm.slots) |s| {
        try std.testing.expectEqual(@as(u32, 0), s.count.load(.monotonic));
    }
}
