//! Exact KNN vector search test harness:
//! - 6-backend x 3-metric x k-variant oracle equivalence matrix
//! - File-backed close/reopen durability
//! - Mixed corpus skip+count and per-backend strict error codes
//! - Exact-match lookup (findByVector) across all 6 backends
//! - Backend edge cases: shrinking overwrites, batch ordering & tombstones,
//!   concurrent scans/writers, legacy 8db376c HashDBM files, TreeDBM backing
//!   read failures, and truncated/overflowing TreeDBM page payloads
//! - Numerical precision: dot cancellation and near-parallel cosine ranking
//! - 10k x 64-dim scale smoke test and README example verification

const std = @import("std");
const tkrzw = @import("tkrzw_zig");
const util = @import("knn_test_util.zig");

fn expectScoreMatch(expected: f64, actual: f64) !void {
    const testing = std.testing;
    try testing.expectEqual(@as(u64, @bitCast(expected)), @as(u64, @bitCast(actual)));
}

test "KNN backend matrix: 6 backends x 3 metrics x {k=1, k=5, k=N} matches scalar oracle" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;

    const dim: usize = 16;
    const dataset = try util.makeAdversarialDataset(alloc, 42, 30, dim);
    defer util.freeDataset(alloc, dataset);

    var q_prng = std.Random.DefaultPrng.init(7);
    const q_rng = q_prng.random();
    var query: [dim]f32 = undefined;
    for (&query) |*x| x.* = q_rng.float(f32) * 2.0 - 1.0;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, io, ".", alloc);
    defer alloc.free(tmp_path);

    const k_values = [_]usize{ 1, 5, dataset.len };

    for (util.all_metrics) |metric| {
        for (k_values) |k| {
            const expected = try util.oracleRank(alloc, dataset, &query, metric, k);
            defer alloc.free(expected);

            for (util.all_backends) |backend| {
                const name = try std.fmt.allocPrint(alloc, "mat_{s}_{s}_{d}", .{
                    @tagName(backend),
                    @tagName(metric),
                    k,
                });
                defer alloc.free(name);

                var db = try util.openBackend(backend, tmp_path, name, true, io, alloc);
                defer db.deinit(io);
                try util.loadInto(&db, io, alloc, dataset);

                var res = try tkrzw.searchSimilar(&db, io, alloc, &query, k, metric, .{});
                defer res.deinit(alloc);

                try testing.expectEqual(dataset.len, res.scanned);
                try testing.expectEqual(@as(usize, 0), res.invalid_records);
                try testing.expectEqual(expected.len, res.hits.len);

                for (expected, res.hits) |exp_hit, got_hit| {
                    try testing.expectEqualStrings(exp_hit.key, got_hit.key);
                    try expectScoreMatch(exp_hit.score, got_hit.score);
                }
            }
        }
    }
}

test "KNN file-backed durability: write, close, reopen read-only, search & exact lookup" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;

    const dim: usize = 12;
    const dataset = try util.makeAdversarialDataset(alloc, 1, 20, dim);
    defer util.freeDataset(alloc, dataset);

    var query: [dim]f32 = undefined;
    @memcpy(&query, dataset[0].vector);

    const expected = try util.oracleRank(alloc, dataset, &query, .cosine, 5);
    defer alloc.free(expected);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, io, ".", alloc);
    defer alloc.free(tmp_path);

    for (util.file_backends) |backend| {
        const name = try std.fmt.allocPrint(alloc, "persist_{s}", .{@tagName(backend)});
        defer alloc.free(name);

        {
            var db = try util.openBackend(backend, tmp_path, name, true, io, alloc);
            try util.loadInto(&db, io, alloc, dataset);
            try testing.expectEqual(tkrzw.Code.SUCCESS, db.close(io).code);
            db.deinit(io);
        }

        {
            var db = try util.openBackend(backend, tmp_path, name, false, io, alloc);
            defer db.deinit(io);

            var res = try tkrzw.searchSimilar(&db, io, alloc, &query, 5, .cosine, .{});
            defer res.deinit(alloc);

            try testing.expectEqual(dataset.len, res.scanned);
            try testing.expectEqual(expected.len, res.hits.len);
            for (expected, res.hits) |exp_hit, got_hit| {
                try testing.expectEqualStrings(exp_hit.key, got_hit.key);
                try expectScoreMatch(exp_hit.score, got_hit.score);
            }

            var exact = try tkrzw.findByVector(&db, io, alloc, dataset[0].vector);
            defer exact.deinit(alloc);
            try testing.expect(exact.keys.len >= 1);
            var found_key = false;
            for (exact.keys) |k| {
                if (std.mem.eql(u8, k, dataset[0].key)) found_key = true;
            }
            try testing.expect(found_key);
        }
    }
}

