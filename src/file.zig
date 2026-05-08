const std = @import("std");
const lib_common = @import("lib_common.zig");
pub const Status = lib_common.Status;
pub const StatusCode = lib_common.Code;

/// Bit-flag options for File.open, matching the C++ OpenOptions bit positions.
///   bit 0: truncate   — truncate file to zero length on open
///   bit 1: no_create  — do not create if missing (return NOT_FOUND_ERROR)
///   bit 2: no_wait    — non-blocking lock attempt; returns INFEASIBLE_ERROR on contention
///   bit 3: no_lock    — skip OS file locking entirely; caller is responsible for
///                       preventing concurrent access
///   bit 4: sync_hard  — use O_SYNC / O_DSYNC on open
pub const OpenOptions = packed struct(i32) {
    truncate: bool = false,
    no_create: bool = false,
    no_wait: bool = false,
    no_lock: bool = false,
    sync_hard: bool = false,
    _pad: i27 = 0,
};

/// Vtable-based file abstraction. The implementation object is stored in ctx;
/// all operations dispatch through vtable. Callers own *File values created
/// via makeFile and must deinit them when done.
pub const File = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        open: *const fn (ctx: *anyopaque, path: []const u8, writable: bool, options: OpenOptions) Status,
        close: *const fn (ctx: *anyopaque) Status,
        read: *const fn (ctx: *anyopaque, off: i64, buf: []u8) Status,
        write: *const fn (ctx: *anyopaque, off: i64, data: []const u8) Status,
        append: *const fn (ctx: *anyopaque, data: []const u8, off: ?*i64) Status,
        truncate: *const fn (ctx: *anyopaque, size: i64) Status,
        synchronize: *const fn (ctx: *anyopaque, hard: bool) Status,
        getSize: *const fn (ctx: *anyopaque, out: *i64) Status,
        makeFile: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) std.mem.Allocator.Error!*File,
        deinit: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) void,
    };

    /// Opens the file at `path`. By default acquires an OS advisory lock
    /// (LOCK_EX for writable opens, LOCK_SH for read-only) via flock(2).
    /// Pass `options.no_lock = true` to skip locking (caller must ensure safety).
    /// Pass `options.no_wait = true` for a non-blocking attempt; returns
    /// INFEASIBLE_ERROR immediately if the lock is held by another process.
    pub fn open(self: File, path: []const u8, writable: bool, options: OpenOptions) Status {
        return self.vtable.open(self.ctx, path, writable, options);
    }

    pub fn close(self: File) Status {
        return self.vtable.close(self.ctx);
    }

    pub fn read(self: File, off: i64, buf: []u8) Status {
        return self.vtable.read(self.ctx, off, buf);
    }

    pub fn write(self: File, off: i64, data: []const u8) Status {
        return self.vtable.write(self.ctx, off, data);
    }

    pub fn append(self: File, data: []const u8, off: ?*i64) Status {
        return self.vtable.append(self.ctx, data, off);
    }

    pub fn truncate(self: File, size: i64) Status {
        return self.vtable.truncate(self.ctx, size);
    }

    pub fn synchronize(self: File, hard: bool) Status {
        return self.vtable.synchronize(self.ctx, hard);
    }

    pub fn getSize(self: File, out: *i64) Status {
        return self.vtable.getSize(self.ctx, out);
    }

    pub fn makeFile(self: File, allocator: std.mem.Allocator) std.mem.Allocator.Error!*File {
        return self.vtable.makeFile(self.ctx, allocator);
    }

    pub fn deinit(self: File, allocator: std.mem.Allocator) void {
        self.vtable.deinit(self.ctx, allocator);
    }

    /// Returns the file size, or -1 on any error.
    pub fn getSizeSimple(self: File) i64 {
        var size: i64 = 0;
        const st = self.getSize(&size);
        if (!st.isOk()) return -1;
        return size;
    }
};

