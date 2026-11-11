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