test "KNN mixed corpus: skip+count default and separately pinned strict error codes per backend" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;

    const dim: usize = 8;
    const dataset = try util.makeDataset(alloc, 7, 15, dim);
    defer util.freeDataset(alloc, dataset);

    const query = dataset[3].vector;
    const expected = try util.oracleRank(alloc, dataset, query, .l2, 4);
    defer alloc.free(expected);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, io, ".", alloc);
    defer alloc.free(tmp_path);

    for (util.all_backends) |backend| {
        // 1. Mixed corpus in default (skip+count) mode.
        {
            const name = try std.fmt.allocPrint(alloc, "mixed_{s}", .{@tagName(backend)});
            defer alloc.free(name);
            var db = try util.openBackend(backend, tmp_path, name, true, io, alloc);
            defer db.deinit(io);
            const bad_count = try util.loadMixed(&db, io, alloc, dataset, dim);

            var res = try tkrzw.searchSimilar(&db, io, alloc, query, 4, .l2, .{});
            defer res.deinit(alloc);
            try testing.expectEqual(dataset.len + bad_count, res.scanned);
            try testing.expectEqual(bad_count, res.invalid_records);
            try testing.expectEqual(expected.len, res.hits.len);
            for (expected, res.hits) |exp_hit, got_hit| {
                try testing.expectEqualStrings(exp_hit.key, got_hit.key);
                try expectScoreMatch(exp_hit.score, got_hit.score);
            }
        }

        // 2. Strict mode with ONLY malformed records -> must return BrokenData.
        {
            const name = try std.fmt.allocPrint(alloc, "strict_malformed_{s}", .{@tagName(backend)});
            defer alloc.free(name);
            var db = try util.openBackend(backend, tmp_path, name, true, io, alloc);
            defer db.deinit(io);
            for (dataset) |rec| {
                const bytes = try tkrzw.encodeF32(alloc, rec.vector);
                defer alloc.free(bytes);
                try testing.expectEqual(tkrzw.Code.SUCCESS, db.set(io, rec.key, bytes, true).code);
            }
            try testing.expectEqual(tkrzw.Code.SUCCESS, db.set(io, "bad_len", "not a vector!", true).code);
            try testing.expectEqual(tkrzw.Code.SUCCESS, db.synchronize(io, false).code);

            try testing.expectError(
                tkrzw.dbm_poly.PolyError.BrokenData,
                tkrzw.searchSimilar(&db, io, alloc, query, 4, .l2, .{ .strict = true }),
            );
        }

        // 3. Strict mode with ONLY NaN record -> must return BrokenData.
        {
            const name = try std.fmt.allocPrint(alloc, "strict_nan_{s}", .{@tagName(backend)});
            defer alloc.free(name);
            var db = try util.openBackend(backend, tmp_path, name, true, io, alloc);
            defer db.deinit(io);
            const good = try tkrzw.encodeF32(alloc, dataset[0].vector);
            defer alloc.free(good);
            try testing.expectEqual(tkrzw.Code.SUCCESS, db.set(io, "good", good, true).code);

            var nan_raw: [dim * 4]u8 = @splat(0);
            std.mem.writeInt(u32, nan_raw[0..4], @bitCast(std.math.nan(f32)), .little);
            try testing.expectEqual(tkrzw.Code.SUCCESS, db.set(io, "bad_nan", &nan_raw, true).code);
            try testing.expectEqual(tkrzw.Code.SUCCESS, db.synchronize(io, false).code);

            try testing.expectError(
                tkrzw.dbm_poly.PolyError.BrokenData,
                tkrzw.searchSimilar(&db, io, alloc, query, 4, .l2, .{ .strict = true }),
            );
        }

        // 4. Strict mode with ONLY dimension-mismatched valid vector -> must return InvalidArgument.
        {
            const name = try std.fmt.allocPrint(alloc, "strict_dim_{s}", .{@tagName(backend)});
            defer alloc.free(name);
            var db = try util.openBackend(backend, tmp_path, name, true, io, alloc);
            defer db.deinit(io);
            for (dataset) |rec| {
                const bytes = try tkrzw.encodeF32(alloc, rec.vector);
                defer alloc.free(bytes);
                try testing.expectEqual(tkrzw.Code.SUCCESS, db.set(io, rec.key, bytes, true).code);
            }
            const wrong = try tkrzw.encodeF32(alloc, &[_]f32{ 1.0, 2.0, 3.0 });
            defer alloc.free(wrong);
            try testing.expectEqual(tkrzw.Code.SUCCESS, db.set(io, "wrong_dim", wrong, true).code);
            try testing.expectEqual(tkrzw.Code.SUCCESS, db.synchronize(io, false).code);

            try testing.expectError(
                tkrzw.dbm_poly.PolyError.InvalidArgument,
                tkrzw.searchSimilar(&db, io, alloc, query, 4, .l2, .{ .strict = true }),
            );
        }
    }
}

test "findByVector across all 6 backends: unique, duplicate, and absent" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;

    const dim: usize = 6;
    const dataset = try util.makeAdversarialDataset(alloc, 42, 10, dim);
    defer util.freeDataset(alloc, dataset);

    var tie_vec: ?[]const f32 = null;
    var axis_vec: ?[]const f32 = null;
    for (dataset) |rec| {
        if (std.mem.eql(u8, rec.key, "tie_a")) tie_vec = rec.vector;
        if (std.mem.eql(u8, rec.key, "axis_0")) axis_vec = rec.vector;
    }

    var absent_vec: [dim]f32 = @splat(123.456);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, io, ".", alloc);
    defer alloc.free(tmp_path);

    for (util.all_backends) |backend| {
        const name = try std.fmt.allocPrint(alloc, "find_{s}", .{@tagName(backend)});
        defer alloc.free(name);

        var db = try util.openBackend(backend, tmp_path, name, true, io, alloc);
        defer db.deinit(io);
        try util.loadInto(&db, io, alloc, dataset);

        {
            var r = try tkrzw.findByVector(&db, io, alloc, axis_vec.?);
            defer r.deinit(alloc);
            try testing.expectEqual(@as(usize, 1), r.keys.len);
            try testing.expectEqualStrings("axis_0", r.keys[0]);
        }

        {
            var r = try tkrzw.findByVector(&db, io, alloc, tie_vec.?);
            defer r.deinit(alloc);
            try testing.expectEqual(@as(usize, 2), r.keys.len);
            try testing.expectEqualStrings("tie_a", r.keys[0]);
            try testing.expectEqualStrings("tie_b", r.keys[1]);
        }

        {
            var r = try tkrzw.findByVector(&db, io, alloc, &absent_vec);
            defer r.deinit(alloc);
            try testing.expectEqual(@as(usize, 0), r.keys.len);
            try testing.expectEqual(dataset.len, r.scanned);
        }
    }
}

// ---------------------------------------------------------------------------
// Backend edge cases, concurrency, corruption handling, and numerical precision
// ---------------------------------------------------------------------------

test "HashDBM shrinking overwrite preserves KNN and exact lookup" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, io, ".", alloc);
    defer alloc.free(tmp_path);

    const v_wide = try tkrzw.encodeF32(alloc, &[_]f32{ 1.0, 2.0 });
    defer alloc.free(v_wide);
    const v_short = try tkrzw.encodeF32(alloc, &[_]f32{3.0});
    defer alloc.free(v_short);

    {
        var db = try util.openBackend(.hash, tmp_path, "shrink", true, io, alloc);
        try testing.expectEqual(tkrzw.Code.SUCCESS, db.set(io, "k", v_wide, true).code);
        try testing.expectEqual(tkrzw.Code.SUCCESS, db.set(io, "k", v_short, true).code);

        var knn = try tkrzw.searchSimilar(&db, io, alloc, &[_]f32{1.0}, 5, .dot, .{ .strict = true });
        defer knn.deinit(alloc);
        try testing.expectEqual(@as(usize, 1), knn.scanned);
        try testing.expectEqual(@as(usize, 0), knn.invalid_records);
        try testing.expectEqual(@as(usize, 1), knn.hits.len);
        try testing.expectEqualStrings("k", knn.hits[0].key);
        try testing.expectEqual(@as(f64, 3.0), knn.hits[0].score);

        var exact = try tkrzw.findByVector(&db, io, alloc, &[_]f32{3.0});
        defer exact.deinit(alloc);
        try testing.expectEqual(@as(usize, 1), exact.keys.len);
        try testing.expectEqualStrings("k", exact.keys[0]);

        try testing.expectEqual(tkrzw.Code.SUCCESS, db.close(io).code);
        db.deinit(io);
    }

    // Reopen read-only and verify durability of the shrunk record.
    {
        var db = try util.openBackend(.hash, tmp_path, "shrink", false, io, alloc);
        defer db.deinit(io);

        var knn = try tkrzw.searchSimilar(&db, io, alloc, &[_]f32{1.0}, 5, .dot, .{ .strict = true });
        defer knn.deinit(alloc);
        try testing.expectEqual(@as(usize, 1), knn.hits.len);
        try testing.expectEqual(@as(f64, 3.0), knn.hits[0].score);

        var exact = try tkrzw.findByVector(&db, io, alloc, &[_]f32{3.0});
        defer exact.deinit(alloc);
        try testing.expectEqual(@as(usize, 1), exact.keys.len);
        try testing.expectEqualStrings("k", exact.keys[0]);
    }
}

