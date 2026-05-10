//! Scalable, thread-safe, serializable Blocked Bloom Filter.
//!
//! Layout:
//! - `Block`: 64-byte (512-bit) cache-line-aligned bit array.
//! - `Layer`: a fixed-size blocked bloom filter (one or more blocks).
//! - `BloomFilter`: an ordered list of layers. `add` always writes into the
//!   active (last) layer; `mightContain` walks ALL layers and returns true if
//!   any layer reports membership. When the active layer's fill ratio exceeds
//!   `Options.fill_threshold`, a new, larger, tighter layer is appended.
//!
//! Hashing: each key is hashed once with `hashMurmur3_128(key, 0)` to obtain
//! a 128-bit `(h1, h2)`. `h1` selects the block; `k` bit positions within the
//! block are derived via Kirsch-Mitzenmacher: `bit_i = (h2 +% i*%h1) % BLOCK_BITS`.
//!
//! Thread safety: every public method acquires an internal `std.Io.RwLock`.
//! Read-only methods (`mightContain`, `count`, etc.) use a shared lock so
//! concurrent reads run in parallel. `add` uses an exclusive lock.
//!
//! `deinit` must be called from a single thread with no concurrent access.
//! The caller must ensure all concurrent operations have completed (e.g. by
//! joining any threads that hold a reference) before calling `deinit`.
//!
//! Security note: `hashMurmur3_128` is called with a fixed seed (0). It is
//! not HashDoS-resistant. Do not use `BloomFilter` with adversarially
//! controlled keys in security-sensitive contexts.

const std = @import("std");
const hash_util = @import("hash_util.zig");

// ---------------------------------------------------------------------------
// Block: 64 bytes / 512 bits, cache-line aligned.
// ---------------------------------------------------------------------------

const Block = extern struct {
    bits: [64]u8 align(64) = [_]u8{0} ** 64,

    pub fn set(self: *Block, idx: u10) void {
        self.bits[idx >> 3] |= @as(u8, 1) << @intCast(idx & 7);
    }

    pub fn get(self: Block, idx: u10) bool {
        return (self.bits[idx >> 3] >> @intCast(idx & 7)) & 1 == 1;
    }
};

comptime {
    std.debug.assert(@sizeOf(Block) == 64 and @alignOf(Block) == 64);
}

/// Number of bits per block (= 64 bytes × 8). Used for Kirsch-Mitzenmacher
/// bit-position derivation and for rounding bit-array sizes to block boundaries.
const BLOCK_BITS: u64 = 512;

// ---------------------------------------------------------------------------
// Layer: a single blocked bloom filter level.
// ---------------------------------------------------------------------------

const Layer = struct {
    blocks: []align(64) Block,
    num_blocks: usize,
    num_hashes: u32,
    count: usize,
    capacity: usize,
    fp_rate: f64,
};

fn makeLayer(allocator: std.mem.Allocator, n_in: usize, p: f64) !Layer {
    const n = if (n_in == 0) 1 else n_in;
    const ln2: f64 = @log(2.0);
    const bpe = -@log(p) / (ln2 * ln2);
    // Round total bit count up to a BLOCK_BITS boundary so every layer
    // contains a whole number of blocks.
    var m_bits: usize = @intFromFloat(@ceil(@as(f64, @floatFromInt(n)) * bpe));
    if (m_bits == 0) m_bits = BLOCK_BITS;
    m_bits = (m_bits + (BLOCK_BITS - 1)) / BLOCK_BITS * BLOCK_BITS;
    var num_blocks = m_bits / BLOCK_BITS;
    if (num_blocks == 0) num_blocks = 1;
    const k_f = @round(bpe * ln2);
    const k: u32 = if (k_f < 1.0) 1 else @intFromFloat(k_f);

    // alloc(Block, n) uses @alignOf(Block) = 64, preserving the cache-line
    // alignment that is central to the blocked filter's performance.
    const blocks = try allocator.alloc(Block, num_blocks);
    @memset(blocks, Block{});
    return .{
        .blocks = blocks,
        .num_blocks = num_blocks,
        .num_hashes = @max(1, k),
        .count = 0,
        .capacity = n,
        .fp_rate = p,
    };
}

