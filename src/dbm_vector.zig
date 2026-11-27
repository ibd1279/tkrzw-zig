//! Exact brute-force KNN vector search and byte-exact vector lookup over
//! PolyDBM (covering all six tkrzw-zig backends).
//!
//! Storage convention: vectors are stored as record values encoded via
//! `vector_util.encodeF32` (packed little-endian IEEE-754 float32, no header
//! or padding). Record keys serve as caller-defined vector IDs.
//!
//! Operational notes:
//! - Headerless blobs: any non-vector record whose byte length equals
//!   `query.len * 4` and whose bytes decode as finite float32 values is
//!   indistinguishable from a vector.
//! - SkipDBM: buffers writes until `synchronize()` or `close()`; unsynchronized
//!   records are not visible to `searchSimilar` or `findByVector`.
//! - Concurrency: scans are not universally point-in-time snapshots across
//!   backends. TinyDBM, HashDBM, and SkipDBM hold shared/whole locks across
//!   `processEach`, whereas BabyDBM and TreeDBM lock one leaf at a time and
//!   CacheDBM locks per slot.
//! - Strict mode: stops scoring on the first invalid record and returns the
//!   error once `PolyDBM.processEach` finishes traversing (because
//!   `RecordAction` has no early-abort signal).

const std = @import("std");
const builtin = @import("builtin");
const dbm_mod = @import("dbm.zig");
const dbm_poly = @import("dbm_poly.zig");
const lib_common = @import("lib_common.zig");
const vector_util = @import("vector_util.zig");

pub const PolyDBM = dbm_poly.PolyDBM;
pub const PolyError = dbm_poly.PolyError;
const RecordAction = dbm_mod.RecordAction;
const Status = lib_common.Status;
const Code = lib_common.Code;

pub const VectorMetric = vector_util.VectorMetric;
const VectorError = vector_util.VectorError;
pub const KnnHit = vector_util.KnnHit;

/// Options controlling exact KNN scan behavior.
pub const SearchOptions = struct {
    /// Optional expected dimensionality. If set and `query.len != expected_dim`,
    /// `searchSimilar` returns `PolyError.InvalidArgument` before scanning.
    expected_dim: ?usize = null,
    /// When false (default), malformed and dimension-mismatched records are
    /// skipped and counted in `KnnResult.invalid_records`.
    /// When true, scoring stops on the first invalid record and returns
    /// `PolyError.BrokenData` (malformed length or NaN/Inf) or
    /// `PolyError.InvalidArgument` (dimension mismatch) after traversal.
    strict: bool = false,
};

/// Result of an exact KNN scan.
pub const KnnResult = struct {
    /// Ranked hits, best first (higher `score` = more similar; ties broken by
    /// ascending key byte order). Caller owns memory; call `deinit`.
    hits: []KnnHit,
    /// Number of malformed or dimension-mismatched records encountered.
    invalid_records: usize,
    /// Total number of records visited during the scan.
    scanned: usize,

    pub fn deinit(self: *KnnResult, allocator: std.mem.Allocator) void {
        for (self.hits) |hit| allocator.free(hit.key);
        allocator.free(self.hits);
        self.hits = &.{};
    }
};

// ---------------------------------------------------------------------------
// Internal byte scorer and bounded top-k heap
// ---------------------------------------------------------------------------

const simd_lanes: usize = std.simd.suggestVectorLength(f32) orelse 1;
const VecF32 = @Vector(simd_lanes, f32);
const VecF64 = @Vector(simd_lanes, f64);

inline fn readElementLE(bytes: []const u8, index: usize) f32 {
    return @bitCast(std.mem.readInt(u32, bytes[index * 4 ..][0..4], .little));
}

inline fn foldAddF64(acc: *f64, chunk: VecF64) void {
    inline for (0..simd_lanes) |lane| {
        acc.* += chunk[lane];
    }
}

inline fn loadChunkLE(bytes: []const u8, elem_offset: usize) VecF32 {
    const byte_offset = elem_offset * 4;
    if (comptime builtin.cpu.arch.endian() == .little) {
        var raw: [simd_lanes]f32 = undefined;
        @memcpy(std.mem.sliceAsBytes(&raw), bytes[byte_offset..][0 .. simd_lanes * 4]);
        return raw;
    } else {
        var raw: [simd_lanes]f32 = undefined;
        inline for (0..simd_lanes) |lane| {
            raw[lane] = readElementLE(bytes, elem_offset + lane);
        }
        return raw;
    }
}

inline fn chunkIsFinite(v: VecF32) bool {
    const max_f32: VecF32 = @splat(std.math.floatMax(f32));
    return @reduce(.And, @abs(v) <= max_f32);
}

