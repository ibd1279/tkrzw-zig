// Reverse-direction generator: writes the golden dataset with THIS PORT into
// all six backend formats, so the official tkrzw library can read the files
// back (see tests/golden/verify_reverse.py). Mirrors the dataset in
// src/golden_compat_test.zig and generate_golden.py — update in lockstep.
//
// Usage:
//   zig build-exe src/golden_reverse_writer.zig -lc --cache-dir .zig-cache \
//       -femit-bin=golden_reverse_writer
//   ./golden_reverse_writer [output-dir]     # default: system temp dir
//   python3 tests/golden/verify_reverse.py [dir-with-rev.tk*-files]
const std = @import("std");
const tkrzw = @import("root.zig");
const PolyDBM = tkrzw.PolyDBM;

const Record = struct { key: []const u8, value: []const u8 };

const prod_like = [_]Record{
    .{ .key = "queue.msg.000001", .value = "{\"room\": \"R0ABC\", \"user\": \"U1\", \"text\": \"standup notes\", \"ts\": 1764000100.0}" },
    .{ .key = "queue.msg.000002", .value = "{\"room\": \"R0ABC\", \"user\": \"U2\", \"text\": \"deploy finished\", \"ts\": 1764000200.0}" },
    .{ .key = "schedule.event.000001", .value = "{\"title\": \"1:1\", \"start\": 1764036000.0, \"duration\": 1800}" },
    .{ .key = "inbox.mail.000001", .value = "{\"from\": \"a@example.com\", \"subject\": \"Re: build\", \"ts\": 1764040000.0}" },
};

const special_records = [_]Record{
    .{ .key = "", .value = "value-for-empty-key" },
    .{ .key = "bin\x00key", .value = "bin\x00\xff\xfevalue" },
    .{ .key = "empty-value", .value = "" },
    .{ .key = "json-doc", .value = "{\"id\": \"sig-001\", \"ts\": 1764000000.0, \"text\": \"hello \xf0\x9f\x8c\x8d\", \"tags\": [\"queue\", \"memo\"], \"n\": 42}" },
    .{ .key = "large", .value = &large_value },
    .{ .key = "unicode-\xf0\x9f\x94\x91", .value = "valeur-\xc3\xa7a-\xc3\xa9\xf0\x9f\x94\x91" },
};

const large_value: [4219]u8 = blk: {
    var buf: [4219]u8 = @splat('A');
    @memset(buf[4096..], 'B');
    break :blk buf;
};

fn goldenRecords(alloc: std.mem.Allocator) ![]Record {
    var records = try std.ArrayList(Record).initCapacity(alloc, 110);
    errdefer records.deinit(alloc);
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const key = try std.fmt.allocPrint(alloc, "key_{d:0>3}", .{i});
        var pad_buf: [16]u8 = undefined;
        const pad_len = i % 17;
        @memset(pad_buf[0..pad_len], 'x');
        const value = try std.fmt.allocPrint(alloc, "val_{d:0>3}_{s}", .{ i, pad_buf[0..pad_len] });
        records.appendAssumeCapacity(.{ .key = key, .value = value });
    }
    for (prod_like) |r| records.appendAssumeCapacity(r);
    for (special_records) |r| records.appendAssumeCapacity(r);
    return records.toOwnedSlice(alloc);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = std.heap.c_allocator;

    var out_dir_buf: [512]u8 = undefined;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip(); // program name
    const out_dir = if (args.next()) |dir|
        try std.fmt.bufPrint(&out_dir_buf, "{s}", .{dir})
    else
        try std.fmt.bufPrint(&out_dir_buf, "/tmp/tkrzw-revgolden", .{});
    try std.Io.Dir.cwd().createDirPath(io, out_dir);

    const records = try goldenRecords(alloc);

    const names = [_][]const u8{ "rev.tkh", "rev.tkt", "rev.tks", "rev.tkmt", "rev.tkmb", "rev.tkmc" };
    for (names) |name| {
        var path_buf: [512]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ out_dir, name });

        var db = try PolyDBM.open(path, .{ .writable = true, .num_buckets = 256 }, io, alloc);
        defer db.deinit(io);

        for (records) |r| {
            const st = db.set(io, r.key, r.value, true);
            if (!st.isOk()) {
                std.debug.print("FAIL set in {s}: {any}\n", .{ name, st });
                std.process.exit(1);
            }
        }
        // Mirror generate_golden.py: explicit synchronize before close.
        const sync_st = db.synchronize(io, false);
        if (!sync_st.isOk()) {
            std.debug.print("FAIL sync {s}: {any}\n", .{ name, sync_st });
            std.process.exit(1);
        }
        const close_st = db.close(io);
        if (!close_st.isOk()) {
            std.debug.print("FAIL close {s}: {any}\n", .{ name, close_st });
            std.process.exit(1);
        }
        std.debug.print("wrote {s}\n", .{path});
    }
    std.debug.print("done\n", .{});
}
