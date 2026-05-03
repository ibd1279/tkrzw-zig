//! PolyDBM: Type-erased wrapper for all DBM implementations.
//!
//! This module provides a tagged union wrapper that erases the concrete DBM type,
//! allowing code to work with any database backend without knowing the specific
//! type at compile time. The backend is selected at open time based on file
//! extension or explicit configuration.
//!
//! File extension mapping (from original tkrzw):
//!   - .tkh  : HashDBM  (file-backed hash table)
//!   - .tkt  : TreeDBM  (file-backed B+ tree)
//!   - .tks  : SkipDBM  (file-backed skip list)
//!   - .tkmt : TinyDBM  (in-memory hash with persistence)
//!   - .tkmb : BabyDBM  (in-memory B+ tree with persistence)
//!   - .tkmc : CacheDBM (in-memory LRU cache)
//!
//! Example:
//!   const db = try PolyDBM.open("data.tkh", .{ .writable = true }, io, allocator);
//!   defer db.close(io);
//!   try db.set("key", "value", true, allocator);
//!   const val = try db.get("key", allocator);

const std = @import("std");
const lib_common = @import("lib_common.zig");
const dbm_mod = @import("dbm.zig");
const file_mod = @import("file.zig");
const dbm_tiny_mod = @import("dbm_tiny.zig");
const dbm_baby_mod = @import("dbm_baby.zig");
const dbm_hash_mod = @import("dbm_hash.zig");
const dbm_tree_mod = @import("dbm_tree.zig");
const dbm_skip_mod = @import("dbm_skip.zig");
const dbm_cache_mod = @import("dbm_cache.zig");

pub const Status = lib_common.Status;
pub const Code = lib_common.Code;
pub const RecordAction = dbm_mod.RecordAction;
pub const UpdateLogger = dbm_mod.UpdateLogger;
pub const File = file_mod.File;
pub const OpenOptions = file_mod.OpenOptions;
pub const Io = std.Io;

/// Error set for PolyDBM operations.
pub const PolyError = error{
    OutOfMemory,
    UnknownError,
    SystemError,
    NotImplemented,
    PreconditionError,
    InvalidArgument,
    Canceled,
    NotFound,
    PermissionError,
    Infeasible,
    Duplication,
    BrokenData,
    NetworkError,
    ApplicationError,
};