fn deinitLayer(layer: *Layer, allocator: std.mem.Allocator) void {
    allocator.free(layer.blocks);
    layer.blocks = &[_]Block{};
}

// ---------------------------------------------------------------------------
// BloomFilter
// ---------------------------------------------------------------------------

pub const BloomFilter = struct {
    layers: std.ArrayListUnmanaged(Layer),
    allocator: std.mem.Allocator,
    mutex: std.Io.RwLock,
    total_count: usize,
    opts: Options,

    pub const MAX_LAYERS: usize = 32;

    /// Maximum permitted `num_blocks` per layer when deserializing
    /// (~1 GiB of bit storage per layer). Guards against malicious inputs.
    const MAX_BLOCKS_PER_LAYER: usize = 1 << 24;

    pub const MAGIC: u32 = 0x424C4F4D; // "BLOM"
    pub const VERSION: u32 = 1;

    pub const Options = struct {
        /// Expected number of unique items to be inserted into the first layer.
        /// Growth layers are sized as multiples of this value. Must be >= 1.
        expected_items: usize = 1000,
        /// Target false-positive probability for the first layer (0.0, 1.0).
        /// Subsequent layers tighten this by `tightening_ratio` each step.
        false_positive_rate: f64 = 0.01,
        /// Multiplicative size factor between successive layers. Each new layer
        /// holds `growth_factor` times more items than the previous. Must be > 1.0.
        growth_factor: f64 = 2.0,
        /// Multiplicative FP-rate tightening between successive layers. Each new
        /// layer targets `tightening_ratio * previous_layer_fp_rate`. Must be in
        /// (0.0, 1.0). Default 0.5 halves the FP target per layer, bounding the
        /// overall FP rate to `false_positive_rate / (1 - tightening_ratio)`.
        tightening_ratio: f64 = 0.5,
        /// Fraction of a layer's capacity at which a new layer is created.
        /// When `layer.count / layer.capacity >= fill_threshold`, `add` will
        /// allocate a new layer before inserting. Must be in (0.0, 1.0).
        fill_threshold: f64 = 0.5,
    };

    fn validateOptions(o: Options) !void {
        // Guard against floating-point overflow in makeLayer's bit-count
        // calculation: @floatFromInt(n) * bpe must not overflow f64 to +Inf.
        if (o.expected_items == 0 or o.expected_items > (1 << 40)) return error.InvalidParameter;
        if (!std.math.isFinite(o.false_positive_rate) or
            o.false_positive_rate <= 0.0 or o.false_positive_rate >= 1.0)
            return error.InvalidParameter;
        if (!std.math.isFinite(o.growth_factor) or o.growth_factor <= 1.0)
            return error.InvalidParameter;
        if (!std.math.isFinite(o.tightening_ratio) or
            o.tightening_ratio <= 0.0 or o.tightening_ratio >= 1.0)
            return error.InvalidParameter;
        if (!std.math.isFinite(o.fill_threshold) or
            o.fill_threshold <= 0.0 or o.fill_threshold >= 1.0)
            return error.InvalidParameter;
    }

    pub fn init(allocator: std.mem.Allocator, opts: Options) !BloomFilter {
        try validateOptions(opts);
        var layers: std.ArrayListUnmanaged(Layer) = .empty;
        errdefer layers.deinit(allocator);
        var first = try makeLayer(allocator, opts.expected_items, opts.false_positive_rate);
        errdefer deinitLayer(&first, allocator);
        try layers.append(allocator, first);
        // Disarm the errdefer above: ownership of first.blocks is now with layers.items[0].
        // Without this, any fallible code inserted here before `return` would double-free.
        first.blocks = &[_]Block{};
        return .{
            .layers = layers,
            .allocator = allocator,
            .mutex = .init,
            .total_count = 0,
            .opts = opts,
        };
    }

    /// Release all resources. Must be called from a single thread; the caller
    /// must ensure no concurrent `add`, `mightContain`, or other method calls
    /// are in progress (e.g. join all worker threads before calling `deinit`).
    pub fn deinit(self: *BloomFilter) void {
        for (self.layers.items) |*layer| deinitLayer(layer, self.allocator);
        self.layers.deinit(self.allocator);
        self.* = undefined;
    }

    /// Insert a key. Acquires the internal exclusive lock. May allocate a new
    /// layer when the active layer exceeds `Options.fill_threshold`.
    ///
    /// Returns `error.BloomLayerLimitExceeded` when `MAX_LAYERS` layers are
    /// already in use. This is a **permanent** terminal condition: once the
    /// limit is reached, every subsequent `add` call will return this error.
    /// `mightContain` continues to work correctly on existing data.
    pub fn add(self: *BloomFilter, io: std.Io, key: []const u8) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        try self.maybeGrow();
        const layer = &self.layers.items[self.layers.items.len - 1];
        const h = hash_util.hashMurmur3_128(key, 0);
        const block_idx = h.h1 % layer.num_blocks;
        // Kirsch & Mitzenmacher 2006: derive k bit positions from two base
        // hashes without k independent hash functions.
        // g_i = (h2 + i*h1) mod BLOCK_BITS, all within a single block.
        var i: u64 = 0;
        while (i < layer.num_hashes) : (i += 1) {
            const bit_idx: u10 = @intCast((h.h2 +% i *% h.h1) % BLOCK_BITS);
            layer.blocks[block_idx].set(bit_idx);
        }
        layer.count += 1;
        self.total_count += 1;
    }

    /// Probabilistic membership test. Walks ALL layers (essential for
    /// post-growth correctness — keys inserted in older layers must still be
    /// found). False positives are possible; false negatives never occur for
    /// keys that were actually inserted.
    pub fn mightContain(self: *BloomFilter, io: std.Io, key: []const u8) bool {
        self.mutex.lockSharedUncancelable(io);
        defer self.mutex.unlockShared(io);
        const h = hash_util.hashMurmur3_128(key, 0);
        for (self.layers.items) |*layer| {
            const block_idx = h.h1 % layer.num_blocks;
            var all_set = true;
            // Same Kirsch-Mitzenmacher derivation as in `add`.
            var i: u64 = 0;
            while (i < layer.num_hashes) : (i += 1) {
                const bit_idx: u10 = @intCast((h.h2 +% i *% h.h1) % BLOCK_BITS);
                if (!layer.blocks[block_idx].get(bit_idx)) {
                    all_set = false;
                    break;
                }
            }
            if (all_set) return true;
        }
        return false;
    }

    pub fn count(self: *BloomFilter, io: std.Io) usize {
        self.mutex.lockSharedUncancelable(io);
        defer self.mutex.unlockShared(io);
        return self.total_count;
    }

    pub fn layerCount(self: *BloomFilter, io: std.Io) usize {
        self.mutex.lockSharedUncancelable(io);
        defer self.mutex.unlockShared(io);
        return self.layers.items.len;
    }

    /// Returns the estimated false-positive probability for the current filter
    /// state, computed as the maximum estimated rate across all layers.
    /// Returns 0.0 when no items have been inserted.
    pub fn estimatedFalsePositiveRate(self: *BloomFilter, io: std.Io) f64 {
        self.mutex.lockSharedUncancelable(io);
        defer self.mutex.unlockShared(io);
        var max_rate: f64 = 0.0;
        for (self.layers.items) |layer| {
            const fill = @as(f64, @floatFromInt(layer.count)) /
                @as(f64, @floatFromInt(layer.capacity));
            const k = @as(f64, @floatFromInt(layer.num_hashes));
            const rate = std.math.pow(f64, 1.0 - @exp(-k * fill), k);
            if (rate > max_rate) max_rate = rate;
        }
        return @max(0.0, @min(1.0, max_rate));
    }

    // -- growth ------------------------------------------------------------

    /// Caller must hold `self.mutex`.
    fn maybeGrow(self: *BloomFilter) !void {
        const layer = &self.layers.items[self.layers.items.len - 1];
        const fill = @as(f64, @floatFromInt(layer.count)) /
            @as(f64, @floatFromInt(layer.capacity));
        if (fill < self.opts.fill_threshold) return;
        if (self.layers.items.len >= MAX_LAYERS) return error.BloomLayerLimitExceeded;

        const layer_idx = self.layers.items.len;
        const idx_f = @as(f64, @floatFromInt(layer_idx));
        const new_n_f = @as(f64, @floatFromInt(self.opts.expected_items)) *
            std.math.pow(f64, self.opts.growth_factor, idx_f);
        const new_n: usize = @intFromFloat(@ceil(new_n_f));
        const new_p = self.opts.false_positive_rate *
            std.math.pow(f64, self.opts.tightening_ratio, idx_f);

        var new_layer = try makeLayer(self.allocator, new_n, new_p);
        errdefer deinitLayer(&new_layer, self.allocator);
        try self.layers.append(self.allocator, new_layer);
    }

    // -- serialization -----------------------------------------------------

    /// Exact byte length that `serialize` will write.
    pub fn serializedSize(self: *BloomFilter, io: std.Io) usize {
        self.mutex.lockSharedUncancelable(io);
        defer self.mutex.unlockShared(io);
        const header_size: usize = 4 + 4 + 8 + 8 + 8 + 8 + 8 + 8 + 4;
        var total = header_size;
        for (self.layers.items) |layer| {
            total += 8 + 4 + 8 + 8 + 8 + layer.num_blocks * 64;
        }
        return total;
    }

    /// Serialize to `writer` (anytype with `writeAll([]const u8) !void`).
    /// Format (all little-endian):
    ///   magic:u32 version:u32 expected_items:u64
    ///   false_positive_rate:f64 growth_factor:f64 tightening_ratio:f64 fill_threshold:f64
    ///   total_count:u64 num_layers:u32
    ///   per layer: num_blocks:u64 num_hashes:u32 count:u64 capacity:u64 fp_rate:f64
    ///              block_data: num_blocks * 64 bytes
    pub fn serialize(self: *BloomFilter, io: std.Io, writer: anytype) !void {
        self.mutex.lockSharedUncancelable(io);
        defer self.mutex.unlockShared(io);

        try writeU32(writer, MAGIC);
        try writeU32(writer, VERSION);
        try writeU64(writer, @as(u64, self.opts.expected_items));
        try writeF64(writer, self.opts.false_positive_rate);
        try writeF64(writer, self.opts.growth_factor);
        try writeF64(writer, self.opts.tightening_ratio);
        try writeF64(writer, self.opts.fill_threshold);
        try writeU64(writer, @as(u64, self.total_count));
        try writeU32(writer, @as(u32, @intCast(self.layers.items.len)));

        for (self.layers.items) |layer| {
            try writeU64(writer, @as(u64, layer.num_blocks));
            try writeU32(writer, layer.num_hashes);
            try writeU64(writer, @as(u64, layer.count));
            try writeU64(writer, @as(u64, layer.capacity));
            try writeF64(writer, layer.fp_rate);
            const raw: [*]const u8 = @ptrCast(layer.blocks.ptr);
            try writer.writeAll(raw[0 .. layer.num_blocks * 64]);
        }
    }

    /// Deserialize from `reader` (anytype with `readSliceAll([]u8) !void`).
    /// `opts` is reserved for future use and is currently ignored; all
    /// Options values are restored from the serialized header.
    pub fn deserialize(allocator: std.mem.Allocator, reader: anytype, opts: Options) !BloomFilter {
        _ = opts; // reserved; all configuration is read from the stream header

        const magic = try readU32(reader);
        if (magic != MAGIC) return error.InvalidMagic;
        const version = try readU32(reader);
        if (version != VERSION) return error.UnsupportedVersion;

        const expected_items = try readU64(reader);
        const fp_rate = try readF64(reader);
        const growth_factor = try readF64(reader);
        const tightening_ratio = try readF64(reader);
        const fill_threshold = try readF64(reader);
        const total_count = try readU64(reader);
        const num_layers = try readU32(reader);

        if (expected_items == 0) return error.InvalidParameter;
        const restored_opts: Options = .{
            .expected_items = @intCast(expected_items),
            .false_positive_rate = fp_rate,
            .growth_factor = growth_factor,
            .tightening_ratio = tightening_ratio,
            .fill_threshold = fill_threshold,
        };
        validateOptions(restored_opts) catch return error.InvalidParameter;

        if (num_layers == 0) return error.InvalidParameter;
        if (num_layers > MAX_LAYERS) return error.TooManyLayers;

        var layers: std.ArrayListUnmanaged(Layer) = .empty;
        errdefer {
            for (layers.items) |*layer| deinitLayer(layer, allocator);
            layers.deinit(allocator);
        }

        var li: u32 = 0;
        while (li < num_layers) : (li += 1) {
            const num_blocks = try readU64(reader);
            const num_hashes = try readU32(reader);
            const layer_count = try readU64(reader);
            const capacity = try readU64(reader);
            const layer_fp = try readF64(reader);

            if (num_blocks == 0) return error.InvalidParameter;
            if (num_blocks > MAX_BLOCKS_PER_LAYER) return error.LayerTooLarge;
            if (num_hashes == 0) return error.InvalidParameter;
            if (capacity == 0) return error.InvalidParameter;

            const nb: usize = @intCast(num_blocks);
            // alloc(Block, nb) uses @alignOf(Block) = 64, same as makeLayer.
            const blocks = try allocator.alloc(Block, nb);
            errdefer allocator.free(blocks);
            @memset(blocks, Block{});
            const raw: [*]u8 = @ptrCast(blocks.ptr);
            try reader.readSliceAll(raw[0 .. nb * 64]);

            try layers.append(allocator, .{
                .blocks = blocks,
                .num_blocks = nb,
                .num_hashes = num_hashes,
                .count = @intCast(layer_count),
                .capacity = @intCast(capacity),
                .fp_rate = layer_fp,
            });
        }

        return .{
            .layers = layers,
            .allocator = allocator,
            .mutex = .init,
            .total_count = @intCast(total_count),
            .opts = restored_opts,
        };
    }
};

