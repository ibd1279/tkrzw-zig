//! C ABI wrapper around tkrzw-zig's PolyDBM.
//!
//! This module exposes a stable C-callable surface for the tkrzw-zig database
//! library. Every `export fn` here uses only C-ABI types (pointers, integers,
//! booleans, opaque handles) and never returns Zig-owned memory across the
//! boundary.
//!
//! ## Memory model
//!
//! All `_out` pointer parameters that receive byte buffers are allocated with
//! `std.heap.c_allocator` (i.e. `malloc`), so the C caller must release them
//! with plain `free()`. The library never hands back pointers into Zig-owned
//! storage.
//!
//! ## Lifecycle
//!
//! 1. `tkrzw_init` — initialise the shared `std.Io.Threaded` executor.
//! 2. `tkrzw_open` — open one or more DBM handles.
//! 3. Operations on those handles.
//! 4. `tkrzw_close` — close and free each handle.
//! 5. `tkrzw_deinit` — tear down the executor once all handles are closed.
//!
//! `tkrzw_init` / `tkrzw_deinit` are ref-counted and guarded by a mutex, but
//! callers are expected to perform init from a single thread before spawning
//! workers, and to perform deinit after all DBMs are closed and threads
//! joined. Concurrent operations on the same handle must be externally
//! synchronised by the caller.
//!
//! ## Null-pointer policy
//!
//! Any required handle that is null causes the function to return
//! `INVALID_ARGUMENT_ERROR` (5). Scalar getters return a defined sentinel
//! (`0` or `false`) for a null handle so that error handling on the C side
//! remains simple.

const std = @import("std");
const tkrzw = @import("tkrzw_zig");

const PolyDBM = tkrzw.PolyDBM;
const PolyCursor = tkrzw.PolyCursor;
const Status = tkrzw.Status;
const Code = tkrzw.Code;
const RecordAction = tkrzw.RecordAction;

const c_allocator = std.heap.c_allocator;

// ---------------------------------------------------------------------------
// Global Io lifecycle state.
// ---------------------------------------------------------------------------

var g_threaded: std.Io.Threaded = undefined;
var g_io: std.Io = undefined;
var g_ref_count: usize = 0;
var g_mutex: std.atomic.Mutex = .unlocked;

// ---------------------------------------------------------------------------
// C-ABI option / enum types.
// ---------------------------------------------------------------------------

/// Subset of `OpenOptionsPoly` exposed across the C boundary.
///
/// Field order and layout must match the `TkrzwOpenOptions` struct in
/// `include/tkrzw.h` exactly. The name here mirrors the C typedef.
pub const TkrzwOpenOptions = extern struct {
    writable: bool = true,
    truncate: bool = false,
    no_create: bool = false,
    no_wait: bool = false,
    no_lock: bool = false,
    sync_hard: bool = false,
};

// ---------------------------------------------------------------------------
// Internal helpers (not exported).
// ---------------------------------------------------------------------------

/// Safely cast an opaque handle to a `*PolyDBM`. Returns null if the handle
/// itself is null.
fn polyFromHandle(h: ?*anyopaque) ?*PolyDBM {
    const raw = h orelse return null;
    return @ptrCast(@alignCast(raw));
}

/// Safely cast an opaque handle to a `*PolyCursor`. Returns null if the
/// handle itself is null.
fn cursorFromHandle(h: ?*anyopaque) ?*PolyCursor {
    const raw = h orelse return null;
    return @ptrCast(@alignCast(raw));
}

/// Duplicate `s` into a freshly-malloc'd buffer and write `(ptr, len)` to
/// the supplied out-parameters. Returns false on allocation failure (in
/// which case the out-parameters are zeroed).
fn writeOutSlice(s: []const u8, out_ptr: *[*c]u8, out_len: *usize) bool {
    const buf = c_allocator.dupe(u8, s) catch {
        out_ptr.* = null;
        out_len.* = 0;
        return false;
    };
    out_ptr.* = buf.ptr;
    out_len.* = buf.len;
    return true;
}

/// Convert a tkrzw `Status` into the i32 status code returned across the
/// C ABI.
fn statusCode(s: Status) i32 {
    return @intFromEnum(s.code);
}

/// Return `g_io` if `tkrzw_init` has been called (ref count > 0), otherwise
/// null. Every exported function that touches `g_io` MUST go through this
/// helper so calling into the library before init produces a defined
/// `PRECONDITION_ERROR` rather than dereferencing undefined state.
///
/// Callers are still responsible for the lifecycle contract documented in
/// `include/tkrzw.h`: `tkrzw_init` must happen-before any operation, and
/// `tkrzw_deinit` must happen-after every operation has returned. The
/// load here is a defensive guard, not a synchronisation primitive.
fn requireIo() ?std.Io {
    if (@atomicLoad(usize, &g_ref_count, .acquire) == 0) return null;
    return g_io;
}

/// Map any error value from `PolyError` to the corresponding C status code.
/// Uses `anyerror` so callers do not need to name the `PolyError` type,
/// which is not re-exported from the `tkrzw_zig` module root.
fn polyErrorToCode(err: anyerror) i32 {
    return switch (err) {
        error.OutOfMemory => @intFromEnum(Code.SYSTEM_ERROR),
        error.UnknownError => @intFromEnum(Code.UNKNOWN_ERROR),
        error.SystemError => @intFromEnum(Code.SYSTEM_ERROR),
        error.NotImplemented => @intFromEnum(Code.NOT_IMPLEMENTED_ERROR),
        error.PreconditionError => @intFromEnum(Code.PRECONDITION_ERROR),
        error.InvalidArgument => @intFromEnum(Code.INVALID_ARGUMENT_ERROR),
        error.Canceled => @intFromEnum(Code.CANCELED_ERROR),
        error.NotFound => @intFromEnum(Code.NOT_FOUND_ERROR),
        error.PermissionError => @intFromEnum(Code.PERMISSION_ERROR),
        error.Infeasible => @intFromEnum(Code.INFEASIBLE_ERROR),
        error.Duplication => @intFromEnum(Code.DUPLICATION_ERROR),
        error.BrokenData => @intFromEnum(Code.BROKEN_DATA_ERROR),
        error.NetworkError => @intFromEnum(Code.NETWORK_ERROR),
        error.ApplicationError => @intFromEnum(Code.APPLICATION_ERROR),
        else => @intFromEnum(Code.UNKNOWN_ERROR),
    };
}

// ---------------------------------------------------------------------------
// Lifecycle.
// ---------------------------------------------------------------------------

/// Initialise the shared executor. Ref-counted: each call must be balanced
/// by a matching `tkrzw_deinit`. Returns `SUCCESS` (0) on success.
/// Spin until we acquire the spinlock.
fn lockMutex() void {
    while (!g_mutex.tryLock()) {
        std.atomic.spinLoopHint();
    }
}

pub export fn tkrzw_init() i32 {
    lockMutex();
    defer g_mutex.unlock();

    if (g_ref_count == 0) {
        g_threaded = std.Io.Threaded.init(c_allocator, .{});
        g_io = g_threaded.io();
    }
    g_ref_count += 1;
    return @intFromEnum(Code.SUCCESS);
}

/// Decrement the executor ref count and tear it down on the last release.
/// Calling this while DBM handles are still open is undefined behaviour.
pub export fn tkrzw_deinit() void {
    lockMutex();
    defer g_mutex.unlock();

    if (g_ref_count == 0) return;
    g_ref_count -= 1;
    if (g_ref_count == 0) {
        g_threaded.deinit();
        g_threaded = undefined;
        g_io = undefined;
    }
}

