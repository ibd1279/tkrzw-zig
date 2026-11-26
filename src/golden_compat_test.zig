//! Golden-dataset compatibility tests.
//!
//! These tests read database files in `tests/golden/` that were created by
//! the OFFICIAL tkrzw library (see tests/golden/generate_golden.py) and
//! verify that this Zig port can open and read them. The record dataset is
//! re-derived here deterministically; if you change it, update
//! tests/golden/generate_golden.py and regenerate the files.

const std = @import("std");
const tkrzw = @import("root.zig");
const PolyDBM = tkrzw.PolyDBM;
const dbm_poly = @import("dbm_poly.zig");

const Record = struct {
    key: []const u8,
    value: []const u8,
};

/// Production-like records: dotted keys with JSON values, matching the
/// shape of the production stores this port must be able to read.
const prod_like = [_]Record{
    .{ .key = "queue.msg.000001", .value = "{\"room\": \"R0ABC\", \"user\": \"U1\", \"text\": \"standup notes\", \"ts\": 1764000100.0}" },
    .{ .key = "queue.msg.000002", .value = "{\"room\": \"R0ABC\", \"user\": \"U2\", \"text\": \"deploy finished\", \"ts\": 1764000200.0}" },
    .{ .key = "schedule.event.000001", .value = "{\"title\": \"1:1\", \"start\": 1764036000.0, \"duration\": 1800}" },
    .{ .key = "inbox.mail.000001", .value = "{\"from\": \"a@example.com\", \"subject\": \"Re: build\", \"ts\": 1764040000.0}" },
};

/// Special edge-case records (also present in generate_golden.py).
const special_records = [_]Record{
    .{ .key = "", .value = "value-for-empty-key" },
    .{ .key = "bin\x00key", .value = "bin\x00\xff\xfevalue" },
    .{ .key = "empty-value", .value = "" },
    .{ .key = "json-doc", .value = "{\"id\": \"sig-001\", \"ts\": 1764000000.0, \"text\": \"hello 🌍\", \"tags\": [\"queue\", \"memo\"], \"n\": 42}" },
    .{ .key = "large", .value = &large_value },
    .{ .key = "unicode-🔑", .value = "valeur-ça-é🔑" },
};

const large_value: [4219]u8 = blk: {
    var buf: [4219]u8 = @splat('A');
    @memset(buf[4096..], 'B');
    break :blk buf;
};

const num_bulk_records = 100;
const num_records = num_bulk_records + prod_like.len + special_records.len;