test "SkipDBM preserves write order for overwrites and tombstones within and across batches" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, io, ".", alloc);
    defer alloc.free(tmp_path);

    const b1 = try tkrzw.encodeF32(alloc, &[_]f32{1.0});
    defer alloc.free(b1);
    const b2 = try tkrzw.encodeF32(alloc, &[_]f32{2.0});
    defer alloc.free(b2);
    const b3 = try tkrzw.encodeF32(alloc, &[_]f32{3.0});
    defer alloc.free(b3);
    const b4 = try tkrzw.encodeF32(alloc, &[_]f32{4.0});
    defer alloc.free(b4);
    const b5 = try tkrzw.encodeF32(alloc, &[_]f32{5.0});
    defer alloc.free(b5);

    // 1. Within-batch overwrites, tombstones, and revive after tombstone.
    {
        var db = try util.openBackend(.skip, tmp_path, "skip_order", true, io, alloc);
        defer db.deinit(io);

        // Multiple overwrites on the same key in one batch must keep the last write.
        try testing.expectEqual(tkrzw.Code.SUCCESS, db.set(io, "k_over", b1, true).code);
        try testing.expectEqual(tkrzw.Code.SUCCESS, db.set(io, "k_over", b2, true).code);
        try testing.expectEqual(tkrzw.Code.SUCCESS, db.set(io, "k_over", b3, true).code);

        // Within-batch write then remove -> tombstone wins.
        try testing.expectEqual(tkrzw.Code.SUCCESS, db.set(io, "k_del", b1, true).code);
        try testing.expectEqual(tkrzw.Code.SUCCESS, db.remove(io, "k_del").code);

        // Within-batch write, remove, then re-write -> latest write wins.
        try testing.expectEqual(tkrzw.Code.SUCCESS, db.set(io, "k_revive", b1, true).code);
        try testing.expectEqual(tkrzw.Code.SUCCESS, db.remove(io, "k_revive").code);
        try testing.expectEqual(tkrzw.Code.SUCCESS, db.set(io, "k_revive", b4, true).code);

        try testing.expectEqual(tkrzw.Code.SUCCESS, db.synchronize(io, false).code);

        {
            var knn = try tkrzw.searchSimilar(&db, io, alloc, &[_]f32{1.0}, 10, .dot, .{ .strict = true });
            defer knn.deinit(alloc);
            try testing.expectEqual(@as(usize, 2), knn.hits.len);
            try testing.expectEqualStrings("k_revive", knn.hits[0].key);
            try testing.expectEqual(@as(f64, 4.0), knn.hits[0].score);
            try testing.expectEqualStrings("k_over", knn.hits[1].key);
            try testing.expectEqual(@as(f64, 3.0), knn.hits[1].score);
        }
        {
            var e3 = try tkrzw.findByVector(&db, io, alloc, &[_]f32{3.0});
            defer e3.deinit(alloc);
            try testing.expectEqual(@as(usize, 1), e3.keys.len);
            try testing.expectEqualStrings("k_over", e3.keys[0]);
        }
        {
            var e2 = try tkrzw.findByVector(&db, io, alloc, &[_]f32{2.0});
            defer e2.deinit(alloc);
            try testing.expectEqual(@as(usize, 0), e2.keys.len);
        }

        // 2. Across-batch overwrites and tombstones.
        try testing.expectEqual(tkrzw.Code.SUCCESS, db.set(io, "k_over", b2, true).code);
        try testing.expectEqual(tkrzw.Code.SUCCESS, db.set(io, "k_over", b5, true).code);
        try testing.expectEqual(tkrzw.Code.SUCCESS, db.remove(io, "k_revive").code);
        try testing.expectEqual(tkrzw.Code.SUCCESS, db.synchronize(io, false).code);

        {
            var knn = try tkrzw.searchSimilar(&db, io, alloc, &[_]f32{1.0}, 10, .dot, .{ .strict = true });
            defer knn.deinit(alloc);
            try testing.expectEqual(@as(usize, 1), knn.hits.len);
            try testing.expectEqualStrings("k_over", knn.hits[0].key);
            try testing.expectEqual(@as(f64, 5.0), knn.hits[0].score);
        }

        // 3. Re-add a key deleted in an earlier batch.
        try testing.expectEqual(tkrzw.Code.SUCCESS, db.set(io, "k_revive", b2, true).code);
        try testing.expectEqual(tkrzw.Code.SUCCESS, db.synchronize(io, false).code);
        {
            var e2 = try tkrzw.findByVector(&db, io, alloc, &[_]f32{2.0});
            defer e2.deinit(alloc);
            try testing.expectEqual(@as(usize, 1), e2.keys.len);
            try testing.expectEqualStrings("k_revive", e2.keys[0]);
        }
    }

    // 4. Multi-flush within a single batch (tiny sort_mem_size forces multiple
    //    temp sorter files, verifying cross-flush ordering and stable slot pointers).
    {
        const skip_path = try std.fmt.allocPrint(alloc, "{s}/skip_multiflush.tks", .{tmp_path});
        defer alloc.free(skip_path);
        const std_file = try tkrzw.StdFile.create(alloc);
        var sdb = try tkrzw.SkipDBM.init(std_file.asFile(), alloc, .{
            .sort_mem_size = 64,
        });
        defer sdb.deinit(io);
        try testing.expectEqual(tkrzw.Code.SUCCESS, sdb.open(io, skip_path, true, .{}).code);

        // Write 12 overwrites to the same key (spills across multiple temp files).
        for (1..13) |step| {
            const val = try tkrzw.encodeF32(alloc, &[_]f32{@floatFromInt(step)});
            defer alloc.free(val);
            try testing.expectEqual(tkrzw.Code.SUCCESS, sdb.set(io, "same_key", val, true, null).code);
        }
        try testing.expectEqual(tkrzw.Code.SUCCESS, sdb.synchronize(io, false).code);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        try testing.expectEqual(tkrzw.Code.SUCCESS, sdb.get(io, "same_key", &out).code);
        const decoded = try tkrzw.decodeF32(alloc, out.items);
        defer alloc.free(decoded);
        try testing.expectEqual(@as(usize, 1), decoded.len);
        try testing.expectEqual(@as(f32, 12.0), decoded[0]);
        _ = sdb.close(io);
    }
}