inline fn negateDistance(d: f64) f64 {
    if (d == 0.0) return 0.0;
    return -d;
}

/// Validates and scores a packed little-endian float32 byte slice against a
/// pre-validated `query` and its squared L2 norm using strict left-to-right
/// f64 summation.
fn scoreBytes(
    metric: VectorMetric,
    query: []const f32,
    query_norm_sq: f64,
    bytes: []const u8,
) VectorError!f64 {
    if (bytes.len == 0 or (bytes.len % 4) != 0) return VectorError.InvalidVectorLength;
    const count = bytes.len / 4;
    if (count != query.len) {
        for (0..count) |i| {
            if (!std.math.isFinite(readElementLE(bytes, i))) return VectorError.NonFiniteElement;
        }
        return VectorError.DimensionMismatch;
    }

    switch (metric) {
        .dot => {
            var i: usize = 0;
            var acc: f64 = 0.0;
            if (comptime simd_lanes > 1) {
                while (i + simd_lanes <= count) : (i += simd_lanes) {
                    const bf = loadChunkLE(bytes, i);
                    if (!chunkIsFinite(bf)) return VectorError.NonFiniteElement;
                    const qv: VecF64 = @as(VecF32, query[i..][0..simd_lanes].*);
                    const bv: VecF64 = bf;
                    foldAddF64(&acc, qv * bv);
                }
            }
            while (i < count) : (i += 1) {
                const bx = readElementLE(bytes, i);
                if (!std.math.isFinite(bx)) return VectorError.NonFiniteElement;
                acc += @as(f64, query[i]) * @as(f64, bx);
            }
            return acc;
        },
        .l2 => {
            var i: usize = 0;
            var acc: f64 = 0.0;
            if (comptime simd_lanes > 1) {
                while (i + simd_lanes <= count) : (i += simd_lanes) {
                    const bf = loadChunkLE(bytes, i);
                    if (!chunkIsFinite(bf)) return VectorError.NonFiniteElement;
                    const qv: VecF64 = @as(VecF32, query[i..][0..simd_lanes].*);
                    const bv: VecF64 = bf;
                    const diff = qv - bv;
                    foldAddF64(&acc, diff * diff);
                }
            }
            while (i < count) : (i += 1) {
                const bx = readElementLE(bytes, i);
                if (!std.math.isFinite(bx)) return VectorError.NonFiniteElement;
                const d = @as(f64, query[i]) - @as(f64, bx);
                acc += d * d;
            }
            return negateDistance(@sqrt(acc));
        },
        .cosine => {
            var i: usize = 0;
            var dot_acc: f64 = 0.0;
            var nb_acc: f64 = 0.0;
            if (comptime simd_lanes > 1) {
                while (i + simd_lanes <= count) : (i += simd_lanes) {
                    const bf = loadChunkLE(bytes, i);
                    if (!chunkIsFinite(bf)) return VectorError.NonFiniteElement;
                    const qv: VecF64 = @as(VecF32, query[i..][0..simd_lanes].*);
                    const bv: VecF64 = bf;
                    foldAddF64(&dot_acc, qv * bv);
                    foldAddF64(&nb_acc, bv * bv);
                }
            }
            while (i < count) : (i += 1) {
                const bx = readElementLE(bytes, i);
                if (!std.math.isFinite(bx)) return VectorError.NonFiniteElement;
                const fb = @as(f64, bx);
                dot_acc += @as(f64, query[i]) * fb;
                nb_acc += fb * fb;
            }
            if (query_norm_sq == 0.0 or nb_acc == 0.0) return -std.math.inf(f64);
            if (dot_acc >= 0.0) {
                const na = @sqrt(query_norm_sq);
                const nb = @sqrt(nb_acc);
                var j: usize = 0;
                var diff_sq: f64 = 0.0;
                if (comptime simd_lanes > 1) {
                    const vna: VecF64 = @splat(na);
                    const vnb: VecF64 = @splat(nb);
                    while (j + simd_lanes <= count) : (j += simd_lanes) {
                        const qv: VecF64 = @as(VecF32, query[j..][0..simd_lanes].*);
                        const bv: VecF64 = loadChunkLE(bytes, j);
                        const d = (qv / vna) - (bv / vnb);
                        foldAddF64(&diff_sq, d * d);
                    }
                }
                while (j < count) : (j += 1) {
                    const d = (@as(f64, query[j]) / na) - (@as(f64, readElementLE(bytes, j)) / nb);
                    diff_sq += d * d;
                }
                return negateDistance(std.math.clamp(0.5 * diff_sq, 0.0, 1.0));
            }
            const prod = query_norm_sq * nb_acc;
            const denom = if (std.math.isInf(prod)) @sqrt(query_norm_sq) * @sqrt(nb_acc) else @sqrt(prod);
            if (denom == 0.0) return -std.math.inf(f64);
            const cos = std.math.clamp(dot_acc / denom, -1.0, 0.0);
            return negateDistance(1.0 - cos);
        },
    }
}