// ---------------------------------------------------------------------------
// StdFile — concrete File implementation backed by a POSIX file descriptor
// ---------------------------------------------------------------------------

pub const StdFile = struct {
    /// -1 means closed.
    fd: std.posix.fd_t = -1,
    /// Heap-allocated copy of the path, freed on close/deinit.
    path: ?[]u8 = null,
    writable: bool = false,
    /// Logical file size tracked after open (like C++ MemoryMapParallelFile).
    logical_size: i64 = 0,
    allocator: std.mem.Allocator,

    const vtable = File.VTable{
        .open = vtOpen,
        .close = vtClose,
        .read = vtRead,
        .write = vtWrite,
        .append = vtAppend,
        .truncate = vtTruncate,
        .synchronize = vtSynchronize,
        .getSize = vtGetSize,
        .makeFile = vtMakeFile,
        .deinit = vtDeinit,
    };

    /// Allocates and initializes a new StdFile with the given allocator.
    pub fn create(allocator: std.mem.Allocator) std.mem.Allocator.Error!*StdFile {
        const self = try allocator.create(StdFile);
        self.* = .{ .allocator = allocator };
        return self;
    }

    /// Returns a File interface value pointing to self.
    pub fn asFile(self: *StdFile) File {
        return .{
            .ctx = self,
            .vtable = &vtable,
        };
    }

    // -----------------------------------------------------------------------
    // Vtable implementations
    // -----------------------------------------------------------------------

    fn vtOpen(ctx: *anyopaque, path: []const u8, writable: bool, options: OpenOptions) Status {
        const self: *StdFile = @ptrCast(@alignCast(ctx));

        if (self.fd != -1) {
            // Already open; caller should close first.
            return Status.init(.PRECONDITION_ERROR);
        }

        const fd: std.posix.fd_t = blk: {
            // Build a null-terminated copy of the path for POSIX calls.
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            if (path.len >= path_buf.len) return Status.init(.INVALID_ARGUMENT_ERROR);
            @memcpy(path_buf[0..path.len], path);
            path_buf[path.len] = 0;
            const pathZ: [*:0]const u8 = path_buf[0..path.len :0];

            if (writable) {
                if (options.no_create) {
                    // Fail if the file doesn't exist.
                    const access_result = std.c.access(pathZ, std.c.F_OK);
                    if (access_result != 0) return Status.init(.NOT_FOUND_ERROR);
                }
                var flags: std.posix.O = .{
                    .ACCMODE = .RDWR,
                    .CREAT = true,
                };
                if (options.truncate) flags.TRUNC = true;
                const new_fd = std.posix.openatZ(std.posix.AT.FDCWD, pathZ, flags, 0o644) catch
                    return Status.init(.SYSTEM_ERROR);
                break :blk new_fd;
            } else {
                const new_fd = std.posix.openatZ(std.posix.AT.FDCWD, pathZ, .{ .ACCMODE = .RDONLY }, 0) catch |err| {
                    return switch (err) {
                        error.FileNotFound => Status.init(.NOT_FOUND_ERROR),
                        else => Status.init(.SYSTEM_ERROR),
                    };
                };
                break :blk new_fd;
            }
        };
        // All error returns below this point must close fd explicitly since
        // vtable functions return Status (not !Status), so errdefer is not applicable.

        // Determine current logical size via fstat.
        const file_size: i64 = blk: {
            var stat_buf: std.c.Stat = undefined;
            if (std.c.fstat(fd, &stat_buf) != 0) break :blk -1;
            break :blk @intCast(stat_buf.size);
        };
        if (file_size < 0) {
            _ = std.c.close(fd);
            return Status.init(.SYSTEM_ERROR);
        }

        // Acquire an OS-level advisory lock unless the caller opted out.
        // Writable opens use LOCK_EX (exclusive); read-only opens use LOCK_SH (shared).
        // no_wait=true adds LOCK_NB so the syscall fails immediately on contention.
        // Blocking flock (no_wait=false) can be interrupted by a signal (EINTR); retry
        // in that case. LOCK_NB never returns EINTR, so the retry is a no-op for no_wait.
        // Note: flock is advisory-only — processes that do not call flock can still
        // access the file. All tkrzw-zig callers must open through this vtable to
        // participate in the locking protocol.
        if (!options.no_lock) {
            const lock_op: c_int = if (writable) std.posix.LOCK.EX else std.posix.LOCK.SH;
            const nb_flag: c_int = if (options.no_wait) std.posix.LOCK.NB else 0;
            const flock_err = blk: {
                while (true) {
                    const rc = std.c.flock(fd, lock_op | nb_flag);
                    if (rc == 0) break :blk @as(std.c.E, .SUCCESS);
                    // Capture errno BEFORE any other syscall can overwrite it.
                    const err = std.c.errno(rc);
                    if (err == .INTR and !options.no_wait) continue; // retry on signal
                    break :blk err;
                }
            };
            if (flock_err != .SUCCESS) {
                _ = std.c.close(fd);
                return if (options.no_wait and flock_err == .AGAIN)
                    Status.init(.INFEASIBLE_ERROR)
                else
                    Status.init(.SYSTEM_ERROR);
            }
        }

        const path_copy = self.allocator.dupe(u8, path) catch {
            _ = std.c.close(fd);
            return Status.init(.SYSTEM_ERROR);
        };

        self.fd = fd;
        self.path = path_copy;
        self.writable = writable;
        self.logical_size = @intCast(file_size);
        return Status.init(.SUCCESS);
    }

    fn vtClose(ctx: *anyopaque) Status {
        const self: *StdFile = @ptrCast(@alignCast(ctx));
        if (self.fd != -1) {
            _ = std.c.close(self.fd);
            self.fd = -1;
        }
        if (self.path) |p| {
            self.allocator.free(p);
            self.path = null;
        }
        self.writable = false;
        self.logical_size = 0;
        return Status.init(.SUCCESS);
    }

    fn vtRead(ctx: *anyopaque, off: i64, buf: []u8) Status {
        const self: *StdFile = @ptrCast(@alignCast(ctx));
        if (self.fd == -1) return Status.init(.PRECONDITION_ERROR);

        if (buf.len == 0) return Status.init(.SUCCESS);
        if (off < 0) return Status.init(.INVALID_ARGUMENT_ERROR);

        const n = std.c.pread(self.fd, buf.ptr, buf.len, off);
        if (n < 0) return Status.init(.SYSTEM_ERROR);

        if (@as(usize, @intCast(n)) < buf.len) {
            return Status.initMsg(.BROKEN_DATA_ERROR, "short read");
        }
        return Status.init(.SUCCESS);
    }

    fn vtWrite(ctx: *anyopaque, off: i64, data: []const u8) Status {
        const self: *StdFile = @ptrCast(@alignCast(ctx));
        if (self.fd == -1) return Status.init(.PRECONDITION_ERROR);

        if (data.len == 0) return Status.init(.SUCCESS);
        if (off < 0) return Status.init(.INVALID_ARGUMENT_ERROR);

        const n = std.c.pwrite(self.fd, data.ptr, data.len, off);
        if (n < 0 or @as(usize, @intCast(n)) < data.len) return Status.initMsg(.SYSTEM_ERROR, "short write");

        return Status.init(.SUCCESS);
    }

    fn vtAppend(ctx: *anyopaque, data: []const u8, off: ?*i64) Status {
        const self: *StdFile = @ptrCast(@alignCast(ctx));
        if (self.fd == -1) return Status.init(.PRECONDITION_ERROR);

        if (data.len == 0) {
            if (off) |p| p.* = self.logical_size;
            return Status.init(.SUCCESS);
        }

        // Write at logical end via pwrite (avoids seek/write races).
        const n = std.c.pwrite(self.fd, data.ptr, data.len, self.logical_size);
        if (n < 0 or @as(usize, @intCast(n)) < data.len) return Status.initMsg(.SYSTEM_ERROR, "short append write");

        if (off) |p| p.* = self.logical_size;
        self.logical_size += @intCast(data.len);
        return Status.init(.SUCCESS);
    }

    fn vtTruncate(ctx: *anyopaque, size: i64) Status {
        const self: *StdFile = @ptrCast(@alignCast(ctx));
        if (self.fd == -1) return Status.init(.PRECONDITION_ERROR);

        const rc = std.c.ftruncate(self.fd, @intCast(size));
        if (rc != 0) return Status.init(.SYSTEM_ERROR);
        self.logical_size = size;
        return Status.init(.SUCCESS);
    }

    fn vtSynchronize(ctx: *anyopaque, hard: bool) Status {
        _ = hard;
        const self: *StdFile = @ptrCast(@alignCast(ctx));
        if (self.fd == -1) return Status.init(.PRECONDITION_ERROR);
        const rc = std.c.fsync(self.fd);
        if (rc != 0) return Status.init(.SYSTEM_ERROR);
        return Status.init(.SUCCESS);
    }

    fn vtGetSize(ctx: *anyopaque, out: *i64) Status {
        const self: *StdFile = @ptrCast(@alignCast(ctx));
        if (self.fd == -1) return Status.init(.PRECONDITION_ERROR);
        out.* = self.logical_size;
        return Status.init(.SUCCESS);
    }

    fn vtMakeFile(ctx: *anyopaque, allocator: std.mem.Allocator) std.mem.Allocator.Error!*File {
        // ctx provides the "model" type; we ignore its state and create a fresh instance.
        _ = ctx;
        const new_std_file = try allocator.create(StdFile);
        errdefer allocator.destroy(new_std_file);
        new_std_file.* = .{ .allocator = allocator };

        const file_ptr = try allocator.create(File);
        file_ptr.* = new_std_file.asFile();
        return file_ptr;
    }

    fn vtDeinit(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *StdFile = @ptrCast(@alignCast(ctx));
        // Close if still open (best-effort; ignore errors on deinit).
        if (self.fd != -1) {
            _ = vtClose(ctx);
        }
        allocator.destroy(self);
    }
};