test "TinyDBM read-only KNN and exact lookup are race-free with concurrent writers" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, io, ".", alloc);
    defer alloc.free(tmp_path);

    var db = try util.openBackend(.tiny, tmp_path, "race", true, io, alloc);
    defer db.deinit(io);

    const v_a = try tkrzw.encodeF32(alloc, &[_]f32{ 1.0, 0.0, 0.0, 0.0 });
    defer alloc.free(v_a);
    const v_b = try tkrzw.encodeF32(alloc, &[_]f32{ 0.0, 1.0, 0.0, 0.0, 0.5, 0.5, 0.5, 0.5 });
    defer alloc.free(v_b);

    // Seed keys across buckets.
    var kbuf: [16]u8 = undefined;
    for (0..32) |i| {
        const k = std.fmt.bufPrint(&kbuf, "k_{d:0>3}", .{i}) catch unreachable;
        try testing.expectEqual(tkrzw.Code.SUCCESS, db.set(io, k, v_a, true).code);
    }

    const Shared = struct {
        db: *tkrzw.PolyDBM,
        io: std.Io,
        v_a: []const u8,
        v_b: []const u8,
        stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    };
    var shared = Shared{
        .db = &db,
        .io = io,
        .v_a = v_a,
        .v_b = v_b,
    };

    const writer = try std.Thread.spawn(.{}, struct {
        fn run(ctx: *Shared) void {
            var buf: [16]u8 = undefined;
            var iter: usize = 0;
            while (!ctx.stop.load(.acquire)) : (iter += 1) {
                const idx = iter % 32;
                const k = std.fmt.bufPrint(&buf, "k_{d:0>3}", .{idx}) catch unreachable;
                // Alternate varying-size overwrites (forces blob realloc/free) and removes.
                if (iter % 3 == 0) {
                    _ = ctx.db.remove(ctx.io, k);
                } else if (iter % 3 == 1) {
                    _ = ctx.db.set(ctx.io, k, ctx.v_b, true);
                } else {
                    _ = ctx.db.set(ctx.io, k, ctx.v_a, true);
                }
            }
        }
    }.run, .{&shared});
    defer {
        shared.stop.store(true, .release);
        writer.join();
    }

    const query = [_]f32{ 1.0, 0.0, 0.0, 0.0 };
    for (0..150) |_| {
        var knn = try tkrzw.searchSimilar(&db, io, alloc, &query, 5, .cosine, .{});
        knn.deinit(alloc);

        var exact = try tkrzw.findByVector(&db, io, alloc, &query);
        exact.deinit(alloc);
    }
}

test "SIMD dot cancellation top-1 ranking and cosine near-parallel self-similarity" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, io, ".", alloc);
    defer alloc.free(tmp_path);

    // 1. Top-1 cancellation regression.
    {
        var db = try util.openBackend(.tiny, tmp_path, "cancel", true, io, alloc);
        defer db.deinit(io);

        const big: f32 = std.math.ldexp(@as(f32, 1.0), 60);
        const query = [_]f32{ 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0 };
        const cancel_bytes = try tkrzw.encodeF32(alloc, &[_]f32{ big, -big, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0 });
        defer alloc.free(cancel_bytes);
        const half_bytes = try tkrzw.encodeF32(alloc, &[_]f32{ 0.5, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 });
        defer alloc.free(half_bytes);

        try testing.expectEqual(tkrzw.Code.SUCCESS, db.set(io, "cancel", cancel_bytes, true).code);
        try testing.expectEqual(tkrzw.Code.SUCCESS, db.set(io, "half", half_bytes, true).code);

        var res = try tkrzw.searchSimilar(&db, io, alloc, &query, 1, .dot, .{ .strict = true });
        defer res.deinit(alloc);
        try testing.expectEqual(@as(usize, 1), res.hits.len);
        try testing.expectEqualStrings("cancel", res.hits[0].key);
        try testing.expectEqual(@as(f64, 1.0), res.hits[0].score);
    }

    // 2. Cosine near-parallel regression:
    //    - [1, 1] must never score worse against itself than against [3, 3],
    //      and both must strictly beat a 1-ULP perturbation.
    //    - [1, 0] vs [1, 2^-27] for query [1, 0]: exact match must beat near
    //      match top-1 even when the near match's key sorts first.
    {
        var db = try util.openBackend(.tiny, tmp_path, "parallel", true, io, alloc);
        defer db.deinit(io);

        const b11 = try tkrzw.encodeF32(alloc, &[_]f32{ 1.0, 1.0 });
        defer alloc.free(b11);
        const b33 = try tkrzw.encodeF32(alloc, &[_]f32{ 3.0, 3.0 });
        defer alloc.free(b33);
        const bpert = try tkrzw.encodeF32(alloc, &[_]f32{ 1.0, std.math.nextAfter(f32, 1.0, 2.0) });
        defer alloc.free(bpert);

        try testing.expectEqual(tkrzw.Code.SUCCESS, db.set(io, "z_self", b11, true).code);
        try testing.expectEqual(tkrzw.Code.SUCCESS, db.set(io, "a_parallel", b33, true).code);
        try testing.expectEqual(tkrzw.Code.SUCCESS, db.set(io, "m_perturbed", bpert, true).code);

        var res = try tkrzw.searchSimilar(&db, io, alloc, &[_]f32{ 1.0, 1.0 }, 3, .cosine, .{ .strict = true });
        defer res.deinit(alloc);
        try testing.expectEqual(@as(usize, 3), res.hits.len);
        // z_self scores exact 0.0 and is never worse than a_parallel; both beat m_perturbed.
        var self_score: f64 = -1.0;
        var parallel_score: f64 = -1.0;
        for (res.hits) |h| {
            if (std.mem.eql(u8, h.key, "z_self")) self_score = h.score;
            if (std.mem.eql(u8, h.key, "a_parallel")) parallel_score = h.score;
        }
        try testing.expectEqual(@as(f64, 0.0), self_score);
        try testing.expect(self_score >= parallel_score);
        try testing.expectEqualStrings("m_perturbed", res.hits[2].key);
        try testing.expect(res.hits[2].score < parallel_score);
    }
    {
        var db = try util.openBackend(.tiny, tmp_path, "near_exact_top1", true, io, alloc);
        defer db.deinit(io);

        const b_exact = try tkrzw.encodeF32(alloc, &[_]f32{ 1.0, 0.0 });
        defer alloc.free(b_exact);
        const b_near = try tkrzw.encodeF32(alloc, &[_]f32{ 1.0, std.math.ldexp(@as(f32, 1.0), -27) });
        defer alloc.free(b_near);

        // Near match key sorts BEFORE exact match key; exact match must still win top-1.
        try testing.expectEqual(tkrzw.Code.SUCCESS, db.set(io, "a_near", b_near, true).code);
        try testing.expectEqual(tkrzw.Code.SUCCESS, db.set(io, "z_exact", b_exact, true).code);

        var top1 = try tkrzw.searchSimilar(&db, io, alloc, &[_]f32{ 1.0, 0.0 }, 1, .cosine, .{ .strict = true });
        defer top1.deinit(alloc);
        try testing.expectEqual(@as(usize, 1), top1.hits.len);
        try testing.expectEqualStrings("z_exact", top1.hits[0].key);
        try testing.expectEqual(@as(f64, 0.0), top1.hits[0].score);

        var both = try tkrzw.searchSimilar(&db, io, alloc, &[_]f32{ 1.0, 0.0 }, 2, .cosine, .{ .strict = true });
        defer both.deinit(alloc);
        try testing.expectEqualStrings("z_exact", both.hits[0].key);
        try testing.expectEqualStrings("a_near", both.hits[1].key);
        try testing.expect(both.hits[1].score < 0.0);
    }
}