/// Bounded top-k selector retaining the `k` highest-scoring hits with stable
/// ascending-key tie-breaking. Owns duped copies of retained keys.
/// Kept internal and rejects NaN scores defensively so NaN cannot pin a slot.
const TopKHeap = struct {
    allocator: std.mem.Allocator,
    capacity: usize,
    items: std.ArrayList(KnnHit),

    const OfferError = std.mem.Allocator.Error || error{NonFiniteElement};

    fn init(allocator: std.mem.Allocator, k: usize) TopKHeap {
        return .{
            .allocator = allocator,
            .capacity = k,
            .items = .empty,
        };
    }

    fn deinit(self: *TopKHeap) void {
        for (self.items.items) |hit| {
            self.allocator.free(hit.key);
        }
        self.items.deinit(self.allocator);
    }

    fn offer(self: *TopKHeap, key: []const u8, score: f64) OfferError!void {
        if (std.math.isNan(score)) return error.NonFiniteElement;
        if (self.capacity == 0) return;

        if (self.items.items.len < self.capacity) {
            const key_copy = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(key_copy);
            try self.items.append(self.allocator, .{ .key = key_copy, .score = score });
            self.siftUp(self.items.items.len - 1);
            return;
        }

        const worst = self.items.items[0];
        if (!vector_util.hitIsBetter(score, key, worst.score, worst.key)) return;

        const key_copy = try self.allocator.dupe(u8, key);
        self.allocator.free(worst.key);
        self.items.items[0] = .{ .key = key_copy, .score = score };
        self.siftDown(0);
    }

    fn toOwnedSortedSlice(self: *TopKHeap) std.mem.Allocator.Error![]KnnHit {
        const slice = try self.items.toOwnedSlice(self.allocator);
        std.mem.sort(KnnHit, slice, {}, struct {
            fn lessThan(_: void, a: KnnHit, b: KnnHit) bool {
                return vector_util.hitIsBetter(a.score, a.key, b.score, b.key);
            }
        }.lessThan);
        return slice;
    }

    fn isWorse(a: KnnHit, b: KnnHit) bool {
        return vector_util.hitIsBetter(b.score, b.key, a.score, a.key);
    }

    fn siftUp(self: *TopKHeap, start_idx: usize) void {
        var idx = start_idx;
        while (idx > 0) {
            const parent = (idx - 1) / 2;
            if (!isWorse(self.items.items[idx], self.items.items[parent])) break;
            std.mem.swap(KnnHit, &self.items.items[idx], &self.items.items[parent]);
            idx = parent;
        }
    }

    fn siftDown(self: *TopKHeap, start_idx: usize) void {
        var idx = start_idx;
        const len = self.items.items.len;
        while (true) {
            const left = idx * 2 + 1;
            const right = left + 1;
            var worst = idx;
            if (left < len and isWorse(self.items.items[left], self.items.items[worst])) {
                worst = left;
            }
            if (right < len and isWorse(self.items.items[right], self.items.items[worst])) {
                worst = right;
            }
            if (worst == idx) break;
            std.mem.swap(KnnHit, &self.items.items[idx], &self.items.items[worst]);
            idx = worst;
        }
    }
};

fn statusToPolyError(status: Status) PolyError {
    return switch (status.code) {
        .SUCCESS => unreachable,
        .UNKNOWN_ERROR => PolyError.UnknownError,
        .SYSTEM_ERROR => PolyError.SystemError,
        .NOT_IMPLEMENTED_ERROR => PolyError.NotImplemented,
        .PRECONDITION_ERROR => PolyError.PreconditionError,
        .INVALID_ARGUMENT_ERROR => PolyError.InvalidArgument,
        .CANCELED_ERROR => PolyError.Canceled,
        .NOT_FOUND_ERROR => PolyError.NotFound,
        .PERMISSION_ERROR => PolyError.PermissionError,
        .INFEASIBLE_ERROR => PolyError.Infeasible,
        .DUPLICATION_ERROR => PolyError.Duplication,
        .BROKEN_DATA_ERROR => PolyError.BrokenData,
        .NETWORK_ERROR => PolyError.NetworkError,
        .APPLICATION_ERROR => PolyError.ApplicationError,
    };
}