// ---------------------------------------------------------------------------
// Little-endian I/O helpers (used with anytype writer/reader).
// ---------------------------------------------------------------------------

fn writeU32(writer: anytype, v: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .little);
    try writer.writeAll(&buf);
}

fn writeU64(writer: anytype, v: u64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, v, .little);
    try writer.writeAll(&buf);
}

fn writeF64(writer: anytype, v: f64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, @bitCast(v), .little);
    try writer.writeAll(&buf);
}

fn readU32(reader: anytype) !u32 {
    var buf: [4]u8 = undefined;
    try reader.readSliceAll(&buf);
    return std.mem.readInt(u32, &buf, .little);
}

fn readU64(reader: anytype) !u64 {
    var buf: [8]u8 = undefined;
    try reader.readSliceAll(&buf);
    return std.mem.readInt(u64, &buf, .little);
}

fn readF64(reader: anytype) !f64 {
    var buf: [8]u8 = undefined;
    try reader.readSliceAll(&buf);
    return @bitCast(std.mem.readInt(u64, &buf, .little));
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "Block: set and get boundary indices" {
    var b: Block = .{};
    const indices = [_]u10{ 0, 255, 256, 511 };
    for (indices) |i| b.set(i);
    for (indices) |i| try testing.expect(b.get(i));
    // Unset bits are still zero.
    try testing.expect(!b.get(1));
    try testing.expect(!b.get(254));
    try testing.expect(!b.get(257));
    try testing.expect(!b.get(510));
}

test "BloomFilter: init with default options" {
    var f = try BloomFilter.init(testing.allocator, .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 0), f.count(testing.io));
    try testing.expectEqual(@as(usize, 1), f.layerCount(testing.io));
}

