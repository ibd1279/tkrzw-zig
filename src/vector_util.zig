//! Byte-level vector codec, validation, and distance kernels for exact KNN
//! vector search.
//!
//! Storage convention: packed IEEE-754 float32, little-endian, no header, no
//! padding. Dimension is derived as `bytes.len / 4`.
//!
//! Every public function validates its inputs and returns `VectorError` on
//! empty inputs, mismatched dimensions, or non-finite (`NaN`/`Inf`) elements.

const std = @import("std");

const simd_lanes: usize = std.simd.suggestVectorLength(f32) orelse 1;
const VecF32 = @Vector(simd_lanes, f32);
const VecF64 = @Vector(simd_lanes, f64);

/// Folds a SIMD f64 chunk into `acc` in strict left-to-right index order so
/// results are target-independent and bit-identical to the scalar oracle.
inline fn foldAddF64(acc: *f64, chunk: VecF64) void {
    inline for (0..simd_lanes) |lane| {
        acc.* += chunk[lane];
    }
}

pub const VectorError = error{
    InvalidVectorLength,
    NonFiniteElement,
    DimensionMismatch,
};

/// Similarity / distance metric for vector comparisons.
pub const VectorMetric = enum {
    /// Euclidean (L2) distance. Higher similarity score = `-l2Distance(a, b)`.
    l2,
    /// Inner (dot) product. Higher similarity score = `dot(a, b)`.
    dot,
    /// Cosine distance in `[0, 2]` (`+inf` for zero-norm vectors). Higher similarity score = `-cosineDistance(a, b)`.
    cosine,
};

/// A single KNN search hit. Higher `score` means more similar across all metrics.
pub const KnnHit = struct {
    key: []u8,
    score: f64,
};

/// Encodes a non-empty, finite slice of f32 elements as packed little-endian
/// IEEE-754 bytes (4 bytes per element, no header or padding).
pub fn encodeF32(
    allocator: std.mem.Allocator,
    vec: []const f32,
) (VectorError || std.mem.Allocator.Error)![]u8 {
    try validateF32(vec);
    const out = try allocator.alloc(u8, vec.len * 4);
    for (vec, 0..) |val, i| {
        std.mem.writeInt(u32, out[i * 4 ..][0..4], @bitCast(val), .little);
    }
    return out;
}

/// Decodes packed little-endian IEEE-754 float32 bytes into an allocated f32
/// slice. Rejects empty slices and byte lengths not divisible by 4.
/// Preserves exact bit patterns (including -0.0 and subnormals); call
/// `validateBytes` or `validateF32` separately to reject NaN/Inf.
pub fn decodeF32(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) (VectorError || std.mem.Allocator.Error)![]f32 {
    if (bytes.len == 0 or (bytes.len % 4) != 0) return VectorError.InvalidVectorLength;
    const count = bytes.len / 4;
    const out = try allocator.alloc(f32, count);
    for (0..count) |i| {
        out[i] = readElementLE(bytes, i);
    }
    return out;
}

inline fn readElementLE(bytes: []const u8, index: usize) f32 {
    return @bitCast(std.mem.readInt(u32, bytes[index * 4 ..][0..4], .little));
}

/// Validates that `vec` is non-empty and contains only finite float32 values.
pub fn validateF32(vec: []const f32) VectorError!void {
    if (vec.len == 0) return VectorError.InvalidVectorLength;
    for (vec) |val| {
        if (!std.math.isFinite(val)) return VectorError.NonFiniteElement;
    }
}

/// Validates that `bytes` has a non-zero length divisible by 4 and every packed
/// little-endian f32 element is finite (no NaN or +/-Inf).
pub fn validateBytes(bytes: []const u8) VectorError!void {
    if (bytes.len == 0 or (bytes.len % 4) != 0) return VectorError.InvalidVectorLength;
    const count = bytes.len / 4;
    for (0..count) |i| {
        if (!std.math.isFinite(readElementLE(bytes, i))) return VectorError.NonFiniteElement;
    }
}

