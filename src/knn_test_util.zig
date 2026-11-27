//! Test-only KNN harness utilities: seeded dataset generators, naive scalar
//! ground-truth oracle, mixed-corpus loaders, and PolyDBM backend matrix opener.
//!
//! Deliberately NOT imported by src/root.zig so production code can never call
//! the oracle.

const std = @import("std");
const tkrzw = @import("tkrzw_zig");

pub const VecRecord = struct {
    key: []u8,
    vector: []f32,
};

pub const ExpectedHit = struct {
    key: []const u8,
    score: f64,
};

pub const all_backends = [_]tkrzw.BackendType{
    .tiny,
    .baby,
    .cache,
    .hash,
    .tree,
    .skip,
};

pub const file_backends = [_]tkrzw.BackendType{
    .hash,
    .tree,
    .skip,
};

pub const all_metrics = [_]tkrzw.VectorMetric{
    .l2,
    .dot,
    .cosine,
};

pub fn extensionFor(backend: tkrzw.BackendType) []const u8 {
    return switch (backend) {
        .hash => ".tkh",
        .tree => ".tkt",
        .skip => ".tks",
        .tiny => ".tkmt",
        .baby => ".tkmb",
        .cache => ".tkmc",
    };
}

pub fn freeDataset(allocator: std.mem.Allocator, records: []VecRecord) void {
    for (records) |rec| {
        allocator.free(rec.key);
        allocator.free(rec.vector);
    }
    allocator.free(records);
}

/// Generates `n` seeded random vectors in `[-1, 1)` with fixed-width zero-padded
/// keys (`rec_0000`, ...).
pub fn makeDataset(
    allocator: std.mem.Allocator,
    seed: u64,
    n: usize,
    dim: usize,
) ![]VecRecord {
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    const out = try allocator.alloc(VecRecord, n);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |rec| {
            allocator.free(rec.key);
            allocator.free(rec.vector);
        }
        allocator.free(out);
    }

    for (0..n) |i| {
        const key = try std.fmt.allocPrint(allocator, "rec_{d:0>6}", .{i});
        errdefer allocator.free(key);
        const vec = try allocator.alloc(f32, dim);
        for (vec) |*x| x.* = rng.float(f32) * 2.0 - 1.0;
        out[i] = .{ .key = key, .vector = vec };
        built += 1;
    }

    return out;
}

/// Generates a seeded dataset of `n + 4` vectors containing:
/// - `n` uniform random vectors in `[-1, 1)`
/// - two identical vectors (forced tie)
/// - one all-zero vector (cosine edge case)
/// - one axis-aligned unit vector `[1, 0, ..., 0]`
/// Insertion order is shuffled with the same seeded PRNG so no backend relies
/// on pre-sorted input.
pub fn makeAdversarialDataset(
    allocator: std.mem.Allocator,
    seed: u64,
    n: usize,
    dim: usize,
) ![]VecRecord {
    const total = n + 4;
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    const out = try allocator.alloc(VecRecord, total);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |rec| {
            allocator.free(rec.key);
            allocator.free(rec.vector);
        }
        allocator.free(out);
    }

    // Random records.
    for (0..n) |i| {
        const key = try std.fmt.allocPrint(allocator, "rec_{d:0>6}", .{i});
        errdefer allocator.free(key);
        const vec = try allocator.alloc(f32, dim);
        for (vec) |*x| x.* = rng.float(f32) * 2.0 - 1.0;
        out[built] = .{ .key = key, .vector = vec };
        built += 1;
    }

    // Two identical vectors to force exact score ties (inserted out of key order).
    const tie_b_key = try allocator.dupe(u8, "tie_b");
    errdefer allocator.free(tie_b_key);
    const tie_b_vec = try allocator.alloc(f32, dim);
    for (tie_b_vec) |*x| x.* = rng.float(f32) * 2.0 - 1.0;
    out[built] = .{ .key = tie_b_key, .vector = tie_b_vec };
    built += 1;

    const tie_a_key = try allocator.dupe(u8, "tie_a");
    errdefer allocator.free(tie_a_key);
    const tie_a_vec = try allocator.dupe(f32, tie_b_vec);
    out[built] = .{ .key = tie_a_key, .vector = tie_a_vec };
    built += 1;

    // All-zero vector (cosine distance = +inf, score = -inf).
    const zero_key = try allocator.dupe(u8, "zero_vec");
    errdefer allocator.free(zero_key);
    const zero_vec = try allocator.alloc(f32, dim);
    @memset(zero_vec, 0.0);
    out[built] = .{ .key = zero_key, .vector = zero_vec };
    built += 1;

    // Axis-aligned unit vector.
    const axis_key = try allocator.dupe(u8, "axis_0");
    errdefer allocator.free(axis_key);
    const axis_vec = try allocator.alloc(f32, dim);
    @memset(axis_vec, 0.0);
    axis_vec[0] = 1.0;
    out[built] = .{ .key = axis_key, .vector = axis_vec };
    built += 1;

    // Shuffle insertion order deterministically.
    rng.shuffle(VecRecord, out);
    return out;
}

