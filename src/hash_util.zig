const std = @import("std");

/// 128-bit hash result, returned by `hashMurmur3_128`.
///
/// `h1` is suitable for selecting a block (e.g. `h1 % num_blocks`) and `h2`
/// can serve as the base of a Kirsch-Mitzenmacher derivation
/// (`h2 +% i *% h1`) when multiple independent hash values are needed.
pub const Hash128 = struct { h1: u64, h2: u64 };

/// MurmurHash3_x64_128 (Austin Appleby), 128-bit variant for 64-bit platforms.
///
/// This is a non-cryptographic, deterministic hash. It is used for the
/// blocked bloom filter; it is intentionally NOT used by any DBM module.
/// The legacy MurmurHash2 (`hashMurmur` below) is retained unchanged because
/// it is wired into the existing tkrzw on-disk file formats.
///
/// **Security note**: MurmurHash3 is not HashDoS-resistant. When called with
/// a fixed seed (as `BloomFilter` does, seed=0), an adversary who controls
/// the input keys can craft collisions that degrade filter accuracy. Do not
/// use with adversarially controlled keys in security-sensitive contexts.
///
/// Reference: https://github.com/aappleby/smhasher/blob/master/src/MurmurHash3.cpp
pub fn hashMurmur3_128(data: []const u8, seed: u64) Hash128 {
    // Constants from Austin Appleby's smhasher reference implementation.
    const c1: u64 = 0x87c37b91114253d5;
    const c2: u64 = 0x4cf5ad432745937f;

    var h1: u64 = seed;
    var h2: u64 = seed;

    var rp: usize = 0;
    var remaining: usize = data.len;

    // Body: process 16-byte blocks.
    while (remaining >= 16) : ({
        rp += 16;
        remaining -= 16;
    }) {
        var k1: u64 = std.mem.readInt(u64, data[rp..][0..8], .little);
        var k2: u64 = std.mem.readInt(u64, data[rp + 8 ..][0..8], .little);

        k1 *%= c1;
        k1 = std.math.rotl(u64, k1, 31);
        k1 *%= c2;
        h1 ^= k1;

        h1 = std.math.rotl(u64, h1, 27);
        h1 +%= h2;
        h1 = h1 *% 5 +% 0x52dce729;

        k2 *%= c2;
        k2 = std.math.rotl(u64, k2, 33);
        k2 *%= c1;
        h2 ^= k2;

        h2 = std.math.rotl(u64, h2, 31);
        h2 +%= h1;
        h2 = h2 *% 5 +% 0x38495ab5;
    }

    // Tail: 0..15 trailing bytes. Zig has no switch fall-through, so each
    // case accumulates every applicable byte explicitly. Bytes at indices
    // 0..7 contribute to k1; bytes at indices 8..15 contribute to k2.
    var k1: u64 = 0;
    var k2: u64 = 0;
    switch (remaining) {
        15 => {
            k2 ^= @as(u64, data[rp + 14]) << 48;
            k2 ^= @as(u64, data[rp + 13]) << 40;
            k2 ^= @as(u64, data[rp + 12]) << 32;
            k2 ^= @as(u64, data[rp + 11]) << 24;
            k2 ^= @as(u64, data[rp + 10]) << 16;
            k2 ^= @as(u64, data[rp + 9]) << 8;
            k2 ^= @as(u64, data[rp + 8]);
            k1 ^= @as(u64, data[rp + 7]) << 56;
            k1 ^= @as(u64, data[rp + 6]) << 48;
            k1 ^= @as(u64, data[rp + 5]) << 40;
            k1 ^= @as(u64, data[rp + 4]) << 32;
            k1 ^= @as(u64, data[rp + 3]) << 24;
            k1 ^= @as(u64, data[rp + 2]) << 16;
            k1 ^= @as(u64, data[rp + 1]) << 8;
            k1 ^= @as(u64, data[rp + 0]);
        },
        14 => {
            k2 ^= @as(u64, data[rp + 13]) << 40;
            k2 ^= @as(u64, data[rp + 12]) << 32;
            k2 ^= @as(u64, data[rp + 11]) << 24;
            k2 ^= @as(u64, data[rp + 10]) << 16;
            k2 ^= @as(u64, data[rp + 9]) << 8;
            k2 ^= @as(u64, data[rp + 8]);
            k1 ^= @as(u64, data[rp + 7]) << 56;
            k1 ^= @as(u64, data[rp + 6]) << 48;
            k1 ^= @as(u64, data[rp + 5]) << 40;
            k1 ^= @as(u64, data[rp + 4]) << 32;
            k1 ^= @as(u64, data[rp + 3]) << 24;
            k1 ^= @as(u64, data[rp + 2]) << 16;
            k1 ^= @as(u64, data[rp + 1]) << 8;
            k1 ^= @as(u64, data[rp + 0]);
        },
        13 => {
            k2 ^= @as(u64, data[rp + 12]) << 32;
            k2 ^= @as(u64, data[rp + 11]) << 24;
            k2 ^= @as(u64, data[rp + 10]) << 16;
            k2 ^= @as(u64, data[rp + 9]) << 8;
            k2 ^= @as(u64, data[rp + 8]);
            k1 ^= @as(u64, data[rp + 7]) << 56;
            k1 ^= @as(u64, data[rp + 6]) << 48;
            k1 ^= @as(u64, data[rp + 5]) << 40;
            k1 ^= @as(u64, data[rp + 4]) << 32;
            k1 ^= @as(u64, data[rp + 3]) << 24;
            k1 ^= @as(u64, data[rp + 2]) << 16;
            k1 ^= @as(u64, data[rp + 1]) << 8;
            k1 ^= @as(u64, data[rp + 0]);
        },
        12 => {
            k2 ^= @as(u64, data[rp + 11]) << 24;
            k2 ^= @as(u64, data[rp + 10]) << 16;
            k2 ^= @as(u64, data[rp + 9]) << 8;
            k2 ^= @as(u64, data[rp + 8]);
            k1 ^= @as(u64, data[rp + 7]) << 56;
            k1 ^= @as(u64, data[rp + 6]) << 48;
            k1 ^= @as(u64, data[rp + 5]) << 40;
            k1 ^= @as(u64, data[rp + 4]) << 32;
            k1 ^= @as(u64, data[rp + 3]) << 24;
            k1 ^= @as(u64, data[rp + 2]) << 16;
            k1 ^= @as(u64, data[rp + 1]) << 8;
            k1 ^= @as(u64, data[rp + 0]);
        },
        11 => {
            k2 ^= @as(u64, data[rp + 10]) << 16;
            k2 ^= @as(u64, data[rp + 9]) << 8;
            k2 ^= @as(u64, data[rp + 8]);
            k1 ^= @as(u64, data[rp + 7]) << 56;
            k1 ^= @as(u64, data[rp + 6]) << 48;
            k1 ^= @as(u64, data[rp + 5]) << 40;
            k1 ^= @as(u64, data[rp + 4]) << 32;
            k1 ^= @as(u64, data[rp + 3]) << 24;
            k1 ^= @as(u64, data[rp + 2]) << 16;
            k1 ^= @as(u64, data[rp + 1]) << 8;
            k1 ^= @as(u64, data[rp + 0]);
        },
        10 => {
            k2 ^= @as(u64, data[rp + 9]) << 8;
            k2 ^= @as(u64, data[rp + 8]);
            k1 ^= @as(u64, data[rp + 7]) << 56;
            k1 ^= @as(u64, data[rp + 6]) << 48;
            k1 ^= @as(u64, data[rp + 5]) << 40;
            k1 ^= @as(u64, data[rp + 4]) << 32;
            k1 ^= @as(u64, data[rp + 3]) << 24;
            k1 ^= @as(u64, data[rp + 2]) << 16;
            k1 ^= @as(u64, data[rp + 1]) << 8;
            k1 ^= @as(u64, data[rp + 0]);
        },
        9 => {
            k2 ^= @as(u64, data[rp + 8]);
            k1 ^= @as(u64, data[rp + 7]) << 56;
            k1 ^= @as(u64, data[rp + 6]) << 48;
            k1 ^= @as(u64, data[rp + 5]) << 40;
            k1 ^= @as(u64, data[rp + 4]) << 32;
            k1 ^= @as(u64, data[rp + 3]) << 24;
            k1 ^= @as(u64, data[rp + 2]) << 16;
            k1 ^= @as(u64, data[rp + 1]) << 8;
            k1 ^= @as(u64, data[rp + 0]);
        },
        8 => {
            k1 ^= @as(u64, data[rp + 7]) << 56;
            k1 ^= @as(u64, data[rp + 6]) << 48;
            k1 ^= @as(u64, data[rp + 5]) << 40;
            k1 ^= @as(u64, data[rp + 4]) << 32;
            k1 ^= @as(u64, data[rp + 3]) << 24;
            k1 ^= @as(u64, data[rp + 2]) << 16;
            k1 ^= @as(u64, data[rp + 1]) << 8;
            k1 ^= @as(u64, data[rp + 0]);
        },
        7 => {
            k1 ^= @as(u64, data[rp + 6]) << 48;
            k1 ^= @as(u64, data[rp + 5]) << 40;
            k1 ^= @as(u64, data[rp + 4]) << 32;
            k1 ^= @as(u64, data[rp + 3]) << 24;
            k1 ^= @as(u64, data[rp + 2]) << 16;
            k1 ^= @as(u64, data[rp + 1]) << 8;
            k1 ^= @as(u64, data[rp + 0]);
        },
        6 => {
            k1 ^= @as(u64, data[rp + 5]) << 40;
            k1 ^= @as(u64, data[rp + 4]) << 32;
            k1 ^= @as(u64, data[rp + 3]) << 24;
            k1 ^= @as(u64, data[rp + 2]) << 16;
            k1 ^= @as(u64, data[rp + 1]) << 8;
            k1 ^= @as(u64, data[rp + 0]);
        },
        5 => {
            k1 ^= @as(u64, data[rp + 4]) << 32;
            k1 ^= @as(u64, data[rp + 3]) << 24;
            k1 ^= @as(u64, data[rp + 2]) << 16;
            k1 ^= @as(u64, data[rp + 1]) << 8;
            k1 ^= @as(u64, data[rp + 0]);
        },
        4 => {
            k1 ^= @as(u64, data[rp + 3]) << 24;
            k1 ^= @as(u64, data[rp + 2]) << 16;
            k1 ^= @as(u64, data[rp + 1]) << 8;
            k1 ^= @as(u64, data[rp + 0]);
        },
        3 => {
            k1 ^= @as(u64, data[rp + 2]) << 16;
            k1 ^= @as(u64, data[rp + 1]) << 8;
            k1 ^= @as(u64, data[rp + 0]);
        },
        2 => {
            k1 ^= @as(u64, data[rp + 1]) << 8;
            k1 ^= @as(u64, data[rp + 0]);
        },
        1 => {
            k1 ^= @as(u64, data[rp + 0]);
        },
        else => {},
    }

    if (remaining > 8) {
        k2 *%= c2;
        k2 = std.math.rotl(u64, k2, 33);
        k2 *%= c1;
        h2 ^= k2;
    }
    if (remaining > 0) {
        k1 *%= c1;
        k1 = std.math.rotl(u64, k1, 31);
        k1 *%= c2;
        h1 ^= k1;
    }

    // Finalization.
    h1 ^= @as(u64, data.len);
    h2 ^= @as(u64, data.len);

    h1 +%= h2;
    h2 +%= h1;

    h1 = fmix64(h1);
    h2 = fmix64(h2);

    h1 +%= h2;
    h2 +%= h1;

    return Hash128{ .h1 = h1, .h2 = h2 };
}