test "BloomFilter: init rejects invalid options" {
    const bad: []const BloomFilter.Options = &.{
        .{ .expected_items = 0 },
        .{ .false_positive_rate = 0.0 },
        .{ .false_positive_rate = 1.0 },
        .{ .false_positive_rate = -0.1 },
        .{ .growth_factor = 0.5 },
        .{ .growth_factor = 1.0 },
        .{ .tightening_ratio = 0.0 },
        .{ .tightening_ratio = 1.0 },
        .{ .fill_threshold = 0.0 },
        .{ .fill_threshold = 1.0 },
    };
    for (bad) |o| {
        try testing.expectError(error.InvalidParameter, BloomFilter.init(testing.allocator, o));
    }
}

test "BloomFilter: empty filter mightContain returns false" {
    var f = try BloomFilter.init(testing.allocator, .{});
    defer f.deinit();
    try testing.expect(!f.mightContain(testing.io, "alpha"));
    try testing.expect(!f.mightContain(testing.io, "beta"));
    try testing.expect(!f.mightContain(testing.io, ""));
    try testing.expect(!f.mightContain(testing.io, "\x00\x01\x02"));
}

test "BloomFilter: zero-length key" {
    var f = try BloomFilter.init(testing.allocator, .{});
    defer f.deinit();
    try f.add(testing.io, "");
    try testing.expect(f.mightContain(testing.io, ""));
}