/// Converts a Status code to a PolyError.
fn codeToError(code: Code) PolyError {
    return switch (code) {
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

/// Backend type selection for PolyDBM.
pub const BackendType = enum {
    /// File-backed hash table (.tkh)
    hash,
    /// File-backed B+ tree (.tkt)
    tree,
    /// File-backed skip list (.tks)
    skip,
    /// In-memory hash with persistence (.tkmt)
    tiny,
    /// In-memory B+ tree with persistence (.tkmb)
    baby,
    /// In-memory LRU cache (.tkmc)
    cache,
};

/// Configuration for opening a PolyDBM.
pub const OpenOptionsPoly = struct {
    /// Whether the database is writable.
    writable: bool = true,
    /// File open options (for file-backed DBMs).
    file_options: OpenOptions = .{},
    /// Explicit backend type. If null, determined from file extension.
    backend: ?BackendType = null,
    /// Number of buckets for hash-based DBMs (0 = default).
    num_buckets: i64 = 0,
    /// Key comparator for BabyDBM (default: lexical).
    key_comparator: ?dbm_baby_mod.KeyComparator = null,
};

/// Internal tagged union holding the concrete DBM instance.
const Backend = union(BackendType) {
    hash: dbm_hash_mod.HashDBM,
    tree: dbm_tree_mod.TreeDBM,
    skip: dbm_skip_mod.SkipDBM,
    tiny: dbm_tiny_mod.TinyDBM,
    baby: dbm_baby_mod.BabyDBM,
    cache: dbm_cache_mod.CacheDBM,
};

/// Type-erased database manager wrapper.
///
/// PolyDBM wraps all DBM implementations behind a unified interface using a
/// tagged union. This allows you to:
/// - Select the backend at runtime based on file extension
/// - Store/pass DBMs without knowing the concrete type
/// - Swap implementations without changing calling code
///
/// All operations dispatch through a switch on the backend type.
pub const PolyDBM = struct {
    backend: Backend,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Determines the backend type from a file extension.
    pub fn backendFromExtension(path: []const u8) !BackendType {
        const ext = std.fs.path.extension(path);
        if (ext.len == 0) return error.UnknownDatabaseType;

        return if (std.mem.eql(u8, ext, ".tkh"))
            BackendType.hash
        else if (std.mem.eql(u8, ext, ".tkt"))
            BackendType.tree
        else if (std.mem.eql(u8, ext, ".tks"))
            BackendType.skip
        else if (std.mem.eql(u8, ext, ".tkmt"))
            BackendType.tiny
        else if (std.mem.eql(u8, ext, ".tkmb"))
            BackendType.baby
        else if (std.mem.eql(u8, ext, ".tkmc"))
            BackendType.cache
        else
            error.UnknownDatabaseType;
    }

    /// Opens a database with automatic backend selection.
    ///
    /// The backend is determined by:
    /// 1. Explicit `options.backend` if provided
    /// 2. File extension otherwise (.tkh, .tkt, .tks, .tkmt, .tkmb, .tkmc)
    ///
    /// \param path Path to the database file (or identifier for in-memory DBMs)
    /// \param options Open configuration
    /// \param io Io instance for async operations
    /// \param allocator Allocator for memory allocations
    /// \return Opened PolyDBM instance
    pub fn open(
        path: []const u8,
        options: OpenOptionsPoly,
        io: Io,
        allocator: std.mem.Allocator,
    ) !Self {
        const backend_type = options.backend orelse try backendFromExtension(path);

        const backend: Backend = switch (backend_type) {
            BackendType.hash => blk: {
                const std_file = try file_mod.StdFile.create(allocator);
                var db = try dbm_hash_mod.HashDBM.init(
                    std_file.asFile(),
                    if (options.num_buckets > 0) options.num_buckets else dbm_hash_mod.DEFAULT_NUM_BUCKETS,
                    allocator,
                );
                _ = db.open(path, options.writable, options.file_options, io);
                break :blk Backend{ .hash = db };
            },
            BackendType.tree => blk: {
                const std_file = try file_mod.StdFile.create(allocator);
                var db = try dbm_tree_mod.TreeDBM.init(
                    std_file.asFile(),
                    allocator,
                );
                _ = db.open(path, options.writable, options.file_options, io);
                break :blk Backend{ .tree = db };
            },
            BackendType.skip => blk: {
                const std_file = try file_mod.StdFile.create(allocator);
                var db = try dbm_skip_mod.SkipDBM.init(
                    std_file.asFile(),
                    allocator,
                    .{},
                );
                _ = db.open(path, options.writable, options.file_options, io);
                break :blk Backend{ .skip = db };
            },
            BackendType.tiny => blk: {
                const std_file = try file_mod.StdFile.create(allocator);
                var db = try dbm_tiny_mod.TinyDBM.init(
                    std_file.asFile(),
                    if (options.num_buckets > 0) options.num_buckets else dbm_tiny_mod.DEFAULT_NUM_BUCKETS,
                    allocator,
                );
                _ = db.open(path, options.writable, options.file_options, io);
                break :blk Backend{ .tiny = db };
            },
            BackendType.baby => blk: {
                const comparator = options.key_comparator orelse dbm_baby_mod.lexicalKeyComparator;
                const std_file = try file_mod.StdFile.create(allocator);
                var db = try dbm_baby_mod.BabyDBM.init(
                    std_file.asFile(),
                    comparator,
                    allocator,
                );
                _ = try db.open(path, options.writable, options.file_options, io);
                break :blk Backend{ .baby = db };
            },
            BackendType.cache => blk: {
                const std_file = try file_mod.StdFile.create(allocator);
                const db = try dbm_cache_mod.CacheDBM.init(
                    std_file.asFile(),
                    dbm_cache_mod.DEFAULT_CAP_REC_NUM,
                    std.math.maxInt(i64),
                    allocator,
                );
                break :blk Backend{ .cache = db };
            },
        };

        return Self{
            .backend = backend,
            .allocator = allocator,
        };
    }

    /// Closes the database and releases resources.
    pub fn close(self: *Self, io: Io) Status {
        return switch (self.backend) {
            BackendType.hash => |*db| db.close(io),
            BackendType.tree => |*db| db.close(io),
            BackendType.skip => |*db| db.close(io),
            BackendType.tiny => |*db| db.close(io),
            BackendType.baby => |*db| db.close(io),
            BackendType.cache => |*db| db.close(io),
        };
    }

    /// Deinitializes the PolyDBM, freeing all resources.
    /// Call close() before deinit() if the database was opened.
    pub fn deinit(self: *Self) void {
        switch (self.backend) {
            BackendType.hash => |*db| db.deinit(),
            BackendType.tree => |*db| db.deinit(),
            BackendType.skip => |*db| db.deinit(),
            BackendType.tiny => |*db| db.deinit(),
            BackendType.baby => |*db| db.deinit(),
            BackendType.cache => |*db| db.deinit(),
        }
    }

    /// Gets a record by key.
    ///
    /// \param key The key to look up
    /// \param allocator Allocator for the result value
    /// \return The value (caller must free) or error
    pub fn get(self: *Self, key: []const u8, allocator: std.mem.Allocator) PolyError![]const u8 {
        // We use get() with an ArrayList on all backends so we can distinguish
        // NOT_FOUND from SUCCESS. getSimple() swallows the miss by returning a
        // default value, which would make NotFound undetectable.
        //
        // The backend grows `buf` using its own internal allocator
        // (`self.allocator`), so we MUST deinit with the same allocator. We
        // then dupe into the caller's `allocator` for the return value.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        const status = switch (self.backend) {
            BackendType.hash => |*db| db.get(key, &buf),
            BackendType.tree => |*db| db.get(key, &buf),
            BackendType.skip => |*db| db.get(key, &buf),
            BackendType.cache => |*db| db.get(key, &buf),
            BackendType.tiny => |*db| db.get(key, &buf),
            BackendType.baby => |*db| db.get(key, &buf),
        };
        if (!status.isOk()) return codeToError(status.code);
        return try allocator.dupe(u8, buf.items);
    }

    /// Sets a record.
    ///
    /// \param key The key for the record
    /// \param value The value to store
    /// \param overwrite If true, overwrite existing records. If false, return DUPLICATION_ERROR.
    /// \return Status indicating success or failure
    pub fn set(
        self: *Self,
        key: []const u8,
        value: []const u8,
        overwrite: bool,
    ) Status {
        return switch (self.backend) {
            // All DBMs: set(key, value, overwrite, old_value)
            BackendType.hash => |*db| db.set(key, value, overwrite, null),
            BackendType.tree => |*db| db.set(key, value, overwrite, null),
            BackendType.skip => |*db| db.set(key, value, overwrite, null),
            BackendType.cache => |*db| db.set(key, value, overwrite, null),
            BackendType.tiny => |*db| db.set(key, value, overwrite, null),
            BackendType.baby => |*db| db.set(key, value, overwrite, null),
        };
    }

    /// Removes a record by key.
    ///
    /// \param key The key to remove
    /// \return Status indicating success or failure
    pub fn remove(self: *Self, key: []const u8) Status {
        return switch (self.backend) {
            BackendType.hash => |*db| db.remove(key),
            BackendType.tree => |*db| db.remove(key),
            BackendType.skip => |*db| db.remove(key, null),
            BackendType.tiny => |*db| db.remove(key),
            BackendType.baby => |*db| db.remove(key),
            BackendType.cache => |*db| db.remove(key),
        };
    }

    /// Appends data to an existing record.
    ///
    /// \param key The key for the record
    /// \param value The value to append
    /// \param delim Delimiter to insert between existing and new value
    /// \return Status indicating success or failure
    pub fn append(
        self: *Self,
        key: []const u8,
        value: []const u8,
        delim: []const u8,
    ) Status {
        return switch (self.backend) {
            BackendType.hash => |*db| db.append(key, value, delim),
            BackendType.tree => |*db| db.append(key, value, delim),
            BackendType.skip => |*db| db.append(key, value, delim),
            BackendType.tiny => |*db| db.append(key, value, delim, self.allocator),
            BackendType.baby => |*db| db.append(key, value, delim, self.allocator),
            BackendType.cache => |*db| db.append(key, value, delim, self.allocator),
        };
    }

    /// Gets multiple records by keys.
    ///
    /// \param keys Array of keys to look up
    /// \param records HashMap to store results (key -> value)
    /// \return Status indicating success (all found) or partial failure
    pub fn getMulti(
        self: *Self,
        keys: []const []const u8,
        records: *std.StringHashMap([]u8),
    ) Status {
        return switch (self.backend) {
            BackendType.hash => |*db| db.getMulti(keys, records),
            BackendType.tree => |*db| db.getMulti(keys, records),
            BackendType.skip => |*db| db.getMulti(keys, records),
            BackendType.tiny => |*db| db.getMulti(keys, records),
            BackendType.baby => |*db| db.getMulti(keys, records),
            BackendType.cache => |*db| db.getMulti(keys, records),
        };
    }

    /// Sets multiple records.
    ///
    /// \param records Array of [key, value] pairs to store
    /// \param overwrite If true, overwrite existing records
    /// \return Status indicating success or failure
    pub fn setMulti(
        self: *Self,
        records: []const [2][]const u8,
        overwrite: bool,
    ) Status {
        return switch (self.backend) {
            BackendType.hash => |*db| db.setMulti(records, overwrite),
            BackendType.tree => |*db| db.setMulti(records, overwrite),
            BackendType.skip => |*db| db.setMulti(records, overwrite),
            BackendType.tiny => |*db| db.setMulti(records, overwrite),
            BackendType.baby => |*db| db.setMulti(records, overwrite),
            BackendType.cache => |*db| db.setMulti(records, overwrite),
        };
    }

    /// Removes multiple records.
    ///
    /// \param keys Array of keys to remove
    /// \return Status indicating success or failure
    pub fn removeMulti(self: *Self, keys: []const []const u8) Status {
        return switch (self.backend) {
            BackendType.hash => |*db| db.removeMulti(keys),
            BackendType.tree => |*db| db.removeMulti(keys),
            BackendType.skip => |*db| db.removeMulti(keys),
            BackendType.tiny => |*db| db.removeMulti(keys),
            BackendType.baby => |*db| db.removeMulti(keys),
            BackendType.cache => |*db| db.removeMulti(keys),
        };
    }

    /// Gets the number of records in the database.
    ///
    /// \return The record count
    pub fn count(self: *Self) i64 {
        var out: i64 = 0;
        _ = switch (self.backend) {
            BackendType.hash => |*db| db.count(&out),
            BackendType.tree => |*db| db.count(&out),
            BackendType.skip => |*db| db.count(&out),
            BackendType.tiny => |*db| db.count(&out),
            BackendType.baby => |*db| db.count(&out),
            BackendType.cache => |*db| db.count(&out),
        };
        return out;
    }

    /// Clears all records from the database.
    ///
    /// \param io Io instance (required for SkipDBM, optional for others)
    /// \return Status indicating success or failure
    pub fn clear(self: *Self, io: Io) Status {
        return switch (self.backend) {
            BackendType.hash => |*db| db.clear(),
            BackendType.tree => |*db| db.clear(),
            BackendType.skip => |*db| db.clear(io),
            BackendType.tiny => |*db| db.clear(),
            BackendType.baby => |*db| db.clear(),
            BackendType.cache => |*db| db.clear(),
        };
    }

    /// Synchronizes the database to storage.
    ///
    /// \param hard If true, do physical sync (fsync). If false, logical sync only.
    /// \param io Io instance for async operations
    /// \return Status indicating success or failure
    pub fn synchronize(self: *Self, hard: bool, io: Io) Status {
        return switch (self.backend) {
            BackendType.hash => |*db| db.synchronize(hard, io),
            BackendType.tree => |*db| db.synchronize(hard, io),
            BackendType.skip => |*db| db.synchronize(hard, io),
            BackendType.tiny => |*db| db.synchronize(hard, io),
            BackendType.baby => |*db| db.synchronize(hard, io),
            BackendType.cache => |*db| db.synchronize(hard, io),
        };
    }

    /// Rebuilds the database.
    ///
    /// \param io Io instance for async operations
    /// \return Status indicating success or failure
    pub fn rebuild(self: *Self, io: Io) Status {
        return switch (self.backend) {
            BackendType.hash => |*db| db.rebuild(io),
            BackendType.tree => |*db| db.rebuild(io),
            BackendType.skip => |*db| db.rebuild(io),
            BackendType.tiny => |*db| db.rebuild(),
            BackendType.baby => |*db| db.rebuild(),
            BackendType.cache => |*db| db.rebuild(),
        };
    }

    /// Processes each record in the database with a processor.
    ///
    /// \param P The processor type
    /// \param proc The processor instance
    /// \param writable Whether the processor can modify records
    /// \return Status indicating success or failure
    pub fn processEach(self: *Self, comptime P: type, proc: *P, writable: bool) !Status {
        return switch (self.backend) {
            BackendType.hash => |*db| db.processEach(proc, writable),
            BackendType.tree => |*db| db.processEach(proc, writable),
            BackendType.skip => |*db| db.processEach(P, proc, writable),
            BackendType.tiny => |*db| db.processEach(P, proc, writable),
            BackendType.baby => |*db| db.processEach(P, proc, writable),
            BackendType.cache => |*db| db.processEach(proc, writable),
        };
    }

    /// Checks if the database is open.
    ///
    /// \return true if open, false otherwise
    pub fn isOpen(self: *Self) bool {
        return switch (self.backend) {
            BackendType.hash => |*db| db.isOpen(),
            BackendType.tree => |*db| db.isOpen(),
            BackendType.skip => |*db| db.isOpen(),
            BackendType.tiny => |*db| db.isOpen(),
            BackendType.baby => |*db| db.isOpen(),
            BackendType.cache => |*db| db.isOpen(),
        };
    }

    /// Checks if the database is writable.
    ///
    /// \return true if writable, false otherwise
    pub fn isWritable(self: *Self) bool {
        return switch (self.backend) {
            BackendType.hash => |*db| db.isWritable(),
            BackendType.tree => |*db| db.isWritable(),
            BackendType.skip => |*db| db.isWritable(),
            BackendType.tiny => |*db| db.isWritable(),
            BackendType.baby => |*db| db.isWritable(),
            BackendType.cache => |*db| db.isWritable(),
        };
    }

    /// Gets the file size.
    ///
    /// \return The file size in bytes, or 0 for in-memory DBMs
    pub fn getFileSize(self: *Self) i64 {
        return switch (self.backend) {
            BackendType.hash => |*db| db.getFileSizeSimple(),
            BackendType.tree => |*db| db.getFileSizeSimple(),
            BackendType.skip => |*db| db.getFileSizeSimple(),
            BackendType.tiny => |*db| db.getFileSizeSimple(),
            BackendType.baby => |*db| db.getFileSizeSimple(),
            BackendType.cache => |*db| db.getFileSizeSimple(),
        };
    }

    /// Sets the update logger for write-ahead logging.
    ///
    /// \param logger The logger to use, or null to disable
    pub fn setUpdateLogger(self: *Self, logger: ?*UpdateLogger) void {
        switch (self.backend) {
            BackendType.hash => |*db| db.setUpdateLogger(logger),
            BackendType.tree => |*db| db.setUpdateLogger(logger),
            BackendType.skip => |*db| db.setUpdateLogger(logger),
            BackendType.tiny => |*db| db.setUpdateLogger(logger),
            BackendType.baby => |*db| db.setUpdateLogger(logger),
            BackendType.cache => |*db| db.setUpdateLogger(logger),
        }
    }

    /// Gets the current update logger.
    ///
    /// \return The logger or null if none set
    pub fn getUpdateLogger(self: *Self) ?*UpdateLogger {
        return switch (self.backend) {
            BackendType.hash => |*db| db.getUpdateLogger(),
            BackendType.tree => |*db| db.getUpdateLogger(),
            BackendType.skip => |*db| db.getUpdateLogger(),
            BackendType.tiny => |*db| db.getUpdateLogger(),
            BackendType.baby => |*db| db.getUpdateLogger(),
            BackendType.cache => |*db| db.getUpdateLogger(),
        };
    }

    /// Checks if the database is healthy.
    ///
    /// \return true if healthy, false otherwise
    pub fn isHealthy(self: *Self) bool {
        return switch (self.backend) {
            BackendType.hash => |*db| db.isHealthy(),
            BackendType.tree => |*db| db.isHealthy(),
            BackendType.skip => |*db| db.isHealthy(),
            BackendType.tiny => |*db| db.isHealthy(),
            BackendType.baby => |*db| db.isHealthy(),
            BackendType.cache => |*db| db.isHealthy(),
        };
    }

    /// Gets the backend type.
    ///
    /// \return The backend type
    pub fn getBackendType(self: *const Self) BackendType {
        return switch (self.backend) {
            BackendType.hash => .hash,
            BackendType.tree => .tree,
            BackendType.skip => .skip,
            BackendType.tiny => .tiny,
            BackendType.baby => .baby,
            BackendType.cache => .cache,
        };
    }

    /// Returns a pointer to the underlying TreeDBM (panics if not tree backend).
    pub fn getTreeDBM(self: *Self) *dbm_tree_mod.TreeDBM {
        return switch (self.backend) {
            BackendType.tree => |*db| db,
            else => @panic("not a tree backend"),
        };
    }

    /// Returns a pointer to the underlying SkipDBM (panics if not skip backend).
    pub fn getSkipDBM(self: *Self) *dbm_skip_mod.SkipDBM {
        return switch (self.backend) {
            BackendType.skip => |*db| db,
            else => @panic("not a skip backend"),
        };
    }

    /// Returns a pointer to the underlying BabyDBM (panics if not baby backend).
    pub fn getBabyDBM(self: *Self) *dbm_baby_mod.BabyDBM {
        return switch (self.backend) {
            BackendType.baby => |*db| db,
            else => @panic("not a baby backend"),
        };
    }

    /// Return a Zig-style iterator positioned at the first record.
    /// The caller must call deinit() when done.
    pub fn iterate(self: *Self, alloc: std.mem.Allocator) !PolyIterator {
        var cursor = try PolyCursor.init(self);
        errdefer cursor.deinit();
        var iter = PolyIterator{
            .cursor = cursor,
            .alloc = alloc,
            .key_buf = .empty,
            .value_buf = .empty,
            .done = false,
        };
        if (!iter.cursor.first().isOk()) iter.done = true;
        return iter;
    }

    /// Return a Zig-style iterator positioned at the first record >= key.
    /// The caller must call deinit() when done.
    pub fn iterateFrom(self: *Self, key: []const u8, alloc: std.mem.Allocator) !PolyIterator {
        var cursor = try PolyCursor.init(self);
        errdefer cursor.deinit();
        var iter = PolyIterator{
            .cursor = cursor,
            .alloc = alloc,
            .key_buf = .empty,
            .value_buf = .empty,
            .done = false,
        };
        if (!iter.cursor.jump(key).isOk()) iter.done = true;
        return iter;
    }

    /// Gets the timestamp of the database.
    ///
    /// \return The timestamp
    pub fn getTimestamp(self: *Self) f64 {
        return switch (self.backend) {
            BackendType.hash => |*db| db.getTimestampSimple(),
            BackendType.tree => |*db| db.getTimestampSimple(),
            BackendType.skip => |*db| db.getTimestampSimple(),
            BackendType.tiny => |*db| db.getTimestampSimple(),
            BackendType.baby => |*db| db.getTimestampSimple(),
            BackendType.cache => |*db| db.getTimestampSimple(),
        };
    }

    /// Checks if the database should be rebuilt.
    ///
    /// \return true if rebuild is needed, false otherwise
    pub fn shouldBeRebuilt(self: *Self) bool {
        return switch (self.backend) {
            BackendType.hash => |*db| db.shouldBeRebuiltSimple(),
            BackendType.tree => |*db| db.shouldBeRebuiltSimple(),
            BackendType.skip => |*db| db.shouldBeRebuiltSimple(),
            BackendType.tiny => |*db| db.shouldBeRebuiltSimple(),
            BackendType.baby => |*db| db.shouldBeRebuiltSimple(),
            BackendType.cache => |*db| db.shouldBeRebuiltSimple(),
        };
    }

    /// Copies the database file to a new location.
    ///
    /// \param dest_path The destination path
    /// \param sync_hard If true, performs a hard sync after copying
    /// \param io Io instance for file operations
    /// \return Status indicating success or failure
    pub fn copyFileData(self: *Self, dest_path: []const u8, sync_hard: bool, io: Io) Status {
        return switch (self.backend) {
            BackendType.hash => |*db| db.copyFileData(dest_path, sync_hard, io),
            BackendType.tree => |*db| db.copyFileData(dest_path, sync_hard, io),
            BackendType.skip => |*db| db.copyFileData(dest_path, sync_hard, io),
            BackendType.tiny => |*db| db.copyFileData(dest_path, sync_hard, io),
            BackendType.baby => |*db| db.copyFileData(dest_path, sync_hard, io),
            BackendType.cache => |*db| db.copyFileData(dest_path, sync_hard, io),
        };
    }

    // ---------------------------------------------------------------------------
    // Static methods
    // ---------------------------------------------------------------------------

    /// Restores a database from an old location to a new location.
    ///
    /// \param old_path The source path
    /// \param new_path The destination path
    /// \param io Io instance for file operations
    /// \return Status indicating success or failure
    pub fn restoreDatabase(old_path: []const u8, new_path: []const u8, io: Io) Status {
        // Determine backend type from old path
        const backend = backendFromExtension(old_path) catch {
            return Status.init(.SYSTEM_ERROR);
        };
        
        return switch (backend) {
            BackendType.hash => dbm_hash_mod.HashDBM.restoreDatabase(old_path, new_path, io),
            BackendType.tree => dbm_tree_mod.TreeDBM.restoreDatabase(old_path, new_path, io),
            BackendType.skip => dbm_skip_mod.SkipDBM.restoreDatabase(old_path, new_path, io),
            BackendType.tiny => dbm_tiny_mod.TinyDBM.restoreDatabase(old_path, new_path, io),
            BackendType.baby => dbm_baby_mod.BabyDBM.restoreDatabase(old_path, new_path, io),
            BackendType.cache => dbm_cache_mod.CacheDBM.restoreDatabase(old_path, new_path, io),
        };
    }

    /// Renames a database from an old location to a new location.
    ///
    /// \param old_path The source path
    /// \param new_path The destination path
    /// \param io Io instance for file operations
    /// \return Status indicating success or failure
    pub fn renameDatabase(old_path: []const u8, new_path: []const u8, io: Io) Status {
        // Determine backend type from old path
        const backend = backendFromExtension(old_path) catch {
            return Status.init(.SYSTEM_ERROR);
        };
        
        return switch (backend) {
            BackendType.hash => dbm_hash_mod.HashDBM.renameDatabase(old_path, new_path, io),
            BackendType.tree => dbm_tree_mod.TreeDBM.renameDatabase(old_path, new_path, io),
            BackendType.skip => dbm_skip_mod.SkipDBM.renameDatabase(old_path, new_path, io),
            BackendType.tiny => dbm_tiny_mod.TinyDBM.renameDatabase(old_path, new_path, io),
            BackendType.baby => dbm_baby_mod.BabyDBM.renameDatabase(old_path, new_path, io),
            BackendType.cache => dbm_cache_mod.CacheDBM.renameDatabase(old_path, new_path, io),
        };
    }
};

// ---------------------------------------------------------------------------
// Cursor support (C++-style: separate movement and read)
// ---------------------------------------------------------------------------

/// Type-erased cursor for PolyDBM.
///
/// Note: Only ordered DBMs (TreeDBM, SkipDBM, BabyDBM) fully support
/// ordered iteration. Hash-based DBMs provide unordered iteration.
pub const PolyCursor = struct {
    backend: union(BackendType) {
        hash: dbm_hash_mod.HashDBM.Cursor,
        tree: dbm_tree_mod.TreeDBM.Cursor,
        skip: dbm_skip_mod.SkipDBM.Cursor,
        tiny: dbm_tiny_mod.TinyDBM.Cursor,
        baby: dbm_baby_mod.BabyDBM.Cursor,
        cache: dbm_cache_mod.CacheDBM.Cursor,
    },

    const Self = @This();

    /// Creates a cursor from a PolyDBM.
    pub fn init(db: *PolyDBM) !Self {
        return switch (db.backend) {
            BackendType.hash => |*hash_db| Self{
                .backend = .{ .hash = try hash_db.makeCursor() },
            },
            BackendType.tree => |*tree_db| Self{
                .backend = .{ .tree = try tree_db.makeCursor() },
            },
            BackendType.skip => |*skip_db| Self{
                .backend = .{ .skip = try skip_db.makeCursor() },
            },
            BackendType.tiny => |*tiny_db| Self{
                .backend = .{ .tiny = try tiny_db.makeCursor() },
            },
            BackendType.baby => |*baby_db| Self{
                .backend = .{ .baby = try baby_db.makeCursor() },
            },
            BackendType.cache => |*cache_db| Self{
                .backend = .{ .cache = try cache_db.makeCursor() },
            },
        };
    }

    /// Deinitializes the cursor.
    pub fn deinit(self: *Self) void {
        switch (self.backend) {
            BackendType.hash => |*iter| iter.deinit(),
            BackendType.tree => |*iter| iter.deinit(),
            BackendType.skip => |*iter| iter.deinit(),
            BackendType.tiny => |*iter| iter.deinit(),
            BackendType.baby => |*iter| iter.deinit(),
            BackendType.cache => |*iter| iter.deinit(),
        }
    }

    /// Moves to the first record.
    pub fn first(self: *Self) Status {
        return switch (self.backend) {
            BackendType.hash => |*iter| iter.first(),
            BackendType.tree => |*iter| iter.first(),
            BackendType.skip => |*iter| iter.first(),
            BackendType.tiny => |*iter| iter.first(),
            BackendType.baby => |*iter| iter.first(),
            BackendType.cache => |*iter| iter.first(),
        };
    }

    /// Moves to the last record (ordered DBMs only).
    pub fn last(self: *Self) Status {
        return switch (self.backend) {
            BackendType.hash => |*iter| iter.last(),
            BackendType.tree => |*iter| iter.last(),
            BackendType.skip => |*iter| iter.last(),
            BackendType.tiny => |*iter| iter.last(),
            BackendType.baby => |*iter| iter.last(),
            BackendType.cache => |*iter| iter.last(),
        };
    }

    /// Moves to the next record.
    pub fn next(self: *Self) Status {
        return switch (self.backend) {
            BackendType.hash => |*iter| iter.next(),
            BackendType.tree => |*iter| iter.next(),
            BackendType.skip => |*iter| iter.next(),
            BackendType.tiny => |*iter| iter.next(),
            BackendType.baby => |*iter| iter.next(),
            BackendType.cache => |*iter| iter.next(),
        };
    }

    /// Moves to the first record >= key.
    pub fn jump(self: *Self, key: []const u8) Status {
        return switch (self.backend) {
            BackendType.hash => |*iter| iter.jump(key),
            BackendType.tree => |*iter| iter.jump(key),
            BackendType.skip => |*iter| iter.jump(key),
            BackendType.tiny => |*iter| iter.jump(key),
            BackendType.baby => |*iter| iter.jump(key),
            BackendType.cache => |*iter| iter.jump(key),
        };
    }

    /// Gets the current record's key and value.
    ///
    /// The key and value are written into the provided ArrayLists using the
    /// DBM's internal allocator. The caller must deinit the ArrayLists with
    /// the same allocator used to create them.
    pub fn get(
        self: *Self,
        allocator: std.mem.Allocator,
        key_out: ?*std.ArrayList(u8),
        value_out: ?*std.ArrayList(u8),
    ) Status {
        _ = allocator;
        return switch (self.backend) {
            BackendType.hash => |*iter| iter.get(key_out, value_out),
            BackendType.tree => |*iter| iter.get(key_out, value_out),
            BackendType.skip => |*iter| iter.get(key_out, value_out),
            BackendType.tiny => |*iter| iter.get(key_out, value_out),
            BackendType.baby => |*iter| iter.get(key_out, value_out),
            BackendType.cache => |*iter| iter.get(key_out, value_out),
        };
    }

    /// Sets the current record's value.
    pub fn set(
        self: *Self,
        value: []const u8,
        old_key: ?*std.ArrayList(u8),
        old_value: ?*std.ArrayList(u8),
    ) Status {
        return switch (self.backend) {
            BackendType.hash => |*iter| iter.set(value, old_key, old_value),
            BackendType.tree => |*iter| iter.set(value, old_key, old_value),
            BackendType.skip => |*iter| iter.set(value, old_key, old_value),
            BackendType.tiny => |*iter| iter.set(value, old_key, old_value),
            BackendType.baby => |*iter| iter.set(value, old_key, old_value),
            BackendType.cache => |*iter| iter.set(value, old_key, old_value),
        };
    }

    /// Removes the current record.
    pub fn remove(
        self: *Self,
        old_key: ?*std.ArrayList(u8),
        old_value: ?*std.ArrayList(u8),
    ) Status {
        return switch (self.backend) {
            BackendType.hash => |*iter| iter.remove(old_key, old_value),
            BackendType.tree => |*iter| iter.remove(old_key, old_value),
            BackendType.skip => |*iter| iter.remove(old_key, old_value),
            BackendType.tiny => |*iter| iter.remove(old_key, old_value),
            BackendType.baby => |*iter| iter.remove(old_key, old_value),
            BackendType.cache => |*iter| iter.remove(old_key, old_value),
        };
    }

    /// Processes the current record with a custom processor.
    pub fn process(
        self: *Self,
        comptime P: type,
        proc: *P,
        writable: bool,
    ) Status {
        return switch (self.backend) {
            BackendType.hash => |*iter| iter.process(P, proc, writable),
            BackendType.tree => |*iter| iter.process(P, proc, writable),
            BackendType.skip => |*iter| iter.process(P, proc, writable),
            BackendType.tiny => |*iter| iter.process(P, proc, writable),
            BackendType.baby => |*iter| iter.process(P, proc, writable),
            BackendType.cache => |*iter| iter.process(P, proc, writable),
        };
    }
};

// ---------------------------------------------------------------------------
// Iterator support (Zig-style: next() returns Entry)
// ---------------------------------------------------------------------------

/// A key-value entry returned by PolyIterator.
///
/// The slices point into the iterator's internal buffers and are invalidated
/// on the next call to next() or deinit(). Copy them if you need the data
/// to outlive this call.
pub const Entry = struct {
    /// Borrowed from iterator's internal buffer.
    /// Valid only until the next call to next() or deinit().
    key: []const u8,
    /// Borrowed from iterator's internal buffer.
    /// Valid only until the next call to next() or deinit().
    value: []const u8,
};

/// Zig-style iterator for PolyDBM.
///
/// This iterator wraps PolyCursor and provides a single next() call that
/// returns both key and value. The returned Entry slices point into internal
/// buffers and are invalidated on the next call to next() or deinit().
///
/// Note: Only ordered DBMs (TreeDBM, SkipDBM, BabyDBM) fully support
/// ordered iteration. Hash-based DBMs provide unordered iteration.
pub const PolyIterator = struct {
    cursor: PolyCursor,
    alloc: std.mem.Allocator,
    key_buf: std.ArrayList(u8),
    value_buf: std.ArrayList(u8),
    done: bool,

    const Self = @This();

    /// Advance and return the current entry, or null when exhausted.
    ///
    /// The returned slices point into internal buffers and are invalidated
    /// on the next call to next() or deinit(). Copy them if you need the
    /// data to outlive this call.
    pub fn next(self: *Self) !?Entry {
        if (self.done) return null;

        // Fill internal buffers from the current cursor position.
        self.key_buf.clearRetainingCapacity();
        self.value_buf.clearRetainingCapacity();
        const st = self.cursor.get(self.alloc, &self.key_buf, &self.value_buf);
        if (!st.isOk()) {
            self.done = true;
            return null;
        }

        // Advance cursor. If it reaches the end, mark done so the next
        // call returns null rather than re-reading the last record.
        if (!self.cursor.next().isOk()) self.done = true;

        return Entry{
            .key = self.key_buf.items,
            .value = self.value_buf.items,
        };
    }

    /// Release internal buffers and the underlying cursor.
    pub fn deinit(self: *Self) void {
        self.key_buf.deinit(self.alloc);
        self.value_buf.deinit(self.alloc);
        self.cursor.deinit();
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "PolyDBM backend type from extension" {
    const testing = std.testing;

    try testing.expectEqual(BackendType.hash, try PolyDBM.backendFromExtension("test.tkh"));
    try testing.expectEqual(BackendType.tree, try PolyDBM.backendFromExtension("test.tkt"));
    try testing.expectEqual(BackendType.skip, try PolyDBM.backendFromExtension("test.tks"));
    try testing.expectEqual(BackendType.tiny, try PolyDBM.backendFromExtension("test.tkmt"));
    try testing.expectEqual(BackendType.baby, try PolyDBM.backendFromExtension("test.tkmb"));
    try testing.expectEqual(BackendType.cache, try PolyDBM.backendFromExtension("test.tkmc"));

    try testing.expectError(error.UnknownDatabaseType, PolyDBM.backendFromExtension("test.xyz"));
    try testing.expectError(error.UnknownDatabaseType, PolyDBM.backendFromExtension("test"));
}

test "PolyDBM TinyDBM basic operations" {
    const testing = std.testing;
    const io = std.testing.io;
    const allocator = testing.allocator;

    // Use temp directory to avoid polluting repo root
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path = tmp_path: {
        const path = try std.Io.Dir.realPathFile(tmp.dir, io, ".", &path_buf);
        break :tmp_path path_buf[0..path];
    };
    const db_path = try std.fmt.allocPrint(allocator, "{s}/test.tkmt", .{tmp_path});
    defer allocator.free(db_path);

    var db = try PolyDBM.open(db_path, .{ .writable = true, .backend = BackendType.tiny }, io, allocator);
    defer db.deinit();

    // Set a value
    try testing.expectEqual(.SUCCESS, db.set("key1", "value1", true).code);

    // Get the value
    const value = try db.get("key1", allocator);
    try testing.expectEqualStrings("value1", value);
    allocator.free(value);

    // Remove the value
    try testing.expectEqual(.SUCCESS, db.remove("key1").code);

    // Verify removal — get() returns NotFound for missing keys so users can
    // distinguish "present with empty value" from "absent".
    try testing.expectError(PolyError.NotFound, db.get("key1", allocator));
}

test "PolyDBM BabyDBM basic operations" {
    const testing = std.testing;
    const io = std.testing.io;
    const allocator = testing.allocator;

    // Use temp directory to avoid polluting repo root
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path = tmp_path: {
        const path = try std.Io.Dir.realPathFile(tmp.dir, io, ".", &path_buf);
        break :tmp_path path_buf[0..path];
    };
    const db_path = try std.fmt.allocPrint(allocator, "{s}/test.tkmb", .{tmp_path});
    defer allocator.free(db_path);

    var db = try PolyDBM.open(db_path, .{ .writable = true, .backend = BackendType.baby }, io, allocator);
    defer db.deinit();

    // Set values
    try testing.expectEqual(.SUCCESS, db.set("b", "2", true).code);
    try testing.expectEqual(.SUCCESS, db.set("a", "1", true).code);
    try testing.expectEqual(.SUCCESS, db.set("c", "3", true).code);

    // Get values
    const val_a = try db.get("a", allocator);
    try testing.expectEqualStrings("1", val_a);
    allocator.free(val_a);

    const val_b = try db.get("b", allocator);
    try testing.expectEqualStrings("2", val_b);
    allocator.free(val_b);

    const val_c = try db.get("c", allocator);
    try testing.expectEqualStrings("3", val_c);
    allocator.free(val_c);

    // Count
    try testing.expectEqual(@as(i64, 3), db.count());
}

fn polyTestPath(alloc: std.mem.Allocator, io: std.Io, tmp: anytype, name: []const u8) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try std.Io.Dir.realPathFile(tmp.dir, io, ".", &buf);
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ buf[0..len], name });
}