/// Performs an exact brute-force k-nearest-neighbor scan across all records in
/// `poly` using `PolyDBM.processEach` (read-only).
///
/// Note: For `SkipDBM`, only synchronized records are visible. Scans are not
/// universally point-in-time snapshots across backends (BabyDBM and TreeDBM
/// lock one leaf at a time, and CacheDBM locks per slot).
pub fn searchSimilar(
    poly: *PolyDBM,
    io: std.Io,
    allocator: std.mem.Allocator,
    query: []const f32,
    k: usize,
    metric: VectorMetric,
    opts: SearchOptions,
) PolyError!KnnResult {
    vector_util.validateF32(query) catch return PolyError.InvalidArgument;
    if (opts.expected_dim) |dim| {
        if (query.len != dim) return PolyError.InvalidArgument;
    }

    const query_norm_sq: f64 = if (metric == .cosine)
        vector_util.normSquared(query) catch return PolyError.InvalidArgument
    else
        0.0;

    const KnnProcessor = struct {
        query: []const f32,
        query_norm_sq: f64,
        metric: VectorMetric,
        strict: bool,
        heap: TopKHeap,
        scanned: usize = 0,
        invalid_records: usize = 0,
        first_error: ?PolyError = null,

        pub fn processFull(self: *@This(), key: []const u8, value: []const u8) RecordAction {
            if (self.first_error != null) return .noop;
            self.scanned += 1;

            const score = scoreBytes(self.metric, self.query, self.query_norm_sq, value) catch |err| {
                self.invalid_records += 1;
                if (self.strict) {
                    self.first_error = switch (err) {
                        VectorError.InvalidVectorLength, VectorError.NonFiniteElement => PolyError.BrokenData,
                        VectorError.DimensionMismatch => PolyError.InvalidArgument,
                    };
                }
                return .noop;
            };

            self.heap.offer(key, score) catch |err| {
                self.first_error = switch (err) {
                    error.OutOfMemory => PolyError.OutOfMemory,
                    error.NonFiniteElement => PolyError.BrokenData,
                };
                return .noop;
            };
            return .noop;
        }

        pub fn processEmpty(_: *@This(), _: []const u8) RecordAction {
            return .noop;
        }
    };

    var proc = KnnProcessor{
        .query = query,
        .query_norm_sq = query_norm_sq,
        .metric = metric,
        .strict = opts.strict,
        .heap = TopKHeap.init(allocator, k),
    };
    defer proc.heap.deinit();

    const status = try poly.processEach(io, KnnProcessor, &proc, false);

    if (proc.first_error) |err| return err;
    if (!status.isOk()) return statusToPolyError(status);

    const hits = try proc.heap.toOwnedSortedSlice();
    return .{
        .hits = hits,
        .invalid_records = proc.invalid_records,
        .scanned = proc.scanned,
    };
}

/// Result of an exact byte-match vector lookup.
pub const FindResult = struct {
    /// All record keys whose value exactly equals the target vector bytes,
    /// sorted in ascending lexical byte order. Caller owns memory; call `deinit`.
    keys: [][]u8,
    /// Total number of records visited during the scan.
    scanned: usize,

    pub fn deinit(self: *FindResult, allocator: std.mem.Allocator) void {
        for (self.keys) |key| allocator.free(key);
        allocator.free(self.keys);
        self.keys = &.{};
    }
};

/// Finds all record keys in `poly` whose stored value is byte-identical to the
/// packed little-endian float32 encoding of `target`.
///
/// Note: For `SkipDBM`, only synchronized records are visible.
pub fn findByVector(
    poly: *PolyDBM,
    io: std.Io,
    allocator: std.mem.Allocator,
    target: []const f32,
) PolyError!FindResult {
    const target_bytes = vector_util.encodeF32(allocator, target) catch |err| switch (err) {
        error.OutOfMemory => return PolyError.OutOfMemory,
        else => return PolyError.InvalidArgument,
    };
    defer allocator.free(target_bytes);
    return findByVectorBytes(poly, io, allocator, target_bytes);
}