test "BloomFilter: no false negatives (100 keys)" {
    var f = try BloomFilter.init(testing.allocator, .{});
    defer f.deinit();
    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const k = try std.fmt.bufPrint(&buf, "key-{d}", .{i});
        try f.add(testing.io, k);
    }
    i = 0;
    while (i < 100) : (i += 1) {
        const k = try std.fmt.bufPrint(&buf, "key-{d}", .{i});
        try testing.expect(f.mightContain(testing.io, k));
    }
}

test "BloomFilter: post-growth correctness" {
    var f = try BloomFilter.init(testing.allocator, .{
        .expected_items = 10,
        .false_positive_rate = 0.1,
        .fill_threshold = 0.5,
    });
    defer f.deinit();
    var buf: [32]u8 = undefined;
    var inserted: usize = 0;
    while (f.layerCount(testing.io) < 2) {
        const k = try std.fmt.bufPrint(&buf, "grow-{d}", .{inserted});
        try f.add(testing.io, k);
        inserted += 1;
        if (inserted > 10000) return error.GrowthDidNotTrigger;
    }
    try testing.expect(inserted >= 1);
    var i: usize = 0;
    while (i < inserted) : (i += 1) {
        const k = try std.fmt.bufPrint(&buf, "grow-{d}", .{i});
        try testing.expect(f.mightContain(testing.io, k));
    }
}

