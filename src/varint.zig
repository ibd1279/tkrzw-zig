const std = @import("std");

/// Returns the number of bytes required to encode num in variable-length
/// big-endian 7-bit encoding (MSB = continuation bit).
pub fn sizeVarNum(num: u64) usize {
    if (num < (1 << 7)) return 1;
    if (num < (1 << 14)) return 2;
    if (num < (1 << 21)) return 3;
    if (num < (1 << 28)) return 4;
    if (num < (1 << 35)) return 5;
    if (num < (1 << 42)) return 6;
    if (num < (1 << 49)) return 7;
    if (num < (1 << 56)) return 8;
    if (num < (1 << 63)) return 9;
    return 10;
}

/// Encodes num into buf using variable-length 7-bit big-endian encoding.
///
/// Each byte holds 7 bits of the value. The MSB of every byte except the last
/// is set to 1 as a continuation flag. The most-significant groups are written
/// first, matching the tkrzw C++ WriteVarNum encoding.
///
/// Returns the number of bytes written.
/// Asserts that buf is large enough (buf.len >= sizeVarNum(num)).
pub fn writeVarNum(buf: []u8, num: u64) usize {
    const needed = sizeVarNum(num);
    std.debug.assert(buf.len >= needed);

    var wp: usize = 0;
    if (num < (1 << 7)) {
        buf[wp] = @intCast(num);
        wp += 1;
    } else if (num < (1 << 14)) {
        buf[wp] = @intCast((num >> 7) | 0x80);
        wp += 1;
        buf[wp] = @intCast(num & 0x7f);
        wp += 1;
    } else if (num < (1 << 21)) {
        buf[wp] = @intCast((num >> 14) | 0x80);
        wp += 1;
        buf[wp] = @intCast(((num >> 7) & 0x7f) | 0x80);
        wp += 1;
        buf[wp] = @intCast(num & 0x7f);
        wp += 1;
    } else if (num < (1 << 28)) {
        buf[wp] = @intCast((num >> 21) | 0x80);
        wp += 1;
        buf[wp] = @intCast(((num >> 14) & 0x7f) | 0x80);
        wp += 1;
        buf[wp] = @intCast(((num >> 7) & 0x7f) | 0x80);
        wp += 1;
        buf[wp] = @intCast(num & 0x7f);
        wp += 1;
    } else if (num < (1 << 35)) {
        buf[wp] = @intCast((num >> 28) | 0x80);
        wp += 1;
        buf[wp] = @intCast(((num >> 21) & 0x7f) | 0x80);
        wp += 1;
        buf[wp] = @intCast(((num >> 14) & 0x7f) | 0x80);
        wp += 1;
        buf[wp] = @intCast(((num >> 7) & 0x7f) | 0x80);
        wp += 1;
        buf[wp] = @intCast(num & 0x7f);
        wp += 1;
    } else if (num < (1 << 42)) {
        buf[wp] = @intCast((num >> 35) | 0x80);
        wp += 1;
        buf[wp] = @intCast(((num >> 28) & 0x7f) | 0x80);
        wp += 1;
        buf[wp] = @intCast(((num >> 21) & 0x7f) | 0x80);
        wp += 1;
        buf[wp] = @intCast(((num >> 14) & 0x7f) | 0x80);
        wp += 1;
        buf[wp] = @intCast(((num >> 7) & 0x7f) | 0x80);
        wp += 1;
        buf[wp] = @intCast(num & 0x7f);
        wp += 1;
    } else if (num < (1 << 49)) {
        buf[wp] = @intCast((num >> 42) | 0x80);
        wp += 1;
        buf[wp] = @intCast(((num >> 35) & 0x7f) | 0x80);
        wp += 1;
        buf[wp] = @intCast(((num >> 28) & 0x7f) | 0x80);
        wp += 1;
        buf[wp] = @intCast(((num >> 21) & 0x7f) | 0x80);
        wp += 1;
        buf[wp] = @intCast(((num >> 14) & 0x7f) | 0x80);
        wp += 1;
        buf[wp] = @intCast(((num >> 7) & 0x7f) | 0x80);
        wp += 1;
        buf[wp] = @intCast(num & 0x7f);
        wp += 1;
    } else if (num < (1 << 56)) {
        buf[wp] = @intCast((num >> 49) | 0x80);
        wp += 1;
        buf[wp] = @intCast(((num >> 42) & 0x7f) | 0x80);
        wp += 1;
        buf[wp] = @intCast(((num >> 35) & 0x7f) | 0x80);
        wp += 1;
        buf[wp] = @intCast(((num >> 28) & 0x7f) | 0x80);
        wp += 1;
        buf[wp] = @intCast(((num >> 21) & 0x7f) | 0x80);
        wp += 1;
        buf[wp] = @intCast(((num >> 14) & 0x7f) | 0x80);
        wp += 1;
        buf[wp] = @intCast(((num >> 7) & 0x7f) | 0x80);
        wp += 1;
        buf[wp] = @intCast(num & 0x7f);
        wp += 1;
    } else if (num < (1 << 63)) {
        buf[wp] = @intCast((num >> 56) | 0x80);
        wp += 1;
        buf[wp] = @intCast(((num >> 49) & 0x7f) | 0x80);
        wp += 1;
        buf[wp] = @intCast(((num >> 42) & 0x7f) | 0x80);
        wp += 1;
        buf[wp] = @intCast(((num >> 35) & 0x7f) | 0x80);
        wp += 1;
        buf[wp] = @intCast(((num >> 28) & 0x7f) | 0x80);
        wp += 1;
        buf[wp] = @intCast(((num >> 21) & 0x7f) | 0x80);
        wp += 1;
        buf[wp] = @intCast(((num >> 14) & 0x7f) | 0x80);
        wp += 1;
        buf[wp] = @intCast(((num >> 7) & 0x7f) | 0x80);
        wp += 1;
        buf[wp] = @intCast(num & 0x7f);
        wp += 1;
    } else {
        // Full 64-bit value: 10 bytes.
        buf[wp] = @intCast((num >> 63) | 0x80);
        wp += 1;
        buf[wp] = @intCast(((num >> 56) & 0x7f) | 0x80);
        wp += 1;
        buf[wp] = @intCast(((num >> 49) & 0x7f) | 0x80);
        wp += 1;
        buf[wp] = @intCast(((num >> 42) & 0x7f) | 0x80);
        wp += 1;
        buf[wp] = @intCast(((num >> 35) & 0x7f) | 0x80);
        wp += 1;
        buf[wp] = @intCast(((num >> 28) & 0x7f) | 0x80);
        wp += 1;
        buf[wp] = @intCast(((num >> 21) & 0x7f) | 0x80);
        wp += 1;
        buf[wp] = @intCast(((num >> 14) & 0x7f) | 0x80);
        wp += 1;
        buf[wp] = @intCast(((num >> 7) & 0x7f) | 0x80);
        wp += 1;
        buf[wp] = @intCast(num & 0x7f);
        wp += 1;
    }

    return wp;
}