/// Finds all record keys in `poly` whose stored value is byte-identical to
/// `target_bytes` (must be a valid finite packed little-endian float32 blob).
pub fn findByVectorBytes(
    poly: *PolyDBM,
    io: std.Io,
    allocator: std.mem.Allocator,
    target_bytes: []const u8,
) PolyError!FindResult {
    vector_util.validateBytes(target_bytes) catch return PolyError.InvalidArgument;

    const ExactProcessor = struct {
        allocator: std.mem.Allocator,
        target_bytes: []const u8,
        matches: std.ArrayList([]u8) = .empty,
        scanned: usize = 0,
        oom: bool = false,

        pub fn deinit(self: *@This()) void {
            for (self.matches.items) |k| self.allocator.free(k);
            self.matches.deinit(self.allocator);
        }

        pub fn processFull(self: *@This(), key: []const u8, value: []const u8) RecordAction {
            if (self.oom) return .noop;
            self.scanned += 1;
            if (std.mem.eql(u8, value, self.target_bytes)) {
                const dup = self.allocator.dupe(u8, key) catch {
                    self.oom = true;
                    return .noop;
                };
                self.matches.append(self.allocator, dup) catch {
                    self.allocator.free(dup);
                    self.oom = true;
                    return .noop;
                };
            }
            return .noop;
        }

        pub fn processEmpty(_: *@This(), _: []const u8) RecordAction {
            return .noop;
        }
    };

    var proc = ExactProcessor{
        .allocator = allocator,
        .target_bytes = target_bytes,
    };
    defer proc.deinit();

    const status = try poly.processEach(io, ExactProcessor, &proc, false);
    if (proc.oom) return PolyError.OutOfMemory;
    if (!status.isOk()) return statusToPolyError(status);

    const keys = try proc.matches.toOwnedSlice(allocator);
    std.mem.sort([]u8, keys, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);

    return .{
        .keys = keys,
        .scanned = proc.scanned,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "internal scoreBytes matches public kernels bit-for-bit and handles unaligned/NaN" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const d: usize = 19; // spans multiple SIMD chunks + tail
    const query = try alloc.alloc(f32, d);
    defer alloc.free(query);
    for (query, 0..) |*q, idx| q.* = @as(f32, @floatFromInt(idx + 1)) * 0.1;
    const q_norm_sq = try vector_util.normSquared(query);

    // Unaligned backing buffer: offset by 1 byte.
    const backing = try alloc.alloc(u8, d * 4 + 1);
    defer alloc.free(backing);
    const unaligned = backing[1..];
    for (0..d) |i| {
        std.mem.writeInt(u32, unaligned[i * 4 ..][0..4], @bitCast(query[i]), .little);
    }

    for ([_]VectorMetric{ .dot, .l2, .cosine }) |m| {
        const expected = try vector_util.similarityScore(m, query, query);
        const got = try scoreBytes(m, query, q_norm_sq, unaligned);
        try testing.expectEqual(@as(u64, @bitCast(expected)), @as(u64, @bitCast(got)));
    }

    // Inject NaN / +Inf / -Inf across SIMD lanes and tail.
    const bad_positions = [_]usize{ 0, 2, 7, 15, 18 };
    const bad_vals = [_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) };
    for (bad_positions) |pos| {
        for (bad_vals) |bad| {
            std.mem.writeInt(u32, unaligned[pos * 4 ..][0..4], @bitCast(bad), .little);
            for ([_]VectorMetric{ .dot, .l2, .cosine }) |m| {
                try testing.expectError(VectorError.NonFiniteElement, scoreBytes(m, query, q_norm_sq, unaligned));
            }
            std.mem.writeInt(u32, unaligned[pos * 4 ..][0..4], @bitCast(query[pos]), .little);
        }
    }

    // Distinguish malformed length vs dimension mismatch vs non-finite mismatch.
    try testing.expectError(VectorError.InvalidVectorLength, scoreBytes(.l2, query, q_norm_sq, ""));
    try testing.expectError(VectorError.InvalidVectorLength, scoreBytes(.l2, query, q_norm_sq, "abc"));
    const other = try vector_util.encodeF32(alloc, &[_]f32{ 1.0, 2.0 });
    defer alloc.free(other);
    try testing.expectError(VectorError.DimensionMismatch, scoreBytes(.l2, query, q_norm_sq, other));

    var inf_diff: [8]u8 = undefined;
    std.mem.writeInt(u32, inf_diff[0..4], @bitCast(std.math.inf(f32)), .little);
    std.mem.writeInt(u32, inf_diff[4..8], @bitCast(@as(f32, 1.0)), .little);
    try testing.expectError(VectorError.NonFiniteElement, scoreBytes(.l2, query, q_norm_sq, &inf_diff));
}