/// Return the canonical name of a status code as a NUL-terminated static
/// string. Unknown codes return `"UNKNOWN"`. The returned pointer is owned
/// by the library and must not be freed.
pub export fn tkrzw_status_name(code: i32) [*:0]const u8 {
    // Validate that `code` is a declared enum value before switching, so that
    // newly-added Code variants cause a compile-time exhaustiveness error.
    // Out-of-range integers return "UNKNOWN" at runtime.
    comptime var valid_values: []const i32 = &.{};
    comptime for (@typeInfo(Code).@"enum".fields) |f| {
        valid_values = valid_values ++ &[_]i32{f.value};
    };
    const is_valid = for (valid_values) |v| {
        if (v == code) break true;
    } else false;
    if (!is_valid) return "UNKNOWN";
    const c: Code = @enumFromInt(code);
    return switch (c) {
        .SUCCESS => "SUCCESS",
        .UNKNOWN_ERROR => "UNKNOWN_ERROR",
        .SYSTEM_ERROR => "SYSTEM_ERROR",
        .NOT_IMPLEMENTED_ERROR => "NOT_IMPLEMENTED_ERROR",
        .PRECONDITION_ERROR => "PRECONDITION_ERROR",
        .INVALID_ARGUMENT_ERROR => "INVALID_ARGUMENT_ERROR",
        .CANCELED_ERROR => "CANCELED_ERROR",
        .NOT_FOUND_ERROR => "NOT_FOUND_ERROR",
        .PERMISSION_ERROR => "PERMISSION_ERROR",
        .INFEASIBLE_ERROR => "INFEASIBLE_ERROR",
        .DUPLICATION_ERROR => "DUPLICATION_ERROR",
        .BROKEN_DATA_ERROR => "BROKEN_DATA_ERROR",
        .NETWORK_ERROR => "NETWORK_ERROR",
        .APPLICATION_ERROR => "APPLICATION_ERROR",
    };
}

// ---------------------------------------------------------------------------
// ===========================================================================
// Core CRUD
// ===========================================================================
// ---------------------------------------------------------------------------

/// Open a PolyDBM at `path` with the supplied options and return an opaque
/// handle, or `NULL` on failure (invalid arguments, allocation failure, or
/// open error). The returned handle must be released with `tkrzw_close`.
pub export fn tkrzw_open(path: [*c]const u8, options: ?*const TkrzwOpenOptions) ?*anyopaque {
    if (path == null) return null;
    const opts = options orelse return null;

    const path_slice = std.mem.span(path);

    const poly_opts: tkrzw.OpenOptionsPoly = .{
        .writable = opts.writable,
        .file_options = tkrzw.OpenOptions{
            .truncate = opts.truncate,
            .no_create = opts.no_create,
            .no_wait = opts.no_wait,
            .no_lock = opts.no_lock,
            .sync_hard = opts.sync_hard,
        },
    };

    const io = requireIo() orelse return null;
    const poly = c_allocator.create(PolyDBM) catch return null;
    poly.* = PolyDBM.open(path_slice, poly_opts, io, c_allocator) catch {
        c_allocator.destroy(poly);
        return null;
    };
    return @ptrCast(poly);
}

/// Close the DBM referenced by `db`, release its resources, and free the
/// handle. Passing the same handle twice is undefined behaviour; the caller
/// should null its pointer after a successful close. Returns the status
/// code produced by the underlying close operation, or
/// `INVALID_ARGUMENT_ERROR` if `db` is null.
pub export fn tkrzw_close(db: ?*anyopaque) i32 {
    const poly = polyFromHandle(db) orelse
        return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    const io = requireIo() orelse return @intFromEnum(Code.PRECONDITION_ERROR);
    const status = poly.close(io);
    poly.deinit(io);
    c_allocator.destroy(poly);
    return statusCode(status);
}
/// Retrieve a record by key.
///
/// On success, `*value_out` and `*value_len_out` are set to a malloc'd buffer
/// owned by the caller; the caller must `free(*value_out)` when done.
/// On any error both out-parameters are set to null / 0.
///
/// Returns: SUCCESS(0) on hit, NOT_FOUND_ERROR(7) on miss,
/// INVALID_ARGUMENT_ERROR(5) if any required pointer is null,
/// SYSTEM_ERROR(2) on OOM, or another status code for other failures.
pub export fn tkrzw_get(
    db: ?*anyopaque,
    key: [*c]const u8,
    key_len: usize,
    value_out: ?*[*c]u8,
    value_len_out: ?*usize,
) i32 {
    const poly = polyFromHandle(db) orelse return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    if (key == null) return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    const vout = value_out orelse return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    const lout = value_len_out orelse return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);

    const io = requireIo() orelse return @intFromEnum(Code.PRECONDITION_ERROR);
    // Pass c_allocator so the returned slice is already malloc-backed;
    // no extra copy is needed — just transfer ownership to the caller.
    const slice = poly.get(c_allocator, io, key[0..key_len]) catch |err| {
        vout.* = null;
        lout.* = 0;
        return polyErrorToCode(err);
    };
    vout.* = @constCast(slice.ptr);
    lout.* = slice.len;
    return @intFromEnum(Code.SUCCESS);
}

/// Store a record.
///
/// When `overwrite` is false and the key already exists, returns
/// DUPLICATION_ERROR(10). Returns INVALID_ARGUMENT_ERROR(5) if `db`,
/// `key`, or `value` is null.
pub export fn tkrzw_set(
    db: ?*anyopaque,
    key: [*c]const u8,
    key_len: usize,
    value: [*c]const u8,
    value_len: usize,
    overwrite: bool,
) i32 {
    const poly = polyFromHandle(db) orelse return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    if (key == null) return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    if (value == null) return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);

    const io = requireIo() orelse return @intFromEnum(Code.PRECONDITION_ERROR);
    const status = poly.set(io, key[0..key_len], value[0..value_len], overwrite);
    return statusCode(status);
}

/// Remove a record by key.
///
/// Returns NOT_FOUND_ERROR(7) if the key does not exist.
/// Returns INVALID_ARGUMENT_ERROR(5) if `db` or `key` is null.
pub export fn tkrzw_remove(
    db: ?*anyopaque,
    key: [*c]const u8,
    key_len: usize,
) i32 {
    const poly = polyFromHandle(db) orelse return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    if (key == null) return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);

    const io = requireIo() orelse return @intFromEnum(Code.PRECONDITION_ERROR);
    const status = poly.remove(io, key[0..key_len]);
    return statusCode(status);
}

/// Append a value to an existing record, separated by `delim`.
///
/// If the key does not exist, the record is created with just `value`.
/// `delim` is a byte sequence (not a single char) and may be empty;
/// passing null for `delim` with `delim_len == 0` is treated as an empty
/// delimiter. Passing null with a non-zero `delim_len` returns
/// INVALID_ARGUMENT_ERROR(5).
pub export fn tkrzw_append(
    db: ?*anyopaque,
    key: [*c]const u8,
    key_len: usize,
    value: [*c]const u8,
    value_len: usize,
    delim: [*c]const u8,
    delim_len: usize,
) i32 {
    const poly = polyFromHandle(db) orelse return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    if (key == null) return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    if (value == null) return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    // null delim is only valid when delim_len == 0 (empty delimiter).
    if (delim == null and delim_len != 0) return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);

    const io = requireIo() orelse return @intFromEnum(Code.PRECONDITION_ERROR);
    const delim_slice: []const u8 = if (delim != null) delim[0..delim_len] else &.{};
    const status = poly.append(io, key[0..key_len], value[0..value_len], delim_slice);
    return statusCode(status);
}
/// Return the number of records in the database.
/// Returns 0 for a null handle.
pub export fn tkrzw_count(db: ?*anyopaque) i64 {
    const poly = polyFromHandle(db) orelse return 0;
    const io = requireIo() orelse return 0;
    return poly.count(io);
}

