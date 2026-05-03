const std = @import("std");
const str_util = @import("str_util.zig");

// Integer and float limits, matching tkrzw_lib_common.h constants.
pub const INT8MIN: i8 = std.math.minInt(i8);
pub const INT8MAX: i8 = std.math.maxInt(i8);
pub const UINT8MAX: u8 = std.math.maxInt(u8);
pub const INT16MIN: i16 = std.math.minInt(i16);
pub const INT16MAX: i16 = std.math.maxInt(i16);
pub const UINT16MAX: u16 = std.math.maxInt(u16);
pub const INT32MIN: i32 = std.math.minInt(i32);
pub const INT32MAX: i32 = std.math.maxInt(i32);
pub const UINT32MAX: u32 = std.math.maxInt(u32);
pub const INT64MIN: i64 = std.math.minInt(i64);
pub const INT64MAX: i64 = std.math.maxInt(i64);
pub const UINT64MAX: u64 = std.math.maxInt(u64);
pub const DOUBLENAN: f64 = std.math.nan(f64);
pub const DOUBLEINF: f64 = std.math.inf(f64);
pub const DOUBLEMIN: f64 = std.math.floatMin(f64);
pub const DOUBLEMAX: f64 = std.math.floatMax(f64);
pub const FLOATMIN: f32 = std.math.floatMin(f32);
pub const FLOATMAX: f32 = std.math.floatMax(f32);
pub const SIZEMAX: usize = std.math.maxInt(usize);

// Minimum buffer size for numeric string conversion.
pub const NUM_BUFFER_SIZE: i32 = 32;

/// Function pointer type for key comparison, used in B+ tree and sorted data structures.
/// Returns std.math.Order: lt, eq, or gt based on comparison of a vs b.
/// Matches C++ KeyComparator signature.
pub const KeyComparator = *const fn (a: []const u8, b: []const u8) std.math.Order;

/// Default lexicographic byte-wise key comparator. Matches C++ LexicalKeyComparator.
pub fn lexicalKeyComparator(a: []const u8, b: []const u8) std.math.Order {
    return std.mem.order(u8, a, b);
}

/// Case-insensitive lexicographic key comparator. Matches C++ LexicalCaseKeyComparator.
pub fn lexicalCaseKeyComparator(a: []const u8, b: []const u8) std.math.Order {
    const min_len = @min(a.len, b.len);
    for (a[0..min_len], b[0..min_len]) |ac, bc| {
        const al = std.ascii.toLower(ac);
        const bl = std.ascii.toLower(bc);
        if (al < bl) return .lt;
        if (al > bl) return .gt;
    }
    if (a.len < b.len) return .lt;
    if (a.len > b.len) return .gt;
    return .eq;
}

/// Decimal numeric key comparator: parses keys as i64 for numeric ordering.
pub fn decimalKeyComparator(a: []const u8, b: []const u8) std.math.Order {
    const a_num = decimalKeyComparatorParseI64(a);
    const b_num = decimalKeyComparatorParseI64(b);
    if (a_num < b_num) return .lt;
    if (a_num > b_num) return .gt;
    return .eq;
}

fn decimalKeyComparatorParseI64(s: []const u8) i64 {
    if (s.len == 0) return 0;
    var result: i64 = 0;
    var neg = false;
    var i: usize = 0;
    if (s[0] == '-') { neg = true; i = 1; } else if (s[0] == '+') { i = 1; }
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c < '0' or c > '9') break;
        result = result *% 10 +% @as(i64, c - '0');
    }
    return if (neg) -result else result;
}

/// Hexadecimal key comparator: parses keys as u64 hex for numeric ordering.
pub fn hexadecimalKeyComparator(a: []const u8, b: []const u8) std.math.Order {
    const a_num = parseHex(a);
    const b_num = parseHex(b);
    if (a_num < b_num) return .lt;
    if (a_num > b_num) return .gt;
    return .eq;
}