test "internal TopKHeap keeps k best hits, owns copies, rejects NaN, matches full sort" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Ties + NaN rejection + -inf sentinel.
    {
        var heap = TopKHeap.init(alloc, 3);
        defer heap.deinit();

        try testing.expectError(error.NonFiniteElement, heap.offer("nan", std.math.nan(f64)));
        try heap.offer("k_c", 5.0);
        try heap.offer("k_a", 5.0);
        try heap.offer("k_low", -std.math.inf(f64));
        try heap.offer("k_top", 10.0);
        try heap.offer("k_b", 5.0);

        const hits = try heap.toOwnedSortedSlice();
        defer {
            for (hits) |h| alloc.free(h.key);
            alloc.free(hits);
        }
        try testing.expectEqual(@as(usize, 3), hits.len);
        try testing.expectEqualStrings("k_top", hits[0].key);
        try testing.expectEqualStrings("k_a", hits[1].key);
        try testing.expectEqualStrings("k_b", hits[2].key);
    }

    // Owned copies across caller buffer clobbering & evictions.
    {
        var heap = TopKHeap.init(alloc, 2);
        defer heap.deinit();

        var scratch: [16]u8 = undefined;
        const names = [_][]const u8{ "evict_1", "keep_hi", "evict_2", "keep_mid", "evict_3" };
        const scores = [_]f64{ 1.0, 99.0, 2.0, 50.0, 3.0 };

        for (names, scores) |name, score| {
            @memcpy(scratch[0..name.len], name);
            try heap.offer(scratch[0..name.len], score);
            @memset(&scratch, 'X');
        }

        const hits = try heap.toOwnedSortedSlice();
        defer {
            for (hits) |h| alloc.free(h.key);
            alloc.free(hits);
        }
        try testing.expectEqual(@as(usize, 2), hits.len);
        try testing.expectEqualStrings("keep_hi", hits[0].key);
        try testing.expectEqualStrings("keep_mid", hits[1].key);
    }

    // 50-trial property test vs naive full-sort prefix.
    var prng = std.Random.DefaultPrng.init(2026);
    const rng = prng.random();
    const Item = struct { key: []u8, score: f64 };
    for (0..50) |trial| {
        const n = rng.intRangeAtMost(usize, 1, 80);
        const k = rng.intRangeAtMost(usize, 0, n + 5);

        const items = try alloc.alloc(Item, n);
        defer {
            for (items) |it| alloc.free(it.key);
            alloc.free(items);
        }

        var heap = TopKHeap.init(alloc, k);
        defer heap.deinit();

        for (0..n) |i| {
            const key = try std.fmt.allocPrint(alloc, "t{d}_k{d:0>3}", .{ trial, i });
            const score: f64 = if (i % 4 == 0)
                @as(f64, @floatFromInt(rng.intRangeAtMost(i32, -3, 3)))
            else
                rng.float(f64) * 10.0 - 5.0;
            items[i] = .{ .key = key, .score = score };
            try heap.offer(key, score);
        }

        std.mem.sort(Item, items, {}, struct {
            fn lt(_: void, a: Item, b: Item) bool {
                return vector_util.hitIsBetter(a.score, a.key, b.score, b.key);
            }
        }.lt);

        const got = try heap.toOwnedSortedSlice();
        defer {
            for (got) |h| alloc.free(h.key);
            alloc.free(got);
        }

        const expected_len = @min(k, n);
        try testing.expectEqual(expected_len, got.len);
        for (0..expected_len) |idx| {
            try testing.expectEqualStrings(items[idx].key, got[idx].key);
            try testing.expectEqual(items[idx].score, got[idx].score);
        }
    }
}

test "searchSimilar ranks seeded vectors matching scalar oracle across all metrics" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, io, ".", alloc);
    defer alloc.free(tmp_path);
    const db_path = try std.fmt.allocPrint(alloc, "{s}/knn.tkmt", .{tmp_path});
    defer alloc.free(db_path);

    var db = try PolyDBM.open(db_path, .{ .writable = true, .backend = .tiny }, io, alloc);
    defer db.deinit(io);

    const n: usize = 20;
    const d: usize = 8;
    var prng = std.Random.DefaultPrng.init(1);
    const rng = prng.random();

    var vecs: [n][d]f32 = undefined;
    var keys: [n][8]u8 = undefined;
    for (0..n) |i| {
        _ = std.fmt.bufPrint(&keys[i], "vec_{d:0>4}", .{i}) catch unreachable;
        for (0..d) |j| vecs[i][j] = rng.float(f32) * 2.0 - 1.0;
        const encoded = try vector_util.encodeF32(alloc, &vecs[i]);
        defer alloc.free(encoded);
        try testing.expectEqual(Code.SUCCESS, db.set(io, &keys[i], encoded, true).code);
    }

    var query: [d]f32 = undefined;
    for (0..d) |j| query[j] = rng.float(f32) * 2.0 - 1.0;

    const k: usize = 5;
    for ([_]VectorMetric{ .l2, .dot, .cosine }) |metric| {
        const OracleItem = struct { key: []const u8, score: f64 };
        var oracle: [n]OracleItem = undefined;
        for (0..n) |i| {
            const s = try vector_util.similarityScore(metric, &query, &vecs[i]);
            oracle[i] = .{ .key = &keys[i], .score = s };
        }
        std.mem.sort(OracleItem, &oracle, {}, struct {
            fn lt(_: void, a: OracleItem, b: OracleItem) bool {
                return vector_util.hitIsBetter(a.score, a.key, b.score, b.key);
            }
        }.lt);

        var res = try searchSimilar(&db, io, alloc, &query, k, metric, .{});
        defer res.deinit(alloc);

        try testing.expectEqual(n, res.scanned);
        try testing.expectEqual(@as(usize, 0), res.invalid_records);
        try testing.expectEqual(k, res.hits.len);
        for (0..k) |rank| {
            try testing.expectEqualStrings(oracle[rank].key, res.hits[rank].key);
            try testing.expectEqual(@as(u64, @bitCast(oracle[rank].score)), @as(u64, @bitCast(res.hits[rank].score)));
        }
    }
}

