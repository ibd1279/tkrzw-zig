# tkrzw-zig Project Guidelines

## Project Overview

This is a pure-Zig port of the tkrzw key-value database library, providing **six database implementations** plus a **unified wrapper**:

### In-Memory Databases
- **TinyDBM**: Hash-table based with optional persistence
- **BabyDBM**: B+ tree based with ordered iteration
- **CacheDBM**: Hash-table based with LRU eviction

### File-Backed Databases
- **HashDBM**: Hash-table based with crash-safe updates
- **TreeDBM**: B+ tree based with ordered iteration
- **SkipDBM**: Skip list based with ordered iteration

### Unified Wrapper
- **PolyDBM**: Type-erased wrapper with automatic backend selection from file extension

### Sharding Wrapper
- **ShardDBM**: Horizontal sharding across multiple PolyDBM instances

The port focuses on functional correctness and maintaining the original API surface while leveraging Zig's memory safety guarantees.

## Development Guidelines

### Code Organization

- **src/root.zig** — Main library entry point and public API
- **src/dbm.zig** — Common DBM interface and types
- **src/dbm_poly.zig** — PolyDBM type-erased wrapper
- **src/dbm_shard.zig** — ShardDBM sharding wrapper
- **src/dbm_tiny.zig** — TinyDBM implementation
- **src/dbm_baby.zig** — BabyDBM implementation
- **src/dbm_cache.zig** — CacheDBM implementation
- **src/dbm_hash.zig** — HashDBM implementation
- **src/dbm_tree.zig** — TreeDBM implementation
- **src/dbm_skip.zig** — SkipDBM implementation
- **src/lib_common.zig** — Status types and result codes
- **src/file.zig** — File I/O abstraction and implementations
- **src/\*_util.zig** — Utility modules (hash, string, time, thread, varint)

### Testing

- Unit tests are embedded in source files with `test` blocks
- Run all tests with `zig build test`
- Run demo with `zig build run`
- Integration tests validate all DBM implementations against common scenarios
- Use `std.testing.tmpDir()` for tests that create files

### Memory Management

- Use arena allocators for request-scoped work (standard pattern for void-returning operations)
- All allocations must be explicitly freed or tied to allocator lifetimes
- File-backed databases must properly deinit resources
- Use defer for cleanup guaranteed to run

### API Design

- Maintain compatibility with original tkrzw API surface
- Return Status with Code enums for all operations (not exceptions)
- Support optional UpdateLogger for write-ahead logging
- Allow custom File implementations for pluggable backends
- Optional parameters use null for "not provided"
- PolyDBM provides type erasure via tagged union (not vtables)

### Performance Considerations

- Hash tables use configurable bucket counts for TinyDBM/HashDBM
- B+ tree maintains balance for BabyDBM/TreeDBM
- Skip list maintains skip levels for SkipDBM
- LRU eviction for CacheDBM
- Mutex protection is standard; read-write locks optional
- Avoid allocations in hot paths where possible
- Benchmark critical paths (get/set operations)

### Threading Safety

- All DBMs use mutex protection for concurrent access
- **Deadlock avoidance**: During import, do not re-acquire global mutex if already held
- Use `processImplForImport()` pattern when importing records during open
- Leaf-level locks are acquired after global lock, never before

### Documentation

- Include doc comments for public APIs
- Keep README.md current with API changes
- Code examples should compile and run successfully
- License headers maintain original attribution

## Build

```bash
zig build                 # Default build
zig build test            # Run tests
zig build run             # Run demo
```

## Notes for Contributors

- When porting features from original tkrzw, check C++ implementation for edge cases
- Coordinate file format compatibility (snapshot and WAL formats)
- Test both in-memory and file-backed scenarios
- Maintain mutex safety without introducing deadlocks
- **Import deadlock pattern**: If holding `self.mutex` exclusively, use `processImplForImport()` instead of `processImpl()` to avoid recursive lock deadlock
- File extension mapping for PolyDBM: `.tkh`, `.tkt`, `.tks`, `.tkmt`, `.tkmb`, `.tkmc`
