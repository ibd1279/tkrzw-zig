# tkrzw-zig

A pure-Zig port of [tkrzw](https://dbmx.net/tkrzw/), a high-performance key-value database library.

## Database Implementations

This library provides **six database managers**, a **sharding wrapper**, and a **unified wrapper**:

### In-Memory Databases

- **TinyDBM** — Hash-table based with optional file persistence
- **BabyDBM** — B+ tree based with ordered iteration
- **CacheDBM** — Hash-table based with LRU eviction

### File-Backed Databases

- **HashDBM** — Hash-table based with crash-safe updates
- **TreeDBM** — B+ tree based with ordered iteration
- **SkipDBM** — Skip list based with ordered iteration

### Unified Wrapper

- **PolyDBM** — Type-erased wrapper that auto-selects backend from file extension

### Sharding Wrapper

- **ShardDBM** — Horizontal sharding across multiple PolyDBM instances with heap-merge iteration

## Features

- **No external dependencies** — Pure Zig implementation, no C bindings
- **Multiple backends** — Choose the right data structure for your workload
- **Optional persistence** — Write-ahead logging and snapshot file support
- **Concurrent safe** — Mutex-protected access
- **Flexible I/O** — Pluggable File interface for custom storage backends
- **Record processing** — Iterator callbacks for bulk operations
- **Type erasure** — PolyDBM provides unified API across all backends
- **Sharding** — ShardDBM partitions data across multiple DBMs by key hash
- **Exact vector search (KNN)** — `searchSimilar` and `findByVector` over packed little-endian `float32` values across all backends

## Quick Start

### Using a Specific Database

```zig
const tkrzw = @import("tkrzw");

// TinyDBM - in-memory hash table
const db = try tkrzw.TinyDBM.init(std_file.asFile(), 0, allocator);
defer db.deinit();

try db.set("hello", "world", true, null);
const value = try db.get("hello", allocator);
defer allocator.free(value);
```

### Using PolyDBM (Auto-Select Backend)

```zig
const tkrzw = @import("tkrzw");

// Backend automatically selected from file extension
// .tkh = HashDBM, .tkt = TreeDBM, .tks = SkipDBM
// .tkmt = TinyDBM, .tkmb = BabyDBM, .tkmc = CacheDBM
const db = try tkrzw.PolyDBM.open("data.tkh", .{ .writable = true }, io, allocator);
defer db.deinit();

try db.set("hello", "world", true);
const value = try db.get("key", allocator);
defer allocator.free(value);
```

## File Extensions

PolyDBM selects the backend based on file extension:

| Extension | Backend | Description |
|-----------|---------|-------------|
| `.tkh` | HashDBM | File-backed hash table |
| `.tkt` | TreeDBM | File-backed B+ tree |
| `.tks` | SkipDBM | File-backed skip list |
| `.tkmt` | TinyDBM | In-memory hash (with persistence) |
| `.tkmb` | BabyDBM | In-memory B+ tree (with persistence) |
| `.tkmc` | CacheDBM | In-memory LRU cache |

ShardDBM uses numbered shard files: `{name}-{i:05d}-of-{n:05d}` (e.g., `data.tkh-00003-of-00015`).

## Building

```bash
zig build
```

## Testing

```bash
zig build test
```

## API Overview

### Core Operations (All DBMs)

```zig
// Set a value
try db.set("key", "value", true);  // overwrite = true

// Get a value
const value = try db.get("key", allocator);
defer allocator.free(value);

// Remove a value
try db.remove("key");

// Count records
const count = db.count();

// Clear all records
try db.clear();
```

### PolyDBM Options

```zig
// Auto-select from extension
const db = try PolyDBM.open("data.tkh", .{ .writable = true }, io, allocator);

// Explicit backend selection
const db = try PolyDBM.open("any_name", .{
    .writable = true,
    .backend = BackendType.tiny,  // Force TinyDBM regardless of extension
}, io, allocator);
```

### Iterators

All DBMs expose a Zig-style iterator with a single `next()` call:

```zig
// Iterate from the beginning
var iter = try db.iterate(allocator);
defer iter.deinit();

while (try iter.next()) |entry| {
    // entry.key and entry.value are []const u8 slices.
    // They are valid only until the next call to next() or deinit();
    // copy them if you need them to outlive the loop body.
    std.debug.print("{s} = {s}\n", .{ entry.key, entry.value });
}

// Start at the first record >= a given key (ordered DBMs only)
var iter2 = try db.iterateFrom("some_key", allocator);
defer iter2.deinit();
while (try iter2.next()) |entry| {
    _ = entry;
}
```

For direct cursor access (lower-level, heap-allocating `get()`):

```zig
var cursor = try db.makeCursor();
defer cursor.deinit();
try cursor.first();
var key_buf: std.ArrayList(u8) = .empty;
var val_buf: std.ArrayList(u8) = .empty;
defer key_buf.deinit(allocator);
defer val_buf.deinit(allocator);
while (cursor.get(&key_buf, &val_buf).isOk()) {
    // use key_buf.items / val_buf.items
    if (!cursor.next().isOk()) break;
}
```

### Exact Vector Search (KNN)

Vectors are stored as regular DBM record values using packed IEEE-754 little-endian `float32` bytes with no header or padding (`dimension = byte_length / 4`, matching NumPy `astype(np.float32).tobytes()`, Redis FP32, and `sqlite-vec`). Zero-length vectors and non-finite elements (`NaN`/`Inf`) are rejected.

`searchSimilar` performs an exact brute-force scan across any `PolyDBM` backend (all six backends supported) with target-independent `f64`-accumulated kernels (`.l2`, `.dot`, `.cosine`). All metrics return a uniform higher-is-more-similar `score` (`.dot` = dot product, `.l2` = `-l2Distance`, `.cosine` = `-cosineDistance`, with `-inf` for zero-norm vectors), with ties broken deterministically by ascending key bytes.

Operational semantics and caveats:
- **Invalid records**: By default, malformed or dimension-mismatched records are skipped and counted in `result.invalid_records`. With `.{ .strict = true }`, `searchSimilar` stops scoring on the first invalid record and returns `PolyError.BrokenData` (malformed length, `NaN`/`Inf`, or dimension mismatch); note that `PolyDBM.processEach` still finishes traversing remaining records because `RecordAction` has no early-abort signal.
- **Headerless format**: Because stored vectors have no type header, any non-vector record whose byte length equals `query.len * 4` and whose bytes decode as finite `float32` values (for example, a 12-byte ASCII string for a 3-dim query) is indistinguishable from a vector. Store vectors in a dedicated DBM or keyspace when mixing arbitrary binary blobs.
- **SkipDBM synchronization**: `SkipDBM` buffers writes until `synchronize()` or `close()`; unsynchronized records are not visible to `searchSimilar` or `findByVector`.
- **Concurrency / snapshots**: Scans are not universally point-in-time snapshots across backends. `TinyDBM`, `HashDBM`, and `SkipDBM` hold shared/whole locks across the scan (blocking concurrent writers for the duration of the scan), while `BabyDBM` and `TreeDBM` lock one leaf at a time and `CacheDBM` locks per slot, so concurrent writes may be partially visible depending on backend.

```zig
const tkrzw = @import("tkrzw_zig");

var db = try tkrzw.PolyDBM.open("embeddings.tkh", .{ .writable = true }, io, allocator);
defer db.deinit(io);

const v_cat = try tkrzw.encodeF32(allocator, &[_]f32{ 0.9, 0.1, 0.0 });
defer allocator.free(v_cat);
const v_dog = try tkrzw.encodeF32(allocator, &[_]f32{ 0.8, 0.2, 0.0 });
defer allocator.free(v_dog);
const v_car = try tkrzw.encodeF32(allocator, &[_]f32{ 0.0, 0.0, 1.0 });
defer allocator.free(v_car);

_ = db.set(io, "cat", v_cat, true);
_ = db.set(io, "dog", v_dog, true);
_ = db.set(io, "car", v_car, true);

// Exact top-2 cosine KNN search
var result = try tkrzw.searchSimilar(&db, io, allocator, &[_]f32{ 1.0, 0.0, 0.0 }, 2, .cosine, .{});
defer result.deinit(allocator);
// result.hits[0].key == "cat", result.hits[1].key == "dog"

// Byte-exact lookup (returns all matching keys sorted ascending)
var exact = try tkrzw.findByVector(&db, io, allocator, &[_]f32{ 0.0, 0.0, 1.0 });
defer exact.deinit(allocator);
// exact.keys[0] == "car"
```

## License

Licensed under the Apache License, Version 2.0. See LICENSE for details.

Original tkrzw implementation by Mikio Hirabayashi.  
Zig port and modifications by Jason Watson.