/// Real-number key comparator: parses keys as f64 for numeric ordering.
pub fn realNumberKeyComparator(a: []const u8, b: []const u8) std.math.Order {
    const a_num = str_util.strToDouble(a, 0.0);
    const b_num = str_util.strToDouble(b, 0.0);
    if (a_num < b_num) return .lt;
    if (a_num > b_num) return .gt;
    return .eq;
}

/// Signed big-endian key comparator: interprets keys as big-endian signed integer.
/// Sign-extends based on key length to match C++ SignedBigEndianKeyComparator:
/// 1-byte → i8, 2-byte → i16, 4-byte → i32, otherwise → i64.
pub fn signedBigEndianKeyComparator(a: []const u8, b: []const u8) std.math.Order {
    const a_num = castSignedBigEndian(str_util.strToIntBigEndian(a), a.len);
    const b_num = castSignedBigEndian(str_util.strToIntBigEndian(b), b.len);
    if (a_num < b_num) return .lt;
    if (a_num > b_num) return .gt;
    return .eq;
}

/// Float big-endian key comparator: interprets keys as big-endian f64.
/// NaN is ordered below all non-NaN values; two NaN values are equal.
pub fn floatBigEndianKeyComparator(a: []const u8, b: []const u8) std.math.Order {
    const a_num = @as(f64, @bitCast(str_util.strToIntBigEndian(a)));
    const b_num = @as(f64, @bitCast(str_util.strToIntBigEndian(b)));
    const a_nan = std.math.isNan(a_num);
    const b_nan = std.math.isNan(b_num);
    if (a_nan and b_nan) return .eq;
    if (a_nan) return .lt;
    if (b_nan) return .gt;
    if (a_num < b_num) return .lt;
    if (a_num > b_num) return .gt;
    return .eq;
}

// ---------------------------------------------------------------------------
// Pair Key Comparators (for secondary indices)
// ---------------------------------------------------------------------------

/// Compares two serialized (key, value) pairs lexicographically: first by key, then by value.
/// Used by MemIndex and other secondary index implementations. Zero-copy deserialization.
pub fn pairLexicalKeyComparator(a: []const u8, b: []const u8) std.math.Order {
    const pa = str_util.deserializeStrPair(a);
    const pb = str_util.deserializeStrPair(b);
    const key_cmp = std.mem.order(u8, pa.first, pb.first);
    if (key_cmp != .eq) return key_cmp;
    return std.mem.order(u8, pa.second, pb.second);
}

/// Case-insensitive lexicographic pair comparator: compares keys case-insensitively, then values.
pub fn pairLexicalCaseKeyComparator(a: []const u8, b: []const u8) std.math.Order {
    const pa = str_util.deserializeStrPair(a);
    const pb = str_util.deserializeStrPair(b);
    const key_cmp = compareCaseInsensitive(pa.first, pb.first);
    if (key_cmp != .eq) return key_cmp;
    return std.mem.order(u8, pa.second, pb.second);
}

/// Decimal numeric pair comparator: parses keys as i64 for numeric comparison, then compares values.
pub fn pairDecimalKeyComparator(a: []const u8, b: []const u8) std.math.Order {
    const pa = str_util.deserializeStrPair(a);
    const pb = str_util.deserializeStrPair(b);
    const a_num = strToInt(pa.first);
    const b_num = strToInt(pb.first);
    if (a_num < b_num) return .lt;
    if (a_num > b_num) return .gt;
    return std.mem.order(u8, pa.second, pb.second);
}

/// Hexadecimal pair comparator: parses keys as hex for numeric comparison, then compares values.
pub fn pairHexadecimalKeyComparator(a: []const u8, b: []const u8) std.math.Order {
    const pa = str_util.deserializeStrPair(a);
    const pb = str_util.deserializeStrPair(b);
    const a_num = parseHex(pa.first);
    const b_num = parseHex(pb.first);
    if (a_num < b_num) return .lt;
    if (a_num > b_num) return .gt;
    return std.mem.order(u8, pa.second, pb.second);
}