// ---------------------------------------------------------------------------
// Path utilities
// ---------------------------------------------------------------------------

pub fn normalizePath(path: []const u8) []const u8 {
    return path;
}

pub fn renameFile(old_path: []const u8, new_path: []const u8) Status {
    var old_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var new_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (old_path.len >= old_buf.len or new_path.len >= new_buf.len)
        return Status.init(.INVALID_ARGUMENT_ERROR);
    @memcpy(old_buf[0..old_path.len], old_path);
    old_buf[old_path.len] = 0;
    @memcpy(new_buf[0..new_path.len], new_path);
    new_buf[new_path.len] = 0;
    const rc = std.c.rename(old_buf[0..old_path.len :0].ptr, new_buf[0..new_path.len :0].ptr);
    if (rc != 0) return Status.init(.SYSTEM_ERROR);
    return Status.init(.SUCCESS);
}

pub fn removeFile(path: []const u8) Status {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return Status.init(.INVALID_ARGUMENT_ERROR);
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = std.c.unlink(buf[0..path.len :0].ptr);
    return Status.init(.SUCCESS);
}

pub fn deleteFileAbsolute(path: []const u8) void {
    _ = removeFile(path);
}

/// Copies a file from src_path to dest_path using POSIX I/O.
/// Both paths must be absolute (or valid relative paths).
pub fn copyFileAbsolute(src_path: []const u8, dest_path: []const u8) !void {
    // Open source.
    var src_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var dst_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (src_path.len >= src_buf.len or dest_path.len >= dst_buf.len) return error.NameTooLong;
    @memcpy(src_buf[0..src_path.len], src_path);
    src_buf[src_path.len] = 0;
    @memcpy(dst_buf[0..dest_path.len], dest_path);
    dst_buf[dest_path.len] = 0;

    const src_fd = try std.posix.openatZ(std.posix.AT.FDCWD, src_buf[0..src_path.len :0], .{ .ACCMODE = .RDONLY }, 0);
    defer _ = std.c.close(src_fd);

    const dst_fd = try std.posix.openatZ(std.posix.AT.FDCWD, dst_buf[0..dest_path.len :0], .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, 0o644);
    defer _ = std.c.close(dst_fd);

    var copy_buf: [65536]u8 = undefined;
    var offset: i64 = 0;
    while (true) {
        const nr = std.c.pread(src_fd, &copy_buf, copy_buf.len, offset);
        if (nr < 0) return error.InputOutput;
        const n: usize = @intCast(nr);
        if (n == 0) break;
        var written: usize = 0;
        while (written < n) {
            const nw = std.c.pwrite(dst_fd, copy_buf[written..n].ptr, n - written, offset + @as(i64, @intCast(written)));
            if (nw <= 0) return error.InputOutput;
            written += @intCast(nw);
        }
        offset += @intCast(n);
    }
}