/// Return the size of the underlying database file in bytes.
/// Returns -1 when the database is not open or the file size is unavailable.
/// Returns 0 for a null handle.
pub export fn tkrzw_file_size(db: ?*anyopaque) i64 {
    const poly = polyFromHandle(db) orelse return 0;
    return poly.getFileSize();
}

/// Return the last modification timestamp of the database as seconds since
/// the Unix epoch (with sub-second precision). Returns 0.0 for a null handle.
pub export fn tkrzw_timestamp(db: ?*anyopaque) f64 {
    const poly = polyFromHandle(db) orelse return 0.0;
    return poly.getTimestamp();
}

/// Return whether the database is currently open.
/// Returns false for a null handle.
pub export fn tkrzw_is_open(db: ?*anyopaque) bool {
    const poly = polyFromHandle(db) orelse return false;
    const io = requireIo() orelse return false;
    return poly.isOpen(io);
}

/// Return whether the database was opened in writable mode.
/// Returns false for a null handle.
pub export fn tkrzw_is_writable(db: ?*anyopaque) bool {
    const poly = polyFromHandle(db) orelse return false;
    const io = requireIo() orelse return false;
    return poly.isWritable(io);
}

/// Return whether the database is healthy (no detected corruption).
/// Returns false for a null handle.
pub export fn tkrzw_is_healthy(db: ?*anyopaque) bool {
    const poly = polyFromHandle(db) orelse return false;
    return poly.isHealthy();
}

/// Return whether the database should be rebuilt to reclaim space or
/// improve performance.
/// Returns false for a null handle.
pub export fn tkrzw_should_rebuild(db: ?*anyopaque) bool {
    const poly = polyFromHandle(db) orelse return false;
    return poly.shouldBeRebuilt();
}

/// Remove all records from the database. Returns a status code.
pub export fn tkrzw_clear(db: ?*anyopaque) i32 {
    const poly = polyFromHandle(db) orelse return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    const io = requireIo() orelse return @intFromEnum(Code.PRECONDITION_ERROR);
    return statusCode(poly.clear(io));
}

/// Synchronise the database to persistent storage.
/// `hard` forces a full flush (fsync-equivalent) rather than a soft sync.
pub export fn tkrzw_synchronize(db: ?*anyopaque, hard: bool) i32 {
    const poly = polyFromHandle(db) orelse return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    const io = requireIo() orelse return @intFromEnum(Code.PRECONDITION_ERROR);
    return statusCode(poly.synchronize(io, hard));
}

/// Rebuild the database to free fragmented space and apply any pending
/// structural changes. Returns a status code.
pub export fn tkrzw_rebuild(db: ?*anyopaque) i32 {
    const poly = polyFromHandle(db) orelse return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    const io = requireIo() orelse return @intFromEnum(Code.PRECONDITION_ERROR);
    return statusCode(poly.rebuild(io));
}

/// Copy the database file to `dest_path` (a UTF-8 path of length
/// `dest_path_len`). `sync_hard` controls whether the destination file is
/// fsynced after writing. Returns a status code.
pub export fn tkrzw_copy_file(
    db: ?*anyopaque,
    dest_path: [*c]const u8,
    dest_path_len: usize,
    sync_hard: bool,
) i32 {
    const poly = polyFromHandle(db) orelse return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    if (dest_path == null) return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    const io = requireIo() orelse return @intFromEnum(Code.PRECONDITION_ERROR);
    const path_slice = dest_path[0..dest_path_len];
    return statusCode(poly.copyFileData(io, path_slice, sync_hard));
}

// ---------------------------------------------------------------------------
// ===========================================================================
// Batch (multi-key) Operations
// ===========================================================================
// ---------------------------------------------------------------------------

/// Retrieve multiple records in a single call.
///
/// `keys_c` and `key_lens` are parallel arrays of length `count` describing
/// the input keys (caller-owned). `values_out` and `value_lens_out` are
/// caller-allocated output arrays of length `count`; the library fills them
/// in input-key order. For keys that were not found, the corresponding
/// `values_out[i]` is left as null and `value_lens_out[i]` as 0.
///
/// Each non-null `values_out[i]` is a malloc'd buffer that the caller must
/// release with `free()`.
///
/// Returns SUCCESS(0) when all requested keys were found, NOT_FOUND_ERROR(7)
/// when at least one key was missing (matching the underlying PolyDBM
/// behaviour), INVALID_ARGUMENT_ERROR(5) on null required pointers, or
/// another status code on backend failure.
pub export fn tkrzw_get_multi(
    db: ?*anyopaque,
    keys_c: [*c]const [*c]const u8,
    key_lens: [*c]const usize,
    count: usize,
    values_out: [*c][*c]u8,
    value_lens_out: [*c]usize,
) i32 {
    const poly = polyFromHandle(db) orelse return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    if (keys_c == null or key_lens == null or values_out == null or value_lens_out == null) {
        return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    }

    // Zero-init outputs so partial-hit cases leave a defined state.
    for (0..count) |i| {
        values_out[i] = null;
        value_lens_out[i] = 0;
    }

    if (count == 0) return @intFromEnum(Code.SUCCESS);

    // Build a []const []const u8 view of the input keys.
    const keys = c_allocator.alloc([]const u8, count) catch {
        return @intFromEnum(Code.SYSTEM_ERROR);
    };
    defer c_allocator.free(keys);
    for (0..count) |i| {
        const kp = keys_c[i];
        if (kp == null and key_lens[i] != 0) {
            return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
        }
        keys[i] = if (kp != null) kp[0..key_lens[i]] else &.{};
    }

    var records = std.StringHashMap([]u8).init(c_allocator);
    // Each backend's getMulti implementation explicitly dupe()s both the key
    // and the value into map_alloc (c_allocator here) before calling put().
    // This is a backend implementation requirement — any backend whose getMulti
    // does NOT dupe keys before put() would make the key-free below unsafe.
    // We free the duped keys here; values are transferred to the C caller via
    // values_out and must NOT be freed.
    //
    // PRECONDITION: the C caller must not pass duplicate keys in keys_c[].
    // Duplicate keys cause the backend to overwrite the map entry without
    // freeing the superseded key/value, resulting in allocation leaks.
    defer {
        var it = records.iterator();
        while (it.next()) |entry| {
            c_allocator.free(entry.key_ptr.*);
        }
        records.deinit();
    }

    const io = requireIo() orelse return @intFromEnum(Code.PRECONDITION_ERROR);
    const status = poly.getMulti(io, keys, &records);

    for (0..count) |i| {
        if (records.get(keys[i])) |val| {
            values_out[i] = val.ptr;
            value_lens_out[i] = val.len;
        }
    }

    return statusCode(status);
}