/// Derives the vector dimension from a packed float32 byte slice (`bytes.len / 4`).
pub fn dims(bytes: []const u8) usize {
    return bytes.len / 4;
}

fn validatePair(a: []const f32, b: []const f32) VectorError!void {
    if (a.len == 0 or b.len == 0) return VectorError.InvalidVectorLength;
    if (a.len != b.len) return VectorError.DimensionMismatch;
    try validateF32(a);
    try validateF32(b);
}

/// Computes the squared L2 norm of a validated f32 slice in f64 using strict
/// left-to-right target-independent summation.
pub fn normSquared(v: []const f32) VectorError!f64 {
    try validateF32(v);
    var i: usize = 0;
    var acc: f64 = 0.0;
    if (comptime simd_lanes > 1) {
        while (i + simd_lanes <= v.len) : (i += simd_lanes) {
            const vv: VecF64 = @as(VecF32, v[i..][0..simd_lanes].*);
            foldAddF64(&acc, vv * vv);
        }
    }
    while (i < v.len) : (i += 1) {
        const fx = @as(f64, v[i]);
        acc += fx * fx;
    }
    return acc;
}

/// Computes cosine distance for `dot_acc < 0` with non-zero squared norms.
inline fn obtuseCosineDistance(dot_acc: f64, na_sq: f64, nb_sq: f64) f64 {
    const prod = na_sq * nb_sq;
    const denom = if (std.math.isInf(prod)) @sqrt(na_sq) * @sqrt(nb_sq) else @sqrt(prod);
    if (denom == 0.0) return std.math.inf(f64);
    const cos = std.math.clamp(dot_acc / denom, -1.0, 0.0);
    return 1.0 - cos;
}

inline fn negateDistance(d: f64) f64 {
    if (d == 0.0) return 0.0;
    return -d;
}

/// Computes the inner (dot) product of two validated equal-length f32 slices
/// in f64 using strict left-to-right target-independent summation.
pub fn dot(a: []const f32, b: []const f32) VectorError!f64 {
    try validatePair(a, b);
    var i: usize = 0;
    var acc: f64 = 0.0;
    if (comptime simd_lanes > 1) {
        while (i + simd_lanes <= a.len) : (i += simd_lanes) {
            const av: VecF64 = @as(VecF32, a[i..][0..simd_lanes].*);
            const bv: VecF64 = @as(VecF32, b[i..][0..simd_lanes].*);
            foldAddF64(&acc, av * bv);
        }
    }
    while (i < a.len) : (i += 1) {
        acc += @as(f64, a[i]) * @as(f64, b[i]);
    }
    return acc;
}

/// Computes the Euclidean (L2) distance between two validated equal-length f32
/// slices in f64 using strict left-to-right target-independent summation.
pub fn l2Distance(a: []const f32, b: []const f32) VectorError!f64 {
    try validatePair(a, b);
    var i: usize = 0;
    var acc: f64 = 0.0;
    if (comptime simd_lanes > 1) {
        while (i + simd_lanes <= a.len) : (i += simd_lanes) {
            const av: VecF64 = @as(VecF32, a[i..][0..simd_lanes].*);
            const bv: VecF64 = @as(VecF32, b[i..][0..simd_lanes].*);
            const diff = av - bv;
            foldAddF64(&acc, diff * diff);
        }
    }
    while (i < a.len) : (i += 1) {
        const d = @as(f64, a[i]) - @as(f64, b[i]);
        acc += d * d;
    }
    return @sqrt(acc);
}

/// Computes the L2 norm of a validated f32 slice in f64.
pub fn l2Norm(v: []const f32) VectorError!f64 {
    return @sqrt(try normSquared(v));
}

