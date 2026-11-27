//! tkrzw-zig: pure-Zig port of the tkrzw database library.
//!
//! ## Quick start
//!
//!   const db = try tkrzw.TinyDBM.init(std_file.asFile(), 0, allocator);
//!   defer db.deinit();
//!   _ = db.set("hello", "world", true, null);
//!
//! ## Public API
//!
//!   TinyDBM                — in-memory hash-table DBM with optional file persistence
//!   BabyDBM                — in-memory B+ tree DBM with ordered iteration
//!   SkipDBM                — sorted file-backed skip list DBM with ordered iteration
//!   CacheDBM               — in-memory hash-table DBM with LRU eviction
//!   HashDBM                — file-backed hash-table DBM with crash-safe updates
//!   TreeDBM                — file-backed B+ tree DBM with ordered iteration
//!   MemIndex               — in-memory secondary index backed by BabyDBM
//!   Status                 — result type returned by all operations
//!   Code                   — enum of status codes (success, not_found, etc.)
//!   RecordAction           — return value from record-processor callbacks
//!   UpdateLogger           — vtable interface for write-ahead / replication logging
//!   File                   — vtable interface for file I/O (implement for custom backends)
//!   StdFile                — concrete std.fs-backed File implementation
//!   OpenOptions            — flags controlling file open behaviour
//!   BloomFilter            — scalable, blocked, thread-safe probabilistic membership filter
//!   searchSimilar          — exact brute-force KNN vector search over PolyDBM
//!   findByVector           — byte-exact vector lookup over PolyDBM
//!   encodeF32 / decodeF32  — packed little-endian IEEE-754 float32 vector codec
//!   pairLexicalKeyComparator — key comparator for pair-based indices

const std = @import("std");

// ---------------------------------------------------------------------------
// Internal sub-modules (accessible as sub-namespaces for power users and
// to ensure refAllDeclsRecursive covers all test blocks).
// ---------------------------------------------------------------------------
pub const lib_common = @import("lib_common.zig");
pub const varint = @import("varint.zig");
pub const hash_util = @import("hash_util.zig");
pub const thread_util = @import("thread_util.zig");
pub const str_util = @import("str_util.zig");
pub const time_util = @import("time_util.zig");
pub const dbm = @import("dbm.zig");
pub const file = @import("file.zig");
pub const file_util = @import("file_util.zig");
pub const dbm_tiny = @import("dbm_tiny.zig");
pub const dbm_baby = @import("dbm_baby.zig");
pub const dbm_cache = @import("dbm_cache.zig");
pub const dbm_skip = @import("dbm_skip.zig");
pub const dbm_hash = @import("dbm_hash.zig");
pub const dbm_tree = @import("dbm_tree.zig");
pub const dbm_poly = @import("dbm_poly.zig");
pub const index = @import("index.zig");
pub const dbm_shard = @import("dbm_shard.zig");
pub const bloom = @import("bloom.zig");
pub const vector_util = @import("vector_util.zig");
pub const dbm_vector = @import("dbm_vector.zig");

// ---------------------------------------------------------------------------
// Flat re-exports — primary public API surface.
// ---------------------------------------------------------------------------
pub const TinyDBM = dbm_tiny.TinyDBM;
pub const BabyDBM = dbm_baby.BabyDBM;
pub const SkipDBM = dbm_skip.SkipDBM;
pub const CacheDBM = dbm_cache.CacheDBM;
pub const HashDBM = dbm_hash.HashDBM;
pub const TreeDBM = dbm_tree.TreeDBM;
pub const PolyDBM = dbm_poly.PolyDBM;
pub const PolyCursor = dbm_poly.PolyCursor;
pub const PolyIterator = dbm_poly.PolyIterator;
pub const PolyEntry = dbm_poly.Entry;
pub const BackendType = dbm_poly.BackendType;
pub const OpenOptionsPoly = dbm_poly.OpenOptionsPoly;
pub const MemIndex = index.MemIndex;
pub const BloomFilter = bloom.BloomFilter;
pub const ShardDBM = dbm_shard.ShardDBM;
pub const ShardCursor = dbm_shard.ShardCursor;
pub const ShardIterator = dbm_shard.ShardIterator;
pub const ShardEntry = dbm_shard.Entry;

// Vector codec and exact KNN search API.
pub const VectorMetric = vector_util.VectorMetric;
pub const VectorError = vector_util.VectorError;
pub const KnnHit = vector_util.KnnHit;
pub const encodeF32 = vector_util.encodeF32;
pub const decodeF32 = vector_util.decodeF32;
pub const validateF32 = vector_util.validateF32;
pub const validateBytes = vector_util.validateBytes;
pub const vectorDims = vector_util.dims;
pub const SearchOptions = dbm_vector.SearchOptions;
pub const KnnResult = dbm_vector.KnnResult;
pub const FindResult = dbm_vector.FindResult;
pub const searchSimilar = dbm_vector.searchSimilar;
pub const findByVector = dbm_vector.findByVector;
pub const findByVectorBytes = dbm_vector.findByVectorBytes;

pub const Status = lib_common.Status;
pub const Code = lib_common.Code;

pub const RecordAction = dbm.RecordAction;
pub const UpdateLogger = dbm.UpdateLogger;
pub const CompareExpected = dbm.CompareExpected;
pub const CompareDesired = dbm.CompareDesired;
pub const CompareExpectedEntry = dbm.CompareExpectedEntry;
pub const CompareDesiredEntry = dbm.CompareDesiredEntry;

pub const File = file.File;
pub const StdFile = file.StdFile;
pub const OpenOptions = file.OpenOptions;

// Primary key comparators.
pub const lexicalKeyComparator         = lib_common.lexicalKeyComparator;
pub const lexicalCaseKeyComparator     = lib_common.lexicalCaseKeyComparator;
pub const decimalKeyComparator         = lib_common.decimalKeyComparator;
pub const hexadecimalKeyComparator     = lib_common.hexadecimalKeyComparator;
pub const realNumberKeyComparator      = lib_common.realNumberKeyComparator;
pub const signedBigEndianKeyComparator = lib_common.signedBigEndianKeyComparator;
pub const floatBigEndianKeyComparator  = lib_common.floatBigEndianKeyComparator;

// Pair key comparators for secondary indices.
pub const pairLexicalKeyComparator = lib_common.pairLexicalKeyComparator;
pub const pairLexicalCaseKeyComparator = lib_common.pairLexicalCaseKeyComparator;
pub const pairDecimalKeyComparator = lib_common.pairDecimalKeyComparator;
pub const pairHexadecimalKeyComparator = lib_common.pairHexadecimalKeyComparator;
pub const pairRealNumberKeyComparator = lib_common.pairRealNumberKeyComparator;
pub const pairSignedBigEndianKeyComparator = lib_common.pairSignedBigEndianKeyComparator;
pub const pairFloatBigEndianKeyComparator = lib_common.pairFloatBigEndianKeyComparator;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
test {
    std.testing.refAllDecls(@This());
}

test "BloomFilter accessible via root re-export" {
    // Smoke test: verify BloomFilter is accessible through the flat re-export
    // path (tkrzw.BloomFilter) and the sub-namespace path (tkrzw.bloom.BloomFilter).
    var f = try BloomFilter.init(std.testing.allocator, .{});
    defer f.deinit();
    try f.add(std.testing.io, "tkrzw");
    try std.testing.expect(f.mightContain(std.testing.io, "tkrzw"));
    try std.testing.expect(!f.mightContain(std.testing.io, "not-inserted"));
    // Also verify sub-namespace path compiles.
    const SubNs: type = bloom.BloomFilter;
    _ = SubNs;
}