/// Real (floating-point) pair comparator: parses keys as f64 for numeric comparison, then compares values.
pub fn pairRealNumberKeyComparator(a: []const u8, b: []const u8) std.math.Order {
    const pa = str_util.deserializeStrPair(a);
    const pb = str_util.deserializeStrPair(b);
    const a_num = str_util.strToDouble(pa.first, 0.0);
    const b_num = str_util.strToDouble(pb.first, 0.0);
    if (a_num < b_num) return .lt;
    if (a_num > b_num) return .gt;
    return std.mem.order(u8, pa.second, pb.second);
}

/// Big-endian binary pair comparator: interprets keys as big-endian signed integer (width-sensitive), then compares values.
pub fn pairSignedBigEndianKeyComparator(a: []const u8, b: []const u8) std.math.Order {
    const pa = str_util.deserializeStrPair(a);
    const pb = str_util.deserializeStrPair(b);
    const a_num = castSignedBigEndian(str_util.strToIntBigEndian(pa.first), pa.first.len);
    const b_num = castSignedBigEndian(str_util.strToIntBigEndian(pb.first), pb.first.len);
    if (a_num < b_num) return .lt;
    if (a_num > b_num) return .gt;
    return std.mem.order(u8, pa.second, pb.second);
}

/// IEEE 754 binary pair comparator: interprets keys as big-endian f64, then compares values.
/// NaN is ordered below all non-NaN values; two NaN values are equal.
pub fn pairFloatBigEndianKeyComparator(a: []const u8, b: []const u8) std.math.Order {
    const pa = str_util.deserializeStrPair(a);
    const pb = str_util.deserializeStrPair(b);
    const a_num = @as(f64, @bitCast(str_util.strToIntBigEndian(pa.first)));
    const b_num = @as(f64, @bitCast(str_util.strToIntBigEndian(pb.first)));
    const a_nan = std.math.isNan(a_num);
    const b_nan = std.math.isNan(b_num);
    if (a_nan and b_nan) return .eq;
    if (a_nan) return .lt;
    if (b_nan) return .gt;
    if (a_num < b_num) return .lt;
    if (a_num > b_num) return .gt;
    return std.mem.order(u8, pa.second, pb.second);
}

// -----------

// Helper functions for comparators.

/// Sign-extends a big-endian u64 value based on the original byte-string length,
/// matching C++ SignedBigEndianKeyComparator: 1-byte → i8, 2-byte → i16, 4-byte → i32,
/// default (incl. 8-byte) → raw i64 bitcast.
fn castSignedBigEndian(raw: u64, len: usize) i64 {
    return switch (len) {
        1 => @as(i64, @as(i8, @truncate(@as(i64, @bitCast(raw))))),
        2 => @as(i64, @as(i16, @truncate(@as(i64, @bitCast(raw))))),
        4 => @as(i64, @as(i32, @truncate(@as(i64, @bitCast(raw))))),
        else => @bitCast(raw),
    };
}

fn compareCaseInsensitive(a: []const u8, b: []const u8) std.math.Order {
    const min_len = @min(a.len, b.len);
    for (a[0..min_len], b[0..min_len]) |ac, bc| {
        const ac_lower = std.ascii.toLower(ac);
        const bc_lower = std.ascii.toLower(bc);
        if (ac_lower < bc_lower) return .lt;
        if (ac_lower > bc_lower) return .gt;
    }
    if (a.len < b.len) return .lt;
    if (a.len > b.len) return .gt;
    return .eq;
}

fn strToInt(s: []const u8) i64 {
    return str_util.strToInt(s, 0);
}