/// Computes the cosine distance in f64 using a cancellation-free formulation:
/// for `dot(a, b) >= 0`, evaluates `0.5 * ||a/|a| - b/|b|||^2` (clamped to
/// `[0, 1]`) so near-parallel vectors (e.g. `[1, 0]` vs `[1, 2^-27]`) retain
/// full f64 precision without cancelling near `cos = 1`; for `dot(a, b) < 0`,
/// evaluates `1 - dot / sqrt(|a|^2 * |b|^2)`. Returns `+inf` if either vector
/// has zero norm.
pub fn cosineDistance(a: []const f32, b: []const f32) VectorError!f64 {
    try validatePair(a, b);
    var i: usize = 0;
    var dot_acc: f64 = 0.0;
    var na_acc: f64 = 0.0;
    var nb_acc: f64 = 0.0;
    if (comptime simd_lanes > 1) {
        while (i + simd_lanes <= a.len) : (i += simd_lanes) {
            const av: VecF64 = @as(VecF32, a[i..][0..simd_lanes].*);
            const bv: VecF64 = @as(VecF32, b[i..][0..simd_lanes].*);
            foldAddF64(&dot_acc, av * bv);
            foldAddF64(&na_acc, av * av);
            foldAddF64(&nb_acc, bv * bv);
        }
    }
    while (i < a.len) : (i += 1) {
        const fx = @as(f64, a[i]);
        const fy = @as(f64, b[i]);
        dot_acc += fx * fy;
        na_acc += fx * fx;
        nb_acc += fy * fy;
    }
    if (na_acc == 0.0 or nb_acc == 0.0) return std.math.inf(f64);
    if (dot_acc >= 0.0) {
        const na = @sqrt(na_acc);
        const nb = @sqrt(nb_acc);
        var j: usize = 0;
        var diff_sq: f64 = 0.0;
        if (comptime simd_lanes > 1) {
            const vna: VecF64 = @splat(na);
            const vnb: VecF64 = @splat(nb);
            while (j + simd_lanes <= a.len) : (j += simd_lanes) {
                const av: VecF64 = @as(VecF32, a[j..][0..simd_lanes].*);
                const bv: VecF64 = @as(VecF32, b[j..][0..simd_lanes].*);
                const d = (av / vna) - (bv / vnb);
                foldAddF64(&diff_sq, d * d);
            }
        }
        while (j < a.len) : (j += 1) {
            const d = (@as(f64, a[j]) / na) - (@as(f64, b[j]) / nb);
            diff_sq += d * d;
        }
        return std.math.clamp(0.5 * diff_sq, 0.0, 1.0);
    }
    return obtuseCosineDistance(dot_acc, na_acc, nb_acc);
}

/// Computes a uniform higher-is-more-similar score for any VectorMetric.
pub fn similarityScore(metric: VectorMetric, a: []const f32, b: []const f32) VectorError!f64 {
    return switch (metric) {
        .dot => dot(a, b),
        .l2 => negateDistance(try l2Distance(a, b)),
        .cosine => negateDistance(try cosineDistance(a, b)),
    };
}

/// Returns true if candidate `a` ranks strictly ahead of `b`:
/// higher score wins; equal scores tie-break by ascending key byte order.
pub fn hitIsBetter(a_score: f64, a_key: []const u8, b_score: f64, b_key: []const u8) bool {
    if (a_score != b_score) return a_score > b_score;
    return std.mem.order(u8, a_key, b_key) == .lt;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "encodeF32 produces little-endian packed bytes" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // IEEE-754 float32 1.0 = 0x3F800000 -> LE bytes: 00 00 80 3F
    const single = try encodeF32(alloc, &[_]f32{1.0});
    defer alloc.free(single);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x80, 0x3F }, single);

    // IEEE-754 float32 -2.0 = 0xC0000000 -> LE bytes: 00 00 00 C0
    const pair = try encodeF32(alloc, &[_]f32{ 1.0, -2.0 });
    defer alloc.free(pair);
    try testing.expectEqual(@as(usize, 8), pair.len);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x80, 0x3F, 0x00, 0x00, 0x00, 0xC0 }, pair);
}

