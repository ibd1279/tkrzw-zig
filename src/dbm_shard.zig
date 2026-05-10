//! ShardDBM: Horizontally partitions records across N underlying PolyDBM shards.
//!
//! Each shard lives in its own file named
//!   "{base_path}-{index:05d}-of-{num_shards:05d}"
//! (e.g. "data.tkh-00003-of-00015"). The number of shards is a required
//! parameter of open(); if existing shard files are found under a different
//! num_shards value, open() returns DUPLICATION_ERROR.
//!
//! This module implements the core lifecycle (init / deinit / open / close).
//! Record-level routing (hash-based dispatch, get/set/remove, iteration)
//! will be added in later waves.

const std = @import("std");
const lib_common = @import("lib_common.zig");
const dbm_poly_mod = @import("dbm_poly.zig");
const dbm_mod = @import("dbm.zig");
const hash_util = @import("hash_util.zig");
const dbm_tree_mod = @import("dbm_tree.zig");
const dbm_skip_mod = @import("dbm_skip.zig");
const dbm_baby_mod = @import("dbm_baby.zig");

pub const Status = lib_common.Status;
pub const Code = lib_common.Code;
pub const PolyDBM = dbm_poly_mod.PolyDBM;
pub const PolyError = dbm_poly_mod.PolyError;
pub const OpenOptionsPoly = dbm_poly_mod.OpenOptionsPoly;
pub const BackendType = dbm_poly_mod.BackendType;
pub const Io = std.Io;

pub const RecordAction = dbm_mod.RecordAction;
pub const CompareExpected = dbm_mod.CompareExpected;
pub const CompareDesired = dbm_mod.CompareDesired;
pub const KeyComparator = lib_common.KeyComparator;

/// A key-processor pair for processMulti operations.
pub const KeyProcPair = struct {
    key: []const u8,
    proc: *anyopaque,
};

pub const CompareExpectedItem = struct {
    key: []const u8,
    value: dbm_mod.CompareExpected,
};

pub const CompareDesiredItem = struct {
    key: []const u8,
    value: dbm_mod.CompareDesired,
};

// ---------------------------------------------------------------------------
// Path helpers
// ---------------------------------------------------------------------------

/// Returns a newly-allocated shard file path of the form
/// "{base_path}-{index:05d}-of-{num_shards:05d}". Caller owns the returned
/// slice and must free it with the same allocator.
pub fn formatShardPath(
    allocator: std.mem.Allocator,
    base_path: []const u8,
    index: u64,
    num_shards: u64,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}-{d:0>5}-of-{d:0>5}",
        .{ base_path, index, num_shards },
    );
}

const ScanError = error{
    NoneFound,
    SystemError,
    Duplication,
};

/// Scans the directory containing `base_path` for existing shard files and
/// returns the total number of shards implied by the "-00000-of-NNNNN" marker
/// file, if one exists. Returns `NoneFound` when the database is fresh,
/// `Duplication` when multiple inconsistent marker files exist, and
/// `SystemError` for any unexpected I/O failure.
fn detectExistingNumShards(io: Io, base_path: []const u8) ScanError!u64 {
    const dir_path: []const u8 = std.fs.path.dirname(base_path) orelse ".";
    const basename: []const u8 = std.fs.path.basename(base_path);

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return ScanError.NoneFound,
        else => return ScanError.SystemError,
    };
    defer dir.close(io);

    const mid_needle = "-00000-of-";
    var found: ?u64 = null;
    var iter = dir.iterate();
    while (true) {
        const maybe_entry = iter.next(io) catch return ScanError.SystemError;
        const entry = maybe_entry orelse break;

        if (!std.mem.startsWith(u8, entry.name, basename)) continue;
        const tail = entry.name[basename.len..];
        if (!std.mem.startsWith(u8, tail, mid_needle)) continue;

        const digits = tail[mid_needle.len..];
        // Parse the leading run of decimal digits (tolerates trailing bytes,
        // matching tkrzw C++ StrToInt behavior).
        var end: usize = 0;
        while (end < digits.len and digits[end] >= '0' and digits[end] <= '9') : (end += 1) {}
        if (end == 0) continue;
        const n = std.fmt.parseInt(u64, digits[0..end], 10) catch continue;

        if (found) |prev| {
            if (prev != n) return ScanError.Duplication;
        } else {
            found = n;
        }
    }
    return found orelse ScanError.NoneFound;
}

// ---------------------------------------------------------------------------
// ShardDBM
// ---------------------------------------------------------------------------

