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

## License

Licensed under the Apache License, Version 2.0. See LICENSE for details.

Original tkrzw implementation by Mikio Hirabayashi.  
Zig port and modifications by Jason Watson.
