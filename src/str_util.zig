const std = @import("std");
const varint = @import("varint.zig");

/// Parses a decimal integer from str, trimming leading/trailing whitespace and
/// handling an optional leading sign character. Returns defval when no digits
/// are found. Faithful port of tkrzw StrToInt.
pub fn strToInt(str: []const u8, defval: i64) i64 {
    // Trim leading whitespace. std.ascii.whitespace covers the common 6 chars
    // (space, tab, LF, CR, VT, FF); the original C++ trimmed all bytes <= 0x20
    // (33 chars). The deviation is acceptable for human-readable integer input.
    var rest = std.mem.trimStart(u8, str, &std.ascii.whitespace);

    var sign: i64 = 1;
    if (rest.len > 0 and rest[0] == '-') {
        rest = rest[1..];
        sign = -1;
    } else if (rest.len > 0 and rest[0] == '+') {
        rest = rest[1..];
    }

    // Trim whitespace between sign and digits.
    rest = std.mem.trimStart(u8, rest, &std.ascii.whitespace);

    var has_number = false;
    var num: i64 = 0;
    for (rest) |c| {
        if (c < '0' or c > '9') break;
        has_number = true;
        // NOTE: no overflow guard — matches C++ StrToInt which uses bare int64_t
        // arithmetic. Inputs with 20+ digits will overflow and panic in safe modes.
        num = num * 10 + @as(i64, c - '0');
    }

    if (!has_number) return defval;
    return num * sign;
}

/// Parses a floating-point number from str, trimming leading whitespace and
/// handling an optional sign. Special tokens "inf"/"INF" and "nan"/"NAN" are
/// recognized. Delegates to std.fmt.parseFloat for the numeric portion.
/// Faithful port of tkrzw StrToDouble behavior.
pub fn strToDouble(str: []const u8, defval: f64) f64 {
    // Trim leading whitespace. std.ascii.whitespace covers the common 6 chars;
    // original C++ trimmed all bytes <= 0x20 — deviation acceptable here.
    var rest = std.mem.trimStart(u8, str, &std.ascii.whitespace);

    if (rest.len == 0) return defval;

    var sign: f64 = 1.0;
    if (rest[0] == '-') {
        sign = -1.0;
        rest = rest[1..];
    } else if (rest[0] == '+') {
        rest = rest[1..];
    }

    if (rest.len == 0) return defval;

    // Check for inf/nan tokens before delegating to parseFloat.
    if (std.mem.eql(u8, rest, "inf") or std.mem.eql(u8, rest, "INF")) {
        return sign * std.math.inf(f64);
    }
    if (std.mem.eql(u8, rest, "nan") or std.mem.eql(u8, rest, "NAN")) {
        return std.math.nan(f64);
    }

    // The sign was already consumed; pass the remaining digits/exponent to
    // parseFloat and apply the sign to the result.
    const val = std.fmt.parseFloat(f64, rest) catch return defval;
    return sign * val;
}

/// Writes the big-endian representation of data into buf[0..size] and returns
/// that slice. size is clamped to 8. Faithful port of tkrzw IntToStrBigEndian /
/// WriteFixNum: writes the most-significant `size` bytes of the 8-byte
/// big-endian encoding.
pub fn intToStrBigEndian(data: u64, size: usize, buf: *[8]u8) []u8 {
    const sz = @min(size, 8);
    // Encode the full 8-byte big-endian representation into a temporary buffer,
    // then copy the most-significant `sz` bytes into buf.
    var tmp: [8]u8 = undefined;
    std.mem.writeInt(u64, &tmp, data, .big);
    // C++ WriteFixNum copies from &be + (8 - width): the least-significant `sz`
    // bytes of the big-endian representation, i.e. tmp[8-sz..8].
    @memcpy(buf[0..sz], tmp[8 - sz .. 8]);
    return buf[0..sz];
}

/// Reads up to 8 bytes from str as a big-endian uint64. The bytes are treated
/// as the most-significant bytes of the 8-byte representation. Faithful port
/// of tkrzw StrToIntBigEndian / ReadFixNum.
pub fn strToIntBigEndian(str: []const u8) u64 {
    if (str.len == 0) return 0;
    const sz = @min(str.len, 8);
    // C++ ReadFixNum: memcpy into low address of uint64, then NetToHost64 >> shift.
    // Equivalent in big-endian terms: place input bytes at buf[8-sz..8].
    var buf: [8]u8 = .{0} ** 8;
    @memcpy(buf[8 - sz .. 8], str[0..sz]);
    return std.mem.readInt(u64, &buf, .big);
}