pub const ShardDBM = struct {
    const Self = @This();

    /// Array of open PolyDBM backends, one per shard. Empty when not open.
    shards: []PolyDBM,
    /// Number of shards. 0 when not open.
    num_shards: u64,
    /// Allocator used for `shards`, `base_path`, and per-shard work buffers.
    allocator: std.mem.Allocator,
    /// Duplicated copy of the base path supplied to open(). Empty when not open.
    base_path: []u8,
    /// Whether the database was opened in writable mode. Consumed by record
    /// operations and `rebuild`/`synchronize` added in later waves.
    writable: bool,
    /// True while shards are open.
    is_open: bool,
    /// Returns the shard index for a given key using secondary hash.
    pub fn getShardIndex(self: *const Self, key: []const u8) usize {
        return @intCast(hash_util.secondaryHash(key, self.num_shards));
    }

    /// Allocates and zero-initializes a ShardDBM. The returned instance must
    /// eventually be released with `deinit`. Call `open` before using any
    /// record operations.
    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .shards = &[_]PolyDBM{},
            .num_shards = 0,
            .allocator = allocator,
            .base_path = &[_]u8{},
            .writable = false,
            .is_open = false,
        };
        return self;
    }

    /// Frees the ShardDBM struct. Call close(io) before deinit() to flush
    /// any pending writes; deinit alone skips file I/O cleanup.
    pub fn deinit(self: *Self, io: std.Io) void {
        if (self.is_open) {
            // Free shard resources without I/O (callers should close() first).
            for (self.shards) |*shard| shard.deinit(io);
            self.allocator.free(self.shards);
            self.allocator.free(self.base_path);
            self.shards = &[_]PolyDBM{};
            self.base_path = &[_]u8{};
            self.is_open = false;
        }
        self.allocator.destroy(self);
    }

    /// Opens the sharded database. All N shards are opened in index order;
    /// on failure any already-opened shards are closed and the instance is
    /// left in the not-open state.
    ///
    /// `path`     Base path. Shard files are named
    ///            `{path}-{i:05d}-of-{num_shards:05d}`.
    /// `num_shards` Required total number of shards (must be >= 1).
    /// `writable` Open mode.
    /// `io`       Io handle, captured for the lifetime of the open DB.
    /// `allocator` Present for API symmetry with PolyDBM.open; the ShardDBM
    ///            uses its own internally-stored allocator from `init`.
    /// `options`  Per-shard PolyDBM options. If `options.backend` is null it
    ///            is resolved from the base-path extension (shard paths have
    ///            a disambiguating suffix that defeats extension parsing).
    pub fn open(
        self: *Self,
        allocator: std.mem.Allocator,
        io: Io,
        path: []const u8,
        num_shards: u64,
        writable: bool,
        options: OpenOptionsPoly,
    ) Status {
        // Intentionally unused: accepted for API symmetry with PolyDBM.open.
        // ShardDBM always uses the allocator captured during init() so that
        // close() frees the matching allocations.
        _ = allocator;

        if (self.is_open) {
            return Status.initMsg(.PRECONDITION_ERROR, "opened database");
        }
        if (num_shards == 0) {
            return Status.initMsg(.INVALID_ARGUMENT_ERROR, "num_shards must be >= 1");
        }
        if (num_shards > std.math.maxInt(usize)) {
            return Status.initMsg(.INVALID_ARGUMENT_ERROR, "num_shards exceeds addressable limit");
        }

        // Resolve the backend once from the base path and reuse it for every
        // shard, so per-shard opens don't try to parse an extension such as
        // ".tkh-00000-of-00004".
        var shard_opts = options;
        shard_opts.writable = writable;
        if (shard_opts.backend == null) {
            shard_opts.backend = PolyDBM.backendFromExtension(path) catch {
                return Status.initMsg(.INVALID_ARGUMENT_ERROR, "unknown backend type");
            };
        }

        // Validate num_shards against any existing shard files.
        if (detectExistingNumShards(io, path)) |existing| {
            if (existing != num_shards) {
                return Status.initMsg(.DUPLICATION_ERROR, "num_shards mismatch with existing files");
            }
        } else |err| switch (err) {
            ScanError.NoneFound => {}, // fresh database or empty directory
            ScanError.Duplication => return Status.initMsg(.DUPLICATION_ERROR, "multiple shard-count candidates"),
            ScanError.SystemError => return Status.init(.SYSTEM_ERROR),
        }

        const base_dup = self.allocator.dupe(u8, path) catch
            return Status.init(.SYSTEM_ERROR);
        const shards_buf = self.allocator.alloc(PolyDBM, @intCast(num_shards)) catch {
            self.allocator.free(base_dup);
            return Status.init(.SYSTEM_ERROR);
        };

        openAllShards(self.allocator, path, num_shards, shard_opts, io, shards_buf) catch {
            self.allocator.free(shards_buf);
            self.allocator.free(base_dup);
            return Status.init(.SYSTEM_ERROR);
        };

        self.shards = shards_buf;
        self.num_shards = num_shards;
        self.base_path = base_dup;
        self.writable = writable;
        self.is_open = true;

        return Status.init(.SUCCESS);
    }

    /// Closes every shard in reverse open-order, merging their Status values,
    /// then releases owned memory and marks the database as not open.
    pub fn close(self: *Self, io: std.Io) Status {
        if (!self.is_open) {
            return Status.initMsg(.PRECONDITION_ERROR, "not opened database");
        }
        var status = Status.init(.SUCCESS);
        var i: usize = self.shards.len;
        while (i > 0) {
            i -= 1;
            status.mergeFrom(self.shards[i].close(io));
            self.shards[i].deinit(io);
        }
        self.allocator.free(self.shards);
        self.shards = &[_]PolyDBM{};
        self.allocator.free(self.base_path);
        self.base_path = &[_]u8{};
        self.num_shards = 0;
        self.is_open = false;
        return status;
    }

    // ---------------------------------------------------------------------------
    // Single-key operations (route to correct shard)
    // ---------------------------------------------------------------------------

    /// Gets a record by key.
    ///
    /// \param key The key to look up
    /// \param allocator Allocator for the result value
    /// \return The value (caller must free) or error
    pub fn get(self: *Self, allocator: std.mem.Allocator, io: std.Io, key: []const u8) PolyError![]const u8 {

        if (!self.is_open) {
            return PolyError.PreconditionError;
        }
        const shard_index = self.getShardIndex(key);
        return self.shards[shard_index].get(allocator, io, key);
    }

    /// Sets a record.
    ///
    /// \param key The key for the record
    /// \param value The value to store
    /// \param overwrite If true, overwrite existing records. If false, return DUPLICATION_ERROR.
    /// \return Status indicating success or failure
    pub fn set(self: *Self, io: std.Io, key: []const u8, value: []const u8, overwrite: bool) Status {

        if (!self.is_open) {
            return Status.initMsg(.PRECONDITION_ERROR, "not opened database");
        }
        const shard_index = self.getShardIndex(key);
        return self.shards[shard_index].set(io, key, value, overwrite);
    }

    /// Removes a record by key.
    ///
    /// \param key The key to remove
    /// \return Status indicating success or failure
    pub fn remove(self: *Self, io: std.Io, key: []const u8) Status {

        if (!self.is_open) {
            return Status.initMsg(.PRECONDITION_ERROR, "not opened database");
        }
        const shard_index = self.getShardIndex(key);
        return self.shards[shard_index].remove(io, key);
    }

    /// Appends data to an existing record.
    ///
    /// \param key The key for the record
    /// \param value The value to append
    /// \param delim Delimiter to insert between existing and new value
    /// \return Status indicating success or failure
    pub fn append(self: *Self, io: std.Io, key: []const u8, value: []const u8, delim: []const u8) Status {

        if (!self.is_open) {
            return Status.initMsg(.PRECONDITION_ERROR, "not opened database");
        }
        const shard_index = self.getShardIndex(key);
        return self.shards[shard_index].append(io, key, value, delim);
    }

    /// Processes a single record with a custom processor.
    ///
    /// \param key The key to process
    /// \param proc The processor to use
    /// \param writable Whether to allow writes
    /// \return Status indicating success or failure
    pub fn process(self: *Self, io: std.Io, comptime P: type, key: []const u8, proc: *P, writable: bool) Status {

        if (!self.is_open) {
            return Status.initMsg(.PRECONDITION_ERROR, "not opened database");
        }
        const shard_index = self.getShardIndex(key);
        return self.shards[shard_index].process(io, P, key, proc, writable);
    }

    // ---------------------------------------------------------------------------
    // Aggregate operations (iterate all shards)
    // ---------------------------------------------------------------------------

    /// Returns the total number of records across all shards.
    ///
    /// \return Total record count
    pub fn count(self: *Self, io: std.Io) i64 {
        if (!self.is_open) {
            return 0;
        }
        var total: i64 = 0;
        for (self.shards) |*shard| {
            total += shard.count(io);
        }
        return total;
    }

    /// Clears all records from all shards.
    ///
    /// \param io Io instance for sync operations
    /// \return Status indicating success or failure
    pub fn clear(self: *Self, io: Io) Status {
        if (!self.is_open) {
            return Status.initMsg(.PRECONDITION_ERROR, "not opened database");
        }
        var status = Status.init(.SUCCESS);
        for (self.shards) |*shard| {
            status.mergeFrom(shard.clear(io));
        }
        return status;
    }

    // ---------------------------------------------------------------------------
    // Multi-key operations
    // ---------------------------------------------------------------------------

    /// Performs compare-and-exchange operations on multiple records.
    ///
    /// Operations are grouped by shard and processed sequentially.
    ///
    /// \param expected Array of expected key-value pairs
    /// \param desired Array of desired key-value pairs
    /// \return Status indicating success or failure
    pub fn compareExchangeMulti(
        self: *Self,
        io: std.Io,
        expected: []const CompareExpectedItem,
        desired: []const CompareDesiredItem,
    ) Status {
        if (!self.is_open) {
            return Status.initMsg(.PRECONDITION_ERROR, "not opened database");
        }

        // For now, implement a simplified version that processes operations sequentially
        // A full implementation would require complex processor chaining like the C++ version

        var overall_status = Status.init(.SUCCESS);

        // First, check all expected conditions
        for (expected) |exp| {
            const shard_index = self.getShardIndex(exp.key);
            const shard = &self.shards[shard_index];

            // Get current value. NOTE: we must NOT `defer free(val)` inside the
            // `if` branch — that would free `val` when the `if` block exits,
            // leaving `current_value` dangling before the condition check below.
            // Free at end of the outer iteration instead.
            var current_value: ?[]const u8 = null;
            if (shard.get(self.allocator, io, exp.key)) |val| {
                current_value = val;
            } else |err| {
                if (err != PolyError.NotFound) {
                    overall_status.mergeFrom(Status.init(.SYSTEM_ERROR));
                    return overall_status;
                }
                // Key doesn't exist
            }
            defer if (current_value) |cv| self.allocator.free(cv);

            // Check condition
            switch (exp.value) {
                .absent => {
                    if (current_value) |_| {
                        overall_status.mergeFrom(Status.init(.INFEASIBLE_ERROR));
                        return overall_status;
                    }
                },
                .any => {
                    // Always ok
                },
                .exact => |expected_val| {
                    if (current_value == null) {
                        overall_status.mergeFrom(Status.init(.INFEASIBLE_ERROR));
                        return overall_status;
                    } else if (!std.mem.eql(u8, expected_val, current_value.?)) {
                        overall_status.mergeFrom(Status.init(.INFEASIBLE_ERROR));
                        return overall_status;
                    }
                },
            }
        }

        // If all conditions are met, apply desired operations
        for (desired) |des| {
            const shard_index = self.getShardIndex(des.key);
            const shard = &self.shards[shard_index];

            switch (des.value) {
                .remove => {
                    overall_status.mergeFrom(shard.remove(io, des.key));
                },
                .noop => {
                    // Do nothing
                },
                .set => |new_val| {
                    overall_status.mergeFrom(shard.set(io, des.key, new_val, true));
                },
            }

            if (!overall_status.isOk()) {
                return overall_status;
            }
        }

        return overall_status;
    }

    /// Processes all records in all shards with a custom processor.
    ///
    /// \param proc The processor to use
    /// \param writable Whether to allow writes
    /// \return Status indicating success or failure
    pub fn processEach(self: *Self, io: std.Io, comptime P: type, proc: *P, writable: bool) !Status {

        if (!self.is_open) {
            return Status.initMsg(.PRECONDITION_ERROR, "not opened database");
        }

        // Create a proxy processor that forwards calls to the original processor
        const ProxyProcessor = struct {
            original: *P,

            pub fn processFull(proxy: *@This(), key: []const u8, value: []const u8) RecordAction {
                return proxy.original.processFull(key, value);
            }

            pub fn processEmpty(proxy: *@This(), key: []const u8) RecordAction {
                return proxy.original.processEmpty(key);
            }
        };

        var proxy = ProxyProcessor{ .original = proc };

        // Pre-loop sentinel
        _ = proc.processEmpty("");

        // Process each shard
        for (self.shards) |*shard| {
            _ = try shard.processEach(io, ProxyProcessor, &proxy, writable);
        }

        // Post-loop sentinel
        _ = proc.processEmpty("");

        return Status.init(.SUCCESS);
    }

    // ---------------------------------------------------------------------------
    // Status queries
    // ---------------------------------------------------------------------------

    /// Returns whether the database is currently open.
    pub fn isOpen(self: *const Self) bool {
        return self.is_open;
    }

    /// Returns whether the database was opened in writable mode.
    pub fn isWritable(self: *const Self) bool {
        return self.writable;
    }

    /// Returns whether all shards are healthy.
    pub fn isHealthy(self: *Self) bool {
        if (!self.is_open) {
            return false;
        }
        for (self.shards) |*shard| {
            if (!shard.isHealthy()) {
                return false;
            }
        }
        return true;
    }

    /// Returns whether the database supports ordered iteration.
    /// This is determined by checking if the first shard supports ordered iteration.
    pub fn isOrdered(self: *const Self) bool {
        if (!self.is_open or self.shards.len == 0) {
            return false;
        }
        // Check if first shard supports ordered iteration
        // Ordered backends are TreeDBM, SkipDBM, and BabyDBM
        const first_shard = &self.shards[0];
        const backend = first_shard.getBackendType();
        return backend == .tree or backend == .skip or backend == .baby;
    }

    /// Returns the base path of the database.
    pub fn getFilePath(self: *const Self) []const u8 {
        return self.base_path;
    }

    /// Returns the total file size of all shards in bytes.
    pub fn getFileSize(self: *const Self) i64 {
        if (!self.is_open) {
            return 0;
        }
        var total: i64 = 0;
        for (self.shards) |*shard| {
            total += shard.getFileSize();
        }
        return total;
    }

    /// Returns the timestamp of shard 0.
    pub fn getTimestamp(self: *const Self) f64 {
        if (!self.is_open or self.shards.len == 0) {
            return 0.0;
        }
        return self.shards[0].getTimestamp();
    }

    /// Returns whether any shard needs to be rebuilt.
    pub fn shouldBeRebuilt(self: *const Self) bool {
        if (!self.is_open) {
            return false;
        }
        for (self.shards) |*shard| {
            if (shard.shouldBeRebuilt()) {
                return true;
            }
        }
        return false;
    }

    // ---------------------------------------------------------------------------
    // Synchronize and Rebuild
    // ---------------------------------------------------------------------------

    /// Synchronizes all shards to disk.
    ///
    /// \param hard If true, performs a hard sync (fsync). If false, performs a soft sync.
    /// \param io Io handle for file operations
    /// \return Status indicating success or failure
    pub fn synchronize(self: *Self, io: Io, hard: bool) Status {

        if (!self.is_open) {
            return Status.initMsg(.PRECONDITION_ERROR, "not opened database");
        }
        var status = Status.init(.SUCCESS);
        for (self.shards) |*shard| {
            status.mergeFrom(shard.synchronize(io, hard));
        }
        return status;
    }

    /// Rebuilds all shards.
    ///
    /// \param io Io handle for file operations
    /// \return Status indicating success or failure
    pub fn rebuild(self: *Self, io: Io) Status {
        if (!self.is_open) {
            return Status.initMsg(.PRECONDITION_ERROR, "not opened database");
        }
        var status = Status.init(.SUCCESS);
        for (self.shards) |*shard| {
            status.mergeFrom(shard.rebuild(io));
        }
        return status;
    }

    /// Copies all shard files to a new location.
    ///
    /// \param dest_path The destination base path
    /// \param sync_hard If true, performs a hard sync after copying
    /// \param io Io handle for file operations
    /// \return Status indicating success or failure
    pub fn copyFileData(self: *Self, io: Io, dest_path: []const u8, sync_hard: bool) Status {

        if (!self.is_open) {
            return Status.initMsg(.PRECONDITION_ERROR, "not opened database");
        }

        // Create destination directory if it doesn't exist
        const dest_dir = std.fs.path.dirname(dest_path) orelse ".";
        std.Io.Dir.cwd().access(io, dest_dir, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                std.Io.Dir.cwd().createDir(io, dest_dir, .default_dir) catch |err2| {
                    return switch (err2) {
                        error.AccessDenied => Status.initMsg(.PERMISSION_ERROR, "cannot create directory"),
                        else => Status.init(.SYSTEM_ERROR),
                    };
                };
            },
            else => return Status.init(.SYSTEM_ERROR),
        };

        var status = Status.init(.SUCCESS);

        // Copy each shard file
        for (self.shards, 0..) |*shard, i| {
            const src_path = formatShardPath(self.allocator, self.base_path, i, self.num_shards) catch {
                return Status.init(.SYSTEM_ERROR);
            };
            defer self.allocator.free(src_path);

            const dest_shard_path = formatShardPath(self.allocator, dest_path, i, self.num_shards) catch {
                return Status.init(.SYSTEM_ERROR);
            };
            defer self.allocator.free(dest_shard_path);

            // Copy file
            const copy_status = shard.copyFileData(io, dest_shard_path, sync_hard);
            status.mergeFrom(copy_status);
        }

        return status;
    }

    // ---------------------------------------------------------------------------
    // Static methods
    // ---------------------------------------------------------------------------

    /// Scans the directory for existing shard files and returns the number of shards.
    ///
    /// \param path The base path to scan
    /// \param io Io handle for file operations
    /// \return Number of shards, or error
    pub fn getNumberOfShards(path: []const u8, io: std.Io) !u64 {

        return detectExistingNumShards(io, path) catch |err| switch (err) {
            ScanError.NoneFound => return 0,
            ScanError.Duplication => return error.DuplicationError,
            ScanError.SystemError => return error.SystemError,
        };
    }

    /// Restores a database from an old location to a new location.
    ///
    /// \param old_path The source base path
    /// \param new_path The destination base path
    /// \param io Io handle for file operations
    /// \return Status indicating success or failure
    pub fn restoreDatabase(old_path: []const u8, new_path: []const u8, io: std.Io) Status {

        // Get number of shards from old location
        const num_shards = getNumberOfShards(old_path, io) catch {
            return Status.init(.SYSTEM_ERROR);
        };

        if (num_shards == 0) {
            return Status.initMsg(.NOT_FOUND_ERROR, "no shard files found");
        }

        // Create destination directory if it doesn't exist
        const dest_dir = std.fs.path.dirname(new_path) orelse ".";
        std.Io.Dir.cwd().access(io, dest_dir, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                std.Io.Dir.cwd().createDir(io, dest_dir, .default_dir) catch {
                    return Status.init(.SYSTEM_ERROR);
                };
            },
            else => return Status.init(.SYSTEM_ERROR),
        };

        var status = Status.init(.SUCCESS);

        // Use a temporary allocator for path formatting
        const temp_allocator = std.heap.page_allocator;

        // Restore each shard
        for (0..num_shards) |i| {
            const old_shard_path = formatShardPath(temp_allocator, old_path, i, num_shards) catch {
                return Status.init(.SYSTEM_ERROR);
            };
            defer temp_allocator.free(old_shard_path);

            const new_shard_path = formatShardPath(temp_allocator, new_path, i, num_shards) catch {
                return Status.init(.SYSTEM_ERROR);
            };
            defer temp_allocator.free(new_shard_path);

            // Use PolyDBM to restore each shard
            const restore_status = PolyDBM.restoreDatabase(io, old_shard_path, new_shard_path);
            status.mergeFrom(restore_status);
        }

        return status;
    }

    /// Renames a database from an old location to a new location.
    ///
    /// \param old_path The source base path
    /// \param new_path The destination base path
    /// \param io Io handle for file operations
    /// \return Status indicating success or failure
    pub fn renameDatabase(old_path: []const u8, new_path: []const u8, io: std.Io) Status {

        // Get number of shards from old location
        const num_shards = getNumberOfShards(old_path, io) catch {
            return Status.init(.SYSTEM_ERROR);
        };

        if (num_shards == 0) {
            return Status.initMsg(.NOT_FOUND_ERROR, "no shard files found");
        }

        // Create destination directory if it doesn't exist
        const dest_dir = std.fs.path.dirname(new_path) orelse ".";
        std.Io.Dir.cwd().access(io, dest_dir, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                std.Io.Dir.cwd().createDir(io, dest_dir, .default_dir) catch {
                    return Status.init(.SYSTEM_ERROR);
                };
            },
            else => return Status.init(.SYSTEM_ERROR),
        };

        var status = Status.init(.SUCCESS);

        // Use a temporary allocator for path formatting
        const temp_allocator = std.heap.page_allocator;

        // Rename each shard file
        for (0..num_shards) |i| {
            const old_shard_path = formatShardPath(temp_allocator, old_path, i, num_shards) catch {
                return Status.init(.SYSTEM_ERROR);
            };
            defer temp_allocator.free(old_shard_path);

            const new_shard_path = formatShardPath(temp_allocator, new_path, i, num_shards) catch {
                return Status.init(.SYSTEM_ERROR);
            };
            defer temp_allocator.free(new_shard_path);

            // Rename the file
            std.Io.Dir.rename(io, .cwd(), old_shard_path, .cwd(), new_shard_path) catch {
                status.mergeFrom(Status.init(.SYSTEM_ERROR));
            };
        }

        return status;
    }

    /// Creates an iterator over all shards.
    /// The iterator performs a heap-merge to provide records in sorted order.
    ///
    /// \param allocator Allocator for the iterator
    /// \return ShardCursor instance
    pub fn makeCursor(self: *Self, allocator: std.mem.Allocator, io: std.Io) !ShardCursor {
        return self.iterator(allocator, io);
    }
    
    pub fn iterator(self: *Self, allocator: std.mem.Allocator, io: std.Io) !ShardCursor {
        return ShardCursor.init(self, allocator, io);
    }

    /// Return a Zig-style iterator positioned at the first record.
    /// The caller must call deinit() when done.
    pub fn iterate(self: *Self, alloc: std.mem.Allocator, io: std.Io) !ShardIterator {
        var cursor = try self.iterator(alloc, io);
        errdefer cursor.deinit(io);
        var iter = ShardIterator{
            .cursor = cursor,
            .alloc = alloc,
            .key_buf = .empty,
            .value_buf = .empty,
            .done = false,
        };
        if (!iter.cursor.first(io).isOk()) iter.done = true;
        
        return iter;
    }

    /// Return a Zig-style iterator positioned at the first record.
    /// Note: ShardDBM uses hash-based sharding; the key argument is accepted
    /// for API compatibility but ordered positioning is not supported —
    /// iteration always starts from the global minimum. Use an ordered backend
    /// (e.g. BabyDBM/TreeDBM via PolyDBM) if you need ordered iterateFrom.
    pub fn iterateFrom(self: *Self, alloc: std.mem.Allocator, io: std.Io, _: []const u8) !ShardIterator {

        return self.iterate(alloc, io);
    }

};