/// MurmurHash3 64-bit finalization mixer.
fn fmix64(k_in: u64) u64 {
    var k = k_in;
    k ^= k >> 33;
    k *%= 0xff51afd7ed558ccd;
    k ^= k >> 33;
    k *%= 0xc4ceb9fe1a85ec53;
    k ^= k >> 33;
    return k;
}

/// MurmurHash2 64-bit, matching tkrzw::HashMurmur.
///
/// Uses wrapping arithmetic throughout to replicate C++ unsigned overflow.
pub fn hashMurmur(data: []const u8, seed: u64) u64 {
    const mul: u64 = 0xc6a4a7935bd1e995;
    const rtt: u6 = 47;

    var hash: u64 = seed ^ (@as(u64, data.len) *% mul);
    var rp: usize = 0;
    var remaining: usize = data.len;

    while (remaining >= 8) : ({
        rp += 8;
        remaining -= 8;
    }) {
        var num: u64 =
            (@as(u64, data[rp + 0])) |
            (@as(u64, data[rp + 1]) << 8) |
            (@as(u64, data[rp + 2]) << 16) |
            (@as(u64, data[rp + 3]) << 24) |
            (@as(u64, data[rp + 4]) << 32) |
            (@as(u64, data[rp + 5]) << 40) |
            (@as(u64, data[rp + 6]) << 48) |
            (@as(u64, data[rp + 7]) << 56);
        num = num *% mul;
        num ^= num >> rtt;
        num = num *% mul;
        hash = hash *% mul;
        hash ^= num;
    }

    // Handle the trailing bytes using fall-through accumulation.
    // Each case adds the contribution of one byte at successively lower shifts,
    // then falls through to handle the bytes below it. This mirrors the C++
    // switch fall-through exactly.
    switch (remaining) {
        7 => {
            hash ^= @as(u64, data[rp + 6]) << 48;
            hash ^= @as(u64, data[rp + 5]) << 40;
            hash ^= @as(u64, data[rp + 4]) << 32;
            hash ^= @as(u64, data[rp + 3]) << 24;
            hash ^= @as(u64, data[rp + 2]) << 16;
            hash ^= @as(u64, data[rp + 1]) << 8;
            hash ^= @as(u64, data[rp + 0]);
            hash = hash *% mul;
        },
        6 => {
            hash ^= @as(u64, data[rp + 5]) << 40;
            hash ^= @as(u64, data[rp + 4]) << 32;
            hash ^= @as(u64, data[rp + 3]) << 24;
            hash ^= @as(u64, data[rp + 2]) << 16;
            hash ^= @as(u64, data[rp + 1]) << 8;
            hash ^= @as(u64, data[rp + 0]);
            hash = hash *% mul;
        },
        5 => {
            hash ^= @as(u64, data[rp + 4]) << 32;
            hash ^= @as(u64, data[rp + 3]) << 24;
            hash ^= @as(u64, data[rp + 2]) << 16;
            hash ^= @as(u64, data[rp + 1]) << 8;
            hash ^= @as(u64, data[rp + 0]);
            hash = hash *% mul;
        },
        4 => {
            hash ^= @as(u64, data[rp + 3]) << 24;
            hash ^= @as(u64, data[rp + 2]) << 16;
            hash ^= @as(u64, data[rp + 1]) << 8;
            hash ^= @as(u64, data[rp + 0]);
            hash = hash *% mul;
        },
        3 => {
            hash ^= @as(u64, data[rp + 2]) << 16;
            hash ^= @as(u64, data[rp + 1]) << 8;
            hash ^= @as(u64, data[rp + 0]);
            hash = hash *% mul;
        },
        2 => {
            hash ^= @as(u64, data[rp + 1]) << 8;
            hash ^= @as(u64, data[rp + 0]);
            hash = hash *% mul;
        },
        1 => {
            hash ^= @as(u64, data[rp + 0]);
            hash = hash *% mul;
        },
        else => {},
    }

    hash ^= hash >> rtt;
    hash = hash *% mul;
    hash ^= hash >> rtt;
    return hash;
}