/// Serializes a StringHashMap into the tkrzw varint-length-prefixed format:
///   varint(key.len) ++ key_bytes ++ varint(val.len) ++ val_bytes
/// repeated for every entry. Iteration order is used (no sorting). Faithful
/// port of tkrzw SerializeStrMap.
pub fn serializeStrMap(
    records: *const std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,
) ![]u8 {
    // First pass: compute total serialized size.
    var total: usize = 0;
    var it = records.iterator();
    while (it.next()) |entry| {
        total += varint.sizeVarNum(entry.key_ptr.len);
        total += entry.key_ptr.len;
        total += varint.sizeVarNum(entry.value_ptr.len);
        total += entry.value_ptr.len;
    }

    const result = try allocator.alloc(u8, total);
    errdefer allocator.free(result);

    // Second pass: write data.
    var wp: usize = 0;
    var it2 = records.iterator();
    while (it2.next()) |entry| {
        // Use a local scratch buffer large enough for a 10-byte varint.
        var vbuf: [10]u8 = undefined;
        const klen_bytes = varint.writeVarNum(vbuf[0..], entry.key_ptr.len);
        @memcpy(result[wp .. wp + klen_bytes], vbuf[0..klen_bytes]);
        wp += klen_bytes;
        @memcpy(result[wp .. wp + entry.key_ptr.len], entry.key_ptr.*);
        wp += entry.key_ptr.len;
        const vlen_bytes = varint.writeVarNum(vbuf[0..], entry.value_ptr.len);
        @memcpy(result[wp .. wp + vlen_bytes], vbuf[0..vlen_bytes]);
        wp += vlen_bytes;
        @memcpy(result[wp .. wp + entry.value_ptr.len], entry.value_ptr.*);
        wp += entry.value_ptr.len;
    }

    return result;
}

/// Deserializes a varint-length-prefixed byte string produced by serializeStrMap
/// into a StringHashMap. Keys and values are slices into the `serialized` buffer;
/// no copies are made. The caller must ensure `serialized` outlives the returned
/// map. Faithful port of tkrzw DeserializeStrMap.
pub fn deserializeStrMap(
    serialized: []const u8,
    allocator: std.mem.Allocator,
) !std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(allocator);
    errdefer map.deinit();

    var rp: usize = 0;
    while (rp < serialized.len) {
        var key_len: u64 = 0;
        const key_hdr = varint.readVarNum(serialized[rp..], &key_len);
        if (key_hdr == 0) return error.InvalidData;
        rp += key_hdr;

        const key_sz: usize = @intCast(key_len);
        if (rp + key_sz > serialized.len) return error.InvalidData;
        const key = serialized[rp .. rp + key_sz];
        rp += key_sz;

        var val_len: u64 = 0;
        const val_hdr = varint.readVarNum(serialized[rp..], &val_len);
        if (val_hdr == 0) return error.InvalidData;
        rp += val_hdr;

        const val_sz: usize = @intCast(val_len);
        if (rp + val_sz > serialized.len) return error.InvalidData;
        const val = serialized[rp .. rp + val_sz];
        rp += val_sz;

        try map.put(key, val);
    }

    return map;
}

/// Returns true iff pattern occurs anywhere within text.
pub fn strContains(text: []const u8, pattern: []const u8) bool {
    return std.mem.find(u8, text, pattern) != null;
}

// ---------------------------------------------------------------------------
// Pair Serialization (for MemIndex and secondary indices)
// ---------------------------------------------------------------------------

pub const StrPair = struct { first: []const u8, second: []const u8 };

/// Serializes a (first, second) string pair using varint-length-prefixed format:
///   varint(first.len) ++ first_bytes ++ varint(second.len) ++ second_bytes
/// Wire format is identical to SerializeStrMap but for a single pair.
/// Caller must free the result with allocator.free().
/// Faithful port of tkrzw SerializeStrPair.
pub fn serializeStrPair(
    first: []const u8,
    second: []const u8,
    allocator: std.mem.Allocator,
) ![]u8 {
    // Compute total serialized size.
    const first_hdr_size = varint.sizeVarNum(first.len);
    const second_hdr_size = varint.sizeVarNum(second.len);
    const total = first_hdr_size + first.len + second_hdr_size + second.len;

    const result = try allocator.alloc(u8, total);
    errdefer allocator.free(result);

    // Write first varint length.
    var wp: usize = 0;
    var vbuf: [10]u8 = undefined;
    const first_len_bytes = varint.writeVarNum(vbuf[0..], first.len);
    @memcpy(result[wp .. wp + first_len_bytes], vbuf[0..first_len_bytes]);
    wp += first_len_bytes;

    // Write first data.
    @memcpy(result[wp .. wp + first.len], first);
    wp += first.len;

    // Write second varint length.
    const second_len_bytes = varint.writeVarNum(vbuf[0..], second.len);
    @memcpy(result[wp .. wp + second_len_bytes], vbuf[0..second_len_bytes]);
    wp += second_len_bytes;

    // Write second data.
    @memcpy(result[wp .. wp + second.len], second);
    wp += second.len;

    return result;
}

