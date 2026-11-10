//! Retry a spooled print job (ADR-0026).

const std = @import("std");
const tcp = @import("tcp.zig");

/// Read the spooled bytes at `path` and send them. On success the
/// caller may delete the file; on failure it stays for the next sweep.
pub fn retryFile(io: std.Io, path: []const u8, host: []const u8, port: u16, attempts: usize) !void {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var bytes: [8192]u8 = undefined;
    const n = try reader.interface.readSliceShort(&bytes);
    try tcp.sendWithRetry(io, host, port, bytes[0..n], attempts);
}

test "retry module compiles" {
    _ = retryFile;
}