/// FNV-1a 64-bit hash, matching tkrzw::HashFNV.
pub fn hashFNV(data: []const u8) u64 {
    var hash: u64 = 14695981039346656037;
    for (data) |byte| {
        // Multiplier matches tkrzw HashFNV verbatim. (The canonical FNV-1a
        // 64-bit prime is 1099511628211; tkrzw uses this variant intentionally.)
        hash = (hash ^ @as(u64, byte)) *% 109951162811;
    }
    return hash;
}

/// Returns true iff num is prime.
pub fn isPrimeNumber(num: u64) bool {
    if (num < 2) return false;
    if (num == 2) return true;
    if (num % 2 == 0) return false;
    var i: u64 = 3;
    // Use i <= num / i to avoid overflow when i*i would exceed u64 max.
    while (i <= num / i) : (i += 2) {
        if (num % i == 0) return false;
    }
    return true;
}

/// Returns the bucket size to use for a hash table.
///
/// For min_size <= 100 returns max(min_size, 1). Otherwise returns the
/// smallest prime >= min_size, matching tkrzw::GetHashBucketSize.
pub fn getHashBucketSize(min_size: i64) i64 {
    if (min_size <= 100) return @max(min_size, 1);
    var num: i64 = min_size;
    while (num < std.math.maxInt(i64)) {
        if (isPrimeNumber(@intCast(num))) return num;
        num += 1;
    }
    return min_size;
}