/// Naive scalar f64 ground-truth oracle (no SIMD, no heap).
/// Computes every score and performs a full sort with ascending-key tie-break,
/// then returns the top `min(k, dataset.len)` entries.
pub fn oracleRank(
    allocator: std.mem.Allocator,
    dataset: []const VecRecord,
    query: []const f32,
    metric: tkrzw.VectorMetric,
    k: usize,
) ![]ExpectedHit {
    const all = try allocator.alloc(ExpectedHit, dataset.len);
    defer allocator.free(all);

    for (dataset, 0..) |rec, idx| {
        const score = oracleScore(metric, query, rec.vector);
        all[idx] = .{ .key = rec.key, .score = score };
    }

    std.mem.sort(ExpectedHit, all, {}, struct {
        fn lt(_: void, a: ExpectedHit, b: ExpectedHit) bool {
            if (a.score != b.score) return a.score > b.score;
            return std.mem.order(u8, a.key, b.key) == .lt;
        }
    }.lt);

    const keep = @min(k, all.len);
    const result = try allocator.alloc(ExpectedHit, keep);
    @memcpy(result, all[0..keep]);
    return result;
}

pub fn oracleScore(metric: tkrzw.VectorMetric, a: []const f32, b: []const f32) f64 {
    std.debug.assert(a.len == b.len);
    switch (metric) {
        .dot => {
            var acc: f64 = 0.0;
            for (a, b) |x, y| acc += @as(f64, x) * @as(f64, y);
            return acc;
        },
        .l2 => {
            var acc: f64 = 0.0;
            for (a, b) |x, y| {
                const d = @as(f64, x) - @as(f64, y);
                acc += d * d;
            }
            const dist = @sqrt(acc);
            return if (dist == 0.0) 0.0 else -dist;
        },
        .cosine => {
            var dp: f64 = 0.0;
            var na_sq: f64 = 0.0;
            var nb_sq: f64 = 0.0;
            for (a, b) |x, y| {
                const fx = @as(f64, x);
                const fy = @as(f64, y);
                dp += fx * fy;
                na_sq += fx * fx;
                nb_sq += fy * fy;
            }
            if (na_sq == 0.0 or nb_sq == 0.0) return -std.math.inf(f64);
            if (dp >= 0.0) {
                const na = @sqrt(na_sq);
                const nb = @sqrt(nb_sq);
                var diff_sq: f64 = 0.0;
                for (a, b) |x, y| {
                    const d = (@as(f64, x) / na) - (@as(f64, y) / nb);
                    diff_sq += d * d;
                }
                const dist = std.math.clamp(0.5 * diff_sq, 0.0, 1.0);
                return if (dist == 0.0) 0.0 else -dist;
            }
            const prod = na_sq * nb_sq;
            const denom = if (std.math.isInf(prod)) @sqrt(na_sq) * @sqrt(nb_sq) else @sqrt(prod);
            if (denom == 0.0) return -std.math.inf(f64);
            const dist = 1.0 - std.math.clamp(dp / denom, -1.0, 0.0);
            return if (dist == 0.0) 0.0 else -dist;
        },
    }
}