test "decodeF32 round-trips arbitrary values including -0.0 and denormals" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const smallest_subnormal: f32 = @bitCast(@as(u32, 1));
    const neg_subnormal: f32 = @bitCast(@as(u32, 0x80000001));
    const input = [_]f32{
        0.0,
        -0.0,
        1.0,
        -1.0,
        smallest_subnormal,
        neg_subnormal,
        std.math.floatMin(f32),
        std.math.floatMax(f32),
        -std.math.floatMax(f32),
    };

    const bytes = try encodeF32(alloc, &input);
    defer alloc.free(bytes);

    const decoded = try decodeF32(alloc, bytes);
    defer alloc.free(decoded);

    try testing.expectEqual(input.len, decoded.len);
    for (input, decoded) |expected, actual| {
        try testing.expectEqual(@as(u32, @bitCast(expected)), @as(u32, @bitCast(actual)));
    }
}

test "decodeF32 and encodeF32 reject bad lengths" {
    const testing = std.testing;
    const alloc = testing.allocator;

    try testing.expectError(VectorError.InvalidVectorLength, encodeF32(alloc, &[_]f32{}));
    try testing.expectError(VectorError.InvalidVectorLength, decodeF32(alloc, ""));
    try testing.expectError(VectorError.InvalidVectorLength, decodeF32(alloc, &[_]u8{1}));
    try testing.expectError(VectorError.InvalidVectorLength, decodeF32(alloc, &[_]u8{ 1, 2 }));
    try testing.expectError(VectorError.InvalidVectorLength, decodeF32(alloc, &[_]u8{ 1, 2, 3 }));
    try testing.expectError(VectorError.InvalidVectorLength, decodeF32(alloc, &[_]u8{ 1, 2, 3, 4, 5 }));
    try testing.expectError(VectorError.InvalidVectorLength, decodeF32(alloc, &[_]u8{ 1, 2, 3, 4, 5, 6, 7 }));
}

test "validateF32, validateBytes, and encodeF32 reject non-finite elements" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const bad_vecs = [_][3]f32{
        .{ std.math.nan(f32), 0.0, 1.0 },
        .{ 0.0, std.math.inf(f32), 1.0 },
        .{ 0.0, 1.0, -std.math.inf(f32) },
    };

    for (bad_vecs) |vec| {
        try testing.expectError(VectorError.NonFiniteElement, validateF32(&vec));
        try testing.expectError(VectorError.NonFiniteElement, encodeF32(alloc, &vec));

        var raw: [12]u8 = undefined;
        for (vec, 0..) |v, i| {
            std.mem.writeInt(u32, raw[i * 4 ..][0..4], @bitCast(v), .little);
        }
        try testing.expectError(VectorError.NonFiniteElement, validateBytes(&raw));
    }

    try testing.expectError(VectorError.InvalidVectorLength, validateF32(&[_]f32{}));
    try testing.expectError(VectorError.InvalidVectorLength, validateBytes(""));
    try testing.expectError(VectorError.InvalidVectorLength, validateBytes(&[_]u8{ 1, 2, 3 }));
}

test "dims derives dimension from byte length" {
    const testing = std.testing;
    const twelve: [12]u8 = @splat(0);
    try testing.expectEqual(@as(usize, 0), dims(""));
    try testing.expectEqual(@as(usize, 1), dims(&[_]u8{ 0, 0, 0, 0 }));
    try testing.expectEqual(@as(usize, 3), dims(&twelve));
}

test "encodeF32/decodeF32 seeded round-trip fuzz" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const rng = prng.random();

    for (0..200) |_| {
        const len = rng.intRangeAtMost(usize, 1, 64);
        const vec = try alloc.alloc(f32, len);
        defer alloc.free(vec);
        for (vec) |*v| {
            v.* = (rng.float(f32) * 2.0 - 1.0) * 1000.0;
        }
        const bytes = try encodeF32(alloc, vec);
        defer alloc.free(bytes);
        try testing.expectEqual(len, dims(bytes));
        try validateBytes(bytes);
        const back = try decodeF32(alloc, bytes);
        defer alloc.free(back);
        try testing.expectEqualSlices(f32, vec, back);
    }
}