/// FNV-1a hash with shard folding, matching tkrzw::SecondaryHash.
///
/// When num_shards fits in a u32, the 64-bit FNV hash is folded to improve
/// distribution across the narrower shard range, matching the C++
/// implementation in tkrzw_dbm_common_impl.h.
pub fn secondaryHash(data: []const u8, num_shards: u64) u64 {
    var hash = hashFNV(data);
    if (num_shards <= std.math.maxInt(u32)) {
        hash =
            (((hash & 0xffff000000000000) >> 48) | ((hash & 0x0000ffff00000000) >> 16)) ^
            (((hash & 0x000000000000ffff) << 16) | ((hash & 0x00000000ffff0000) >> 16));
    }
    return hash % num_shards;
}

/// MurmurHash with bucket folding, matching tkrzw::PrimaryHash.
///
/// When num_buckets fits in a u32, the 64-bit hash is folded to improve
/// distribution across the narrower bucket range.
pub fn primaryHash(data: []const u8, num_buckets: u64) u64 {
    const seed: u64 = 19780211;
    var hash = hashMurmur(data, seed);
    if (num_buckets <= std.math.maxInt(u32)) {
        hash =
            (((hash & 0xffff000000000000) >> 48) | ((hash & 0x0000ffff00000000) >> 16)) ^
            (((hash & 0x000000000000ffff) << 16) | ((hash & 0x00000000ffff0000) >> 16));
    }
    return hash % num_buckets;
}

