//! TCP :9100 transport for raw printers (ADR-0026).
//!
//! The encoder writes bytes; this module moves them onto a TCP socket.
//! A failed job is the caller's problem to spool and retry - this
//! function returns the error and does not block the sale.

const std = @import("std");

/// Send `bytes` to a raw printer on `host`:`port` (usually 9100).
pub fn send(io: std.Io, host: []const u8, port: u16, bytes: []const u8) !void {
    var address = try std.Io.net.IpAddress.parseIp4(host, port);
    const stream = try std.Io.net.IpAddress.connect(&address, io, .{
        .mode = .stream,
        .protocol = .tcp,
    });
    defer stream.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = stream.writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}


/// Send with a small number of retries. Returns the last error if all
/// attempts fail. A sale is never blocked by this: the caller spools
/// on failure.
pub fn sendWithRetry(io: std.Io, host: []const u8, port: u16, bytes: []const u8, attempts: usize) !void {
    var last_err: anyerror = error.ConnectionFailed;
    var i: usize = 0;
    while (i < attempts) : (i += 1) {
        send(io, host, port, bytes) catch |err| {
            last_err = err;
            if (i + 1 < attempts) std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
            continue;
        };
        return;
    }
    return last_err;
}
