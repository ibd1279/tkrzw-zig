// tkrzw-zig smoke test — mirrors the verification scenario from the port plan:
//   1. Set 1000 keys
//   2. Get and verify each
//   3. Remove half (even-indexed keys)
//   4. Iterate the remaining 500 and verify count

const std = @import("std");
const tkzrw = @import("tkrzw_zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    _ = init.io; // smoke test uses in-memory TinyDBM; no open/synchronize/pushLast calls needed

    const std_file = try tkzrw.StdFile.create(allocator);
    var db = try tkzrw.TinyDBM.init(std_file.asFile(), 0, allocator);
    defer db.deinit();

    const N: usize = 1000;
    var key_buf: [32]u8 = undefined;
    var val_buf: [32]u8 = undefined;

    // --- Phase 1: set 1000 keys ---
    for (0..N) |i| {
        const k = try std.fmt.bufPrint(&key_buf, "key{d}", .{i});
        const v = try std.fmt.bufPrint(&val_buf, "val{d}", .{i});
        const st = db.set(k, v, true, null);
        if (!st.isOk()) {
            std.debug.print("FAIL set key{d}: {s}\n", .{ i, @tagName(st.code) });
            std.process.exit(1);
        }
    }
    std.debug.print("set {d} keys, count={d}\n", .{ N, db.countSimple() });

    // --- Phase 2: get and verify each ---
    var mismatches: usize = 0;
    for (0..N) |i| {
        const k = try std.fmt.bufPrint(&key_buf, "key{d}", .{i});
        const expected = try std.fmt.bufPrint(&val_buf, "val{d}", .{i});
        var value_list: std.ArrayList(u8) = .empty;
        defer value_list.deinit(allocator);
        const st = db.get(k, &value_list);
        if (!st.isOk() or !std.mem.eql(u8, value_list.items, expected)) {
            mismatches += 1;
        }
    }
    if (mismatches > 0) {
        std.debug.print("FAIL: {d} get mismatches\n", .{mismatches});
        std.process.exit(1);
    }
    std.debug.print("verified all {d} keys\n", .{N});

    // --- Phase 3: remove even-indexed keys (500 removals) ---
    for (0..N / 2) |i| {
        const k = try std.fmt.bufPrint(&key_buf, "key{d}", .{i * 2});
        _ = db.remove(k);
    }
    std.debug.print("removed {d} keys, count={d}\n", .{ N / 2, db.countSimple() });

    // --- Phase 4: iterate remaining records ---
    var iter = try db.makeCursor();
    defer iter.deinit();
    _ = iter.first();

    var iterated: usize = 0;
    var iter_key: std.ArrayList(u8) = .empty;
    defer iter_key.deinit(allocator);
    while (true) {
        const get_st = iter.get(&iter_key, null);
        if (get_st.code == .NOT_FOUND_ERROR) break;
        if (!get_st.isOk()) {
            std.debug.print("FAIL: iterator get returned {s}\n", .{@tagName(get_st.code)});
            std.process.exit(1);
        }
        iterated += 1;
        _ = iter.next();
    }

    if (iterated != N / 2) {
        std.debug.print("FAIL: iterated {d}, expected {d}\n", .{ iterated, N / 2 });
        std.process.exit(1);
    }
    std.debug.print("iterated {d} remaining keys\n", .{iterated});
    std.debug.print("all smoke tests passed\n", .{});
}