test "hashMurmur is deterministic and non-trivial" {
    const h1 = hashMurmur("hello", 0);
    const h2 = hashMurmur("hello", 0);
    const h3 = hashMurmur("world", 0);
    try std.testing.expectEqual(h1, h2);
    try std.testing.expect(h1 != h3);
}

test "hashMurmur empty input" {
    // Must not crash and must be deterministic.
    const h = hashMurmur("", 0);
    try std.testing.expectEqual(h, hashMurmur("", 0));
}

test "hashMurmur seed affects output" {
    const h0 = hashMurmur("test", 0);
    const h1 = hashMurmur("test", 1);
    try std.testing.expect(h0 != h1);
}

test "primaryHash result is in [0, num_buckets)" {
    const data = "somekey";
    const buckets: u64 = 1000;
    const h = primaryHash(data, buckets);
    try std.testing.expect(h < buckets);
}

test "primaryHash with large bucket count stays in range" {
    const data = "anotherkey";
    const buckets: u64 = 0x1_0000_0001; // exceeds u32
    const h = primaryHash(data, buckets);
    try std.testing.expect(h < buckets);
}

test "secondaryHash result is in [0, num_shards)" {
    const inputs = [_][]const u8{ "", "a", "shardkey", "another-longer-key-value" };
    const shard_counts = [_]u64{ 1, 2, 7, 1000, 0xFFFFFFFF, 0x1_0000_0001 };
    for (inputs) |data| {
        for (shard_counts) |n| {
            const h = secondaryHash(data, n);
            try std.testing.expect(h < n);
        }
    }
}

test "secondaryHash is deterministic" {
    const data = "deterministic-key";
    const n: u64 = 997;
    const h1 = secondaryHash(data, n);
    const h2 = secondaryHash(data, n);
    try std.testing.expectEqual(h1, h2);
}