test "BloomFilter: layer fp_rate tightens across layers" {
    var f = try BloomFilter.init(testing.allocator, .{
        .expected_items = 8,
        .false_positive_rate = 0.1,
        .fill_threshold = 0.5,
    });
    defer f.deinit();
    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (f.layerCount(testing.io) < 2) : (i += 1) {
        const k = try std.fmt.bufPrint(&buf, "tight-{d}", .{i});
        try f.add(testing.io, k);
        if (i > 10000) return error.GrowthDidNotTrigger;
    }
    f.mutex.lockUncancelable(std.testing.io);
    defer f.mutex.unlock(std.testing.io);
    try testing.expect(f.layers.items[1].fp_rate < f.layers.items[0].fp_rate);
}

test "BloomFilter: false positive rate sanity" {
    const opts: BloomFilter.Options = .{
        .expected_items = 1000,
        .false_positive_rate = 0.01,
    };
    var f = try BloomFilter.init(testing.allocator, opts);
    defer f.deinit();
    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const k = try std.fmt.bufPrint(&buf, "fp-test-{d}", .{i});
        try f.add(testing.io, k);
    }
    var fp: usize = 0;
    i = 0;
    // Probe keys "unseen-0".."unseen-9999" are lexically disjoint from the
    // insert keys "fp-test-0".."fp-test-999", so any mightContain hit here
    // is a genuine false positive.
    while (i < 10000) : (i += 1) {
        const k = try std.fmt.bufPrint(&buf, "unseen-{d}", .{i});
        if (f.mightContain(testing.io, k)) fp += 1;
    }
    const rate = @as(f64, @floatFromInt(fp)) / 10000.0;
    try testing.expect(rate < 5.0 * opts.false_positive_rate);
}