/// Fault-injecting File wrapper around StdFile that fails `read` after a
/// configurable number of successful read calls.
const FaultReadFile = struct {
    inner: *tkrzw.StdFile,
    fail_reads: bool = false,
    reads_before_fail: usize = 0,
    reads_seen: usize = 0,

    fn asFile(self: *FaultReadFile) tkrzw.File {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable = tkrzw.File.VTable{
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

    fn selfFrom(ctx: *anyopaque) *FaultReadFile {
        return @ptrCast(@alignCast(ctx));
    }

    fn vtOpen(ctx: *anyopaque, io: std.Io, path: []const u8, writable: bool, options: tkrzw.OpenOptions) tkrzw.Status {
        return selfFrom(ctx).inner.asFile().open(io, path, writable, options);
    }
    fn vtClose(ctx: *anyopaque, io: std.Io) tkrzw.Status {
        return selfFrom(ctx).inner.asFile().close(io);
    }
    fn vtRead(ctx: *anyopaque, io: std.Io, off: i64, buf: []u8) tkrzw.Status {
        const self = selfFrom(ctx);
        if (self.fail_reads) {
            if (self.reads_seen >= self.reads_before_fail) {
                return tkrzw.Status.initMsg(.SYSTEM_ERROR, "injected read failure");
            }
            self.reads_seen += 1;
        }
        return self.inner.asFile().read(io, off, buf);
    }
    fn vtWrite(ctx: *anyopaque, io: std.Io, off: i64, data: []const u8) tkrzw.Status {
        return selfFrom(ctx).inner.asFile().write(io, off, data);
    }
    fn vtAppend(ctx: *anyopaque, io: std.Io, data: []const u8, off: ?*i64) tkrzw.Status {
        return selfFrom(ctx).inner.asFile().append(io, data, off);
    }
    fn vtTruncate(ctx: *anyopaque, io: std.Io, size: i64) tkrzw.Status {
        return selfFrom(ctx).inner.asFile().truncate(io, size);
    }
    fn vtSynchronize(ctx: *anyopaque, io: std.Io, hard: bool) tkrzw.Status {
        return selfFrom(ctx).inner.asFile().synchronize(io, hard);
    }
    fn vtGetSize(ctx: *anyopaque, out: *i64) tkrzw.Status {
        return selfFrom(ctx).inner.asFile().getSize(out);
    }
    fn vtMakeFile(ctx: *anyopaque, allocator: std.mem.Allocator) std.mem.Allocator.Error!*tkrzw.File {
        return selfFrom(ctx).inner.asFile().makeFile(allocator);
    }
    fn vtDeinit(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const self = selfFrom(ctx);
        self.inner.asFile().deinit(allocator);
        allocator.destroy(self);
    }
};

test "TreeDBM multi-leaf scan propagates injected backing read failures" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, io, ".", alloc);
    defer alloc.free(tmp_path);
    const tree_path = try std.fmt.allocPrint(alloc, "{s}/multileaf.tkt", .{tmp_path});
    defer alloc.free(tree_path);

    // 1. Build a multi-leaf TreeDBM (small max_page_size forces multiple leaves).
    const num_records: usize = 30;
    {
        const sf = try tkrzw.StdFile.create(alloc);
        var tree = try tkrzw.TreeDBM.init(sf.asFile(), alloc);
        defer tree.deinit(io);
        try testing.expectEqual(tkrzw.Code.SUCCESS, tree.openAdvanced(io, tree_path, true, .{}, .{
            .max_page_size = 64,
        }).code);

        var kbuf: [16]u8 = undefined;
        for (0..num_records) |i| {
            const k = std.fmt.bufPrint(&kbuf, "leaf_rec_{d:0>4}", .{i}) catch unreachable;
            const v = try tkrzw.encodeF32(alloc, &[_]f32{ @floatFromInt(i), 1.0, 2.0, 3.0 });
            defer alloc.free(v);
            try testing.expectEqual(tkrzw.Code.SUCCESS, tree.set(io, k, v, true, null).code);
        }
        try testing.expectEqual(tkrzw.Code.SUCCESS, tree.close(io).code);
    }

    // 2. Reopen read-only with a FaultReadFile that succeeds on open & first leaf,
    //    then fails subsequent backing reads during the multi-leaf scan.
    {
        const fault = try alloc.create(FaultReadFile);
        fault.* = .{
            .inner = try tkrzw.StdFile.create(alloc),
            .fail_reads = false,
            .reads_before_fail = 1,
        };
        var tree = try tkrzw.TreeDBM.init(fault.asFile(), alloc);
        defer tree.deinit(io);
        try testing.expectEqual(tkrzw.Code.SUCCESS, tree.open(io, tree_path, false, .{}).code);

        // Enable read failure after 1 read (so first leaf loads, second leaf fails).
        fault.reads_seen = 0;
        fault.fail_reads = true;

        const CounterProc = struct {
            visited: usize = 0,
            pub fn processFull(self: *@This(), _: []const u8, _: []const u8) tkrzw.RecordAction {
                self.visited += 1;
                return .noop;
            }
            pub fn processEmpty(_: *@This(), _: []const u8) tkrzw.RecordAction {
                return .noop;
            }
        };
        var proc = CounterProc{};
        const st = tree.processEach(io, &proc, false);
        try testing.expect(!st.isOk());
        try testing.expectEqual(tkrzw.Code.SYSTEM_ERROR, st.code);
        try testing.expect(proc.visited < num_records);

        fault.fail_reads = false;
        _ = tree.close(io);
    }

    // 3. Remove a non-first leaf page from the backing HashDBM and verify
    //    PolyDBM(.tree) searchSimilar & findByVector return BrokenData (not partial SUCCESS).
    {
        const sf = try tkrzw.StdFile.create(alloc);
        var backing = try tkrzw.HashDBM.init(sf.asFile(), 0, alloc);
        defer backing.deinit(io);
        try testing.expectEqual(tkrzw.Code.SUCCESS, backing.open(io, tree_path, true, .{}).code);

        // Leaf IDs start at 1 (6-byte big-endian). Remove page ID 2 (second leaf).
        const page2_key = [_]u8{ 0, 0, 0, 0, 0, 2 };
        try testing.expectEqual(tkrzw.Code.SUCCESS, backing.remove(io, &page2_key).code);
        try testing.expectEqual(tkrzw.Code.SUCCESS, backing.close(io).code);
    }
    {
        var poly = try tkrzw.PolyDBM.open(tree_path, .{ .writable = false }, io, alloc);
        defer poly.deinit(io);

        try testing.expectError(
            tkrzw.dbm_poly.PolyError.BrokenData,
            tkrzw.searchSimilar(&poly, io, alloc, &[_]f32{ 1.0, 1.0, 2.0, 3.0 }, 5, .l2, .{}),
        );
        try testing.expectError(
            tkrzw.dbm_poly.PolyError.BrokenData,
            tkrzw.findByVector(&poly, io, alloc, &[_]f32{ 1.0, 1.0, 2.0, 3.0 }),
        );
    }
}