/// Store multiple records in a single call.
///
/// `keys_c`/`key_lens` and `values_c`/`value_lens` are parallel arrays of
/// length `count` describing the input records (caller-owned). When
/// `overwrite` is false and any key already exists, returns
/// DUPLICATION_ERROR(10).
pub export fn tkrzw_set_multi(
    db: ?*anyopaque,
    keys_c: [*c]const [*c]const u8,
    key_lens: [*c]const usize,
    values_c: [*c]const [*c]const u8,
    value_lens: [*c]const usize,
    count: usize,
    overwrite: bool,
) i32 {
    const poly = polyFromHandle(db) orelse return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    if (keys_c == null or key_lens == null or values_c == null or value_lens == null) {
        return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    }
    if (count == 0) return @intFromEnum(Code.SUCCESS);

    const records = c_allocator.alloc([2][]const u8, count) catch {
        return @intFromEnum(Code.SYSTEM_ERROR);
    };
    defer c_allocator.free(records);
    for (0..count) |i| {
        const kp = keys_c[i];
        const vp = values_c[i];
        if ((kp == null and key_lens[i] != 0) or (vp == null and value_lens[i] != 0)) {
            return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
        }
        const key_slice: []const u8 = if (kp != null) kp[0..key_lens[i]] else &.{};
        const val_slice: []const u8 = if (vp != null) vp[0..value_lens[i]] else &.{};
        records[i] = .{ key_slice, val_slice };
    }

    const io = requireIo() orelse return @intFromEnum(Code.PRECONDITION_ERROR);
    return statusCode(poly.setMulti(io, records, overwrite));
}

/// Remove multiple records in a single call.
///
/// `keys_c`/`key_lens` are parallel arrays of length `count`. Returns
/// NOT_FOUND_ERROR(7) if at least one key was missing (matching the
/// underlying PolyDBM behaviour).
pub export fn tkrzw_remove_multi(
    db: ?*anyopaque,
    keys_c: [*c]const [*c]const u8,
    key_lens: [*c]const usize,
    count: usize,
) i32 {
    const poly = polyFromHandle(db) orelse return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    if (keys_c == null or key_lens == null) {
        return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    }
    if (count == 0) return @intFromEnum(Code.SUCCESS);

    const keys = c_allocator.alloc([]const u8, count) catch {
        return @intFromEnum(Code.SYSTEM_ERROR);
    };
    defer c_allocator.free(keys);
    for (0..count) |i| {
        const kp = keys_c[i];
        if (kp == null and key_lens[i] != 0) {
            return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
        }
        keys[i] = if (kp != null) kp[0..key_lens[i]] else &.{};
    }

    const io = requireIo() orelse return @intFromEnum(Code.PRECONDITION_ERROR);
    return statusCode(poly.removeMulti(io, keys));
}

/// Append to multiple records in a single call, using `delim` as the
/// separator between any existing value and the appended value.
///
/// `keys_c`/`key_lens` and `values_c`/`value_lens` are parallel arrays of
/// length `count`. `delim` may be null when `delim_len` is 0.
pub export fn tkrzw_append_multi(
    db: ?*anyopaque,
    keys_c: [*c]const [*c]const u8,
    key_lens: [*c]const usize,
    values_c: [*c]const [*c]const u8,
    value_lens: [*c]const usize,
    count: usize,
    delim: [*c]const u8,
    delim_len: usize,
) i32 {
    const poly = polyFromHandle(db) orelse return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    if (keys_c == null or key_lens == null or values_c == null or value_lens == null) {
        return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    }
    if (delim == null and delim_len != 0) {
        return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    }
    if (count == 0) return @intFromEnum(Code.SUCCESS);

    const records = c_allocator.alloc([2][]const u8, count) catch {
        return @intFromEnum(Code.SYSTEM_ERROR);
    };
    defer c_allocator.free(records);
    for (0..count) |i| {
        const kp = keys_c[i];
        const vp = values_c[i];
        if ((kp == null and key_lens[i] != 0) or (vp == null and value_lens[i] != 0)) {
            return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
        }
        const key_slice: []const u8 = if (kp != null) kp[0..key_lens[i]] else &.{};
        const val_slice: []const u8 = if (vp != null) vp[0..value_lens[i]] else &.{};
        records[i] = .{ key_slice, val_slice };
    }

    const io = requireIo() orelse return @intFromEnum(Code.PRECONDITION_ERROR);
    const delim_slice: []const u8 = if (delim != null) delim[0..delim_len] else &.{};
    return statusCode(poly.appendMulti(io, records, delim_slice));
}
/// Atomically add `delta` to the stored i64 value at `key`.
///
/// If the key does not exist, the record is created with value `initial + delta`.
/// On success, `*current_out` is set to the resulting value (if non-null).
/// Returns INVALID_ARGUMENT_ERROR(5) if `db` or `key` is null.
pub export fn tkrzw_increment(
    db: ?*anyopaque,
    key: [*c]const u8,
    key_len: usize,
    delta: i64,
    initial: i64,
    current_out: ?*i64,
) i32 {
    const poly = polyFromHandle(db) orelse return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    if (key == null) return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    const io = requireIo() orelse return @intFromEnum(Code.PRECONDITION_ERROR);
    const status = poly.increment(io, key[0..key_len], delta, current_out, initial);
    return statusCode(status);
}

/// Rename a record from `old_key` to `new_key`.
///
/// When `overwrite` is false and `new_key` already exists, returns
/// DUPLICATION_ERROR(10). When `copying` is true, the original record is
/// retained and its value is copied to `new_key` rather than moved.
/// Returns INVALID_ARGUMENT_ERROR(5) if `db`, `old_key`, or `new_key` is null.
pub export fn tkrzw_rekey(
    db: ?*anyopaque,
    old_key: [*c]const u8,
    old_key_len: usize,
    new_key: [*c]const u8,
    new_key_len: usize,
    overwrite: bool,
    copying: bool,
) i32 {
    const poly = polyFromHandle(db) orelse return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    if (old_key == null) return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    if (new_key == null) return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    const io = requireIo() orelse return @intFromEnum(Code.PRECONDITION_ERROR);
    const status = poly.rekey(io, old_key[0..old_key_len], new_key[0..new_key_len], overwrite, copying);
    return statusCode(status);
}

/// Remove and return the lexicographically-first record.
///
/// On success, `*key_out` / `*key_len_out` and `*value_out` / `*value_len_out`
/// are set to malloc'd buffers owned by the caller; the caller must `free()` each
/// non-null pointer. Any of the four out-parameters may be null if that portion
/// of the record is not needed.
/// Returns NOT_FOUND_ERROR(7) if the database is empty.
/// Returns INVALID_ARGUMENT_ERROR(5) if `db` is null.
pub export fn tkrzw_pop_first(
    db: ?*anyopaque,
    key_out: ?*[*c]u8,
    key_len_out: ?*usize,
    value_out: ?*[*c]u8,
    value_len_out: ?*usize,
) i32 {
    const poly = polyFromHandle(db) orelse return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);

    // Use unmanaged ArrayLists (Zig 0.16 pattern: no stored allocator).
    // The backend appends to these using self.allocator, which equals
    // c_allocator because tkrzw_open always opens with c_allocator.
    // deinit(c_allocator) is therefore correct.
    var key_buf: std.ArrayList(u8) = .empty;
    defer key_buf.deinit(c_allocator);
    var val_buf: std.ArrayList(u8) = .empty;
    defer val_buf.deinit(c_allocator);

    // Only ask PolyDBM to populate each buffer if the caller actually wants it.
    const key_buf_ptr: ?*std.ArrayList(u8) = if (key_out != null and key_len_out != null) &key_buf else null;
    const val_buf_ptr: ?*std.ArrayList(u8) = if (value_out != null and value_len_out != null) &val_buf else null;

    const io = requireIo() orelse return @intFromEnum(Code.PRECONDITION_ERROR);
    const status = poly.popFirst(io, key_buf_ptr, val_buf_ptr) catch |err| {
        return polyErrorToCode(err);
    };

    if (status.code != .SUCCESS) return statusCode(status);

    // Transfer key ownership to caller (duplicate into a fresh malloc buffer,
    // then let key_buf's defer-deinit free the ArrayList's backing memory).
    if (key_buf_ptr != null) {
        const kout = key_out.?;
        const klout = key_len_out.?;
        if (!writeOutSlice(key_buf.items, kout, klout)) {
            return @intFromEnum(Code.SYSTEM_ERROR);
        }
    }

    // Transfer value ownership to caller.
    if (val_buf_ptr != null) {
        const vout = value_out.?;
        const vlout = value_len_out.?;
        if (!writeOutSlice(val_buf.items, vout, vlout)) {
            // Free the key we already allocated to avoid a leak.
            if (key_buf_ptr != null) {
                c_allocator.free(key_out.?.*[0..key_len_out.?.*]);
                key_out.?.* = null;
                key_len_out.?.* = 0;
            }
            return @intFromEnum(Code.SYSTEM_ERROR);
        }
    }

    return statusCode(status);
}

