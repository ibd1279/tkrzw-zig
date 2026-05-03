const std = @import("std");

/// Returns the current wall-clock time as seconds since the Unix epoch.
/// Faithful port of tkrzw GetWallTime.
pub fn getWallTime(io: std.Io) f64 {
    const ts = std.Io.Clock.real.now(io);
    return @as(f64, @floatFromInt(ts.nanoseconds)) / 1_000_000_000.0;
}

/// Computes the 100-nanosecond-granularity timestamp base used by pushLast key
/// generation. Returns the number of 100ns units since the Unix epoch, derived
/// from wtime if non-negative or from the wall clock otherwise.
/// Faithful port of tkrzw's pushLast key quantization (WTIME_UNIT = 1e-8 s).
pub fn pushLastKeyBase(wtime: f64, io: std.Io) u64 {
    const t = if (wtime < 0) getWallTime(io) else wtime;
    const base: u64 = @trunc(t * 100_000_000.0);
    return base;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "getWallTime returns a plausible timestamp" {
    const t = getWallTime(std.testing.io);
    // Must be positive and well past a known reference point (2023-11-14 in
    // Unix seconds) to verify the function is not returning zero or epoch.
    try std.testing.expect(t > 1_700_000_000.0);
}

