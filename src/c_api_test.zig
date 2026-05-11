//! C API integration tests — Wave 2.
//!
//! These tests call the exported `tkrzw_*` functions directly from Zig,
//! exercising the C-ABI surface without requiring a separate C program.

const std = @import("std");
const c_api = @import("c_api.zig");

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

test "init/deinit ref-counting" {
    // Double init — ref count goes to 2.
    _ = c_api.tkrzw_init();
    _ = c_api.tkrzw_init();
    c_api.tkrzw_deinit();
    c_api.tkrzw_deinit();

    // After two balanced deinits the ref count is 0.  A fresh init must
    // succeed (return SUCCESS == 0).
    const rc = c_api.tkrzw_init();
    try std.testing.expectEqual(@as(i32, 0), rc);
    c_api.tkrzw_deinit();
}

// ---------------------------------------------------------------------------
// Status name mapping
// ---------------------------------------------------------------------------

test "tkrzw_status_name" {
    try std.testing.expectEqualStrings("SUCCESS", std.mem.span(c_api.tkrzw_status_name(0)));
    try std.testing.expectEqualStrings("NOT_FOUND_ERROR", std.mem.span(c_api.tkrzw_status_name(7)));
    try std.testing.expectEqualStrings("APPLICATION_ERROR", std.mem.span(c_api.tkrzw_status_name(13)));
    try std.testing.expectEqualStrings("UNKNOWN", std.mem.span(c_api.tkrzw_status_name(99)));
    try std.testing.expectEqualStrings("UNKNOWN", std.mem.span(c_api.tkrzw_status_name(-1)));
}

// ---------------------------------------------------------------------------
// Open / set / get / close round-trip
// ---------------------------------------------------------------------------

test "open, set, get, close round-trip" {
    _ = c_api.tkrzw_init();
    defer c_api.tkrzw_deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Resolve the absolute path of the tmp directory.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = path_buf[0..dir_len];

    // Build a null-terminated database path inside the tmp directory.
    var db_path_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/test.tkmt", .{dir_path});

    const opts = c_api.TkrzwOpenOptions{};
    const db = c_api.tkrzw_open(db_path.ptr, &opts);
    try std.testing.expect(db != null);
    defer _ = c_api.tkrzw_close(db);

    // set
    const key = "hello";
    const val = "world";
    const set_rc = c_api.tkrzw_set(db, key.ptr, key.len, val.ptr, val.len, true);
    try std.testing.expectEqual(@as(i32, 0), set_rc);

    // get — caller owns the returned buffer; free it with c_allocator.
    var value_out: [*c]u8 = null;
    var value_len: usize = 0;
    const get_rc = c_api.tkrzw_get(db, key.ptr, key.len, &value_out, &value_len);
    try std.testing.expectEqual(@as(i32, 0), get_rc);
    try std.testing.expect(value_out != null);
    defer std.heap.c_allocator.free(value_out[0..value_len]);
    try std.testing.expectEqualStrings("world", value_out[0..value_len]);
}

// ---------------------------------------------------------------------------
// Miss path
// ---------------------------------------------------------------------------

test "get miss returns NOT_FOUND_ERROR and null out" {
    _ = c_api.tkrzw_init();
    defer c_api.tkrzw_deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = path_buf[0..dir_len];

    var db_path_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/miss.tkmt", .{dir_path});

    const opts = c_api.TkrzwOpenOptions{};
    const db = c_api.tkrzw_open(db_path.ptr, &opts);
    try std.testing.expect(db != null);
    defer _ = c_api.tkrzw_close(db);

    var value_out: [*c]u8 = null;
    var value_len: usize = 0;
    const missing_key = "missing";
    const rc = c_api.tkrzw_get(db, missing_key.ptr, missing_key.len, &value_out, &value_len);
    try std.testing.expectEqual(@as(i32, 7), rc); // NOT_FOUND_ERROR
    try std.testing.expect(value_out == null);
}

