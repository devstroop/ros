//! Parse a printer address of the form "host:port".

const std = @import("std");

pub fn parse(text: []const u8, default_port: u16) struct { host: []const u8, port: u16 } {
    if (std.mem.lastIndexOfScalar(u8, text, ':')) |idx| {
        const host = text[0..idx];
        const port_text = text[idx + 1 ..];
        const port = std.fmt.parseInt(u16, port_text, 10) catch default_port;
        return .{ .host = host, .port = port };
    }
    return .{ .host = text, .port = default_port };
}

test "parse host:port" {
    const r = parse("192.168.1.9:9100", 9100);
    try std.testing.expectEqualStrings("192.168.1.9", r.host);
    try std.testing.expectEqual(@as(u16, 9100), r.port);
}

test "parse host only" {
    const r = parse("printer.local", 9100);
    try std.testing.expectEqualStrings("printer.local", r.host);
    try std.testing.expectEqual(@as(u16, 9100), r.port);
}