// ---------------------------------------------------------------------------
// NullFile: noop File implementation for in-memory-only use (e.g., MemIndex)
// ---------------------------------------------------------------------------

fn nullFileOpen(ctx: *anyopaque, path: []const u8, writable: bool, options: OpenOptions) Status {
    _ = ctx;
    _ = path;
    _ = writable;
    _ = options;
    return Status.init(.NOT_IMPLEMENTED_ERROR);
}

fn nullFileClose(ctx: *anyopaque) Status {
    _ = ctx;
    return Status.init(.NOT_IMPLEMENTED_ERROR);
}

fn nullFileRead(ctx: *anyopaque, off: i64, buf: []u8) Status {
    _ = ctx;
    _ = off;
    _ = buf;
    return Status.init(.NOT_IMPLEMENTED_ERROR);
}

fn nullFileWrite(ctx: *anyopaque, off: i64, data: []const u8) Status {
    _ = ctx;
    _ = off;
    _ = data;
    return Status.init(.NOT_IMPLEMENTED_ERROR);
}

fn nullFileAppend(ctx: *anyopaque, data: []const u8, off: ?*i64) Status {
    _ = ctx;
    _ = data;
    _ = off;
    return Status.init(.NOT_IMPLEMENTED_ERROR);
}

fn nullFileTruncate(ctx: *anyopaque, size: i64) Status {
    _ = ctx;
    _ = size;
    return Status.init(.NOT_IMPLEMENTED_ERROR);
}

