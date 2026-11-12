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
    var buf = try allocator.alloc(u8, 1024 * 1024);
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