test "BloomFilter: estimatedFalsePositiveRate in range" {
    var f = try BloomFilter.init(testing.allocator, .{});
    defer f.deinit();
    try testing.expectEqual(@as(f64, 0.0), f.estimatedFalsePositiveRate(testing.io));
    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const k = try std.fmt.bufPrint(&buf, "est-{d}", .{i});
        try f.add(testing.io, k);
    }
    const r = f.estimatedFalsePositiveRate(testing.io);
    try testing.expect(r > 0.0);
    try testing.expect(r < 1.0);
}

test "BloomFilter: serializedSize matches actual serialize output" {
    var f = try BloomFilter.init(testing.allocator, .{
        .expected_items = 16,
        .false_positive_rate = 0.05,
        .fill_threshold = 0.5,
    });
    defer f.deinit();
    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const k = try std.fmt.bufPrint(&buf, "size-{d}", .{i});
        try f.add(testing.io, k);
    }
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try f.serialize(testing.io, &aw.writer);
    try testing.expectEqual(f.serializedSize(testing.io), aw.written().len);
}

test "BloomFilter: serialize deserialize round-trip" {
    var f = try BloomFilter.init(testing.allocator, .{
        .expected_items = 16,
        .false_positive_rate = 0.05,
        .fill_threshold = 0.5,
    });
    defer f.deinit();
    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const k = try std.fmt.bufPrint(&buf, "rt-{d}", .{i});
        try f.add(testing.io, k);
    }
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try f.serialize(testing.io, &aw.writer);

    var reader = std.Io.Reader.fixed(aw.written());
    var g = try BloomFilter.deserialize(testing.allocator, &reader, .{});
    defer g.deinit();

    try testing.expectEqual(f.count(testing.io), g.count(testing.io));
    try testing.expectEqual(f.layerCount(testing.io), g.layerCount(testing.io));

    i = 0;
    while (i < 50) : (i += 1) {
        const k = try std.fmt.bufPrint(&buf, "rt-{d}", .{i});
        try testing.expect(g.mightContain(testing.io, k));
    }
}

test "BloomFilter: serialize deserialize idempotent" {
    var f = try BloomFilter.init(testing.allocator, .{
        .expected_items = 16,
        .false_positive_rate = 0.05,
        .fill_threshold = 0.5,
    });
    defer f.deinit();
    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        const k = try std.fmt.bufPrint(&buf, "idem-{d}", .{i});
        try f.add(testing.io, k);
    }
    var aw1: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw1.deinit();
    try f.serialize(testing.io, &aw1.writer);

    var r1 = std.Io.Reader.fixed(aw1.written());
    var g = try BloomFilter.deserialize(testing.allocator, &r1, .{});
    defer g.deinit();

    var aw2: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw2.deinit();
    try g.serialize(testing.io, &aw2.writer);

    try testing.expectEqualSlices(u8, aw1.written(), aw2.written());
}