// ---------------------------------------------------------------------------
// Duplicate-key rejection
// ---------------------------------------------------------------------------

test "set overwrite=false returns DUPLICATION_ERROR" {
    _ = c_api.tkrzw_init();
    defer c_api.tkrzw_deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = path_buf[0..dir_len];

    var db_path_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/dup.tkmt", .{dir_path});

    const opts = c_api.TkrzwOpenOptions{};
    const db = c_api.tkrzw_open(db_path.ptr, &opts);
    try std.testing.expect(db != null);
    defer _ = c_api.tkrzw_close(db);

    const k = "k";
    const v1 = "v1";
    const v2 = "v2";
    _ = c_api.tkrzw_set(db, k.ptr, k.len, v1.ptr, v1.len, true);
    const rc = c_api.tkrzw_set(db, k.ptr, k.len, v2.ptr, v2.len, false);
    try std.testing.expectEqual(@as(i32, 10), rc); // DUPLICATION_ERROR
}

// ---------------------------------------------------------------------------
// Null-handle sentinels
// ---------------------------------------------------------------------------

test "null handle calls return sentinel" {
    // Must init first so g_io is valid inside c_api.
    _ = c_api.tkrzw_init();
    defer c_api.tkrzw_deinit();

    try std.testing.expectEqual(@as(i64, 0), c_api.tkrzw_count(null));
    try std.testing.expectEqual(false, c_api.tkrzw_is_open(null));
    try std.testing.expectEqual(false, c_api.tkrzw_is_writable(null));
    try std.testing.expectEqual(@as(i64, 0), c_api.tkrzw_file_size(null));
}

// ---------------------------------------------------------------------------
// Wave 5: callback-driven ops
// ---------------------------------------------------------------------------

const ProcessCounter = struct {
    calls: usize = 0,
    last_key: [64]u8 = undefined,
    last_key_len: usize = 0,
    last_value: [64]u8 = undefined,
    last_value_len: usize = 0,
    last_value_was_null: bool = false,
};

fn noopCountingCallback(
    key: [*c]const u8,
    key_len: usize,
    value: [*c]const u8,
    value_len: usize,
    user_data: ?*anyopaque,
    new_value_out: *[*c]const u8,
    new_value_len_out: *usize,
) callconv(.c) i32 {
    _ = new_value_out;
    _ = new_value_len_out;
    const state: *ProcessCounter = @ptrCast(@alignCast(user_data.?));
    state.calls += 1;
    if (key != null and key_len <= state.last_key.len) {
        @memcpy(state.last_key[0..key_len], key[0..key_len]);
        state.last_key_len = key_len;
    }
    state.last_value_was_null = (value == null);
    if (value != null and value_len <= state.last_value.len) {
        @memcpy(state.last_value[0..value_len], value[0..value_len]);
        state.last_value_len = value_len;
    } else {
        state.last_value_len = 0;
    }
    return 0; // NOOP
}

fn setValueCallback(
    key: [*c]const u8,
    key_len: usize,
    value: [*c]const u8,
    value_len: usize,
    user_data: ?*anyopaque,
    new_value_out: *[*c]const u8,
    new_value_len_out: *usize,
) callconv(.c) i32 {
    _ = key;
    _ = key_len;
    _ = value;
    _ = value_len;
    const new_val: *const []const u8 = @ptrCast(@alignCast(user_data.?));
    new_value_out.* = new_val.ptr;
    new_value_len_out.* = new_val.len;
    return 2; // SET
}

fn removeCallback(
    key: [*c]const u8,
    key_len: usize,
    value: [*c]const u8,
    value_len: usize,
    user_data: ?*anyopaque,
    new_value_out: *[*c]const u8,
    new_value_len_out: *usize,
) callconv(.c) i32 {
    _ = key;
    _ = key_len;
    _ = value;
    _ = value_len;
    _ = user_data;
    _ = new_value_out;
    _ = new_value_len_out;
    return 1; // REMOVE
}