/// Append a value as the last record, using a timestamp-derived key.
///
/// `wtime` is the wall-clock time in seconds (use 0.0 to let the library
/// choose the current time). On success, if `key_out` and `key_len_out` are
/// both non-null they are set to a malloc'd buffer owned by the caller holding
/// the generated key; the caller must `free(*key_out)`.
/// Returns INVALID_ARGUMENT_ERROR(5) if `db` or `value` is null.
pub export fn tkrzw_push_last(
    db: ?*anyopaque,
    value: [*c]const u8,
    value_len: usize,
    wtime: f64,
    key_out: ?*[*c]u8,
    key_len_out: ?*usize,
) i32 {
    const poly = polyFromHandle(db) orelse return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    if (value == null) return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);

    // See comment in tkrzw_pop_first: backend uses self.allocator == c_allocator.
    var key_buf: std.ArrayList(u8) = .empty;
    defer key_buf.deinit(c_allocator);

    const key_buf_ptr: ?*std.ArrayList(u8) = if (key_out != null and key_len_out != null) &key_buf else null;

    const io = requireIo() orelse return @intFromEnum(Code.PRECONDITION_ERROR);
    const status = poly.pushLast(io, value[0..value_len], wtime, key_buf_ptr);

    if (status.code != .SUCCESS) return statusCode(status);

    if (key_buf_ptr != null) {
        const kout = key_out.?;
        const klout = key_len_out.?;
        if (!writeOutSlice(key_buf.items, kout, klout)) {
            return @intFromEnum(Code.SYSTEM_ERROR);
        }
    }

    return statusCode(status);
}

// ---------------------------------------------------------------------------
// ===========================================================================
// Atomic Operations
// ===========================================================================
// ---------------------------------------------------------------------------

/// Atomic compare-and-exchange on a single key.
///
/// `exp_mode` selects the expected condition (`TkrzwExpected`): `0 = ABSENT`,
/// `1 = ANY`, `2 = EXACT` (in which case `exp_val`/`exp_val_len` provide the
/// required current value). `des_mode` selects the desired update
/// (`TkrzwDesired`): `0 = REMOVE`, `1 = NOOP`, `2 = SET` (in which case
/// `des_val`/`des_val_len` provide the new value).
///
/// When non-null, `actual_out`/`actual_len_out` receive a malloc'd copy of
/// the prior stored value (caller must `free()` it). When the record did
/// not exist before the operation, `*actual_out` is left as null.
/// `found_out`, if non-null, is set to true iff the record existed prior
/// to the operation.
///
/// Returns SUCCESS(0) when the exchange happens, INFEASIBLE_ERROR(9) when
/// the expected condition does not match, INVALID_ARGUMENT_ERROR(5) on
/// invalid enum values or null required pointers, or another status code
/// on backend failure.
pub export fn tkrzw_compare_exchange(
    db: ?*anyopaque,
    key: [*c]const u8,
    key_len: usize,
    exp_mode: i32,
    exp_val: [*c]const u8,
    exp_val_len: usize,
    des_mode: i32,
    des_val: [*c]const u8,
    des_val_len: usize,
    actual_out: ?*[*c]u8,
    actual_len_out: ?*usize,
    found_out: ?*bool,
) i32 {
    const poly = polyFromHandle(db) orelse return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    if (key == null) return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);

    // Zero outputs so error and not-found paths leave defined state.
    if (actual_out) |p| p.* = null;
    if (actual_len_out) |p| p.* = 0;
    if (found_out) |p| p.* = false;

    const expected: tkrzw.CompareExpected = switch (exp_mode) {
        0 => .absent,
        1 => .any,
        2 => blk: {
            if (exp_val == null and exp_val_len != 0)
                return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
            const slice: []const u8 = if (exp_val != null) exp_val[0..exp_val_len] else &.{};
            break :blk .{ .exact = slice };
        },
        else => return @intFromEnum(Code.INVALID_ARGUMENT_ERROR),
    };
    const desired: tkrzw.CompareDesired = switch (des_mode) {
        0 => .remove,
        1 => .noop,
        2 => blk: {
            if (des_val == null and des_val_len != 0)
                return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
            const slice: []const u8 = if (des_val != null) des_val[0..des_val_len] else &.{};
            break :blk .{ .set = slice };
        },
        else => return @intFromEnum(Code.INVALID_ARGUMENT_ERROR),
    };

    // PolyDBM appends into the ArrayList using its own (DB) allocator. The
    // DB was constructed with c_allocator in tkrzw_open, so c_allocator is
    // the correct allocator for deinit here as well.
    const want_actual = actual_out != null and actual_len_out != null;
    var actual_buf: std.ArrayList(u8) = .empty;
    defer actual_buf.deinit(c_allocator);

    const io = requireIo() orelse return @intFromEnum(Code.PRECONDITION_ERROR);
    const status = poly.compareExchange(
        io,
        key[0..key_len],
        expected,
        desired,
        if (want_actual) &actual_buf else null,
        found_out,
    );

    if (want_actual and actual_buf.items.len > 0) {
        // Transfer ownership of the ArrayList's backing storage directly
        // to the C caller. The backend allocated `actual_buf` with
        // `c_allocator` (the DB's allocator), so the returned pointer is
        // already `free()`-able. `toOwnedSlice` leaves `actual_buf` empty,
        // making its deferred deinit a no-op.
        const owned = actual_buf.toOwnedSlice(c_allocator) catch
            return @intFromEnum(Code.SYSTEM_ERROR);
        actual_out.?.* = owned.ptr;
        actual_len_out.?.* = owned.len;
    }

    return statusCode(status);
}