test "TreeDBM rejects truncated and overflowing leaf and inner page payloads with BrokenData" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, io, ".", alloc);
    defer alloc.free(tmp_path);

    // 1. Two-record single-leaf DB: strip final byte of leaf payload -> must return BrokenData
    //    in both default and strict KNN modes and in findByVector (NOT 1 hit + SUCCESS).
    const leaf_path = try std.fmt.allocPrint(alloc, "{s}/trunc_leaf.tkt", .{tmp_path});
    defer alloc.free(leaf_path);
    {
        var db = try tkrzw.PolyDBM.open(leaf_path, .{ .writable = true }, io, alloc);
        const v1 = try tkrzw.encodeF32(alloc, &[_]f32{ 1.0, 0.0 });
        defer alloc.free(v1);
        const v2 = try tkrzw.encodeF32(alloc, &[_]f32{ 0.0, 1.0 });
        defer alloc.free(v2);
        try testing.expectEqual(tkrzw.Code.SUCCESS, db.set(io, "k1", v1, true).code);
        try testing.expectEqual(tkrzw.Code.SUCCESS, db.set(io, "k2", v2, true).code);
        try testing.expectEqual(tkrzw.Code.SUCCESS, db.close(io).code);
        db.deinit(io);
    }
    {
        const sf = try tkrzw.StdFile.create(alloc);
        var backing = try tkrzw.HashDBM.init(sf.asFile(), 0, alloc);
        defer backing.deinit(io);
        try testing.expectEqual(tkrzw.Code.SUCCESS, backing.open(io, leaf_path, true, .{}).code);

        const page1_key = [_]u8{ 0, 0, 0, 0, 0, 1 };
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(alloc);
        try testing.expectEqual(tkrzw.Code.SUCCESS, backing.get(io, &page1_key, &payload).code);
        try testing.expect(payload.items.len > 12);
        // Strip the final byte of the second record's value.
        try testing.expectEqual(
            tkrzw.Code.SUCCESS,
            backing.set(io, &page1_key, payload.items[0 .. payload.items.len - 1], true, null).code,
        );
        try testing.expectEqual(tkrzw.Code.SUCCESS, backing.close(io).code);
    }
    {
        var db = try tkrzw.PolyDBM.open(leaf_path, .{ .writable = false }, io, alloc);
        defer db.deinit(io);

        try testing.expectError(
            tkrzw.dbm_poly.PolyError.BrokenData,
            tkrzw.searchSimilar(&db, io, alloc, &[_]f32{ 1.0, 0.0 }, 5, .l2, .{}),
        );
        try testing.expectError(
            tkrzw.dbm_poly.PolyError.BrokenData,
            tkrzw.searchSimilar(&db, io, alloc, &[_]f32{ 1.0, 0.0 }, 5, .l2, .{ .strict = true }),
        );
        try testing.expectError(
            tkrzw.dbm_poly.PolyError.BrokenData,
            tkrzw.findByVector(&db, io, alloc, &[_]f32{ 1.0, 0.0 }),
        );
    }

    // 2. Multi-leaf DB: strip final byte of the root inner node payload -> keyed lookup returns BROKEN_DATA_ERROR.
    const inner_path = try std.fmt.allocPrint(alloc, "{s}/trunc_inner.tkt", .{tmp_path});
    defer alloc.free(inner_path);
    {
        const sf = try tkrzw.StdFile.create(alloc);
        var tree = try tkrzw.TreeDBM.init(sf.asFile(), alloc);
        defer tree.deinit(io);
        try testing.expectEqual(tkrzw.Code.SUCCESS, tree.openAdvanced(io, inner_path, true, .{}, .{
            .max_page_size = 64,
        }).code);
        var kbuf: [16]u8 = undefined;
        for (0..25) |i| {
            const k = std.fmt.bufPrint(&kbuf, "in_{d:0>4}", .{i}) catch unreachable;
            const v = try tkrzw.encodeF32(alloc, &[_]f32{ @floatFromInt(i), 1.0, 2.0, 3.0 });
            defer alloc.free(v);
            try testing.expectEqual(tkrzw.Code.SUCCESS, tree.set(io, k, v, true, null).code);
        }
        try testing.expectEqual(tkrzw.Code.SUCCESS, tree.close(io).code);
    }
    {
        const sf = try tkrzw.StdFile.create(alloc);
        var backing = try tkrzw.HashDBM.init(sf.asFile(), 0, alloc);
        defer backing.deinit(io);
        try testing.expectEqual(tkrzw.Code.SUCCESS, backing.open(io, inner_path, true, .{}).code);

        // Read root_id from TreeDBM opaque metadata (META_OFFSET_ROOT_ID = 16, width = 6).
        const opaque_meta = backing.getOpaqueMetadata();
        const root_key = opaque_meta[16..22];
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(alloc);
        try testing.expectEqual(tkrzw.Code.SUCCESS, backing.get(io, root_key, &payload).code);
        try testing.expect(payload.items.len > 6);
        try testing.expectEqual(
            tkrzw.Code.SUCCESS,
            backing.set(io, root_key, payload.items[0 .. payload.items.len - 1], true, null).code,
        );
        try testing.expectEqual(tkrzw.Code.SUCCESS, backing.close(io).code);
    }
    {
        const sf = try tkrzw.StdFile.create(alloc);
        var tree = try tkrzw.TreeDBM.init(sf.asFile(), alloc);
        defer tree.deinit(io);
        try testing.expectEqual(tkrzw.Code.SUCCESS, tree.open(io, inner_path, false, .{}).code);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        try testing.expectEqual(tkrzw.Code.BROKEN_DATA_ERROR, tree.get(io, "in_0005", &out).code);
        _ = tree.close(io);
    }

    // 3. Overflowing varint lengths (2^64 + 4) in leaf value length and inner key length
    //    must be rejected with BrokenData (must not truncate to 4 and return a hit).
    const ovf_leaf_path = try std.fmt.allocPrint(alloc, "{s}/ovf_leaf.tkt", .{tmp_path});
    defer alloc.free(ovf_leaf_path);
    {
        var db = try tkrzw.PolyDBM.open(ovf_leaf_path, .{ .writable = true }, io, alloc);
        const v1 = try tkrzw.encodeF32(alloc, &[_]f32{1.0});
        defer alloc.free(v1);
        try testing.expectEqual(tkrzw.Code.SUCCESS, db.set(io, "k1", v1, true).code);
        try testing.expectEqual(tkrzw.Code.SUCCESS, db.close(io).code);
        db.deinit(io);
    }
    {
        const sf = try tkrzw.StdFile.create(alloc);
        var backing = try tkrzw.HashDBM.init(sf.asFile(), 0, alloc);
        defer backing.deinit(io);
        try testing.expectEqual(tkrzw.Code.SUCCESS, backing.open(io, ovf_leaf_path, true, .{}).code);

        // Craft leaf payload: 12-byte prev/next (0, 0), key_len=2 ("k1"),
        // val_len = 2^64 + 4 (0x82, 0x80 x 8, 0x04), 4-byte float32(1.0).
        const v1 = try tkrzw.encodeF32(alloc, &[_]f32{1.0});
        defer alloc.free(v1);
        var bad_leaf: std.ArrayList(u8) = .empty;
        defer bad_leaf.deinit(alloc);
        try bad_leaf.appendNTimes(alloc, 0, 12);
        try bad_leaf.append(alloc, 2);
        try bad_leaf.appendSlice(alloc, "k1");
        try bad_leaf.appendSlice(alloc, &[_]u8{ 0x82, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x04 });
        try bad_leaf.appendSlice(alloc, v1);

        const page1_key = [_]u8{ 0, 0, 0, 0, 0, 1 };
        try testing.expectEqual(tkrzw.Code.SUCCESS, backing.set(io, &page1_key, bad_leaf.items, true, null).code);
        try testing.expectEqual(tkrzw.Code.SUCCESS, backing.close(io).code);
    }
    {
        var db = try tkrzw.PolyDBM.open(ovf_leaf_path, .{ .writable = false }, io, alloc);
        defer db.deinit(io);
        try testing.expectError(
            tkrzw.dbm_poly.PolyError.BrokenData,
            tkrzw.searchSimilar(&db, io, alloc, &[_]f32{1.0}, 5, .l2, .{ .strict = true }),
        );
        try testing.expectError(
            tkrzw.dbm_poly.PolyError.BrokenData,
            tkrzw.searchSimilar(&db, io, alloc, &[_]f32{1.0}, 5, .l2, .{}),
        );
        try testing.expectError(
            tkrzw.dbm_poly.PolyError.BrokenData,
            tkrzw.findByVector(&db, io, alloc, &[_]f32{1.0}),
        );
    }

    // 4. Overflowing varint key_len (2^64 + 4) in root inner node must return BROKEN_DATA_ERROR.
    {
        const sf = try tkrzw.StdFile.create(alloc);
        var backing = try tkrzw.HashDBM.init(sf.asFile(), 0, alloc);
        defer backing.deinit(io);
        try testing.expectEqual(tkrzw.Code.SUCCESS, backing.open(io, inner_path, true, .{}).code);

        const opaque_meta = backing.getOpaqueMetadata();
        const root_key = opaque_meta[16..22];
        var bad_inner: std.ArrayList(u8) = .empty;
        defer bad_inner.deinit(alloc);
        try bad_inner.appendSlice(alloc, &[_]u8{ 0, 0, 0, 0, 0, 1 }); // heir_id = 1
        try bad_inner.appendSlice(alloc, &[_]u8{ 0x82, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x04 }); // key_len = 2^64 + 4
        try bad_inner.appendSlice(alloc, "abcd");
        try bad_inner.appendSlice(alloc, &[_]u8{ 0, 0, 0, 0, 0, 2 }); // child = 2

        try testing.expectEqual(tkrzw.Code.SUCCESS, backing.set(io, root_key, bad_inner.items, true, null).code);
        try testing.expectEqual(tkrzw.Code.SUCCESS, backing.close(io).code);
    }
    {
        const sf = try tkrzw.StdFile.create(alloc);
        var tree = try tkrzw.TreeDBM.init(sf.asFile(), alloc);
        defer tree.deinit(io);
        try testing.expectEqual(tkrzw.Code.SUCCESS, tree.open(io, inner_path, false, .{}).code);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        try testing.expectEqual(tkrzw.Code.BROKEN_DATA_ERROR, tree.get(io, "in_0005", &out).code);
        _ = tree.close(io);
    }
}

