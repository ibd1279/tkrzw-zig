const std = @import("std");
const tkrzw = @import("tkrzw_zig");
const PolyDBM = tkrzw.PolyDBM;
const BackendType = tkrzw.BackendType;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // --- Arg parsing ---
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip(); // skip argv[0]

    var file_path: ?[]const u8 = null;
    var type_str: ?[]const u8 = null;
    var action: ?[]const u8 = null;
    var key: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--file") or std.mem.eql(u8, arg, "-f")) {
            file_path = args.next() orelse {
                std.log.err("--file requires a value", .{});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--type") or std.mem.eql(u8, arg, "-t")) {
            type_str = args.next() orelse {
                std.log.err("--type requires a value", .{});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--act") or std.mem.eql(u8, arg, "-a")) {
            action = args.next() orelse {
                std.log.err("--act requires a value", .{});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--key") or std.mem.eql(u8, arg, "-k")) {
            key = args.next() orelse {
                std.log.err("--key requires a value", .{});
                std.process.exit(1);
            };
        } else {
            std.log.err("unknown flag: {s}", .{arg});
            std.process.exit(1);
        }
    }

    // --- Validate required flags ---
    const path = file_path orelse {
        std.log.err("--file is required", .{});
        std.process.exit(1);
    };
    const act = action orelse {
        std.log.err("--act is required", .{});
        std.process.exit(1);
    };

    // --- Parse optional backend type override ---
    const backend_override: ?BackendType = if (type_str) |t| blk: {
        if (std.mem.eql(u8, t, "hash")) break :blk .hash;
        if (std.mem.eql(u8, t, "tree")) break :blk .tree;
        if (std.mem.eql(u8, t, "skip")) break :blk .skip;
        if (std.mem.eql(u8, t, "tiny")) break :blk .tiny;
        if (std.mem.eql(u8, t, "baby")) break :blk .baby;
        if (std.mem.eql(u8, t, "cache")) break :blk .cache;
        std.log.err("unknown backend type: {s}", .{t});
        std.process.exit(1);
    } else null;

    // --- Open database ---
    var db = PolyDBM.open(path, .{ .writable = false, .backend = backend_override }, io, allocator) catch |err| {
        std.log.err("failed to open database: {}", .{err});
        std.process.exit(1);
    };
    defer db.deinit(io);
    defer _ = db.close(io);

    // --- Dispatch action ---
    if (std.mem.eql(u8, act, "get")) {
        const k = key orelse {
            std.log.err("--key is required for action 'get'", .{});
            std.process.exit(1);
        };

        const value = db.get(allocator, io, k) catch |err| switch (err) {
            error.NotFound => {
                std.log.err("key not found: {s}", .{k});
                std.process.exit(1);
            },
            else => {
                std.log.err("get failed: {}", .{err});
                std.process.exit(1);
            },
        };
        defer allocator.free(value);

        var buf: [4096]u8 = undefined;
        var stdout_bw = std.Io.File.stdout().writer(io, &buf);
        const stdout = &stdout_bw.interface;
        defer stdout.flush() catch {};
        try stdout.print("{s}\n", .{value});
    } else if (std.mem.eql(u8, act, "keys")) {
        var buf: [4096]u8 = undefined;
        var stdout_bw = std.Io.File.stdout().writer(io, &buf);
        const stdout = &stdout_bw.interface;
        defer stdout.flush() catch {};

        var iter = db.iterate(allocator, io) catch |err| {
            std.log.err("failed to open iterator: {}", .{err});
            std.process.exit(1);
        };
        defer iter.deinit(io);

        while (iter.next(io) catch |err| {
            std.log.err("iterator error: {}", .{err});
            std.process.exit(1);
        }) |entry| {
            try stdout.print("{s}\n", .{entry.key});
        }
    } else {
        std.log.err("unknown action: {s}", .{act});
        std.process.exit(1);
    }
}