fn oracleDot(a: []const f32, b: []const f32) f64 {
    var s: f64 = 0.0;
    for (a, b) |x, y| s += @as(f64, x) * @as(f64, y);
    return s;
}

fn oracleL2(a: []const f32, b: []const f32) f64 {
    var s: f64 = 0.0;
    for (a, b) |x, y| {
        const d = @as(f64, x) - @as(f64, y);
        s += d * d;
    }
    return @sqrt(s);
}

fn oracleCosine(a: []const f32, b: []const f32) f64 {
    var d: f64 = 0.0;
    var na_sq: f64 = 0.0;
    var nb_sq: f64 = 0.0;
    for (a, b) |x, y| {
        const fx = @as(f64, x);
        const fy = @as(f64, y);
        d += fx * fy;
        na_sq += fx * fx;
        nb_sq += fy * fy;
    }
    if (na_sq == 0.0 or nb_sq == 0.0) return std.math.inf(f64);
    if (d >= 0.0) {
        const na = @sqrt(na_sq);
        const nb = @sqrt(nb_sq);
        var diff_sq: f64 = 0.0;
        for (a, b) |x, y| {
            const diff = (@as(f64, x) / na) - (@as(f64, y) / nb);
            diff_sq += diff * diff;
        }
        return std.math.clamp(0.5 * diff_sq, 0.0, 1.0);
    }
    const prod = na_sq * nb_sq;
    const denom = if (std.math.isInf(prod)) @sqrt(na_sq) * @sqrt(nb_sq) else @sqrt(prod);
    if (denom == 0.0) return std.math.inf(f64);
    const cos = std.math.clamp(d / denom, -1.0, 0.0);
    return 1.0 - cos;
}

test "dot, l2Distance, and cosineDistance match scalar oracle bit-for-bit" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(7);
    const rng = prng.random();

    const test_dims = [_]usize{ 1, 3, 4, 7, 8, 15, 16, 33, 64, 129 };
    for (test_dims) |d| {
        const a = try alloc.alloc(f32, d);
        defer alloc.free(a);
        const b = try alloc.alloc(f32, d);
        defer alloc.free(b);
        for (a) |*x| x.* = rng.float(f32) * 2.0 - 1.0;
        for (b) |*x| x.* = rng.float(f32) * 2.0 - 1.0;

        try testing.expectEqual(@as(u64, @bitCast(oracleDot(a, b))), @as(u64, @bitCast(try dot(a, b))));
        try testing.expectEqual(@as(u64, @bitCast(oracleL2(a, b))), @as(u64, @bitCast(try l2Distance(a, b))));
        try testing.expectEqual(@as(u64, @bitCast(oracleCosine(a, b))), @as(u64, @bitCast(try cosineDistance(a, b))));
    }
}

test "dot preserves scalar cancellation order across SIMD lanes" {
    const testing = std.testing;
    const big: f32 = std.math.ldexp(@as(f32, 1.0), 60);
    const query = [_]f32{ 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0 };
    const cancel_vec = [_]f32{ big, -big, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0 };
    const half_vec = [_]f32{ 0.5, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 };

    try testing.expectEqual(@as(f64, 1.0), try dot(&query, &cancel_vec));
    try testing.expectEqual(@as(f64, 0.5), try dot(&query, &half_vec));
}