test "searchSimilar skip vs strict error policy for malformed and mismatched records" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, io, ".", alloc);
    defer alloc.free(tmp_path);
    const db_path = try std.fmt.allocPrint(alloc, "{s}/mixed.tkmt", .{tmp_path});
    defer alloc.free(db_path);

    var db = try PolyDBM.open(db_path, .{ .writable = true, .backend = .tiny }, io, alloc);
    defer db.deinit(io);

    const v1 = try vector_util.encodeF32(alloc, &[_]f32{ 1.0, 0.0, 0.0 });
    defer alloc.free(v1);
    const v2 = try vector_util.encodeF32(alloc, &[_]f32{ 0.0, 1.0, 0.0 });
    defer alloc.free(v2);
    const wrong_dim = try vector_util.encodeF32(alloc, &[_]f32{ 1.0, 2.0 });
    defer alloc.free(wrong_dim);

    try testing.expectEqual(Code.SUCCESS, db.set(io, "good_1", v1, true).code);
    try testing.expectEqual(Code.SUCCESS, db.set(io, "good_2", v2, true).code);
    try testing.expectEqual(Code.SUCCESS, db.set(io, "wrong_dim", wrong_dim, true).code);

    const query = [_]f32{ 1.0, 0.0, 0.0 };

    // Default mode: skips dim-mismatched record and counts it.
    {
        var res = try searchSimilar(&db, io, alloc, &query, 5, .l2, .{});
        defer res.deinit(alloc);
        try testing.expectEqual(@as(usize, 3), res.scanned);
        try testing.expectEqual(@as(usize, 1), res.invalid_records);
        try testing.expectEqual(@as(usize, 2), res.hits.len);
        try testing.expectEqualStrings("good_1", res.hits[0].key);
    }

    // Strict mode on dim-mismatch -> InvalidArgument.
    try testing.expectError(PolyError.InvalidArgument, searchSimilar(&db, io, alloc, &query, 5, .l2, .{ .strict = true }));

    // Add malformed garbage string (len % 4 != 0) + NaN vector.
    try testing.expectEqual(Code.SUCCESS, db.remove(io, "wrong_dim").code);
    try testing.expectEqual(Code.SUCCESS, db.set(io, "garbage", "not a vector!", true).code);
    var nan_bytes: [12]u8 = undefined;
    std.mem.writeInt(u32, nan_bytes[0..4], @bitCast(std.math.nan(f32)), .little);
    std.mem.writeInt(u32, nan_bytes[4..8], @bitCast(@as(f32, 0.0)), .little);
    std.mem.writeInt(u32, nan_bytes[8..12], @bitCast(@as(f32, 0.0)), .little);
    try testing.expectEqual(Code.SUCCESS, db.set(io, "nan_vec", &nan_bytes, true).code);

    // Default mode skips both malformed records.
    {
        var res = try searchSimilar(&db, io, alloc, &query, 5, .l2, .{});
        defer res.deinit(alloc);
        try testing.expectEqual(@as(usize, 4), res.scanned);
        try testing.expectEqual(@as(usize, 2), res.invalid_records);
        try testing.expectEqual(@as(usize, 2), res.hits.len);
    }

    // Strict mode on malformed records -> BrokenData.
    try testing.expectError(PolyError.BrokenData, searchSimilar(&db, io, alloc, &query, 5, .l2, .{ .strict = true }));
}