fn parseHex(s: []const u8) u64 {
    var result: u64 = 0;
    for (s) |c| {
        result *= 16;
        if (c >= '0' and c <= '9') {
            result += c - '0';
        } else if (c >= 'a' and c <= 'f') {
            result += c - 'a' + 10;
        } else if (c >= 'A' and c <= 'F') {
            result += c - 'A' + 10;
        }
    }
    return result;
}

// Maximum allowable in-memory data size (1 TiB).
pub const MAX_MEMORY_SIZE: i64 = 1 << 40;

/// Status codes matching tkrzw::Status::Code.
pub const Code = enum(i32) {
    SUCCESS = 0,
    UNKNOWN_ERROR = 1,
    SYSTEM_ERROR = 2,
    NOT_IMPLEMENTED_ERROR = 3,
    PRECONDITION_ERROR = 4,
    INVALID_ARGUMENT_ERROR = 5,
    CANCELED_ERROR = 6,
    NOT_FOUND_ERROR = 7,
    PERMISSION_ERROR = 8,
    INFEASIBLE_ERROR = 9,
    DUPLICATION_ERROR = 10,
    BROKEN_DATA_ERROR = 11,
    NETWORK_ERROR = 12,
    APPLICATION_ERROR = 13,
};

/// Returns the canonical name string for a status code.
pub fn codeName(code: Code) []const u8 {
    return switch (code) {
        .SUCCESS => "SUCCESS",
        .UNKNOWN_ERROR => "UNKNOWN_ERROR",
        .SYSTEM_ERROR => "SYSTEM_ERROR",
        .NOT_IMPLEMENTED_ERROR => "NOT_IMPLEMENTED_ERROR",
        .PRECONDITION_ERROR => "PRECONDITION_ERROR",
        .INVALID_ARGUMENT_ERROR => "INVALID_ARGUMENT_ERROR",
        .CANCELED_ERROR => "CANCELED_ERROR",
        .NOT_FOUND_ERROR => "NOT_FOUND_ERROR",
        .PERMISSION_ERROR => "PERMISSION_ERROR",
        .INFEASIBLE_ERROR => "INFEASIBLE_ERROR",
        .DUPLICATION_ERROR => "DUPLICATION_ERROR",
        .BROKEN_DATA_ERROR => "BROKEN_DATA_ERROR",
        .NETWORK_ERROR => "NETWORK_ERROR",
        .APPLICATION_ERROR => "APPLICATION_ERROR",
    };
}

/// A status value combining a code with an optional static message.
///
/// Messages are always string literals (static lifetime). No heap allocation
/// is performed or owned by this struct.
pub const Status = struct {
    code: Code,
    /// Optional diagnostic message. Points to a string literal; never freed.
    message: ?[]const u8,

    /// Constructs a Status with no message.
    pub fn init(code: Code) Status {
        return .{ .code = code, .message = null };
    }

    /// Constructs a Status with a static message string.
    pub fn initMsg(code: Code, message: []const u8) Status {
        return .{ .code = code, .message = message };
    }

    /// Returns true iff the code is SUCCESS.
    pub fn isOk(self: Status) bool {
        return self.code == .SUCCESS;
    }

    /// Merges another status into this one.
    ///
    /// Matches the C++ `|=` operator: self is overwritten by other only when
    /// self is currently SUCCESS and other is not SUCCESS.
    pub fn mergeFrom(self: *Status, other: Status) void {
        if (self.code == .SUCCESS and other.code != .SUCCESS) {
            self.* = other;
        }
    }

    /// Formats as "CODE_NAME: message" or just "CODE_NAME" when no message.
    pub fn format(
        self: Status,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.writeAll(codeName(self.code));
        if (self.message) |msg| {
            if (msg.len > 0) {
                try writer.writeAll(": ");
                try writer.writeAll(msg);
            }
        }
    }
};

test "Status default init is SUCCESS" {
    const s = Status.init(.SUCCESS);
    try std.testing.expect(s.isOk());
    try std.testing.expectEqual(Code.SUCCESS, s.code);
    try std.testing.expect(s.message == null);
}