test "cosine near parallel vectors never scores [1,1] worse against itself and distinguishes [1,0] vs [1,2^-27]" {
    const testing = std.testing;
    const v11 = [_]f32{ 1.0, 1.0 };
    const v33 = [_]f32{ 3.0, 3.0 };
    const perturbed = [_]f32{ 1.0, std.math.nextAfter(f32, 1.0, 2.0) };

    try testing.expectEqual(@as(f64, 0.0), try cosineDistance(&v11, &v11));
    try testing.expectEqual(@as(f64, 0.0), try similarityScore(.cosine, &v11, &v11));
    try testing.expect((try similarityScore(.cosine, &v11, &v11)) >= (try similarityScore(.cosine, &v11, &v33)));
    try testing.expect((try similarityScore(.cosine, &v11, &v11)) > (try similarityScore(.cosine, &v11, &perturbed)));
    try testing.expect((try similarityScore(.cosine, &v11, &v33)) > (try similarityScore(.cosine, &v11, &perturbed)));

    // [1, 0] vs [1, 2^-27]: naive 1 - dot/(|a||b|) rounds 1 + 2^-54 to 1 and ties them at 0.
    const exact = [_]f32{ 1.0, 0.0 };
    const near = [_]f32{ 1.0, std.math.ldexp(@as(f32, 1.0), -27) };
    const d_exact = try cosineDistance(&exact, &exact);
    const d_near = try cosineDistance(&exact, &near);
    try testing.expectEqual(@as(f64, 0.0), d_exact);
    try testing.expect(d_near > 0.0);
    try testing.expect((try similarityScore(.cosine, &exact, &exact)) > (try similarityScore(.cosine, &exact, &near)));
}

test "cosineDistance with zero vector returns +inf and -inf score without NaN" {
    const testing = std.testing;
    const zero = [_]f32{ 0.0, 0.0, 0.0, 0.0 };
    const unit = [_]f32{ 1.0, 0.0, 0.0, 0.0 };

    try testing.expect(std.math.isPositiveInf(try cosineDistance(&zero, &unit)));
    try testing.expect(std.math.isPositiveInf(try cosineDistance(&unit, &zero)));
    try testing.expect(std.math.isPositiveInf(try cosineDistance(&zero, &zero)));
    try testing.expect(std.math.isNegativeInf(try similarityScore(.cosine, &zero, &unit)));
}

test "public distance kernels reject empty, mismatched, and non-finite inputs" {
    const testing = std.testing;
    const a2 = [_]f32{ 1.0, 2.0 };
    const b3 = [_]f32{ 1.0, 2.0, 3.0 };
    const nan2 = [_]f32{ 1.0, std.math.nan(f32) };

    try testing.expectError(VectorError.InvalidVectorLength, dot(&[_]f32{}, &[_]f32{}));
    try testing.expectError(VectorError.DimensionMismatch, dot(&a2, &b3));
    try testing.expectError(VectorError.NonFiniteElement, dot(&a2, &nan2));
    try testing.expectError(VectorError.DimensionMismatch, l2Distance(&a2, &b3));
    try testing.expectError(VectorError.NonFiniteElement, cosineDistance(&nan2, &a2));
    try testing.expectError(VectorError.InvalidVectorLength, l2Norm(&[_]f32{}));
    try testing.expectError(VectorError.NonFiniteElement, l2Norm(&nan2));
}

test "kernels are bit-identical across repeated calls" {
    const testing = std.testing;
    const a = [_]f32{ 0.1, -0.2, 0.3, -0.4, 0.5, -0.6, 0.7, -0.8, 0.9 };
    const b = [_]f32{ -0.9, 0.8, -0.7, 0.6, -0.5, 0.4, -0.3, 0.2, -0.1 };

    try testing.expectEqual(@as(u64, @bitCast(try dot(&a, &b))), @as(u64, @bitCast(try dot(&a, &b))));
    try testing.expectEqual(@as(u64, @bitCast(try l2Distance(&a, &b))), @as(u64, @bitCast(try l2Distance(&a, &b))));
    try testing.expectEqual(@as(u64, @bitCast(try cosineDistance(&a, &b))), @as(u64, @bitCast(try cosineDistance(&a, &b))));
}