/// Atomic compare-and-exchange across multiple keys.
///
/// The expected and desired conditions are passed as parallel C arrays.
/// For each `i` in `[0, exp_count)`:
///   - `exp_keys[i]` / `exp_key_lens[i]` describe the key,
///   - `exp_modes[i]` is a `TkrzwExpected` value, and
///   - when the mode is EXACT, `exp_vals[i]` / `exp_val_lens[i]` provide
///     the required current value.
/// The desired array follows the same layout with `TkrzwDesired` modes;
/// mode SET consumes `des_vals[i]` / `des_val_lens[i]`.
///
/// `exp_vals` / `exp_val_lens` may be null when no expected entry uses
/// EXACT, and similarly `des_vals` / `des_val_lens` may be null when no
/// desired entry uses SET. The expected and desired key counts need not
/// be equal.
///
/// Returns SUCCESS(0) when all conditions match and the updates are
/// applied, INFEASIBLE_ERROR(9) when any expected condition fails to
/// match, INVALID_ARGUMENT_ERROR(5) for null required arrays or unknown
/// enum values, or SYSTEM_ERROR(2) on allocation failure.
pub export fn tkrzw_compare_exchange_multi(
    db: ?*anyopaque,
    exp_keys: [*c]const [*c]const u8,
    exp_key_lens: [*c]const usize,
    exp_modes: [*c]const i32,
    exp_vals: [*c]const [*c]const u8,
    exp_val_lens: [*c]const usize,
    exp_count: usize,
    des_keys: [*c]const [*c]const u8,
    des_key_lens: [*c]const usize,
    des_modes: [*c]const i32,
    des_vals: [*c]const [*c]const u8,
    des_val_lens: [*c]const usize,
    des_count: usize,
) i32 {
    const poly = polyFromHandle(db) orelse return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);

    if (exp_count != 0 and (exp_keys == null or exp_key_lens == null or exp_modes == null))
        return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    if (des_count != 0 and (des_keys == null or des_key_lens == null or des_modes == null))
        return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);

    // Reflect the exact parameter element types from
    // `PolyDBM.compareExchangeMulti` so the slices we build coerce cleanly
    // regardless of how its signature names the inline structs.
    // Use the named types from dbm.zig; these are the same types used in all
    // backend compareExchangeMulti signatures, avoiding cross-module anon-struct
    // identity issues.
    const ExpItem = tkrzw.CompareExpectedEntry;
    const DesItem = tkrzw.CompareDesiredEntry;

    const exp_items = c_allocator.alloc(ExpItem, exp_count) catch
        return @intFromEnum(Code.SYSTEM_ERROR);
    defer c_allocator.free(exp_items);
    const des_items = c_allocator.alloc(DesItem, des_count) catch
        return @intFromEnum(Code.SYSTEM_ERROR);
    defer c_allocator.free(des_items);

    var i: usize = 0;
    while (i < exp_count) : (i += 1) {
        const kp = exp_keys[i];
        if (kp == null and exp_key_lens[i] != 0)
            return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
        const key_slice: []const u8 = if (kp != null) kp[0..exp_key_lens[i]] else &.{};
        const value: tkrzw.CompareExpected = switch (exp_modes[i]) {
            0 => .absent,
            1 => .any,
            2 => blk: {
                if (exp_vals == null or exp_val_lens == null)
                    return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
                const vp = exp_vals[i];
                if (vp == null and exp_val_lens[i] != 0)
                    return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
                const vs: []const u8 = if (vp != null) vp[0..exp_val_lens[i]] else &.{};
                break :blk .{ .exact = vs };
            },
            else => return @intFromEnum(Code.INVALID_ARGUMENT_ERROR),
        };
        exp_items[i] = .{ .key = key_slice, .value = value };
    }

    i = 0;
    while (i < des_count) : (i += 1) {
        const kp = des_keys[i];
        if (kp == null and des_key_lens[i] != 0)
            return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
        const key_slice: []const u8 = if (kp != null) kp[0..des_key_lens[i]] else &.{};
        const value: tkrzw.CompareDesired = switch (des_modes[i]) {
            0 => .remove,
            1 => .noop,
            2 => blk: {
                if (des_vals == null or des_val_lens == null)
                    return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
                const vp = des_vals[i];
                if (vp == null and des_val_lens[i] != 0)
                    return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
                const vs: []const u8 = if (vp != null) vp[0..des_val_lens[i]] else &.{};
                break :blk .{ .set = vs };
            },
            else => return @intFromEnum(Code.INVALID_ARGUMENT_ERROR),
        };
        des_items[i] = .{ .key = key_slice, .value = value };
    }

    const io = requireIo() orelse return @intFromEnum(Code.PRECONDITION_ERROR);
    return statusCode(poly.compareExchangeMulti(io, exp_items, des_items));
}

// ---------------------------------------------------------------------------
// ===========================================================================
// Cursor API
// ===========================================================================
// ---------------------------------------------------------------------------

/// Create a new cursor over `db`. Returns an opaque handle that must be
/// released with `tkrzw_cursor_free`. Returns null if `db` is null or the
/// cursor cannot be allocated/initialised.
pub export fn tkrzw_cursor_make(db: ?*anyopaque) ?*anyopaque {
    const poly = polyFromHandle(db) orelse return null;
    const io = requireIo() orelse return null;

    const cur = c_allocator.create(PolyCursor) catch return null;
    errdefer c_allocator.destroy(cur);
    cur.* = PolyCursor.init(poly, io) catch return null;
    return @ptrCast(cur);
}

/// Release a cursor previously returned by `tkrzw_cursor_make`. Safe to call
/// with a null handle (no-op). Caller must null its pointer afterwards;
/// double-free is undefined behaviour. Calling this after `tkrzw_deinit` will
/// not crash: memory is reclaimed and deregistration is skipped (the parent
/// DBM and its cursor registry are already gone).
pub export fn tkrzw_cursor_free(cursor: ?*anyopaque) void {
    const cur = cursorFromHandle(cursor) orelse return;
    if (requireIo()) |io| {
        // Normal path: deregister the cursor from the parent DBM's iterator
        // registry before freeing, so the DB doesn't hold a dangling pointer.
        cur.deinit(io);
    }
    // No-IO path (g_io unavailable): the parent DBM has already been destroyed
    // along with its cursor registry, so skipping deregistration is correct —
    // there is nothing left to deregister from. We still free our own memory.
    c_allocator.destroy(cur);
}

/// Position the cursor at the first record.
/// Returns NOT_FOUND_ERROR(7) if the database is empty.
/// Returns INVALID_ARGUMENT_ERROR(5) if `cursor` is null.
pub export fn tkrzw_cursor_first(cursor: ?*anyopaque) i32 {
    const cur = cursorFromHandle(cursor) orelse return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    const io = requireIo() orelse return @intFromEnum(Code.PRECONDITION_ERROR);
    return statusCode(cur.first(io));
}

/// Position the cursor at the last record (ordered backends only).
/// Returns NOT_FOUND_ERROR(7) if the database is empty.
/// Returns INVALID_ARGUMENT_ERROR(5) if `cursor` is null.
pub export fn tkrzw_cursor_last(cursor: ?*anyopaque) i32 {
    const cur = cursorFromHandle(cursor) orelse return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    const io = requireIo() orelse return @intFromEnum(Code.PRECONDITION_ERROR);
    return statusCode(cur.last(io));
}

/// Advance the cursor to the next record.
/// Returns NOT_FOUND_ERROR(7) when the cursor moves past the last record.
/// Returns INVALID_ARGUMENT_ERROR(5) if `cursor` is null.
pub export fn tkrzw_cursor_next(cursor: ?*anyopaque) i32 {
    const cur = cursorFromHandle(cursor) orelse return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    const io = requireIo() orelse return @intFromEnum(Code.PRECONDITION_ERROR);
    return statusCode(cur.next(io));
}

/// Move the cursor to the previous record (ordered backends only).
/// Returns NOT_FOUND_ERROR(7) when the cursor moves before the first record.
/// Returns INVALID_ARGUMENT_ERROR(5) if `cursor` is null.
pub export fn tkrzw_cursor_previous(cursor: ?*anyopaque) i32 {
    const cur = cursorFromHandle(cursor) orelse return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    const io = requireIo() orelse return @intFromEnum(Code.PRECONDITION_ERROR);
    return statusCode(cur.previous(io));
}

