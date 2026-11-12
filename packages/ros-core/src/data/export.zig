//! Small export helpers for back-office data.

const std = @import("std");
const domain = @import("../domain/models.zig");

/// Write refunds as CSV. Amounts are minor units.
pub fn refundsCsv(writer: *std.Io.Writer, refunds: []const domain.Refund) !void {
    try writer.writeAll("id,payment_id,order_id,amount_minor,reason,refunded_at\n");
    for (refunds) |r| {
        try writer.print("{d},{d},{d},{d},\"{s}\",{d}\n", .{
            r.id, r.payment_id, r.order_id, r.amount_minor, r.reason, r.refunded_at,
        });
    }
}

test "refundsCsv header" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try refundsCsv(&w, &.{});
    try std.testing.expectEqualStrings("id,payment_id,order_id,amount_minor,reason,refunded_at\n", w.buffered());
}

test "refundsCsv scales to a large refund log" {
    const allocator = std.testing.allocator;
    const count: usize = 10_000;
    const refunds = try allocator.alloc(domain.Refund, count);
    defer allocator.free(refunds);
    for (refunds, 0..) |*r, i| {
        r.* = .{
            .id = @intCast(i + 1),
            .payment_id = @intCast(i + 1),
            .order_id = @intCast(i + 1),
            .amount_minor = 1234,
            .reason = "voided line",
            .refunded_at = 1_700_000_000_000,
        };
    }
    const buf = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(buf);
    var w = std.Io.Writer.fixed(buf);
    const start = std.time.nanoTimestamp();
    try refundsCsv(&w, refunds);
    const elapsed_ms = @divTrunc(std.time.nanoTimestamp() - start, 1_000_000);
    // Guard against accidental O(n^2) regressions: 10k rows must
    // finish well under a second on any supported machine.
    try std.testing.expect(elapsed_ms < 1000);
    try std.testing.expect(w.buffered().len > count);
}

/// Write payments as CSV. Amounts are minor units.
pub fn paymentsCsv(writer: *std.Io.Writer, payments: []const domain.Payment) !void {
    try writer.writeAll("id,order_id,order_no,mode,amount_minor,reference,paid_at\n");
    for (payments) |p| {
        try writer.print("{d},{d},\"{s}\",{d},{d},\"{s}\",{d}\n", .{
            p.id, p.order_id, p.order_no, @intFromEnum(p.mode), p.amount_minor, p.reference, p.paid_at,
        });
    }
}

/// Write orders as CSV. Amounts are minor units.
pub fn ordersCsv(writer: *std.Io.Writer, orders: []const domain.Order) !void {
    try writer.writeAll("id,order_no,status,total_minor,placed_at\n");
    for (orders) |o| {
        try writer.print("{d},\"{s}\",{d},{d},{d}\n", .{
            o.id, o.order_no, o.status_code, o.total_minor, o.placed_at,
        });
    }
}