test "Status isOk false for non-success" {
    const s = Status.init(.NOT_FOUND_ERROR);
    try std.testing.expect(!s.isOk());
}

test "Status initMsg stores message" {
    const s = Status.initMsg(.SYSTEM_ERROR, "disk full");
    try std.testing.expectEqual(Code.SYSTEM_ERROR, s.code);
    try std.testing.expectEqualStrings("disk full", s.message.?);
}

test "codeName returns correct strings" {
    try std.testing.expectEqualStrings("SUCCESS", codeName(.SUCCESS));
    try std.testing.expectEqualStrings("NOT_FOUND_ERROR", codeName(.NOT_FOUND_ERROR));
    try std.testing.expectEqualStrings("APPLICATION_ERROR", codeName(.APPLICATION_ERROR));
}

test "signedBigEndianKeyComparator: width-sensitive sign extension" {
    // 1-byte: 0xFF should be -1 (i8), less than 0x01 (+1)
    try std.testing.expectEqual(std.math.Order.lt, signedBigEndianKeyComparator("\xFF", "\x01"));
    // 1-byte: 0x7F (+127) should be greater than 0x01 (+1)
    try std.testing.expectEqual(std.math.Order.gt, signedBigEndianKeyComparator("\x7F", "\x01"));
    // 2-byte: 0xFFFF → -1 (i16), less than 0x0001 (+1)
    try std.testing.expectEqual(std.math.Order.lt, signedBigEndianKeyComparator("\xFF\xFF", "\x00\x01"));
    // 4-byte: 0xFFFFFFFF → -1 (i32), less than 0x00000001 (+1)
    try std.testing.expectEqual(std.math.Order.lt, signedBigEndianKeyComparator("\xFF\xFF\xFF\xFF", "\x00\x00\x00\x01"));
    // 8-byte: equal
    try std.testing.expectEqual(std.math.Order.eq, signedBigEndianKeyComparator("\x00\x00\x00\x00\x00\x00\x00\x01", "\x00\x00\x00\x00\x00\x00\x00\x01"));
}

test "floatBigEndianKeyComparator: NaN ordering" {
    // Encode NaN as big-endian f64 bits.
    const nan_bits: u64 = @bitCast(std.math.nan(f64));
    var nan_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &nan_buf, nan_bits, .big);
    var one_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &one_buf, @bitCast(@as(f64, 1.0)), .big);

    // NaN == NaN
    try std.testing.expectEqual(std.math.Order.eq, floatBigEndianKeyComparator(&nan_buf, &nan_buf));
    // NaN < 1.0
    try std.testing.expectEqual(std.math.Order.lt, floatBigEndianKeyComparator(&nan_buf, &one_buf));
    // 1.0 > NaN
    try std.testing.expectEqual(std.math.Order.gt, floatBigEndianKeyComparator(&one_buf, &nan_buf));
}

test "mergeFrom only updates SUCCESS with non-SUCCESS" {
    // SUCCESS merges a failure: self should become the failure.
    var s = Status.init(.SUCCESS);
    const err = Status.initMsg(.NOT_FOUND_ERROR, "key missing");
    s.mergeFrom(err);
    try std.testing.expectEqual(Code.NOT_FOUND_ERROR, s.code);
    try std.testing.expectEqualStrings("key missing", s.message.?);

    // Non-SUCCESS merges another failure: self must not change.
    var s2 = Status.init(.SYSTEM_ERROR);
    s2.mergeFrom(Status.init(.INVALID_ARGUMENT_ERROR));
    try std.testing.expectEqual(Code.SYSTEM_ERROR, s2.code);

    // SUCCESS merges SUCCESS: self must remain SUCCESS.
    var s3 = Status.init(.SUCCESS);
    s3.mergeFrom(Status.init(.SUCCESS));
    try std.testing.expect(s3.isOk());
}