test "secondaryHash bit-folding differs from plain modulo for small num_shards" {
    // With num_shards <= u32, folding is applied. Verify at least one input
    // produces a different result than the unfolded FNV % num_shards would.
    const shards: u64 = 1000;
    const inputs = [_][]const u8{ "abc", "hello", "shardkey", "tkrzw", "another" };
    var any_diff = false;
    for (inputs) |data| {
        const folded = secondaryHash(data, shards);
        const plain = hashFNV(data) % shards;
        if (folded != plain) {
            any_diff = true;
            break;
        }
    }
    try std.testing.expect(any_diff);
}

test "secondaryHash skips folding when num_shards exceeds u32" {
    // For num_shards > u32 max, folding must not be applied: the result must
    // equal the raw FNV hash modulo num_shards.
    const data = "largeshardkey";
    const shards: u64 = 0x1_0000_0001;
    const expected = hashFNV(data) % shards;
    try std.testing.expectEqual(expected, secondaryHash(data, shards));
}

test "getHashBucketSize small values" {
    try std.testing.expectEqual(@as(i64, 1), getHashBucketSize(0));
    try std.testing.expectEqual(@as(i64, 1), getHashBucketSize(1));
    try std.testing.expectEqual(@as(i64, 50), getHashBucketSize(50));
    try std.testing.expectEqual(@as(i64, 100), getHashBucketSize(100));
}

test "getHashBucketSize returns next prime above 100" {
    // 101 is prime, so min_size=101 should return 101.
    try std.testing.expectEqual(@as(i64, 101), getHashBucketSize(101));
    // 102 is not prime; next prime is 103.
    try std.testing.expectEqual(@as(i64, 103), getHashBucketSize(102));
}

test "isPrimeNumber correctness" {
    try std.testing.expect(!isPrimeNumber(0));
    try std.testing.expect(!isPrimeNumber(1));
    try std.testing.expect(isPrimeNumber(2));
    try std.testing.expect(isPrimeNumber(3));
    try std.testing.expect(!isPrimeNumber(4));
    try std.testing.expect(isPrimeNumber(101));
    try std.testing.expect(!isPrimeNumber(100));
}

// Verified against smhasher MurmurHash3_x64_128 (Austin Appleby).
test "hashMurmur3_128: reference vector empty seed=0" {
    const r = hashMurmur3_128("", 0);
    try std.testing.expectEqual(@as(u64, 0x0000000000000000), r.h1);
    try std.testing.expectEqual(@as(u64, 0x0000000000000000), r.h2);
}

test "hashMurmur3_128: reference vector hello seed=0" {
    // 5-byte input exercises the pure-tail (no full block) path.
    const r = hashMurmur3_128("hello", 0);
    try std.testing.expectEqual(@as(u64, 0xcbd8a7b341bd9b02), r.h1);
    try std.testing.expectEqual(@as(u64, 0x5b1e906a48ae1d19), r.h2);
}

test "hashMurmur3_128: reference vector 15 bytes seed=0" {
    // Maximum-length tail (15 bytes, all k2+k1 tail branches active).
    const r = hashMurmur3_128("aaaaaaaaaaaaaaa", 0);
    try std.testing.expectEqual(@as(u64, 0x7d07a8dbfd2e7fbc), r.h1);
    try std.testing.expectEqual(@as(u64, 0x8fa8044aa85ff959), r.h2);
}

test "hashMurmur3_128: reference vector 16 bytes seed=0" {
    // Exactly one 16-byte block, no tail bytes.
    const r = hashMurmur3_128("aaaaaaaaaaaaaaaa", 0);
    try std.testing.expectEqual(@as(u64, 0xf2c1180d62aaa6ce), r.h1);
    try std.testing.expectEqual(@as(u64, 0x6af6f3032bb23942), r.h2);
}