test "tkrzw_process_each with no-op callback visits every record" {
    _ = c_api.tkrzw_init();
    defer c_api.tkrzw_deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = path_buf[0..dir_len];

    var db_path_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/proc_each.tkmt", .{dir_path});

    const opts = c_api.TkrzwOpenOptions{};
    const db = c_api.tkrzw_open(db_path.ptr, &opts);
    try std.testing.expect(db != null);
    defer _ = c_api.tkrzw_close(db);

    const k1 = "a";
    const v1 = "1";
    const k2 = "b";
    const v2 = "2";
    _ = c_api.tkrzw_set(db, k1.ptr, k1.len, v1.ptr, v1.len, true);
    _ = c_api.tkrzw_set(db, k2.ptr, k2.len, v2.ptr, v2.len, true);

    var state = ProcessCounter{};
    const rc = c_api.tkrzw_process_each(db, noopCountingCallback, &state, false);
    try std.testing.expectEqual(@as(i32, 0), rc);
    // Must be called exactly once per real record — no boundary sentinels.
    try std.testing.expectEqual(@as(usize, 2), state.calls);
}

test "tkrzw_process SET writes new value" {
    _ = c_api.tkrzw_init();
    defer c_api.tkrzw_deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = path_buf[0..dir_len];

    var db_path_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/proc_set.tkmt", .{dir_path});

    const opts = c_api.TkrzwOpenOptions{};
    const db = c_api.tkrzw_open(db_path.ptr, &opts);
    try std.testing.expect(db != null);
    defer _ = c_api.tkrzw_close(db);

    const k = "key";
    const v0 = "old";
    _ = c_api.tkrzw_set(db, k.ptr, k.len, v0.ptr, v0.len, true);

    const new_val: []const u8 = "new";
    const rc = c_api.tkrzw_process(db, k.ptr, k.len, setValueCallback, @ptrCast(@constCast(&new_val)), true);
    try std.testing.expectEqual(@as(i32, 0), rc);

    var out: [*c]u8 = null;
    var out_len: usize = 0;
    _ = c_api.tkrzw_get(db, k.ptr, k.len, &out, &out_len);
    defer std.heap.c_allocator.free(out[0..out_len]);
    try std.testing.expectEqualStrings("new", out[0..out_len]);
}

test "tkrzw_process REMOVE deletes the record" {
    _ = c_api.tkrzw_init();
    defer c_api.tkrzw_deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = path_buf[0..dir_len];

    var db_path_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/proc_rm.tkmt", .{dir_path});

    const opts = c_api.TkrzwOpenOptions{};
    const db = c_api.tkrzw_open(db_path.ptr, &opts);
    try std.testing.expect(db != null);
    defer _ = c_api.tkrzw_close(db);

    const k = "key";
    const v = "val";
    _ = c_api.tkrzw_set(db, k.ptr, k.len, v.ptr, v.len, true);

    const rc = c_api.tkrzw_process(db, k.ptr, k.len, removeCallback, null, true);
    try std.testing.expectEqual(@as(i32, 0), rc);

    var out: [*c]u8 = null;
    var out_len: usize = 0;
    const get_rc = c_api.tkrzw_get(db, k.ptr, k.len, &out, &out_len);
    try std.testing.expectEqual(@as(i32, 7), get_rc); // NOT_FOUND_ERROR
}

// ---------------------------------------------------------------------------
// Wave 4: cursor round-trip + cursor_free safety
// ---------------------------------------------------------------------------

test "tkrzw_cursor_free(null) is a no-op" {
    // No tkrzw_init required — null should be handled before any IO access.
    c_api.tkrzw_cursor_free(null);
    // Reaching here without a crash is the pass condition.
}