test "legacy 8db376c align_pow=10 HashDBM works with KNN, exact lookup, and in-place update" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, io, ".", alloc);
    defer alloc.free(tmp_path);
    const db_path = try std.fmt.allocPrint(alloc, "{s}/legacy_knn_a10.tkh", .{tmp_path});
    defer alloc.free(db_path);

    const v1 = try tkrzw.encodeF32(alloc, &[_]f32{ 1.0, 2.0 });
    defer alloc.free(v1);
    const v2 = try tkrzw.encodeF32(alloc, &[_]f32{ 3.0, 4.0 });
    defer alloc.free(v2);
    const v1_new = try tkrzw.encodeF32(alloc, &[_]f32{ 10.0, 20.0 });
    defer alloc.free(v1_new);

    // 1. Write two records at align_pow=10.
    {
        const sf = try tkrzw.StdFile.create(alloc);
        var hdb = try tkrzw.HashDBM.init(sf.asFile(), 64, alloc);
        defer hdb.deinit(io);
        try testing.expectEqual(tkrzw.Code.SUCCESS, hdb.openAdvanced(io, db_path, true, .{}, .{
            .align_pow = 10,
            .num_buckets = 64,
        }).code);
        try testing.expectEqual(tkrzw.Code.SUCCESS, hdb.set(io, "vec1", v1, true, null).code);
        try testing.expectEqual(tkrzw.Code.SUCCESS, hdb.set(io, "vec2", v2, true, null).code);
        try testing.expectEqual(tkrzw.Code.SUCCESS, hdb.close(io).code);
    }

    // 2. Patch both 1024-byte records on disk to legacy 8db376c padding encoding
    //    (record_base = alignUp(128 + 64 * 4, 1024) = 1024; ow = 4; key_len=4, val_len=8).
    {
        const sf = try tkrzw.StdFile.create(alloc);
        defer sf.asFile().deinit(alloc);
        try testing.expectEqual(tkrzw.Code.SUCCESS, sf.asFile().open(io, db_path, true, .{}).code);
        defer _ = sf.asFile().close(io);

        // Header layout: 1 (magic) + 4 (child) + 1 (ks=4) + 1 (vs=8) = 7 bytes before padding varint.
        // Official padding_size = 1024 - (7 + 1 + 4 + 8) = 1004 (2-byte varint).
        // Legacy 8db376c wrote actual_padding = 1024 - (7 + 2 + 4 + 8) = 1003 (2-byte varint).
        var legacy_pad_buf: [8]u8 = undefined;
        const n = tkrzw.varint.writeVarNum(&legacy_pad_buf, 1003);
        try testing.expectEqual(@as(usize, 2), n);

        const rec_offsets = [_]i64{ 1024, 2048 };
        for (rec_offsets) |off| {
            try testing.expectEqual(tkrzw.Code.SUCCESS, sf.asFile().write(io, off + 7, legacy_pad_buf[0..n]).code);
        }
    }

    // 3. Open via PolyDBM(.hash): KNN scan, exact lookup, and in-place update must all work.
    {
        var poly = try tkrzw.PolyDBM.open(db_path, .{ .writable = true }, io, alloc);
        defer poly.deinit(io);

        {
            var knn = try tkrzw.searchSimilar(&poly, io, alloc, &[_]f32{ 3.0, 4.0 }, 2, .l2, .{ .strict = true });
            defer knn.deinit(alloc);
            try testing.expectEqual(@as(usize, 2), knn.scanned);
            try testing.expectEqual(@as(usize, 0), knn.invalid_records);
            try testing.expectEqualStrings("vec2", knn.hits[0].key);
            try testing.expectEqualStrings("vec1", knn.hits[1].key);
        }
        {
            var exact = try tkrzw.findByVector(&poly, io, alloc, &[_]f32{ 1.0, 2.0 });
            defer exact.deinit(alloc);
            try testing.expectEqual(@as(usize, 1), exact.keys.len);
            try testing.expectEqualStrings("vec1", exact.keys[0]);
        }

        // Update vec1 in place and verify both records still scan cleanly.
        try testing.expectEqual(tkrzw.Code.SUCCESS, poly.set(io, "vec1", v1_new, true).code);
        {
            var knn = try tkrzw.searchSimilar(&poly, io, alloc, &[_]f32{ 10.0, 20.0 }, 2, .l2, .{ .strict = true });
            defer knn.deinit(alloc);
            try testing.expectEqual(@as(usize, 2), knn.scanned);
            try testing.expectEqualStrings("vec1", knn.hits[0].key);
            try testing.expectEqual(@as(f64, 0.0), knn.hits[0].score);
            try testing.expectEqualStrings("vec2", knn.hits[1].key);
        }
    }
}