test "BloomFilter: deserialize error cases" {
    // Wrong magic.
    {
        var bad: [60]u8 = [_]u8{0} ** 60;
        std.mem.writeInt(u32, bad[0..4], 0xDEADBEEF, .little);
        std.mem.writeInt(u32, bad[4..8], 1, .little);
        var r = std.Io.Reader.fixed(&bad);
        try testing.expectError(error.InvalidMagic, BloomFilter.deserialize(testing.allocator, &r, .{}));
    }
    // Wrong version.
    {
        var bad: [60]u8 = [_]u8{0} ** 60;
        std.mem.writeInt(u32, bad[0..4], 0x424C4F4D, .little);
        std.mem.writeInt(u32, bad[4..8], 0xFF, .little);
        var r = std.Io.Reader.fixed(&bad);
        try testing.expectError(error.UnsupportedVersion, BloomFilter.deserialize(testing.allocator, &r, .{}));
    }
    // Truncated buffer (4 bytes; valid magic but nothing else).
    {
        var bad: [4]u8 = undefined;
        std.mem.writeInt(u32, &bad, 0x424C4F4D, .little);
        var r = std.Io.Reader.fixed(&bad);
        const result = BloomFilter.deserialize(testing.allocator, &r, .{});
        try testing.expect(std.meta.isError(result));
    }
    // num_layers > MAX_LAYERS → error.TooManyLayers (guards against malicious input).
    {
        var bad: [60]u8 = [_]u8{0} ** 60;
        std.mem.writeInt(u32, bad[0..4], BloomFilter.MAGIC, .little);
        std.mem.writeInt(u32, bad[4..8], BloomFilter.VERSION, .little);
        std.mem.writeInt(u64, bad[8..16], 1000, .little); // expected_items
        const fp: u64 = @bitCast(@as(f64, 0.01));
        std.mem.writeInt(u64, bad[16..24], fp, .little); // false_positive_rate
        const gf: u64 = @bitCast(@as(f64, 2.0));
        std.mem.writeInt(u64, bad[24..32], gf, .little); // growth_factor
        const tr: u64 = @bitCast(@as(f64, 0.5));
        std.mem.writeInt(u64, bad[32..40], tr, .little); // tightening_ratio
        std.mem.writeInt(u64, bad[40..48], tr, .little); // fill_threshold
        std.mem.writeInt(u64, bad[48..56], 0, .little); // total_count
        std.mem.writeInt(u32, bad[56..60], BloomFilter.MAX_LAYERS + 1, .little);
        var r = std.Io.Reader.fixed(&bad);
        try testing.expectError(error.TooManyLayers,
            BloomFilter.deserialize(testing.allocator, &r, .{}));
    }
}

test "BloomFilter: allocation failure handled cleanly" {
    // Fail at the very first allocation: init must propagate OOM with no leak.
    {
        var fa = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
        try testing.expectError(error.OutOfMemory, BloomFilter.init(fa.allocator(), .{}));
    }
    // Fail at the second allocation: layer alloc succeeds, ArrayList append fails.
    {
        var fa = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
        try testing.expectError(error.OutOfMemory, BloomFilter.init(fa.allocator(), .{}));
    }
}

test "BloomFilter: concurrent add no panic, count consistent" {
    var f = try BloomFilter.init(testing.allocator, .{
        .expected_items = 2000,
        .false_positive_rate = 0.01,
    });
    defer f.deinit();

    const Worker = struct {
        fn run(filter: *BloomFilter, t: usize) !void {
            var buf: [32]u8 = undefined;
            var i: usize = 0;
            while (i < 250) : (i += 1) {
                const k = try std.fmt.bufPrint(&buf, "thread-{d}-{d}", .{ t, i });
                try filter.add(std.testing.io, k);
            }
        }
    };

    var threads: [4]std.Thread = undefined;
    var t: usize = 0;
    while (t < 4) : (t += 1) {
        threads[t] = try std.Thread.spawn(.{}, Worker.run, .{ &f, t });
    }
    // join() in Zig 0.16 returns void; worker errors are not propagated
    // to the joiner. Worker failures would be visible only via count() != 1000.
    for (threads) |th| th.join();

    try testing.expectEqual(@as(usize, 1000), f.count(testing.io));

    var buf: [32]u8 = undefined;
    t = 0;
    while (t < 4) : (t += 1) {
        var i: usize = 0;
        while (i < 250) : (i += 1) {
            const k = try std.fmt.bufPrint(&buf, "thread-{d}-{d}", .{ t, i });
            try testing.expect(f.mightContain(testing.io, k));
        }
    }
}