pub export fn tkrzw_cursor_jump(cursor: ?*anyopaque, key: [*c]const u8, key_len: usize) i32 {
    const cur = cursorFromHandle(cursor) orelse return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    if (key == null and key_len != 0) return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    const io = requireIo() orelse return @intFromEnum(Code.PRECONDITION_ERROR);
    const key_slice: []const u8 = if (key_len == 0) &[_]u8{} else key[0..key_len];
    return statusCode(cur.jump(io, key_slice));
}

pub export fn tkrzw_cursor_jump_lower(cursor: ?*anyopaque, key: [*c]const u8, key_len: usize, inclusive: bool) i32 {
    const cur = cursorFromHandle(cursor) orelse return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    if (key == null and key_len != 0) return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    const io = requireIo() orelse return @intFromEnum(Code.PRECONDITION_ERROR);
    const key_slice: []const u8 = if (key_len == 0) &[_]u8{} else key[0..key_len];
    return statusCode(cur.jumpLower(io, key_slice, inclusive));
}

pub export fn tkrzw_cursor_jump_upper(cursor: ?*anyopaque, key: [*c]const u8, key_len: usize, inclusive: bool) i32 {
    const cur = cursorFromHandle(cursor) orelse return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    if (key == null and key_len != 0) return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    const io = requireIo() orelse return @intFromEnum(Code.PRECONDITION_ERROR);
    const key_slice: []const u8 = if (key_len == 0) &[_]u8{} else key[0..key_len];
    return statusCode(cur.jumpUpper(io, key_slice, inclusive));
}

/// Common implementation backing `tkrzw_cursor_get` and `tkrzw_cursor_step`.
/// `step_and_advance` selects between `cursor.get` (false) and `cursor.step` (true).
fn cursorGetOrStep(
    cursor: ?*anyopaque,
    key_out: ?*[*c]u8,
    key_len_out: ?*usize,
    value_out: ?*[*c]u8,
    value_len_out: ?*usize,
    step_and_advance: bool,
) i32 {
    const cur = cursorFromHandle(cursor) orelse return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);

    // Pre-zero out-parameters so the caller sees a defined state on miss.
    if (key_out) |p| p.* = null;
    if (key_len_out) |p| p.* = 0;
    if (value_out) |p| p.* = null;
    if (value_len_out) |p| p.* = 0;

    // Both cur.get and cur.step populate the ArrayLists using the cursor/DB
    // stored allocator, which equals c_allocator because tkrzw_open always
    // passes c_allocator. deinit(c_allocator) is therefore correct for both
    // branches. If a backend ever gains an explicit allocator parameter on
    // step(), update the step call to pass c_allocator there too.
    var key_buf: std.ArrayList(u8) = .empty;
    defer key_buf.deinit(c_allocator);
    var val_buf: std.ArrayList(u8) = .empty;
    defer val_buf.deinit(c_allocator);

    const want_key = key_out != null and key_len_out != null;
    const want_val = value_out != null and value_len_out != null;
    const key_buf_ptr: ?*std.ArrayList(u8) = if (want_key) &key_buf else null;
    const val_buf_ptr: ?*std.ArrayList(u8) = if (want_val) &val_buf else null;

    const io = requireIo() orelse return @intFromEnum(Code.PRECONDITION_ERROR);
    const status = if (step_and_advance)
        cur.step(io, key_buf_ptr, val_buf_ptr)
    else
        cur.get(c_allocator, io, key_buf_ptr, val_buf_ptr);

    if (status.code != .SUCCESS) return statusCode(status);

    if (step_and_advance) {
        // STEP path: backend's allocator is the cursor/DB allocator (which is
        // c_allocator in this binding), but to keep this branch resilient to
        // any future signature change we keep the dupe-and-free pattern.
        if (want_key) {
            if (!writeOutSlice(key_buf.items, key_out.?, key_len_out.?)) {
                return @intFromEnum(Code.SYSTEM_ERROR);
            }
        }
        if (want_val) {
            if (!writeOutSlice(val_buf.items, value_out.?, value_len_out.?)) {
                if (want_key) {
                    c_allocator.free(key_out.?.*[0..key_len_out.?.*]);
                    key_out.?.* = null;
                    key_len_out.?.* = 0;
                }
                return @intFromEnum(Code.SYSTEM_ERROR);
            }
        }
    } else {
        // GET path: `cur.get` was passed c_allocator explicitly, so the
        // ArrayList's backing buffer is already malloc-backed. Transfer
        // ownership directly via `toOwnedSlice` to avoid an extra copy.
        if (want_key) {
            const owned = key_buf.toOwnedSlice(c_allocator) catch
                return @intFromEnum(Code.SYSTEM_ERROR);
            key_out.?.* = owned.ptr;
            key_len_out.?.* = owned.len;
        }
        if (want_val) {
            const owned = val_buf.toOwnedSlice(c_allocator) catch {
                if (want_key) {
                    c_allocator.free(key_out.?.*[0..key_len_out.?.*]);
                    key_out.?.* = null;
                    key_len_out.?.* = 0;
                }
                return @intFromEnum(Code.SYSTEM_ERROR);
            };
            value_out.?.* = owned.ptr;
            value_len_out.?.* = owned.len;
        }
    }

    return statusCode(status);
}

/// Fetch the key/value at the cursor's current position. Either or both of
/// `(key_out, key_len_out)` and `(value_out, value_len_out)` may be null to
/// skip the corresponding output. Non-null outputs are filled with a fresh
/// malloc'd buffer that the caller must `free()`. On a non-SUCCESS status,
/// the out-parameters remain null/0.
pub export fn tkrzw_cursor_get(
    cursor: ?*anyopaque,
    key_out: ?*[*c]u8,
    key_len_out: ?*usize,
    value_out: ?*[*c]u8,
    value_len_out: ?*usize,
) i32 {
    return cursorGetOrStep(cursor, key_out, key_len_out, value_out, value_len_out, false);
}

/// Like `tkrzw_cursor_get`, but advances the cursor to the next record
/// after reading. Output ownership rules match `tkrzw_cursor_get`.
pub export fn tkrzw_cursor_step(
    cursor: ?*anyopaque,
    key_out: ?*[*c]u8,
    key_len_out: ?*usize,
    value_out: ?*[*c]u8,
    value_len_out: ?*usize,
) i32 {
    return cursorGetOrStep(cursor, key_out, key_len_out, value_out, value_len_out, true);
}

/// Overwrite the value of the record at the cursor's current position.
pub export fn tkrzw_cursor_set(cursor: ?*anyopaque, value: [*c]const u8, value_len: usize) i32 {
    const cur = cursorFromHandle(cursor) orelse return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    if (value == null and value_len != 0) return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    const io = requireIo() orelse return @intFromEnum(Code.PRECONDITION_ERROR);
    const val_slice: []const u8 = if (value_len == 0) &[_]u8{} else value[0..value_len];
    return statusCode(cur.set(io, val_slice, null, null));
}

/// Remove the record at the cursor's current position.
pub export fn tkrzw_cursor_remove(cursor: ?*anyopaque) i32 {
    const cur = cursorFromHandle(cursor) orelse return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    const io = requireIo() orelse return @intFromEnum(Code.PRECONDITION_ERROR);
    return statusCode(cur.remove(io, null, null));
}