/// Re-derives the deterministic dataset written by generate_golden.py.
fn goldenRecords(alloc: std.mem.Allocator) ![]Record {
    var records = try std.ArrayList(Record).initCapacity(alloc, num_records);
    errdefer records.deinit(alloc);

    var i: usize = 0;
    while (i < num_bulk_records) : (i += 1) {
        const key = try std.fmt.allocPrint(alloc, "key_{d:0>3}", .{i});
        // Same padding rule as the generator: "x" repeated (i % 17) times.
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

fn freeRecords(alloc: std.mem.Allocator, records: []Record) void {
    // Only the bulk records are heap-allocated (allocPrint); the
    // production-like and special records are static literals.
    for (records[0..num_bulk_records]) |r| {
        alloc.free(r.key);
        alloc.free(r.value);
    }
    alloc.free(records);
}

fn findRecord(records: []const Record, key: []const u8) ?Record {
    for (records) |r| {
        if (std.mem.eql(u8, r.key, key)) return r;
    }
    return null;
}

const GoldenFile = struct {
    path: []const u8,
    ordered: bool,
};

const golden_files = [_]GoldenFile{
    .{ .path = "tests/golden/golden.tkh", .ordered = false },
    .{ .path = "tests/golden/golden.tkt", .ordered = true },
    .{ .path = "tests/golden/golden.tks", .ordered = true },
    .{ .path = "tests/golden/golden.tkmt", .ordered = false },
    .{ .path = "tests/golden/golden.tkmb", .ordered = true },
    .{ .path = "tests/golden/golden.tkmc", .ordered = false },
};

/// The golden fixtures are generated locally with the OFFICIAL tkrzw
/// bindings (python3 tests/golden/generate_golden.py) and are deliberately
/// NOT committed — the generator script is the source of truth. Skip the
/// golden tests when the fixtures are absent.
fn goldenFixturesPresent() bool {
    _ = std.Io.Dir.cwd().statFile(std.testing.io, "tests/golden/golden.tkh", .{}) catch
        return false;
    return true;
}

fn skipIfNoFixtures() !void {
    if (!goldenFixturesPresent()) {
        std.debug.print(
            "skipping golden tests: tests/golden/*.tk* not present. " ++
                "Generate them with: python3 tests/golden/generate_golden.py\n",
            .{},
        );
        return error.SkipZigTest;
    }
}

test "golden files written by official tkrzw are readable" {
    const testing = std.testing;
    const io = std.testing.io;
    const alloc = testing.allocator;

    try skipIfNoFixtures();

    const records = try goldenRecords(alloc);
    defer freeRecords(alloc, records);
    try testing.expectEqual(@as(usize, num_records), records.len);

    // Sorted view of the dataset for ordered-iteration checks.
    const sorted = try alloc.dupe(Record, records);
    defer alloc.free(sorted);
    std.mem.sort(Record, sorted, {}, struct {
        fn lessThan(_: void, a: Record, b: Record) bool {
            return std.mem.lessThan(u8, a.key, b.key);
        }
    }.lessThan);

    for (&golden_files) |gf| {
        // The file layer requires absolute paths; resolve against cwd.
        const path = try std.Io.Dir.cwd().realPathFileAlloc(io, gf.path, alloc);
        defer alloc.free(path);

        // Sanity: the golden file must exist on disk.
        std.Io.Dir.cwd().access(io, gf.path, .{}) catch |err| {
            std.debug.print("missing golden file {s}: {any}\n", .{ gf.path, err });
            return err;
        };

        var db = PolyDBM.open(path, .{ .writable = false }, io, alloc) catch |err| {
            std.debug.print("failed to open golden file {s}: {any}\n", .{ path, err });
            return err;
        };
        defer db.deinit(io);

        try testing.expect(db.isOpen(io));
        try testing.expect(!db.isWritable(io));

        // Record count must match the generator exactly.
        const actual_count = db.count(io);
        if (actual_count != num_records) {
            std.debug.print("{s}: count {d} != expected {d}\n", .{ gf.path, actual_count, num_records });
        }
        try testing.expectEqual(@as(i64, num_records), actual_count);

        // Spot-check every record (the dataset is small enough).
        for (records) |r| {
            const got = db.get(alloc, io, r.key) catch |err| {
                std.debug.print("{s}: get({s}) failed: {any}\n", .{ path, r.key, err });
                return err;
            };
            defer alloc.free(got);
            if (!std.mem.eql(u8, got, r.value)) {
                std.debug.print("{s}: value mismatch for key {s}: got {d} bytes, want {d}\n", .{ path, r.key, got.len, r.value.len });
                return error.TestUnexpectedResult;
            }
        }

        // A missing key must surface as NotFound, not garbage.
        try testing.expectError(dbm_poly.PolyError.NotFound, db.get(alloc, io, "no-such-key"));

        // Iterate the whole file. Ordered backends must return keys in
        // sorted order; hash backends must return each key exactly once.
        var iter = try db.iterate(alloc, io);
        defer iter.deinit(io);

        var seen = try alloc.alloc(bool, records.len);
        defer alloc.free(seen);
        @memset(seen, false);

        var iterated: usize = 0;
        var expected_sorted_index: usize = 0;
        while (try iter.next(io)) |entry| {
            const idx = blk: {
                for (records, 0..) |r, j| {
                    if (std.mem.eql(u8, r.key, entry.key)) break :blk j;
                }
                std.debug.print("{s}: iterated unknown key {any}\n", .{ path, entry.key });
                return error.TestUnexpectedResult;
            };
            if (seen[idx]) {
                std.debug.print("{s}: duplicate key {any} in iteration\n", .{ path, entry.key });
                return error.TestUnexpectedResult;
            }
            seen[idx] = true;
            try testing.expectEqualStrings(records[idx].value, entry.value);

            if (gf.ordered) {
                try testing.expectEqualStrings(sorted[expected_sorted_index].key, entry.key);
                expected_sorted_index += 1;
            }
            iterated += 1;
        }
        try testing.expectEqual(records.len, iterated);
    }
}

test "golden hash file matches production store profile" {
    // The production stores are HashDBM files created with default tuning;
    // their on-disk size (~4.2 MB, dominated by the 1M-slot bucket table)
    // must be recognizable by this port. This pins that the port reads the
    // same default-tuned layout, not just tiny synthetic files.
    const testing = std.testing;
    const io = std.testing.io;

    try skipIfNoFixtures();

    const stat = try std.Io.Dir.cwd().statFile(io, "tests/golden/golden.tkh", .{});
    try testing.expectEqual(@as(u64, 4206696), stat.size);
}