fn nullFileSynchronize(ctx: *anyopaque, hard: bool) Status {
    _ = ctx;
    _ = hard;
    return Status.init(.NOT_IMPLEMENTED_ERROR);
}

fn nullFileGetSize(ctx: *anyopaque, out: *i64) Status {
    _ = ctx;
    _ = out;
    return Status.init(.NOT_IMPLEMENTED_ERROR);
}

fn nullFileMakeFile(ctx: *anyopaque, allocator: std.mem.Allocator) std.mem.Allocator.Error!*File {
    _ = ctx;
    // Return a copy of NullFile itself
    const file_ptr = try allocator.create(File);
    file_ptr.* = NullFile;
    return file_ptr;
}

fn nullFileDeinit(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    _ = ctx;
    _ = allocator;
    // noop; NullFile uses a static ctx
}

var null_file_vtable: File.VTable = .{
    .open = nullFileOpen,
    .close = nullFileClose,
    .read = nullFileRead,
    .write = nullFileWrite,
    .append = nullFileAppend,
    .truncate = nullFileTruncate,
    .synchronize = nullFileSynchronize,
    .getSize = nullFileGetSize,
    .makeFile = nullFileMakeFile,
    .deinit = nullFileDeinit,
};

var null_file_ctx: u8 = 0; // dummy non-null context