test "SkipDBM concurrent writers serialize cleanly with synchronize and KNN scan" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, io, ".", alloc);
    defer alloc.free(tmp_path);

    var db = try util.openBackend(.skip, tmp_path, "skip_concurrent", true, io, alloc);
    defer db.deinit(io);

    const v1 = try tkrzw.encodeF32(alloc, &[_]f32{ 1.0, 0.0 });
    defer alloc.free(v1);
    const v2 = try tkrzw.encodeF32(alloc, &[_]f32{ 0.0, 1.0 });
    defer alloc.free(v2);

    const Shared = struct {
        db: *tkrzw.PolyDBM,
        io: std.Io,
        v1: []const u8,
        v2: []const u8,
        stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    };
    var shared = Shared{ .db = &db, .io = io, .v1 = v1, .v2 = v2 };

    const worker = struct {
        fn run(ctx: *Shared, worker_id: usize) void {
            var kbuf: [16]u8 = undefined;
            var i: usize = 0;
            while (!ctx.stop.load(.acquire) and i < 400) : (i += 1) {
                const k = std.fmt.bufPrint(&kbuf, "sk_{d}_{d}", .{ worker_id, i % 8 }) catch unreachable;
                if (i % 4 == 0) {
                    _ = ctx.db.remove(ctx.io, k);
                } else {
                    const val = if ((i % 2) == 0) ctx.v1 else ctx.v2;
                    _ = ctx.db.set(ctx.io, k, val, true);
                }
                std.Thread.yield() catch {};
            }
        }
    }.run;

    const t1 = try std.Thread.spawn(.{}, worker, .{ &shared, 1 });
    const t2 = try std.Thread.spawn(.{}, worker, .{ &shared, 2 });
    defer {
        shared.stop.store(true, .release);
        t1.join();
        t2.join();
    }

    for (0..8) |_| {
        try testing.expectEqual(tkrzw.Code.SUCCESS, db.synchronize(io, false).code);
        var knn = try tkrzw.searchSimilar(&db, io, alloc, &[_]f32{ 1.0, 0.0 }, 5, .cosine, .{ .strict = true });
        knn.deinit(alloc);
        var exact = try tkrzw.findByVector(&db, io, alloc, &[_]f32{ 1.0, 0.0 });
        exact.deinit(alloc);
    }
}

test "KNN performance smoke: 10k x 64-dim cosine top-10 completes cleanly" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;

    const n: usize = 10_000;
    const dim: usize = 64;
    const k: usize = 10;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, io, ".", alloc);
    defer alloc.free(tmp_path);

    var db = try util.openBackend(.tiny, tmp_path, "perf_10k", true, io, alloc);
    defer db.deinit(io);

    var prng = std.Random.DefaultPrng.init(99);
    const rng = prng.random();

    var vec_buf: [dim]f32 = undefined;
    var key_buf: [16]u8 = undefined;
    for (0..n) |i| {
        const key = std.fmt.bufPrint(&key_buf, "v_{d:0>6}", .{i}) catch unreachable;
        for (&vec_buf) |*x| x.* = rng.float(f32) * 2.0 - 1.0;
        const encoded = try tkrzw.encodeF32(alloc, &vec_buf);
        defer alloc.free(encoded);
        try testing.expectEqual(tkrzw.Code.SUCCESS, db.set(io, key, encoded, true).code);
    }

    var query: [dim]f32 = undefined;
    for (&query) |*x| x.* = rng.float(f32) * 2.0 - 1.0;

    const t0 = tkrzw.time_util.getWallTime(io);
    var res = try tkrzw.searchSimilar(&db, io, alloc, &query, k, .cosine, .{});
    const elapsed_ms = (tkrzw.time_util.getWallTime(io) - t0) * 1000.0;
    defer res.deinit(alloc);

    try testing.expectEqual(n, res.scanned);
    try testing.expectEqual(@as(usize, 0), res.invalid_records);
    try testing.expectEqual(k, res.hits.len);
    for (1..res.hits.len) |i| {
        try testing.expect(res.hits[i - 1].score >= res.hits[i].score);
    }
    try testing.expect(elapsed_ms >= 0.0);
}

test "README KNN quick-start example compiles and runs" {
    const testing = std.testing;
    const io = testing.io;
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, io, ".", allocator);
    defer allocator.free(tmp_path);
    const db_path = try std.fmt.allocPrint(allocator, "{s}/embeddings.tkh", .{tmp_path});
    defer allocator.free(db_path);

    var db = try tkrzw.PolyDBM.open(db_path, .{ .writable = true }, io, allocator);
    defer db.deinit(io);

    const v_cat = try tkrzw.encodeF32(allocator, &[_]f32{ 0.9, 0.1, 0.0 });
    defer allocator.free(v_cat);
    const v_dog = try tkrzw.encodeF32(allocator, &[_]f32{ 0.8, 0.2, 0.0 });
    defer allocator.free(v_dog);
    const v_car = try tkrzw.encodeF32(allocator, &[_]f32{ 0.0, 0.0, 1.0 });
    defer allocator.free(v_car);

    _ = db.set(io, "cat", v_cat, true);
    _ = db.set(io, "dog", v_dog, true);
    _ = db.set(io, "car", v_car, true);

    var result = try tkrzw.searchSimilar(&db, io, allocator, &[_]f32{ 1.0, 0.0, 0.0 }, 2, .cosine, .{});
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), result.hits.len);
    try testing.expectEqualStrings("cat", result.hits[0].key);
    try testing.expectEqualStrings("dog", result.hits[1].key);

    var exact = try tkrzw.findByVector(&db, io, allocator, &[_]f32{ 0.0, 0.0, 1.0 });
    defer exact.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), exact.keys.len);
    try testing.expectEqualStrings("car", exact.keys[0]);
}
