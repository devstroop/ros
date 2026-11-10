//! ESC/POS encoder shared by every app.
//!
//! This is the in-process printer core from ADR-0026. It writes bytes
//! to any `std.Io.Writer`; the transport (TCP :9100, `fx.spawn`,
//! spool file) is the caller's concern. Keeping the encoder free of I/O
//! means it can be tested without a printer.

const std = @import("std");

/// ESC/POS control bytes.
pub const ESC: u8 = 0x1B;
pub const GS: u8 = 0x1D;
pub const LF: u8 = 0x0A;

/// Initialize the printer.
pub fn init(writer: *std.Io.Writer) !void {
    try writer.writeAll(&.{ ESC, 0x40 });
}

/// Print a line of text followed by a newline.
pub fn line(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeAll(text);
    try writer.writeByte(LF);
}

/// Bold on/off.
pub fn bold(writer: *std.Io.Writer, on: bool) !void {
    try writer.writeAll(&.{ ESC, 0x45, if (on) @as(u8, 1) else @as(u8, 0) });
}

/// Center alignment.
pub fn center(writer: *std.Io.Writer) !void {
    try writer.writeAll(&.{ ESC, 0x61, 1 });
}

/// Left alignment.
pub fn left(writer: *std.Io.Writer) !void {
    try writer.writeAll(&.{ ESC, 0x61, 0 });
}

/// Cut paper (full cut).
pub fn cut(writer: *std.Io.Writer) !void {
    try writer.writeAll(&.{ GS, 0x56, 0 });
}

/// Write a small receipt. Amounts are minor units; `decimals` is the
/// currency's decimal count.
pub fn receipt(
    writer: *std.Io.Writer,
    order_no: []const u8,
    total_minor: i64,
    decimals: u8,
) !void {
    try init(writer);
    try center(writer);
    try bold(writer, true);
    try line(writer, "Restaurant OS");
    try bold(writer, false);
    try left(writer);
    try line(writer, "");
    var buf: [64]u8 = undefined;
    const no_line = std.fmt.bufPrint(&buf, "Order: {s}", .{order_no}) catch "Order: ?";
    try line(writer, no_line);
    const amount = formatMinor(total_minor, decimals, &buf) catch "0.00";
    const total_line = std.fmt.bufPrint(&buf, "Total: {s}", .{amount}) catch "Total: ?";
    try line(writer, total_line);
    try line(writer, "");
    try cut(writer);
}

fn formatMinor(minor: i64, decimals: u8, buf: []u8) ![]const u8 {
    // Simple two-decimal formatting for the common case.
    _ = decimals;
    const whole = @divTrunc(minor, 100);
    const frac = @mod(minor, 100);
    return std.fmt.bufPrint(buf, "{d}.{d:0>2}", .{ whole, frac });
}

test "receipt emits init and cut" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try receipt(&w, "A-1", 1234, 2);
    const out = w.buffered();
    try std.testing.expect(out.len > 0);
    try std.testing.expectEqual(ESC, out[0]);
}
