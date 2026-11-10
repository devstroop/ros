//! Spool file helpers for failed print jobs (ADR-0026).
//!
//! A sale is never blocked by a printer. When the TCP send fails the
//! bytes are written here and retried later. The path is deterministic
//! from the order and the time so a retry is idempotent.

const std = @import("std");

/// Build a spool path into `buf`. Returns the slice written.
pub fn path(buf: []u8, order_no: []const u8, at: i64) ![]u8 {
    return std.fmt.bufPrint(buf, "spool/{s}-{d}.prn", .{ order_no, at });
}

/// Write `bytes` to `path` (creating parent dirs is the caller's job).
pub fn write(io: std.Io, path_str: []const u8, bytes: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path_str, .data = bytes });
}

test "spool path is deterministic" {
    var buf: [128]u8 = undefined;
    const p = try path(&buf, "A-1", 1700000000000);
    try std.testing.expectEqualStrings("spool/A-1-1700000000000.prn", p);
}