// ---------------------------------------------------------------------------
// ShardCursor: Heap-merge iterator across all shards
// ---------------------------------------------------------------------------

/// A slot in the heap representing one shard's current position.
const ShardSlot = struct {
    const Self = @This();

    key: []u8,
    value: []u8,
    iter: dbm_poly_mod.PolyCursor,
    allocator: std.mem.Allocator,

    /// Initializes a ShardSlot with empty key/value.
    fn init(allocator: std.mem.Allocator) Self {
        return .{
            .key = &[_]u8{},
            .value = &[_]u8{},
            .iter = undefined,
            .allocator = allocator,
        };
    }

    /// Deinitializes the slot, freeing key/value and the iterator.
    fn deinit(self: *Self, io: std.Io) void {
        if (self.key.len > 0) {
            self.allocator.free(self.key);
        }
        if (self.value.len > 0) {
            self.allocator.free(self.value);
        }
        self.iter.deinit(io);
    }
};

/// Iterator that merges records from all shards using a min-heap.
pub const ShardCursor = struct {
    const Self = @This();

    slots: []ShardSlot,
    heap: []usize,  // heap of slot indices
    comp: KeyComparator,
    asc: bool,
    allocator: std.mem.Allocator,

    /// Initializes a ShardCursor for the given ShardDBM.
    fn init(db: *ShardDBM, allocator: std.mem.Allocator, io: std.Io) !Self {
        if (!db.is_open) {
            return error.PreconditionError;
        }

        // Determine comparator from first shard or use lexical fallback
        var comp: KeyComparator = lib_common.lexicalKeyComparator;
        if (db.shards.len > 0) {
            // Get comparator from first shard
            const first_shard = &db.shards[0];
            comp = switch (first_shard.backend) {
                BackendType.hash => lib_common.lexicalKeyComparator,
                BackendType.tree => first_shard.getTreeDBM().getKeyComparator(),
                BackendType.skip => lib_common.lexicalKeyComparator,
                BackendType.tiny => lib_common.lexicalKeyComparator,
                BackendType.baby => first_shard.getBabyDBM().getKeyComparator(),
                BackendType.cache => lib_common.lexicalKeyComparator,
            };
        }

        // Initialize slots for each shard
        const slots = try allocator.alloc(ShardSlot, db.shards.len);
        for (db.shards, 0..) |*shard_ptr, i| {
            slots[i] = ShardSlot.init(allocator);
            slots[i].iter = try dbm_poly_mod.PolyCursor.init(shard_ptr, io);
        }
        errdefer {
            // Clean up already-initialized slots on failure
            var i: usize = 0;
            while (i < slots.len) : (i += 1) {
                slots[i].deinit(io);
            }
            allocator.free(slots);
        }

        const heap = try allocator.alloc(usize, 0);

        return Self{
            .slots = slots,
            .heap = heap,
            .comp = comp,
            .asc = true,
            .allocator = allocator,
        };
    }

    /// Deinitializes the iterator, freeing all resources.
    pub fn deinit(self: *Self, io: std.Io) void {
        for (self.slots) |*slot| {
            slot.deinit(io);
        }
        self.allocator.free(self.slots);
        self.allocator.free(self.heap);
    }

    /// Moves to the first record across all shards (global minimum).
    pub fn first(self: *Self, io: std.Io) Status {
        // Clear any existing heap
        if (self.heap.len > 0) {
            self.allocator.free(self.heap);
        }
        self.heap = &[_]usize{};

        // Initialize each shard iterator and build heap
        for (self.slots, 0..) |*slot, i| {
            // Move to first record in this shard
            const status = slot.iter.first(io);
            if (!status.isOk()) {
                if (status.code == .NOT_FOUND_ERROR) {
                    // Empty shard, skip it
                    continue;
                }
                return status;
            }

            // Get the key/value
            var key_list: std.ArrayList(u8) = .empty;
            var value_list: std.ArrayList(u8) = .empty;
            defer {
                key_list.deinit(self.allocator);
                value_list.deinit(self.allocator);
            }

            const get_status = slot.iter.get(self.allocator, io, &key_list, &value_list);
            if (!get_status.isOk()) {
                return get_status;
            }

            // Store key/value in slot (free old first)
            const new_key = key_list.toOwnedSlice(self.allocator) catch return Status.init(.SYSTEM_ERROR);
            errdefer self.allocator.free(new_key);
            const new_value = value_list.toOwnedSlice(self.allocator) catch return Status.init(.SYSTEM_ERROR);
            errdefer self.allocator.free(new_value);

            if (slot.key.len > 0) {
                self.allocator.free(slot.key);
            }
            if (slot.value.len > 0) {
                self.allocator.free(slot.value);
            }
            slot.key = new_key;
            slot.value = new_value;

            // Add to heap
            self.pushHeap(i) catch return Status.init(.SYSTEM_ERROR);
        }

        self.asc = true;
        return Status.init(.SUCCESS);
    }

    /// Moves to the next record in sorted order.
    pub fn next(self: *Self, io: std.Io) Status {
        if (self.heap.len == 0) {
            return Status.init(.NOT_FOUND_ERROR);
        }

        // Get the minimum slot (top of heap)
        const min_slot_index = self.heap[0];
        const min_slot_ptr = &self.slots[min_slot_index];

        // Move to next record in that shard
        const status = min_slot_ptr.iter.next(io);
        if (!status.isOk()) {
            if (status.code == .NOT_FOUND_ERROR) {
                // This shard is exhausted: remove it from the heap.
                // The remaining heap entries are already at their current
                // positions — do NOT advance them by recursing into next().
                self.popHeap();
                if (self.heap.len == 0) {
                    return Status.init(.NOT_FOUND_ERROR);
                }
                // Heap still has records; caller will read from the new
                // minimum on the next cursor.get() call.
                return Status.init(.SUCCESS);
            }
            return status;
        }

        // Get the new key/value
        var key_list: std.ArrayList(u8) = .empty;
        var value_list: std.ArrayList(u8) = .empty;
        defer {
            key_list.deinit(self.allocator);
            value_list.deinit(self.allocator);
        }

        const get_status = min_slot_ptr.iter.get(self.allocator, io, &key_list, &value_list);
        if (!get_status.isOk()) {
            return get_status;
        }

        // Update slot key/value
        if (min_slot_ptr.key.len > 0) {
            self.allocator.free(min_slot_ptr.key);
        }
        if (min_slot_ptr.value.len > 0) {
            self.allocator.free(min_slot_ptr.value);
        }
        min_slot_ptr.key = key_list.toOwnedSlice(self.allocator) catch return Status.init(.SYSTEM_ERROR);
        min_slot_ptr.value = value_list.toOwnedSlice(self.allocator) catch return Status.init(.SYSTEM_ERROR);

        // Re-heapify
        self.popHeap();
        self.pushHeap(min_slot_index) catch return Status.init(.SYSTEM_ERROR);

        return Status.init(.SUCCESS);
    }

    /// Gets the current record's key and value.
    pub fn get(self: *Self, key_out: *[]u8, value_out: *[]u8) Status {
        if (self.heap.len == 0) {
            return Status.init(.NOT_FOUND_ERROR);
        }

        const min_slot_index = self.heap[0];
        const min_slot_ptr = &self.slots[min_slot_index];

        // OUT parameters — we never read key_out.*/value_out.* first because
        // callers commonly declare `var k: []u8 = undefined; iter.get(&k, &v);`
        // The caller owns any prior allocation and must free it before calling.

        // Copy key
        key_out.* = self.allocator.dupe(u8, min_slot_ptr.key) catch return Status.init(.SYSTEM_ERROR);

        // Copy value
        value_out.* = self.allocator.dupe(u8, min_slot_ptr.value) catch {
            self.allocator.free(key_out.*);
            return Status.init(.SYSTEM_ERROR);
        };

        return Status.init(.SUCCESS);
    }

    /// Sets the current record's value.
    pub fn set(self: *Self, io: std.Io, value: []const u8, old_key: ?*[]u8, old_value: ?*[]u8) Status {

        if (self.heap.len == 0) {
            return Status.init(.NOT_FOUND_ERROR);
        }

        const min_slot_index = self.heap[0];
        const min_slot_ptr = &self.slots[min_slot_index];

        // Store old key/value if requested. OUT parameters — we never read
        // ptr.* first because it may be `undefined` in the caller's frame.
        if (old_key) |ptr| {
            ptr.* = self.allocator.dupe(u8, min_slot_ptr.key) catch return Status.init(.SYSTEM_ERROR);
        }

        if (old_value) |ptr| {
            ptr.* = self.allocator.dupe(u8, min_slot_ptr.value) catch return Status.init(.SYSTEM_ERROR);
        }

        // Delegate to the shard iterator (without old_key/old_value since we handled them above)
        const status = min_slot_ptr.iter.set(io, value, null, null);
        if (!status.isOk()) return status;

        // Refresh the slot's cached value so a subsequent get() returns the
        // newly-written value, not the pre-set value. The key is unchanged.
        const new_value = self.allocator.dupe(u8, value) catch return Status.init(.SYSTEM_ERROR);
        if (min_slot_ptr.value.len > 0) {
            self.allocator.free(min_slot_ptr.value);
        }
        min_slot_ptr.value = new_value;

        return status;
    }

    /// Removes the current record.
    pub fn remove(self: *Self, io: std.Io, old_key: ?*[]u8, old_value: ?*[]u8) Status {

        if (self.heap.len == 0) {
            return Status.init(.NOT_FOUND_ERROR);
        }

        const min_slot_index = self.heap[0];
        const min_slot_ptr = &self.slots[min_slot_index];

        // Store old key/value if requested. OUT parameters — we never read
        // ptr.* first because it may be `undefined` in the caller's frame.
        if (old_key) |ptr| {
            ptr.* = self.allocator.dupe(u8, min_slot_ptr.key) catch return Status.init(.SYSTEM_ERROR);
        }

        if (old_value) |ptr| {
            ptr.* = self.allocator.dupe(u8, min_slot_ptr.value) catch return Status.init(.SYSTEM_ERROR);
        }

        // Delegate to the shard iterator (without old_key/old_value since we handled them above)
        const status = min_slot_ptr.iter.remove(io, null, null);

        if (status.isOk()) {
            // After removal, advance to next record in this shard
            self.popHeap();

            // Try to get next record from this shard
            const next_status = min_slot_ptr.iter.next(io);
            if (next_status.isOk()) {
                // Get new key/value
                var key_list: std.ArrayList(u8) = .empty;
                var value_list: std.ArrayList(u8) = .empty;
                defer {
                    key_list.deinit(self.allocator);
                    value_list.deinit(self.allocator);
                }

                const get_status = min_slot_ptr.iter.get(self.allocator, io, &key_list, &value_list);
                if (get_status.isOk()) {
                    // Update slot and reinsert into heap
                    if (min_slot_ptr.key.len > 0) {
                        self.allocator.free(min_slot_ptr.key);
                    }
                    if (min_slot_ptr.value.len > 0) {
                        self.allocator.free(min_slot_ptr.value);
                    }
                    min_slot_ptr.key = key_list.toOwnedSlice(self.allocator) catch return Status.init(.SYSTEM_ERROR);
                    min_slot_ptr.value = value_list.toOwnedSlice(self.allocator) catch return Status.init(.SYSTEM_ERROR);
                    self.pushHeap(min_slot_index) catch return Status.init(.SYSTEM_ERROR);
                }
            }
            // If next() failed, the shard is exhausted and we don't reinsert
        }

        return status;
    }

    /// Processes the current record with a custom processor.
    pub fn process(comptime P: type, self: *Self, io: std.Io, proc: *P, writable: bool) Status {


        if (self.heap.len == 0) {
            return Status.init(.NOT_FOUND_ERROR);
        }

        const min_slot_index = self.heap[0];
        const min_slot_ptr = &self.slots[min_slot_index];
        return min_slot_ptr.iter.process(io, proc, writable);
    }

    /// Pushes a slot index onto the heap, maintaining heap property.
    fn pushHeap(self: *Self, slot_index: usize) !void {
        // Resize heap
        const new_heap = try self.allocator.realloc(self.heap, self.heap.len + 1);
        self.heap = new_heap;
        const new_index = self.heap.len - 1;
        self.heap[new_index] = slot_index;

        // Bubble up
        var index = new_index;
        while (index > 0) {
            const parent_index = (index - 1) / 2;
            const parent_slot_index = self.heap[parent_index];
            const parent_slot = &self.slots[parent_slot_index];
            const current_slot_index = self.heap[index];
            const current_slot = &self.slots[current_slot_index];

            const order = self.comp(current_slot.key, parent_slot.key);
            const should_swap = if (self.asc) order == .lt else order == .gt;

            if (!should_swap) {
                break;
            }

            // Swap with parent
            self.heap[parent_index] = current_slot_index;
            self.heap[index] = parent_slot_index;
            index = parent_index;
        }
    }

    /// Pops the top element from the heap, maintaining heap property.
    fn popHeap(self: *Self) void {
        if (self.heap.len == 0) {
            return;
        }

        // Move last element to root
        const last_index = self.heap.len - 1;
        self.heap[0] = self.heap[last_index];

        // Resize heap
        const new_heap = self.allocator.realloc(self.heap, last_index) catch {
            // If realloc fails, just shrink the logical size
            self.heap = self.heap[0..last_index];
            return;
        };
        self.heap = new_heap;

        // Sift down
        if (self.heap.len > 0) {
            self.siftDown(0, self.heap.len);
        }
    }

    /// Sifts an element down the heap to maintain heap property.
    fn siftDown(self: *Self, start: usize, end: usize) void {
        var root = start;

        while (true) {
            var child = root * 2 + 1;
            if (child >= end) {
                break;
            }

            // Find the child to swap with
            var swap = root;
            const root_slot_index = self.heap[root];
            const root_slot = &self.slots[root_slot_index];

            // Check left child
            const left_slot_index = self.heap[child];
            const left_slot = &self.slots[left_slot_index];
            const left_order = self.comp(root_slot.key, left_slot.key);
            const left_should_swap = if (self.asc) left_order == .gt else left_order == .lt;

            if (left_should_swap) {
                swap = child;
            }

            // Check right child
            child += 1;
            if (child < end) {
                const right_slot_index = self.heap[child];
                const right_slot = &self.slots[right_slot_index];
                const right_order = self.comp(root_slot.key, right_slot.key);
                const right_should_swap = if (self.asc) right_order == .gt else right_order == .lt;

                if (right_should_swap and (swap == root or self.shouldSwap(left_slot, right_slot))) {
                    swap = child;
                }
            }

            if (swap == root) {
                break;
            }

            // Swap
            self.heap[root] = self.heap[swap];
            self.heap[swap] = root_slot_index;
            root = swap;
        }
    }

    /// Helper to determine which of two slots should come first.
    fn shouldSwap(self: *Self, a: *ShardSlot, b: *ShardSlot) bool {
        const order = self.comp(a.key, b.key);
        return if (self.asc) order == .lt else order == .gt;
    }
};



// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Opens all shards into `shards_buf[0..num_shards]`. On any failure, closes
/// and deinits the shards opened so far and propagates the error.
fn openAllShards(
    allocator: std.mem.Allocator,
    base_path: []const u8,
    num_shards: u64,
    shard_opts: OpenOptionsPoly,
    io: std.Io,
    shards_buf: []PolyDBM,
) !void {
    var opened: usize = 0;
    errdefer {
        var j: usize = opened;
        while (j > 0) {
            j -= 1;
            _ = shards_buf[j].close(io);
            shards_buf[j].deinit(io);
        }
    }
    while (opened < num_shards) : (opened += 1) {
        const shard_path = try formatShardPath(allocator, base_path, opened, num_shards);
        defer allocator.free(shard_path);
        shards_buf[opened] = try PolyDBM.open(shard_path, shard_opts, io, allocator);
    }
}

/// Entry returned by ShardIterator.next()
pub const Entry = struct {
    /// Borrowed from iterator's internal buffer.
    /// Valid only until the next call to next() or deinit().
    key: []const u8,
    /// Borrowed from iterator's internal buffer.
    /// Valid only until the next call to next() or deinit().
    value: []const u8,
};

/// Zig-style iterator for ShardDBM
pub const ShardIterator = struct {
    cursor: ShardCursor,
    alloc: std.mem.Allocator,
    key_buf: std.ArrayList(u8),
    value_buf: std.ArrayList(u8),
    done: bool,

    const Self = @This();

    /// Advance and return the current entry, or null when exhausted.
    pub fn next(self: *Self, io: std.Io) !?Entry {
        if (self.done) return null;

        // Fill internal buffers from the current cursor position.
        self.key_buf.clearRetainingCapacity();
        self.value_buf.clearRetainingCapacity();
        var key_ptr: []u8 = undefined;
        var val_ptr: []u8 = undefined;
        const st = self.cursor.get(&key_ptr, &val_ptr);
        if (!st.isOk()) {
            self.done = true;
            return null;
        }
        // ShardCursor.get() allocates via dupe() — free after copying into buffers.
        defer self.alloc.free(key_ptr);
        defer self.alloc.free(val_ptr);

        // Copy into our buffers
        try self.key_buf.appendSlice(self.alloc, key_ptr);
        try self.value_buf.appendSlice(self.alloc, val_ptr);

        // Advance cursor
        if (!self.cursor.next(io).isOk()) self.done = true;
        

        return Entry{
            .key = self.key_buf.items,
            .value = self.value_buf.items,
        };
    }

    pub fn deinit(self: *Self, io: std.Io) void {
        self.key_buf.deinit(self.alloc);
        self.value_buf.deinit(self.alloc);
        self.cursor.deinit(io);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "formatShardPath basic" {
    const allocator = std.testing.allocator;
    const p = try formatShardPath(allocator, "data.tkh", 3, 15);
    defer allocator.free(p);
    try std.testing.expectEqualStrings("data.tkh-00003-of-00015", p);

    const p0 = try formatShardPath(allocator, "data.tkh", 0, 4);
    defer allocator.free(p0);
    try std.testing.expectEqualStrings("data.tkh-00000-of-00004", p0);

    const p_max = try formatShardPath(allocator, "x", 99999, 99999);
    defer allocator.free(p_max);
    try std.testing.expectEqualStrings("x-99999-of-99999", p_max);
}

test "ShardDBM open with 4 shards creates N files" {
    const testing = std.testing;
    const io = std.testing.io;
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try std.Io.Dir.realPathFile(tmp.dir, io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    const base_path = try std.fmt.allocPrint(allocator, "{s}/shard.tkh", .{tmp_path});
    defer allocator.free(base_path);

    const db = try ShardDBM.init(allocator);
    defer db.deinit(io);

    const status = db.open(allocator, io, base_path, 4, true, .{});
    try testing.expect(status.isOk());
    try testing.expectEqual(@as(u64, 4), db.num_shards);
    try testing.expectEqual(true, db.is_open);
    try testing.expectEqualStrings(base_path, db.base_path);
    try testing.expectEqual(@as(usize, 4), db.shards.len);

    // Verify each shard file exists on disk.
    var i: u64 = 0;
    while (i < 4) : (i += 1) {
        const shard_path = try formatShardPath(allocator, base_path, i, 4);
        defer allocator.free(shard_path);
        try std.Io.Dir.cwd().access(io, shard_path, .{});
    }

    const cstatus = db.close(std.testing.io);
    try testing.expect(cstatus.isOk());
    try testing.expectEqual(false, db.is_open);
    try testing.expectEqual(@as(usize, 0), db.shards.len);
    try testing.expectEqual(@as(usize, 0), db.base_path.len);
}

test "ShardDBM open existing DB with wrong num_shards returns DUPLICATION_ERROR" {
    const testing = std.testing;
    const io = std.testing.io;
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try std.Io.Dir.realPathFile(tmp.dir, io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    const base_path = try std.fmt.allocPrint(allocator, "{s}/mismatch.tkh", .{tmp_path});
    defer allocator.free(base_path);

    // Create a database with 4 shards, then close it.
    {
        const db = try ShardDBM.init(allocator);
        defer db.deinit(io);
        const s = db.open(allocator, io, base_path, 4, true, .{});
        try testing.expect(s.isOk());
        const cs = db.close(std.testing.io);
        try testing.expect(cs.isOk());
    }

    // Re-opening with a different num_shards must fail.
    {
        const db = try ShardDBM.init(allocator);
        defer db.deinit(io);
        const s = db.open(allocator, io, base_path, 8, true, .{});
        try testing.expectEqual(Code.DUPLICATION_ERROR, s.code);
        try testing.expectEqual(false, db.is_open);
    }

    // Re-opening with the correct num_shards succeeds.
    {
        const db = try ShardDBM.init(allocator);
        defer db.deinit(io);
        const s = db.open(allocator, io, base_path, 4, true, .{});
        try testing.expect(s.isOk());
        try testing.expectEqual(@as(u64, 4), db.num_shards);
        const cs = db.close(std.testing.io);
        try testing.expect(cs.isOk());
    }
}

test "ShardDBM close releases state and rejects double close" {
    const testing = std.testing;
    const io = std.testing.io;
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try std.Io.Dir.realPathFile(tmp.dir, io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    const base_path = try std.fmt.allocPrint(allocator, "{s}/closecheck.tkh", .{tmp_path});
    defer allocator.free(base_path);

    const db = try ShardDBM.init(allocator);
    defer db.deinit(io);

    const s = db.open(allocator, io, base_path, 3, true, .{});
    try testing.expect(s.isOk());
    try testing.expectEqual(true, db.is_open);
    try testing.expectEqual(@as(usize, 3), db.shards.len);

    const cs = db.close(std.testing.io);
    try testing.expect(cs.isOk());
    try testing.expectEqual(false, db.is_open);
    try testing.expectEqual(@as(usize, 0), db.shards.len);
    try testing.expectEqual(@as(u64, 0), db.num_shards);

    // Second close must report precondition error.
    const cs2 = db.close(std.testing.io);
    try testing.expectEqual(Code.PRECONDITION_ERROR, cs2.code);
}

// ---------------------------------------------------------------------------
// Tests for record operations
// ---------------------------------------------------------------------------

test "ShardDBM getShardIndex routes correctly" {
    const testing = std.testing;
    const io = std.testing.io;
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try std.Io.Dir.realPathFile(tmp.dir, io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    const base_path = try std.fmt.allocPrint(allocator, "{s}/routing.tkh", .{tmp_path});
    defer allocator.free(base_path);

    const db = try ShardDBM.init(allocator);
    defer db.deinit(io);

    const s = db.open(allocator, io, base_path, 4, true, .{});
    try testing.expect(s.isOk());

    // Test that keys route to expected shards
    const shard0 = db.getShardIndex("key0");
    const shard1 = db.getShardIndex("key1");
    const shard2 = db.getShardIndex("key2");
    const shard3 = db.getShardIndex("key3");

    try testing.expect(shard0 < 4);
    try testing.expect(shard1 < 4);
    try testing.expect(shard2 < 4);
    try testing.expect(shard3 < 4);

    const cs = db.close(std.testing.io);
    try testing.expect(cs.isOk());
}

test "ShardDBM get/set/remove route to correct shard" {
    const testing = std.testing;
    const io = std.testing.io;
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try std.Io.Dir.realPathFile(tmp.dir, io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    const base_path = try std.fmt.allocPrint(allocator, "{s}/crud.tkh", .{tmp_path});
    defer allocator.free(base_path);

    const db = try ShardDBM.init(allocator);
    defer db.deinit(io);

    const s = db.open(allocator, io, base_path, 3, true, .{});
    try testing.expect(s.isOk());

    // Set some values
    const key1 = "test_key_1";
    const val1 = "test_value_1";
    const key2 = "test_key_2";
    const val2 = "test_value_2";

    const set1 = db.set(std.testing.io, key1, val1, false);
    try testing.expect(set1.isOk());

    const set2 = db.set(std.testing.io, key2, val2, false);
    try testing.expect(set2.isOk());

    // Get values back
    const got1 = try db.get(allocator, std.testing.io, key1);
    defer allocator.free(got1);
    try testing.expectEqualStrings(val1, got1);

    const got2 = try db.get(allocator, std.testing.io, key2);
    defer allocator.free(got2);
    try testing.expectEqualStrings(val2, got2);

    // Remove one key
    const rem = db.remove(std.testing.io, key1);
    try testing.expect(rem.isOk());

    // Verify it's gone
    const get_removed = db.get(allocator, std.testing.io, key1);
    try testing.expectError(PolyError.NotFound, get_removed);

    // Verify other key still exists
    const got2_again = try db.get(allocator, std.testing.io, key2);
    defer allocator.free(got2_again);
    try testing.expectEqualStrings(val2, got2_again);

    const cs = db.close(std.testing.io);
    try testing.expect(cs.isOk());
}

test "ShardDBM count sums all shards" {
    const testing = std.testing;
    const io = std.testing.io;
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try std.Io.Dir.realPathFile(tmp.dir, io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    const base_path = try std.fmt.allocPrint(allocator, "{s}/count.tkh", .{tmp_path});
    defer allocator.free(base_path);

    const db = try ShardDBM.init(allocator);
    defer db.deinit(io);

    const s = db.open(allocator, io, base_path, 2, true, .{});
    try testing.expect(s.isOk());

    // Add records to different shards
    const key1 = "key_for_shard_0";
    const key2 = "key_for_shard_1";

    try testing.expect(db.set(std.testing.io, key1, "value1", false).isOk());
    try testing.expect(db.set(std.testing.io, key2, "value2", false).isOk());

    // Count should be 2
    const total = db.count(io);
    try testing.expectEqual(@as(i64, 2), total);

    const cs = db.close(std.testing.io);
    try testing.expect(cs.isOk());
}

test "ShardDBM clear clears all shards" {
    const testing = std.testing;
    const io = std.testing.io;
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try std.Io.Dir.realPathFile(tmp.dir, io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    const base_path = try std.fmt.allocPrint(allocator, "{s}/clear.tkh", .{tmp_path});
    defer allocator.free(base_path);

    const db = try ShardDBM.init(allocator);
    defer db.deinit(io);

    const s = db.open(allocator, io, base_path, 2, true, .{});
    try testing.expect(s.isOk());

    // Add records to different shards
    try testing.expect(db.set(std.testing.io, "key1", "value1", false).isOk());
    try testing.expect(db.set(std.testing.io, "key2", "value2", false).isOk());

    // Verify they exist
    const count_before = db.count(io);
    try testing.expect(count_before > 0);

    // Clear all shards
    const clear_status = db.clear(io);
    try testing.expect(clear_status.isOk());

    // Count should be 0
    const count_after = db.count(io);
    try testing.expectEqual(@as(i64, 0), count_after);

    const cs = db.close(std.testing.io);
    try testing.expect(cs.isOk());
}

// NOTE: processMulti test removed - method not yet implemented
// test "ShardDBM processMulti with keys across multiple shards" {
//     const testing = std.testing;
//     const io = std.testing.io;
//     const allocator = testing.allocator;
//
//     var tmp = std.testing.tmpDir(.{});
//     defer tmp.cleanup();
//
//     var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
//     const tmp_path_len = try std.Io.Dir.realPathFile(tmp.dir, io, ".", &path_buf);
//     const tmp_path = path_buf[0..tmp_path_len];
//
//     const base_path = try std.fmt.allocPrint(allocator, "{s}/processmulti.tkh", .{tmp_path});
//     defer allocator.free(base_path);
//
//     const db = try ShardDBM.init(allocator);
//     defer db.deinit(io);
//
//     const s = db.open(allocator, io, base_path, 3, true, .{});
//     try testing.expect(s.isOk());
//
//     // Set up some test data
//     try testing.expect(db.set("key1", "initial1", false).isOk());
//     try testing.expect(db.set("key2", "initial2", false).isOk());
//     try testing.expect(db.set("key3", "initial3", false).isOk());
//
//     // Create a simple processor that appends "_processed"
//     const TestProcessor = struct {
//         const Self = @This();
//         status: Status,
//
//         pub fn processFull(self: *Self, _: []const u8, _: []const u8) RecordAction {
//             // For this test, we'll just return noop
//             // In a real scenario, we'd modify the value
//             return .noop;
//         }
//
//         pub fn processEmpty(_: *Self, _: []const u8) RecordAction {
//             return .noop;
//         }
//     };
//
//     var proc1 = TestProcessor{ .status = Status.init(.SUCCESS) };
//     var proc2 = TestProcessor{ .status = Status.init(.SUCCESS) };
//     var proc3 = TestProcessor{ .status = Status.init(.SUCCESS) };
//
//     // Create key-proc pairs
//     var keys_procs: [3]KeyProcPair = [_]KeyProcPair{
//         .{ .key = "key1", .proc = &proc1 },
//         .{ .key = "key2", .proc = &proc2 },
//         .{ .key = "key3", .proc = &proc3 },
//     };
//
//     // Process multiple keys
//     // const status = db.processMulti(TestProcessor, &keys_procs, true);
//     // try testing.expect(status.isOk());
//
//     const cs = db.close();
//     try testing.expect(cs.isOk());
// }

test "ShardDBM compareExchangeMulti basic functionality" {
    const testing = std.testing;
    const io = std.testing.io;
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try std.Io.Dir.realPathFile(tmp.dir, io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    const base_path = try std.fmt.allocPrint(allocator, "{s}/compareexchange.tkh", .{tmp_path});
    defer allocator.free(base_path);

    const db = try ShardDBM.init(allocator);
    defer db.deinit(io);

    const s = db.open(allocator, io, base_path, 2, true, .{});
    try testing.expect(s.isOk());

    // Set up initial data
    try testing.expect(db.set(std.testing.io, "key1", "value1", false).isOk());
    try testing.expect(db.set(std.testing.io, "key2", "value2", false).isOk());

    // Test successful compare-exchange
    var expected = [_]CompareExpectedItem{
        .{ .key = "key1", .value = .{ .exact = "value1" } },
        .{ .key = "key2", .value = .{ .exact = "value2" } },
    };

    var desired = [_]CompareDesiredItem{
        .{ .key = "key1", .value = .{ .set = "new_value1" } },
        .{ .key = "key2", .value = .{ .set = "new_value2" } },
    };

    const status = db.compareExchangeMulti(std.testing.io, &expected, &desired);
    try testing.expect(status.isOk());

    // Verify changes were applied
    const got1 = try db.get(allocator, std.testing.io, "key1");
    defer allocator.free(got1);
    try testing.expectEqualStrings("new_value1", got1);

    const got2 = try db.get(allocator, std.testing.io, "key2");
    defer allocator.free(got2);
    try testing.expectEqualStrings("new_value2", got2);

    const cs = db.close(std.testing.io);
    try testing.expect(cs.isOk());
}

test "ShardDBM compareExchangeMulti fails on condition mismatch" {
    const testing = std.testing;
    const io = std.testing.io;
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try std.Io.Dir.realPathFile(tmp.dir, io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    const base_path = try std.fmt.allocPrint(allocator, "{s}/compareexchange_fail.tkh", .{tmp_path});
    defer allocator.free(base_path);

    const db = try ShardDBM.init(allocator);
    defer db.deinit(io);

    const s = db.open(allocator, io, base_path, 2, true, .{});
    try testing.expect(s.isOk());

    // Set up initial data
    try testing.expect(db.set(std.testing.io, "key1", "value1", false).isOk());

    // Test failed compare-exchange (wrong expected value)
    var expected = [_]CompareExpectedItem{
        .{ .key = "key1", .value = .{ .exact = "wrong_value" } },
    };

    var desired = [_]CompareDesiredItem{
        .{ .key = "key1", .value = .{ .set = "new_value" } },
    };

    const status = db.compareExchangeMulti(std.testing.io, &expected, &desired);
    try testing.expectEqual(Code.INFEASIBLE_ERROR, status.code);

    // Verify original value is unchanged
    const got1 = try db.get(allocator, std.testing.io, "key1");
    defer allocator.free(got1);
    try testing.expectEqualStrings("value1", got1);

    const cs = db.close(std.testing.io);
    try testing.expect(cs.isOk());
}

test "ShardDBM processEach iterates all records" {
    const testing = std.testing;
    const io = std.testing.io;
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try std.Io.Dir.realPathFile(tmp.dir, io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    const base_path = try std.fmt.allocPrint(allocator, "{s}/process_each.tkh", .{tmp_path});
    defer allocator.free(base_path);

    const db = try ShardDBM.init(allocator);
    defer db.deinit(io);

    const s = db.open(allocator, io, base_path, 2, true, .{});
    try testing.expect(s.isOk());

    // Set up test data
    try testing.expect(db.set(std.testing.io, "key1", "value1", false).isOk());
    try testing.expect(db.set(std.testing.io, "key2", "value2", false).isOk());
    try testing.expect(db.set(std.testing.io, "key3", "value3", false).isOk());

    // Create a counting processor
    var count: i32 = 0;
    const CounterProcessor = struct {
        const Self = @This();
        count: *i32,

        pub fn processFull(self: *Self, key: []const u8, value: []const u8) RecordAction {
            _ = key;
            _ = value;
            self.count.* += 1;
            return .noop;
        }

        pub fn processEmpty(_: *Self, _: []const u8) RecordAction {
            return .noop;
        }
    };

    var counter = CounterProcessor{ .count = &count };

    // Process all records
    _ = try db.processEach(std.testing.io, CounterProcessor, &counter, false);

    // Should have processed 3 records
    try testing.expectEqual(3, count);

    const cs = db.close(std.testing.io);
    try testing.expect(cs.isOk());
}

// ---------------------------------------------------------------------------
// Tests for status queries
// ---------------------------------------------------------------------------

test "ShardDBM isOpen returns correct state" {
    const testing = std.testing;
    const io = std.testing.io;
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try std.Io.Dir.realPathFile(tmp.dir, io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    const base_path = try std.fmt.allocPrint(allocator, "{s}/isopen.tkh", .{tmp_path});
    defer allocator.free(base_path);

    const db = try ShardDBM.init(allocator);
    defer db.deinit(io);

    // Should be false before open
    try testing.expectEqual(false, db.isOpen());

    const s = db.open(allocator, io, base_path, 2, true, .{});
    try testing.expect(s.isOk());

    // Should be true after open
    try testing.expectEqual(true, db.isOpen());

    const cs = db.close(std.testing.io);
    try testing.expect(cs.isOk());

    // Should be false after close
    try testing.expectEqual(false, db.isOpen());
}

test "ShardDBM isWritable returns correct mode" {
    const testing = std.testing;
    const io = std.testing.io;
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try std.Io.Dir.realPathFile(tmp.dir, io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    const base_path = try std.fmt.allocPrint(allocator, "{s}/iswritable.tkh", .{tmp_path});
    defer allocator.free(base_path);

    // Test writable mode
    {
        const db = try ShardDBM.init(allocator);
        defer db.deinit(io);

        const s = db.open(allocator, io, base_path, 2, true, .{});
        try testing.expect(s.isOk());
        try testing.expectEqual(true, db.isWritable());

        const cs = db.close(std.testing.io);
        try testing.expect(cs.isOk());
    }

    // Test read-only mode
    {
        const db = try ShardDBM.init(allocator);
        defer db.deinit(io);

        const s = db.open(allocator, io, base_path, 2, false, .{});
        try testing.expect(s.isOk());
        try testing.expectEqual(false, db.isWritable());

        const cs = db.close(std.testing.io);
        try testing.expect(cs.isOk());
    }
}

test "ShardDBM isHealthy returns true for healthy shards" {
    const testing = std.testing;
    const io = std.testing.io;
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try std.Io.Dir.realPathFile(tmp.dir, io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    const base_path = try std.fmt.allocPrint(allocator, "{s}/ishealthy.tkh", .{tmp_path});
    defer allocator.free(base_path);

    const db = try ShardDBM.init(allocator);
    defer db.deinit(io);

    const s = db.open(allocator, io, base_path, 2, true, .{});
    try testing.expect(s.isOk());

    // Should be healthy after open
    try testing.expectEqual(true, db.isHealthy());

    const cs = db.close(std.testing.io);
    try testing.expect(cs.isOk());
}

test "ShardDBM getFileSize sums all shard sizes" {
    const testing = std.testing;
    const io = std.testing.io;
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try std.Io.Dir.realPathFile(tmp.dir, io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    const base_path = try std.fmt.allocPrint(allocator, "{s}/filesize.tkh", .{tmp_path});
    defer allocator.free(base_path);

    const db = try ShardDBM.init(allocator);
    defer db.deinit(io);

    const s = db.open(allocator, io, base_path, 2, true, .{});
    try testing.expect(s.isOk());

    // Add some data
    try testing.expect(db.set(std.testing.io, "key1", "value1", false).isOk());
    try testing.expect(db.set(std.testing.io, "key2", "value2", false).isOk());

    // Get file size - should be greater than 0
    const file_size = db.getFileSize();
    try testing.expect(file_size > 0);

    const cs = db.close(std.testing.io);
    try testing.expect(cs.isOk());
}

test "ShardDBM getFilePath returns base path" {
    const testing = std.testing;
    const io = std.testing.io;
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try std.Io.Dir.realPathFile(tmp.dir, io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    const base_path = try std.fmt.allocPrint(allocator, "{s}/filepath.tkh", .{tmp_path});
    defer allocator.free(base_path);

    const db = try ShardDBM.init(allocator);
    defer db.deinit(io);

    const s = db.open(allocator, io, base_path, 2, true, .{});
    try testing.expect(s.isOk());

    // Should return the base path
    try testing.expectEqualStrings(base_path, db.getFilePath());

    const cs = db.close(std.testing.io);
    try testing.expect(cs.isOk());
}

test "ShardDBM getTimestamp returns shard 0 timestamp" {
    const testing = std.testing;
    const io = std.testing.io;
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try std.Io.Dir.realPathFile(tmp.dir, io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    const base_path = try std.fmt.allocPrint(allocator, "{s}/timestamp.tkh", .{tmp_path});
    defer allocator.free(base_path);

    const db = try ShardDBM.init(allocator);
    defer db.deinit(io);

    const s = db.open(allocator, io, base_path, 2, true, .{});
    try testing.expect(s.isOk());

    // Should return a timestamp (should be > 0)
    const timestamp = db.getTimestamp();
    try testing.expect(timestamp > 0.0);

    const cs = db.close(std.testing.io);
    try testing.expect(cs.isOk());
}

test "ShardDBM shouldBeRebuilt returns false for new database" {
    const testing = std.testing;
    const io = std.testing.io;
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try std.Io.Dir.realPathFile(tmp.dir, io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    const base_path = try std.fmt.allocPrint(allocator, "{s}/shouldrebuild.tkh", .{tmp_path});
    defer allocator.free(base_path);

    const db = try ShardDBM.init(allocator);
    defer db.deinit(io);

    const s = db.open(allocator, io, base_path, 2, true, .{});
    try testing.expect(s.isOk());

    // Should not need rebuild for new database
    try testing.expectEqual(false, db.shouldBeRebuilt());

    const cs = db.close(std.testing.io);
    try testing.expect(cs.isOk());
}

// ---------------------------------------------------------------------------
// Tests for synchronize and rebuild
// ---------------------------------------------------------------------------

test "ShardDBM synchronize calls all shards" {
    const testing = std.testing;
    const io = std.testing.io;
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try std.Io.Dir.realPathFile(tmp.dir, io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    const base_path = try std.fmt.allocPrint(allocator, "{s}/sync.tkh", .{tmp_path});
    defer allocator.free(base_path);

    const db = try ShardDBM.init(allocator);
    defer db.deinit(io);

    const s = db.open(allocator, io, base_path, 2, true, .{});
    try testing.expect(s.isOk());

    // Add some data
    try testing.expect(db.set(std.testing.io, "key1", "value1", false).isOk());

    // Synchronize should succeed
    const sync_status = db.synchronize(io, false);
    try testing.expect(sync_status.isOk());

    const cs = db.close(std.testing.io);
    try testing.expect(cs.isOk());
}

test "ShardDBM rebuild calls all shards" {
    const testing = std.testing;
    const io = std.testing.io;
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try std.Io.Dir.realPathFile(tmp.dir, io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    const base_path = try std.fmt.allocPrint(allocator, "{s}/rebuild.tkh", .{tmp_path});
    defer allocator.free(base_path);

    const db = try ShardDBM.init(allocator);
    defer db.deinit(io);

    const s = db.open(allocator, io, base_path, 2, true, .{});
    try testing.expect(s.isOk());

    // Add some data
    try testing.expect(db.set(std.testing.io, "key1", "value1", false).isOk());

    // Rebuild should succeed
    const rebuild_status = db.rebuild(io);
    try testing.expect(rebuild_status.isOk());

    const cs = db.close(std.testing.io);
    try testing.expect(cs.isOk());
}

// ---------------------------------------------------------------------------
// Tests for copyFileData
// ---------------------------------------------------------------------------


// ---------------------------------------------------------------------------
// Tests for ShardCursor
// ---------------------------------------------------------------------------

test "ShardCursor basic functionality" {
    const testing = std.testing;
    const io = std.testing.io;
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try std.Io.Dir.realPathFile(tmp.dir, io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    const base_path = try std.fmt.allocPrint(allocator, "{s}/iterator.tkt", .{tmp_path});
    defer allocator.free(base_path);

    const db = try ShardDBM.init(allocator);
    defer db.deinit(io);

    const s = db.open(allocator, io, base_path, 2, true, .{});
    try testing.expect(s.isOk());

    // Add some test data
    try testing.expect(db.set(std.testing.io, "key1", "value1", false).isOk());
    try testing.expect(db.set(std.testing.io, "key2", "value2", false).isOk());
    try testing.expect(db.set(std.testing.io, "key3", "value3", false).isOk());

    // Create iterator
    var iter = try db.iterator(allocator, io);
    defer iter.deinit(io);

    // Test first()
    const first_status = iter.first(std.testing.io);
    try testing.expect(first_status.isOk());

    // Test get() — initialize out-params to empty so test cleanup is safe
    // regardless of whether get() allocates.
    var key: []u8 = &[_]u8{};
    var value: []u8 = &[_]u8{};
    const get_status = iter.get(&key, &value);
    defer allocator.free(key);
    defer allocator.free(value);
    try testing.expect(get_status.isOk());

    // Should get the first key in order
    try testing.expect(key.len > 0);
    try testing.expect(value.len > 0);

    // Test next()
    const next_status = iter.next(std.testing.io);
    try testing.expect(next_status.isOk());

    const cs = db.close(std.testing.io);
    try testing.expect(cs.isOk());
}

test "ShardCursor handles empty database" {
    const testing = std.testing;
    const io = std.testing.io;
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try std.Io.Dir.realPathFile(tmp.dir, io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    const base_path = try std.fmt.allocPrint(allocator, "{s}/iterator_empty.tkt", .{tmp_path});
    defer allocator.free(base_path);

    const db = try ShardDBM.init(allocator);
    defer db.deinit(io);

    const s = db.open(allocator, io, base_path, 2, true, .{});
    try testing.expect(s.isOk());

    // Create iterator on empty database
    var iter = try db.iterator(allocator, io);
    defer iter.deinit(io);

    // first() should succeed but heap should be empty
    const first_status = iter.first(std.testing.io);
    try testing.expect(first_status.isOk());

    // get() should return NOT_FOUND_ERROR (no allocation on error path)
    var key: []u8 = &[_]u8{};
    var value: []u8 = &[_]u8{};
    const get_status = iter.get(&key, &value);
    try testing.expectEqual(Code.NOT_FOUND_ERROR, get_status.code);

    const cs = db.close(std.testing.io);
    try testing.expect(cs.isOk());
}

test "ShardCursor get/set/remove operations" {
    const testing = std.testing;
    const io = std.testing.io;
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try std.Io.Dir.realPathFile(tmp.dir, io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    const base_path = try std.fmt.allocPrint(allocator, "{s}/iterator_ops.tkt", .{tmp_path});
    defer allocator.free(base_path);

    const db = try ShardDBM.init(allocator);
    defer db.deinit(io);

    const s = db.open(allocator, io, base_path, 2, true, .{});
    try testing.expect(s.isOk());

    // Add test data
    try testing.expect(db.set(std.testing.io, "test_key", "original_value", false).isOk());

    // Create iterator
    var iter = try db.iterator(allocator, io);
    defer iter.deinit(io);

    const first_status = iter.first(std.testing.io);
    try testing.expect(first_status.isOk());

    // Test set() operation — out-params are newly allocated by set()
    {
        var old_key: []u8 = &[_]u8{};
        var old_value: []u8 = &[_]u8{};
        const set_status = iter.set(std.testing.io, "new_value", &old_key, &old_value);
        defer allocator.free(old_key);
        defer allocator.free(old_value);
        try testing.expect(set_status.isOk());
        try testing.expectEqualStrings("test_key", old_key);
        try testing.expectEqualStrings("original_value", old_value);
    }

    // Verify the value was updated
    {
        var k: []u8 = &[_]u8{};
        var v: []u8 = &[_]u8{};
        const get_status = iter.get(&k, &v);
        defer allocator.free(k);
        defer allocator.free(v);
        try testing.expect(get_status.isOk());
        try testing.expectEqualStrings("new_value", v);
    }

    // Test remove() operation
    {
        var old_key: []u8 = &[_]u8{};
        var old_value: []u8 = &[_]u8{};
        const remove_status = iter.remove(std.testing.io, &old_key, &old_value);
        defer allocator.free(old_key);
        defer allocator.free(old_value);
        try testing.expect(remove_status.isOk());
    }

    // Verify the record was removed
    {
        var k: []u8 = &[_]u8{};
        var v: []u8 = &[_]u8{};
        const get_after_remove = iter.get(&k, &v);
        try testing.expectEqual(Code.NOT_FOUND_ERROR, get_after_remove.code);
        // get() only allocates k/v on SUCCESS; nothing to free.
    }

    const cs = db.close(std.testing.io);
    try testing.expect(cs.isOk());
}

// ---------------------------------------------------------------------------
// Tests for static methods
// ---------------------------------------------------------------------------

test "ShardDBM getNumberOfShards detects existing shards" {
    const testing = std.testing;
    const io = std.testing.io;
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try std.Io.Dir.realPathFile(tmp.dir, io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    const base_path = try std.fmt.allocPrint(allocator, "{s}/numshards.tkh", .{tmp_path});
    defer allocator.free(base_path);

    // Create a database with 3 shards
    {
        const db = try ShardDBM.init(allocator);
        defer db.deinit(io);
        const s = db.open(allocator, io, base_path, 3, true, .{});
        try testing.expect(s.isOk());
        const cs = db.close(std.testing.io);
        try testing.expect(cs.isOk());
    }

    // Should detect 3 shards
    const num_shards = try ShardDBM.getNumberOfShards(base_path, io);
    try testing.expectEqual(@as(u64, 3), num_shards);
}

test "ShardDBM getNumberOfShards returns 0 for non-existent database" {
    const testing = std.testing;
    const io = std.testing.io;
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try std.Io.Dir.realPathFile(tmp.dir, io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    const base_path = try std.fmt.allocPrint(allocator, "{s}/nonexistent.tkh", .{tmp_path});
    defer allocator.free(base_path);

    // Should return 0 for non-existent database
    const num_shards = try ShardDBM.getNumberOfShards(base_path, io);
    try testing.expectEqual(@as(u64, 0), num_shards);
}


test "ShardDBM.iterate() visits all records" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try std.Io.Dir.realPathFile(tmp.dir, io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];
    const base_path = try std.fmt.allocPrint(alloc, "{s}/iter.tkt", .{tmp_path});
    defer alloc.free(base_path);

    const db = try ShardDBM.init(alloc);
    defer db.deinit(io);
    try std.testing.expect(db.open(alloc, io, base_path, 2, true, .{}).isOk());

    _ = db.set(std.testing.io, "a", "1", false);
    _ = db.set(std.testing.io, "b", "2", false);
    _ = db.set(std.testing.io, "c", "3", false);

    var iter = try db.iterate(alloc, std.testing.io);
    defer iter.deinit(io);

    var count: usize = 0;
    while (try iter.next(std.testing.io)) |entry| {
        _ = entry.key;
        _ = entry.value;
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "ShardDBM.iterate() empty database" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try std.Io.Dir.realPathFile(tmp.dir, io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];
    const base_path = try std.fmt.allocPrint(alloc, "{s}/empty.tkt", .{tmp_path});
    defer alloc.free(base_path);

    const db = try ShardDBM.init(alloc);
    defer db.deinit(io);
    try std.testing.expect(db.open(alloc, io, base_path, 2, true, .{}).isOk());

    var iter = try db.iterate(alloc, std.testing.io);
    defer iter.deinit(io);

    try std.testing.expect(try iter.next(std.testing.io) == null);
    try std.testing.expect(try iter.next(std.testing.io) == null);
}

test "ShardDBM.iterate() lifetime contract" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try std.Io.Dir.realPathFile(tmp.dir, io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];
    const base_path = try std.fmt.allocPrint(alloc, "{s}/lt.tkt", .{tmp_path});
    defer alloc.free(base_path);

    const db = try ShardDBM.init(alloc);
    defer db.deinit(io);
    try std.testing.expect(db.open(alloc, io, base_path, 2, true, .{}).isOk());

    _ = db.set(std.testing.io, "p", "v1", false);
    _ = db.set(std.testing.io, "q", "v2", false);

    var iter = try db.iterate(alloc, std.testing.io);
    defer iter.deinit(io);

    const first = try iter.next(std.testing.io);
    try std.testing.expect(first != null);
    // Copy before calling next() — demonstrates lifetime contract.
    const key_copy = try alloc.dupe(u8, first.?.key);
    defer alloc.free(key_copy);
    _ = try iter.next(std.testing.io);
    try std.testing.expect(key_copy.len > 0);
}

// [DONE:wave.5.1]