test "PolyDBM.iterate() visits all records" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try polyTestPath(alloc, io, tmp, "iter.tkmt");
    defer alloc.free(db_path);

    var db = try PolyDBM.open(db_path, .{ .writable = true, .backend = .tiny }, io, alloc);
    defer db.deinit();
    _ = db.set("a", "1", true);
    _ = db.set("b", "2", true);
    _ = db.set("c", "3", true);

    var iter = try db.iterate(alloc);
    defer iter.deinit();
    var count: usize = 0;
    while (try iter.next()) |entry| {
        _ = entry.key;
        _ = entry.value;
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "PolyDBM.iterate() lifetime contract" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try polyTestPath(alloc, io, tmp, "lt.tkmt");
    defer alloc.free(db_path);

    var db = try PolyDBM.open(db_path, .{ .writable = true, .backend = .tiny }, io, alloc);
    defer db.deinit();
    _ = db.set("x", "val_x", true);
    _ = db.set("y", "val_y", true);

    var iter = try db.iterate(alloc);
    defer iter.deinit();
    const first = try iter.next();
    try std.testing.expect(first != null);
    const key_copy = try alloc.dupe(u8, first.?.key);
    defer alloc.free(key_copy);
    _ = try iter.next();
    try std.testing.expect(key_copy.len > 0);
}