/// Opens a fresh PolyDBM for `backend` under `tmp_path` using the canonical
/// file extension.
pub fn openBackend(
    backend: tkrzw.BackendType,
    tmp_path: []const u8,
    name: []const u8,
    writable: bool,
    io: std.Io,
    allocator: std.mem.Allocator,
) !tkrzw.PolyDBM {
    const db_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}{s}",
        .{ tmp_path, name, extensionFor(backend) },
    );
    defer allocator.free(db_path);
    return tkrzw.PolyDBM.open(db_path, .{ .writable = writable }, io, allocator);
}

/// Encodes and stores every record from `dataset` into `poly`, then synchronizes
/// so batch-oriented backends (SkipDBM) are immediately queryable.
pub fn loadInto(
    poly: *tkrzw.PolyDBM,
    io: std.Io,
    allocator: std.mem.Allocator,
    dataset: []const VecRecord,
) !void {
    for (dataset) |rec| {
        const bytes = try tkrzw.encodeF32(allocator, rec.vector);
        defer allocator.free(bytes);
        const st = poly.set(io, rec.key, bytes, true);
        if (!st.isOk()) return error.SetFailed;
    }
    const sync_st = poly.synchronize(io, false);
    if (!sync_st.isOk()) return error.SyncFailed;
}

/// Loads `dataset` plus 5 invalid records (bad string length, empty blob,
/// NaN blob, +Inf blob, and a valid wrong-dimension vector).
/// Returns the number of injected invalid records (5).
pub fn loadMixed(
    poly: *tkrzw.PolyDBM,
    io: std.Io,
    allocator: std.mem.Allocator,
    dataset: []const VecRecord,
    dim: usize,
) !usize {
    for (dataset) |rec| {
        const bytes = try tkrzw.encodeF32(allocator, rec.vector);
        defer allocator.free(bytes);
        if (!poly.set(io, rec.key, bytes, true).isOk()) return error.SetFailed;
    }

    // 1. Non-vector text whose length is not divisible by 4 (13 bytes).
    if (!poly.set(io, "bad_str", "not a vector!", true).isOk()) return error.SetFailed;
    // 2. Empty blob.
    if (!poly.set(io, "bad_empty", "", true).isOk()) return error.SetFailed;

    // 3. Raw NaN vector of matching dimension (bypassing encodeF32).
    const nan_raw = try allocator.alloc(u8, dim * 4);
    defer allocator.free(nan_raw);
    @memset(nan_raw, 0);
    std.mem.writeInt(u32, nan_raw[0..4], @bitCast(std.math.nan(f32)), .little);
    if (!poly.set(io, "bad_nan", nan_raw, true).isOk()) return error.SetFailed;

    // 4. Raw +Inf vector of matching dimension.
    const inf_raw = try allocator.alloc(u8, dim * 4);
    defer allocator.free(inf_raw);
    @memset(inf_raw, 0);
    std.mem.writeInt(u32, inf_raw[(dim - 1) * 4 ..][0..4], @bitCast(std.math.inf(f32)), .little);
    if (!poly.set(io, "bad_inf", inf_raw, true).isOk()) return error.SetFailed;

    // 5. Valid float32 vector of wrong dimension (`dim + 1`).
    const wrong_vec = try allocator.alloc(f32, dim + 1);
    defer allocator.free(wrong_vec);
    @memset(wrong_vec, 0.5);
    const wrong_bytes = try tkrzw.encodeF32(allocator, wrong_vec);
    defer allocator.free(wrong_bytes);
    if (!poly.set(io, "bad_dim", wrong_bytes, true).isOk()) return error.SetFailed;

    if (!poly.synchronize(io, false).isOk()) return error.SyncFailed;
    return 5;
}