/// Deserializes a pair blob (produced by serializeStrPair) into a (first, second) pair.
/// Both returned slices are zero-copy views into the input buffer.
/// Faithful port of tkrzw DeserializeStrPair.
/// Returns empty slices on truncated or corrupt input rather than panicking.
pub fn deserializeStrPair(data: []const u8) StrPair {
    var rp: usize = 0;

    // Read first length.
    var first_len: u64 = 0;
    const first_hdr = varint.readVarNum(data[rp..], &first_len);
    rp += first_hdr;
    const first_sz = @as(usize, @intCast(first_len));
    if (rp + first_sz > data.len) return .{ .first = "", .second = "" };

    // Read first data.
    const first = data[rp .. rp + first_sz];
    rp += first_sz;

    // Read second length.
    var second_len: u64 = 0;
    const second_hdr = varint.readVarNum(data[rp..], &second_len);
    rp += second_hdr;
    const second_sz = @as(usize, @intCast(second_len));
    if (rp + second_sz > data.len) return .{ .first = first, .second = "" };

    // Read second data.
    const second = data[rp .. rp + second_sz];

    return .{ .first = first, .second = second };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "strToInt basic decimal" {
    try std.testing.expectEqual(@as(i64, 42), strToInt("42", 0));
    try std.testing.expectEqual(@as(i64, 0), strToInt("0", -1));
}

test "strToInt leading and trailing whitespace" {
    try std.testing.expectEqual(@as(i64, 7), strToInt("  7  ", 0));
    try std.testing.expectEqual(@as(i64, 7), strToInt("\t7\n", 0));
}

test "strToInt sign handling" {
    try std.testing.expectEqual(@as(i64, -5), strToInt("-5", 0));
    try std.testing.expectEqual(@as(i64, 5), strToInt("+5", 0));
    try std.testing.expectEqual(@as(i64, -99), strToInt("  -99  ", 0));
}

test "strToInt defval on empty and non-numeric" {
    try std.testing.expectEqual(@as(i64, -1), strToInt("", -1));
    try std.testing.expectEqual(@as(i64, -1), strToInt("abc", -1));
    try std.testing.expectEqual(@as(i64, -1), strToInt("  ", -1));
}

test "strToInt whitespace trimming: std.ascii.whitespace covers 6 chars (deviation from C++ <= 0x20)" {
    // Bytes in std.ascii.whitespace are trimmed: space(0x20), tab(0x09), LF(0x0A), CR(0x0D), VT(0x0B), FF(0x0C)
    try std.testing.expectEqual(@as(i64, 7), strToInt(" 7", 0));
    try std.testing.expectEqual(@as(i64, 7), strToInt("\t7", 0));
    try std.testing.expectEqual(@as(i64, 7), strToInt("\n7", 0));
    try std.testing.expectEqual(@as(i64, 7), strToInt("\r7", 0));
    // Bytes NOT in std.ascii.whitespace (0x01-0x08, 0x0E-0x1F) are NOT trimmed.
    // The original C++ StrToInt trimmed all bytes <= 0x20; this implementation does not.
    try std.testing.expectEqual(@as(i64, 0), strToInt("\x017", 0));
    try std.testing.expectEqual(@as(i64, 0), strToInt("\x1f7", 0));
}

test "intToStrBigEndian and strToIntBigEndian round-trip" {
    var buf: [8]u8 = undefined;

    // data=1, size=8 → [0,0,0,0,0,0,0,1]
    const s1 = intToStrBigEndian(1, 8, &buf);
    try std.testing.expectEqual(@as(usize, 8), s1.len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 1 }, s1);
    try std.testing.expectEqual(@as(u64, 1), strToIntBigEndian(s1));

    // data=256, size=2 → [1,0]
    const s2 = intToStrBigEndian(256, 2, &buf);
    try std.testing.expectEqual(@as(usize, 2), s2.len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 0 }, s2);
    try std.testing.expectEqual(@as(u64, 256), strToIntBigEndian(s2));

    // Round-trip a few more values with size=8.
    const cases = [_]u64{ 0, 1, 255, 65535, 0xDEADBEEFCAFE };
    for (cases) |v| {
        const s = intToStrBigEndian(v, 8, &buf);
        try std.testing.expectEqual(v, strToIntBigEndian(s));
    }
}

test "serializeStrMap and deserializeStrMap round-trip" {
    const allocator = std.testing.allocator;

    var map = std.StringHashMap([]const u8).init(allocator);
    defer map.deinit();
    try map.put("alpha", "one");
    try map.put("beta", "two");
    try map.put("gamma", "three");

    const serialized = try serializeStrMap(&map, allocator);
    defer allocator.free(serialized);

    var result = try deserializeStrMap(serialized, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 3), result.count());
    try std.testing.expectEqualStrings("one", result.get("alpha").?);
    try std.testing.expectEqualStrings("two", result.get("beta").?);
    try std.testing.expectEqualStrings("three", result.get("gamma").?);
}