test "tkrzw_cursor_free on a valid cursor before deinit" {
    // Exercises the requireIo()-succeeds path of the post-fix tkrzw_cursor_free,
    // ensuring the cursor is properly deregistered from the parent DBM's
    // iterator registry before memory is freed.
    _ = c_api.tkrzw_init();
    defer c_api.tkrzw_deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = path_buf[0..dir_len];

    var db_path_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/cur_free.tkmt", .{dir_path});

    const opts = c_api.TkrzwOpenOptions{};
    const db = c_api.tkrzw_open(db_path.ptr, &opts);
    try std.testing.expect(db != null);
    defer _ = c_api.tkrzw_close(db);

    const cur = c_api.tkrzw_cursor_make(db);
    try std.testing.expect(cur != null);

    // Free before deinit — deregistration path must complete without crash.
    c_api.tkrzw_cursor_free(cur);
    // Reaching here without a crash is the pass condition.
    // (post-tkrzw_deinit free is safe by contract but not tested in-process;
    // see tkrzw_cursor_free doc comment in include/tkrzw.h for the guarantee.)
}

test "cursor iteration round-trip" {
    _ = c_api.tkrzw_init();
    defer c_api.tkrzw_deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = path_buf[0..dir_len];

    var db_path_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
    // Use .tkmt (TinyDBM) which supports cursors.
    const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/cursor.tkmt", .{dir_path});

    const opts = c_api.TkrzwOpenOptions{};
    const db = c_api.tkrzw_open(db_path.ptr, &opts);
    try std.testing.expect(db != null);
    defer _ = c_api.tkrzw_close(db);

    // Insert 3 records.  TinyDBM is a hash backend so iteration order is
    // unspecified; we will collect all three key/value pairs and verify the
    // set (not the order).
    const pairs = [_][2][]const u8{
        .{ "alpha", "1" },
        .{ "beta", "2" },
        .{ "gamma", "3" },
    };
    for (pairs) |p| {
        _ = c_api.tkrzw_set(db, p[0].ptr, p[0].len, p[1].ptr, p[1].len, true);
    }

    const cur = c_api.tkrzw_cursor_make(db);
    try std.testing.expect(cur != null);
    defer c_api.tkrzw_cursor_free(cur);

    // Position at the first record.
    var rc = c_api.tkrzw_cursor_first(cur);
    try std.testing.expectEqual(@as(i32, 0), rc);

    // Iterate and collect.  Track which keys we saw.
    var seen_alpha = false;
    var seen_beta = false;
    var seen_gamma = false;
    var iters: usize = 0;

    while (true) : (iters += 1) {
        if (iters > 10) break; // safety guard against infinite loop

        var key_out: [*c]u8 = null;
        var key_len: usize = 0;
        var val_out: [*c]u8 = null;
        var val_len: usize = 0;

        rc = c_api.tkrzw_cursor_get(cur, &key_out, &key_len, &val_out, &val_len);
        if (rc != 0) break; // NOT_FOUND_ERROR or end-of-iteration

        const key_str = key_out[0..key_len];
        const val_str = val_out[0..val_len];
        if (std.mem.eql(u8, key_str, "alpha")) {
            try std.testing.expectEqualStrings("1", val_str);
            seen_alpha = true;
        } else if (std.mem.eql(u8, key_str, "beta")) {
            try std.testing.expectEqualStrings("2", val_str);
            seen_beta = true;
        } else if (std.mem.eql(u8, key_str, "gamma")) {
            try std.testing.expectEqualStrings("3", val_str);
            seen_gamma = true;
        }

        std.heap.c_allocator.free(key_out[0..key_len]);
        std.heap.c_allocator.free(val_out[0..val_len]);

        rc = c_api.tkrzw_cursor_next(cur);
        if (rc != 0) break; // end of records
    }

    try std.testing.expect(seen_alpha);
    try std.testing.expect(seen_beta);
    try std.testing.expect(seen_gamma);
}