// ---------------------------------------------------------------------------
// ===========================================================================
// Callback-Driven Operations
// ===========================================================================
// ---------------------------------------------------------------------------

/// Maximum size of a value the C callback may return for a SET action.
/// Guards against a buggy or malicious callback writing an absurd length
/// into `*new_value_len_out` and causing the library to read megabytes of
/// garbage. SET actions exceeding this limit are silently downgraded to
/// NOOP.
const MAX_CALLBACK_VALUE_SIZE: usize = 64 * 1024 * 1024;

/// Callback type for process_each / process / process_first.
///
/// Returns: 0=NOOP, 1=REMOVE, 2=SET. Any other value is treated as NOOP.
/// For SET: write the new value pointer to *new_value_out and its length
/// to *new_value_len_out. The library copies the bytes before the callback
/// returns; the pointer need not remain valid afterwards.
/// When value is null and value_len is 0 the key is absent (processEmpty).
/// Do NOT call any tkrzw_* function on the same DBM from within the callback.
///
/// TRUST CONTRACT: the callback is trusted code. The library reads
/// `(*new_value_out)[0..*new_value_len_out]` directly without bounds
/// validation against the source buffer. Values whose length exceeds
/// 64 MiB cause the SET action to be silently downgraded to NOOP as a
/// last-line defence against a buggy callback returning a corrupted length.
pub const TkrzwRecordProcessor = *const fn (
    [*c]const u8,
    usize,
    [*c]const u8,
    usize,
    ?*anyopaque,
    *[*c]const u8,
    *usize,
) callconv(.c) i32;

/// Adapts a C TkrzwRecordProcessor into the Zig processor protocol
/// (processFull/processEmpty returning RecordAction).
const CProcessor = struct {
    callback: TkrzwRecordProcessor,
    user_data: ?*anyopaque,
    /// A copy of any SET value returned by the last callback invocation.
    /// Duped into c_allocator before we return RecordAction.set so the
    /// C callback's pointer need only live until it returns.
    /// Freed at the start of each new callback invocation and at deinit.
    arena_buf: ?[]u8 = null,

    pub fn deinit(self: *@This()) void {
        if (self.arena_buf) |buf| {
            c_allocator.free(buf);
            self.arena_buf = null;
        }
    }

    fn invoke(self: *@This(), key: []const u8, value: ?[]const u8) RecordAction {
        // Free previous SET buffer (if any).
        if (self.arena_buf) |buf| {
            c_allocator.free(buf);
            self.arena_buf = null;
        }
        var new_val_ptr: [*c]const u8 = null;
        var new_val_len: usize = 0;
        const val_ptr: [*c]const u8 = if (value) |v| v.ptr else null;
        const val_len: usize = if (value) |v| v.len else 0;
        const action = self.callback(
            key.ptr,
            key.len,
            val_ptr,
            val_len,
            self.user_data,
            &new_val_ptr,
            &new_val_len,
        );
        return switch (action) {
            1 => .remove,
            2 => blk: {
                // Cap size to guard against garbage / malicious length values.
                if (new_val_len > MAX_CALLBACK_VALUE_SIZE) break :blk .noop;
                const src: []const u8 = if (new_val_ptr != null and new_val_len != 0)
                    new_val_ptr[0..new_val_len]
                else
                    &[_]u8{};
                const owned = c_allocator.dupe(u8, src) catch break :blk .noop;
                self.arena_buf = owned;
                break :blk .{ .set = owned };
            },
            else => .noop,
        };
    }

    pub fn processFull(self: *@This(), key: []const u8, value: []const u8) RecordAction {
        return self.invoke(key, value);
    }

    pub fn processEmpty(self: *@This(), key: []const u8) RecordAction {
        // Absorb the Zig-layer batch-boundary sentinel: every backend emits
        // processEmpty("") once before and once after the processEach record
        // loop. Forwarding those calls to the C callback would violate the
        // documented contract ("invoked once per real record") and break any
        // callback that counts invocations.
        //
        // Known limitation: if a caller uses tkrzw_process() to query a record
        // whose key is literally the empty string and that key is absent, the
        // absent-key callback branch is also suppressed here. A real key=""
        // record visited via processEach is unaffected because that path goes
        // through processFull, not processEmpty.
        if (key.len == 0) return .noop;
        return self.invoke(key, null);
    }
};

/// Iterate over every record in the database invoking `callback` once per
/// record. When `writable` is false the callback's REMOVE/SET return values
/// are ignored by the backend.
///
/// The callback is trusted code; the library reads `*new_value_out[0..*new_value_len_out]`
/// directly. Values exceeding 64 MiB cause the SET action to be silently
/// downgraded to NOOP.
pub export fn tkrzw_process_each(
    db: ?*anyopaque,
    callback: ?TkrzwRecordProcessor,
    user_data: ?*anyopaque,
    writable: bool,
) i32 {
    const poly = polyFromHandle(db) orelse return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    const cb = callback orelse return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    const io = requireIo() orelse return @intFromEnum(Code.PRECONDITION_ERROR);
    var proc = CProcessor{ .callback = cb, .user_data = user_data };
    defer proc.deinit();
    const status = poly.processEach(io, CProcessor, &proc, writable) catch
        return @intFromEnum(Code.SYSTEM_ERROR);
    return statusCode(status);
}

/// Process the record for `key`. The callback is called with the existing
/// value when present, or with a null value pointer and zero length when the
/// key is absent.
///
/// The callback is trusted code; the library reads `*new_value_out[0..*new_value_len_out]`
/// directly. Values exceeding 64 MiB cause the SET action to be silently
/// downgraded to NOOP.
pub export fn tkrzw_process(
    db: ?*anyopaque,
    key: [*c]const u8,
    key_len: usize,
    callback: ?TkrzwRecordProcessor,
    user_data: ?*anyopaque,
    writable: bool,
) i32 {
    const poly = polyFromHandle(db) orelse return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    if (key == null) return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    const cb = callback orelse return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    const io = requireIo() orelse return @intFromEnum(Code.PRECONDITION_ERROR);
    var proc = CProcessor{ .callback = cb, .user_data = user_data };
    defer proc.deinit();
    const status = poly.process(io, key[0..key_len], &proc, writable) catch
        return @intFromEnum(Code.SYSTEM_ERROR);
    return statusCode(status);
}

/// Process the first record in the database with the given callback.
///
/// The callback is trusted code; the library reads `*new_value_out[0..*new_value_len_out]`
/// directly. Values exceeding 64 MiB cause the SET action to be silently
/// downgraded to NOOP.
pub export fn tkrzw_process_first(
    db: ?*anyopaque,
    callback: ?TkrzwRecordProcessor,
    user_data: ?*anyopaque,
    writable: bool,
) i32 {
    const poly = polyFromHandle(db) orelse return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    const cb = callback orelse return @intFromEnum(Code.INVALID_ARGUMENT_ERROR);
    const io = requireIo() orelse return @intFromEnum(Code.PRECONDITION_ERROR);
    var proc = CProcessor{ .callback = cb, .user_data = user_data };
    defer proc.deinit();
    return statusCode(poly.processFirst(io, &proc, writable));
}

// ---------------------------------------------------------------------------
// Force-reference helpers so the compiler doesn't drop them while waves
// 2-5 are still stubs.
// ---------------------------------------------------------------------------

comptime {
    _ = &polyFromHandle;
    _ = &cursorFromHandle;
    _ = &writeOutSlice;
    _ = &statusCode;
    _ = &polyErrorToCode;
}