test "hashMurmur3_128: reference vector 32 bytes seed=0" {
    // Two full 16-byte blocks, no tail bytes.
    const r = hashMurmur3_128("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 0);
    try std.testing.expectEqual(@as(u64, 0xe5f99e2780696aed), r.h1);
    try std.testing.expectEqual(@as(u64, 0x77ced13066ddfb5b), r.h2);
}

test "hashMurmur3_128: all tail lengths 1..15 produce distinct hashes" {
    var results: [15]Hash128 = undefined;
    for (1..16) |len| {
        var buf: [15]u8 = undefined;
        @memset(buf[0..len], 'a');
        const r = hashMurmur3_128(buf[0..len], 0);
        // Each result must be deterministic.
        const r2 = hashMurmur3_128(buf[0..len], 0);
        try std.testing.expectEqual(r.h1, r2.h1);
        try std.testing.expectEqual(r.h2, r2.h2);
        results[len - 1] = r;
    }
    // All 15 results must be pairwise distinct.
    for (0..15) |i| {
        for (i + 1..15) |j| {
            try std.testing.expect(
                results[i].h1 != results[j].h1 or results[i].h2 != results[j].h2,
            );
        }
    }
}

test "hashMurmur3_128: byte order sensitivity" {
    // Guards against accidental native-endian reads instead of little-endian.
    const a = hashMurmur3_128(&[_]u8{ 0x01, 0x02 }, 0);
    const b = hashMurmur3_128(&[_]u8{ 0x02, 0x01 }, 0);
    try std.testing.expect(a.h1 != b.h1);
}

test "hashMurmur3_128: deterministic" {
    const r1 = hashMurmur3_128("deterministic", 42);
    const r2 = hashMurmur3_128("deterministic", 42);
    try std.testing.expectEqual(r1.h1, r2.h1);
    try std.testing.expectEqual(r1.h2, r2.h2);
}

test "hashMurmur3_128: seed sensitivity" {
    const r0 = hashMurmur3_128("test", 0);
    const r1 = hashMurmur3_128("test", 1);
    try std.testing.expect(r0.h1 != r1.h1);
}

test "hashMurmur3_128: distinct keys produce distinct hashes" {
    const rh = hashMurmur3_128("hello", 0);
    const rw = hashMurmur3_128("world", 0);
    const re = hashMurmur3_128("", 0);
    try std.testing.expect(rh.h1 != rw.h1 or rh.h2 != rw.h2);
    try std.testing.expect(rh.h1 != re.h1 or rh.h2 != re.h2);
    try std.testing.expect(rw.h1 != re.h1 or rw.h2 != re.h2);
}

test "hashMurmur3_128: tail boundary length 8 vs 9" {
    // Exercises the if (remaining > 8) guard that mixes k2.
    // remaining==8: k2 must NOT be mixed; remaining==9: k2 MUST be mixed.
    // Vectors verified against the C reference (MurmurHash3.cpp, seed=0).
    const r8 = hashMurmur3_128("abcdefgh", 0);
    const r9 = hashMurmur3_128("abcdefghi", 0);
    try std.testing.expectEqual(@as(u64, 0xcc8a0ab037ef8c02), r8.h1);
    try std.testing.expectEqual(@as(u64, 0x48890d60eb6940a1), r8.h2);
    try std.testing.expectEqual(@as(u64, 0x0547c0cff13c7964), r9.h1);
    try std.testing.expectEqual(@as(u64, 0x79b53df5b741e033), r9.h2);
    // Also confirm the two must differ (guards against collapsed k2-mix logic).
    try std.testing.expect(r8.h1 != r9.h1 or r8.h2 != r9.h2);
    // Determinism at the boundary.
    try std.testing.expectEqual(r8.h1, hashMurmur3_128("abcdefgh", 0).h1);
    try std.testing.expectEqual(r9.h1, hashMurmur3_128("abcdefghi", 0).h1);
}

test "hashMurmur3_128: avalanche" {
    const key: []const u8 = &[_]u8{ 'h', 'e', 'l', 'l', 'o' };
    const modified: []const u8 = &[_]u8{ 'h' ^ 1, 'e', 'l', 'l', 'o' };
    const ra = hashMurmur3_128(key, 0);
    const rb = hashMurmur3_128(modified, 0);
    const diff_bits: usize =
        @as(usize, @popCount(ra.h1 ^ rb.h1)) +
        @as(usize, @popCount(ra.h2 ^ rb.h2));
    // Require >=48/128 bits to differ (37.5%) — generous but catches a
    // severely broken or missing finalization step.
    try std.testing.expect(diff_bits >= 48);
}
