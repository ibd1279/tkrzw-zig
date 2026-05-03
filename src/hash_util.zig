const std = @import("std");

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