pub const NullFile: File = .{
    .ctx = @ptrCast(&null_file_ctx),
    .vtable = &null_file_vtable,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "OpenOptions default value is 0 as i32" {
    const opts = OpenOptions{};
    try std.testing.expectEqual(@as(i32, 0), @as(i32, @bitCast(opts)));
}

test "StdFile open/write/read/close round-trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf);
    const tmp_path = path_buf[0..path_len];

    const file_name = try std.fmt.allocPrint(std.testing.allocator, "{s}/roundtrip.bin", .{tmp_path});
    defer std.testing.allocator.free(file_name);

    const sf = try StdFile.create(std.testing.allocator);
    var f = sf.asFile();

    // Open for writing (create).
    var st = f.open(file_name, true, .{});
    try std.testing.expect(st.isOk());

    // Write some bytes at offset 0.
    const data = "hello, world";
    st = f.write(0, data);
    try std.testing.expect(st.isOk());

    // Close.
    st = f.close();
    try std.testing.expect(st.isOk());

    // Re-open read-only.
    st = f.open(file_name, false, .{});
    try std.testing.expect(st.isOk());

    // Read back.
    var buf: [12]u8 = undefined;
    st = f.read(0, &buf);
    try std.testing.expect(st.isOk());
    try std.testing.expectEqualStrings(data, &buf);

    // Close and destroy.
    st = f.close();
    try std.testing.expect(st.isOk());

    f.deinit(std.testing.allocator);
}

test "StdFile append increases logical size correctly" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf);
    const tmp_path = path_buf[0..path_len];

    const file_name = try std.fmt.allocPrint(std.testing.allocator, "{s}/append_test.bin", .{tmp_path});
    defer std.testing.allocator.free(file_name);

    const sf = try StdFile.create(std.testing.allocator);
    var f = sf.asFile();
    defer f.deinit(std.testing.allocator);

    var st = f.open(file_name, true, .{});
    try std.testing.expect(st.isOk());

    var off1: i64 = -1;
    st = f.append("abc", &off1);
    try std.testing.expect(st.isOk());
    try std.testing.expectEqual(@as(i64, 0), off1);

    var off2: i64 = -1;
    st = f.append("de", &off2);
    try std.testing.expect(st.isOk());
    try std.testing.expectEqual(@as(i64, 3), off2);

    var size: i64 = 0;
    st = f.getSize(&size);
    try std.testing.expect(st.isOk());
    try std.testing.expectEqual(@as(i64, 5), size);

    _ = f.close();
}

test "renameFile and removeFile" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf);
    const tmp_path = path_buf[0..path_len];

    const src = try std.fmt.allocPrint(std.testing.allocator, "{s}/src.bin", .{tmp_path});
    defer std.testing.allocator.free(src);
    const dst = try std.fmt.allocPrint(std.testing.allocator, "{s}/dst.bin", .{tmp_path});
    defer std.testing.allocator.free(dst);

    // Create source file.
    {
        var src_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        if (src.len < src_buf.len) {
            @memcpy(src_buf[0..src.len], src);
            src_buf[src.len] = 0;
            const fd = try std.posix.openatZ(std.posix.AT.FDCWD, src_buf[0..src.len :0], .{ .ACCMODE = .RDWR, .CREAT = true }, 0o644);
            _ = std.c.close(fd);
        }
    }

    var st = renameFile(src, dst);
    try std.testing.expect(st.isOk());

    // src should be gone; dst should exist.
    {
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        @memcpy(buf[0..src.len], src);
        buf[src.len] = 0;
        try std.testing.expectEqual(@as(c_int, -1), std.c.access(buf[0..src.len :0].ptr, std.c.F_OK));
    }
    {
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        @memcpy(buf[0..dst.len], dst);
        buf[dst.len] = 0;
        try std.testing.expectEqual(@as(c_int, 0), std.c.access(buf[0..dst.len :0].ptr, std.c.F_OK));
    }

    st = removeFile(dst);
    try std.testing.expect(st.isOk());

    {
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        @memcpy(buf[0..dst.len], dst);
        buf[dst.len] = 0;
        try std.testing.expectEqual(@as(c_int, -1), std.c.access(buf[0..dst.len :0].ptr, std.c.F_OK));
    }
}