/// Decodes a variable-length integer from buf with bounds checking.
///
/// Writes the decoded value into np. Returns the number of bytes consumed,
/// or 0 if buf is too short to contain a complete encoding (np is set to 0).
pub fn readVarNum(buf: []const u8, np: *u64) usize {
    var num: u64 = 0;
    var rp: usize = 0;
    while (true) {
        if (rp >= buf.len) {
            np.* = 0;
            return 0;
        }
        const c: u64 = buf[rp];
        rp += 1;
        num = (num << 7) + (c & 0x7f);
        if (c < 0x80) break;
    }
    np.* = num;
    return rp;
}

/// Decodes a variable-length integer from a pointer with no bounds checking.
///
/// The caller must guarantee that buf points to a complete, valid encoding.
/// Returns the number of bytes consumed and writes the decoded value into np.
pub fn readVarNumUnsafe(buf: [*]const u8, np: *u64) usize {
    var num: u64 = 0;
    var rp: usize = 0;
    while (true) {
        const c: u64 = buf[rp];
        rp += 1;
        num = (num << 7) + (c & 0x7f);
        if (c < 0x80) break;
    }
    np.* = num;
    return rp;
}

test "sizeVarNum boundary values" {
    try std.testing.expectEqual(@as(usize, 1), sizeVarNum(0));
    try std.testing.expectEqual(@as(usize, 1), sizeVarNum(127));
    try std.testing.expectEqual(@as(usize, 2), sizeVarNum(128));
    try std.testing.expectEqual(@as(usize, 2), sizeVarNum(16383));
    try std.testing.expectEqual(@as(usize, 3), sizeVarNum(16384));
    try std.testing.expectEqual(@as(usize, 10), sizeVarNum(std.math.maxInt(u64)));
}

test "writeVarNum length matches sizeVarNum" {
    const cases = [_]u64{ 0, 1, 127, 128, 16383, 16384, std.math.maxInt(u64) };
    var buf: [10]u8 = undefined;
    for (cases) |v| {
        const written = writeVarNum(&buf, v);
        try std.testing.expectEqual(sizeVarNum(v), written);
    }
}

test "round-trip encode/decode with readVarNum" {
    const cases = [_]u64{ 0, 1, 127, 128, 16383, 16384, std.math.maxInt(u64) };
    var buf: [10]u8 = undefined;
    for (cases) |v| {
        const written = writeVarNum(&buf, v);
        var decoded: u64 = 0;
        const read = readVarNum(buf[0..written], &decoded);
        try std.testing.expectEqual(written, read);
        try std.testing.expectEqual(v, decoded);
    }
}

test "round-trip encode/decode with readVarNumUnsafe" {
    const cases = [_]u64{ 0, 1, 127, 128, 16383, 16384, std.math.maxInt(u64) };
    var buf: [10]u8 = undefined;
    for (cases) |v| {
        const written = writeVarNum(&buf, v);
        var decoded: u64 = 0;
        const read = readVarNumUnsafe(&buf, &decoded);
        try std.testing.expectEqual(written, read);
        try std.testing.expectEqual(v, decoded);
    }
}

test "readVarNum returns 0 on truncated input" {
    // 128 encodes as 2 bytes: [0x81, 0x00]. Feeding only 1 byte should fail.
    var buf: [10]u8 = undefined;
    _ = writeVarNum(&buf, 128);
    var decoded: u64 = 0xdeadbeef;
    const read = readVarNum(buf[0..1], &decoded);
    try std.testing.expectEqual(@as(usize, 0), read);
    try std.testing.expectEqual(@as(u64, 0), decoded);
}