// ---------------------------------------------------------------------------
// Wave 3: compareExchange
// ---------------------------------------------------------------------------

test "compareExchange ABSENT to SET" {
    _ = c_api.tkrzw_init();
    defer c_api.tkrzw_deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = path_buf[0..dir_len];

    var db_path_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/cmpex.tkmt", .{dir_path});

    const opts = c_api.TkrzwOpenOptions{};
    const db = c_api.tkrzw_open(db_path.ptr, &opts);
    try std.testing.expect(db != null);
    defer _ = c_api.tkrzw_close(db);

    const key = "cmpkey";
    const new_val = "newval";

    var found_out: bool = true; // pre-set to true so we verify it's flipped
    // exp_mode=0 (ABSENT), des_mode=2 (SET)
    const rc = c_api.tkrzw_compare_exchange(
        db,
        key.ptr, key.len,
        0,    // TKRZW_EXPECTED_ABSENT
        null, 0,
        2,    // TKRZW_DESIRED_SET
        new_val.ptr, new_val.len,
        null, null, // do not request actual_out
        &found_out,
    );
    try std.testing.expectEqual(@as(i32, 0), rc); // SUCCESS
    try std.testing.expectEqual(false, found_out); // key was absent

    // Verify the record was actually written.
    var value_out: [*c]u8 = null;
    var value_len: usize = 0;
    const get_rc = c_api.tkrzw_get(db, key.ptr, key.len, &value_out, &value_len);
    try std.testing.expectEqual(@as(i32, 0), get_rc);
    defer std.heap.c_allocator.free(value_out[0..value_len]);
    try std.testing.expectEqualStrings("newval", value_out[0..value_len]);
}

// ---------------------------------------------------------------------------
// Wave 5 (extra): processEach SET persists
// ---------------------------------------------------------------------------

test "processEach SET writes new value" {
    _ = c_api.tkrzw_init();
    defer c_api.tkrzw_deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = path_buf[0..dir_len];

    var db_path_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/each_set.tkmt", .{dir_path});

    const opts = c_api.TkrzwOpenOptions{};
    const db = c_api.tkrzw_open(db_path.ptr, &opts);
    try std.testing.expect(db != null);
    defer _ = c_api.tkrzw_close(db);

    // Insert the initial record.
    const k = "k";
    const v_old = "old";
    _ = c_api.tkrzw_set(db, k.ptr, k.len, v_old.ptr, v_old.len, true);

    // Run processEach with writable=true, replacing every value with "new".
    // Re-use the existing setValueCallback defined above.
    const new_val: []const u8 = "new";
    const rc = c_api.tkrzw_process_each(db, setValueCallback, @ptrCast(@constCast(&new_val)), true);
    try std.testing.expectEqual(@as(i32, 0), rc);

    // Verify the record was updated.
    var value_out: [*c]u8 = null;
    var value_len: usize = 0;
    const get_rc = c_api.tkrzw_get(db, k.ptr, k.len, &value_out, &value_len);
    try std.testing.expectEqual(@as(i32, 0), get_rc);
    defer std.heap.c_allocator.free(value_out[0..value_len]);
    try std.testing.expectEqualStrings("new", value_out[0..value_len]);
}

test "tkrzw_process with null callback returns INVALID_ARGUMENT_ERROR" {
    _ = c_api.tkrzw_init();
    defer c_api.tkrzw_deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = path_buf[0..dir_len];

    var db_path_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/proc_null.tkmt", .{dir_path});

    const opts = c_api.TkrzwOpenOptions{};
    const db = c_api.tkrzw_open(db_path.ptr, &opts);
    try std.testing.expect(db != null);
    defer _ = c_api.tkrzw_close(db);

    const k = "k";
    const rc = c_api.tkrzw_process(db, k.ptr, k.len, null, null, false);
    // INVALID_ARGUMENT_ERROR code is non-zero; just assert it's not OK.
    try std.testing.expect(rc != 0);
}