test "StdFile no_lock skips flock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf);
    const tmp_path = path_buf[0..path_len];

    const file_name = try std.fmt.allocPrint(std.testing.allocator, "{s}/lock_test.bin", .{tmp_path});
    defer std.testing.allocator.free(file_name);

    const sf1 = try StdFile.create(std.testing.allocator);
    var f1 = sf1.asFile();
    defer f1.deinit(std.testing.allocator);

    const sf2 = try StdFile.create(std.testing.allocator);
    var f2 = sf2.asFile();
    defer f2.deinit(std.testing.allocator);

    // f1 acquires LOCK_EX via normal locking.
    var st = f1.open(file_name, true, .{});
    try std.testing.expect(st.isOk());

    // f2 uses no_lock=true — must succeed DESPITE f1 holding LOCK_EX.
    // If no_lock were ignored, this would block (deadlock), proving the flag works.
    st = f2.open(file_name, true, .{ .no_lock = true });
    try std.testing.expect(st.isOk());

    _ = f1.close();
    _ = f2.close();
}

test "StdFile no_wait returns INFEASIBLE_ERROR on contention" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf);
    const tmp_path = path_buf[0..path_len];

    const file_name = try std.fmt.allocPrint(std.testing.allocator, "{s}/lock_contention.bin", .{tmp_path});
    defer std.testing.allocator.free(file_name);

    const sf1 = try StdFile.create(std.testing.allocator);
    var f1 = sf1.asFile();
    defer f1.deinit(std.testing.allocator);

    const sf2 = try StdFile.create(std.testing.allocator);
    var f2 = sf2.asFile();
    defer f2.deinit(std.testing.allocator);

    // sf1 acquires LOCK_EX and holds it.
    var st = f1.open(file_name, true, .{});
    try std.testing.expect(st.isOk());

    // sf2 attempts LOCK_EX | LOCK_NB on the same file — must fail immediately.
    st = f2.open(file_name, true, .{ .no_wait = true });
    try std.testing.expectEqual(StatusCode.INFEASIBLE_ERROR, st.code);

    _ = f1.close();
}

test "StdFile shared locks coexist" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try std.Io.Dir.realPathFile(tmp.dir, std.testing.io, ".", &path_buf);
    const tmp_path = path_buf[0..path_len];

    const file_name = try std.fmt.allocPrint(std.testing.allocator, "{s}/lock_shared.bin", .{tmp_path});
    defer std.testing.allocator.free(file_name);

    // Create the file first so read-only opens succeed.
    {
        const sf_init = try StdFile.create(std.testing.allocator);
        var f_init = sf_init.asFile();
        const st = f_init.open(file_name, true, .{ .no_lock = true });
        try std.testing.expect(st.isOk());
        _ = f_init.close();
        f_init.deinit(std.testing.allocator);
    }

    const sf1 = try StdFile.create(std.testing.allocator);
    var f1 = sf1.asFile();
    defer f1.deinit(std.testing.allocator);

    const sf2 = try StdFile.create(std.testing.allocator);
    var f2 = sf2.asFile();
    defer f2.deinit(std.testing.allocator);

    // Both open read-only — LOCK_SH is compatible with another LOCK_SH.
    var st = f1.open(file_name, false, .{});
    try std.testing.expect(st.isOk());

    st = f2.open(file_name, false, .{});
    try std.testing.expect(st.isOk());

    _ = f1.close();
    _ = f2.close();
}