test "PolyDBM.iterate() empty database" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try polyTestPath(alloc, io, tmp, "empty.tkmt");
    defer alloc.free(db_path);

    var db = try PolyDBM.open(db_path, .{ .writable = true, .backend = .tiny }, io, alloc);
    defer db.deinit();

    var iter = try db.iterate(alloc);
    defer iter.deinit();
    try std.testing.expect(try iter.next() == null);
    try std.testing.expect(try iter.next() == null);
}

test "PolyDBM.iterateFrom() ordered backend" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try polyTestPath(alloc, io, tmp, "from.tkmb");
    defer alloc.free(db_path);

    var db = try PolyDBM.open(db_path, .{ .writable = true, .backend = .baby }, io, alloc);
    defer db.deinit();
    _ = db.set("aaa", "v1", true);
    _ = db.set("bbb", "v2", true);
    _ = db.set("ccc", "v3", true);

    var iter = try db.iterateFrom("bbb", alloc);
    defer iter.deinit();
    const first = try iter.next();
    try std.testing.expect(first != null);
    try std.testing.expectEqualSlices(u8, "bbb", first.?.key);
    const second = try iter.next();
    try std.testing.expect(second != null);
    try std.testing.expectEqualSlices(u8, "ccc", second.?.key);
    try std.testing.expect(try iter.next() == null);
}

test "PolyDBM explicit backend type" {
    const testing = std.testing;
    const io = std.testing.io;
    const allocator = testing.allocator;

    // Use temp directory - filename doesn't matter when backend is explicit
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path = tmp_path: {
        const path = try std.Io.Dir.realPathFile(tmp.dir, io, ".", &path_buf);
        break :tmp_path path_buf[0..path];
    };
    const db_path = try std.fmt.allocPrint(allocator, "{s}/any_file", .{tmp_path});
    defer allocator.free(db_path);

    // Open TinyDBM explicitly regardless of extension
    var db = try PolyDBM.open(db_path, .{
        .writable = true,
        .backend = BackendType.tiny,
    }, io, allocator);
    defer db.deinit();

    try testing.expectEqual(.SUCCESS, db.set("test", "data", true).code);
    const value = try db.get("test", allocator);
    try testing.expectEqualStrings("data", value);
    allocator.free(value);
}