test "searchSimilar handles empty db, k=0, k>N, and invalid query" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, io, ".", alloc);
    defer alloc.free(tmp_path);
    const db_path = try std.fmt.allocPrint(alloc, "{s}/edge.tkmt", .{tmp_path});
    defer alloc.free(db_path);

    var db = try PolyDBM.open(db_path, .{ .writable = true, .backend = .tiny }, io, alloc);
    defer db.deinit(io);

    const query = [_]f32{ 1.0, 2.0 };

    // Malformed queries rejected pre-scan.
    try testing.expectError(PolyError.InvalidArgument, searchSimilar(&db, io, alloc, &[_]f32{}, 5, .l2, .{}));
    try testing.expectError(PolyError.InvalidArgument, searchSimilar(&db, io, alloc, &[_]f32{ 1.0, std.math.nan(f32) }, 5, .l2, .{}));
    try testing.expectError(PolyError.InvalidArgument, searchSimilar(&db, io, alloc, &query, 5, .l2, .{ .expected_dim = 4 }));

    // Empty DB.
    {
        var res = try searchSimilar(&db, io, alloc, &query, 5, .l2, .{});
        defer res.deinit(alloc);
        try testing.expectEqual(@as(usize, 0), res.hits.len);
        try testing.expectEqual(@as(usize, 0), res.scanned);
    }

    // Add 2 vectors, test k=0 and k>N.
    const a = try vector_util.encodeF32(alloc, &[_]f32{ 1.0, 2.0 });
    defer alloc.free(a);
    const b = try vector_util.encodeF32(alloc, &[_]f32{ 5.0, 6.0 });
    defer alloc.free(b);
    try testing.expectEqual(Code.SUCCESS, db.set(io, "a", a, true).code);
    try testing.expectEqual(Code.SUCCESS, db.set(io, "b", b, true).code);

    {
        var res0 = try searchSimilar(&db, io, alloc, &query, 0, .l2, .{});
        defer res0.deinit(alloc);
        try testing.expectEqual(@as(usize, 0), res0.hits.len);
        try testing.expectEqual(@as(usize, 2), res0.scanned);
    }
    {
        var res_many = try searchSimilar(&db, io, alloc, &query, 100, .l2, .{});
        defer res_many.deinit(alloc);
        try testing.expectEqual(@as(usize, 2), res_many.hits.len);
        try testing.expectEqualStrings("a", res_many.hits[0].key);
        try testing.expectEqualStrings("b", res_many.hits[1].key);
    }
}

test "findByVector finds unique key, duplicate keys sorted, and empty on no match" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, io, ".", alloc);
    defer alloc.free(tmp_path);
    const db_path = try std.fmt.allocPrint(alloc, "{s}/exact.tkmt", .{tmp_path});
    defer alloc.free(db_path);

    var db = try PolyDBM.open(db_path, .{ .writable = true, .backend = .tiny }, io, alloc);
    defer db.deinit(io);

    const v1 = [_]f32{ 1.0, 2.0, 3.0 };
    const v2 = [_]f32{ 4.0, 5.0, 6.0 };
    const v3 = [_]f32{ 7.0, 8.0, 9.0 };
    const b1 = try vector_util.encodeF32(alloc, &v1);
    defer alloc.free(b1);
    const b2 = try vector_util.encodeF32(alloc, &v2);
    defer alloc.free(b2);
    const b3 = try vector_util.encodeF32(alloc, &v3);
    defer alloc.free(b3);

    try testing.expectEqual(Code.SUCCESS, db.set(io, "k1", b1, true).code);
    try testing.expectEqual(Code.SUCCESS, db.set(io, "k2_z", b2, true).code);
    try testing.expectEqual(Code.SUCCESS, db.set(io, "k2_a", b2, true).code);
    try testing.expectEqual(Code.SUCCESS, db.set(io, "k3", b3, true).code);
    try testing.expectEqual(Code.SUCCESS, db.set(io, "non_vec", "hello", true).code);

    // Unique match.
    {
        var res = try findByVector(&db, io, alloc, &v1);
        defer res.deinit(alloc);
        try testing.expectEqual(@as(usize, 5), res.scanned);
        try testing.expectEqual(@as(usize, 1), res.keys.len);
        try testing.expectEqualStrings("k1", res.keys[0]);
    }

    // Duplicate match returns all matching keys in sorted ascending order.
    {
        var res = try findByVector(&db, io, alloc, &v2);
        defer res.deinit(alloc);
        try testing.expectEqual(@as(usize, 2), res.keys.len);
        try testing.expectEqualStrings("k2_a", res.keys[0]);
        try testing.expectEqualStrings("k2_z", res.keys[1]);
    }

    // No match returns empty keys, no error.
    {
        var res = try findByVector(&db, io, alloc, &[_]f32{ 99.0, 99.0, 99.0 });
        defer res.deinit(alloc);
        try testing.expectEqual(@as(usize, 5), res.scanned);
        try testing.expectEqual(@as(usize, 0), res.keys.len);
    }

    // Invalid targets rejected pre-scan.
    try testing.expectError(PolyError.InvalidArgument, findByVector(&db, io, alloc, &[_]f32{}));
    try testing.expectError(PolyError.InvalidArgument, findByVector(&db, io, alloc, &[_]f32{std.math.nan(f32)}));
    try testing.expectError(PolyError.InvalidArgument, findByVectorBytes(&db, io, alloc, "bad"));
}
