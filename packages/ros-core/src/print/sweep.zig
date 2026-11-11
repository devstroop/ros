//! Retry every spooled print job in a directory (ADR-0026).

const std = @import("std");
const retry = @import("retry.zig");

pub fn sweepDir(io: std.Io, dir_path: []const u8, host: []const u8, port: u16, attempts: usize) void {
    var dir = std.Io.Dir.openDir(std.Io.Dir.cwd(), io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".prn")) continue;

        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
        retry.retryFile(io, path, host, port, attempts) catch continue;
        // Best effort: a successful retry may remove the spool file.
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
    }
}

test "sweep module compiles" {
    _ = sweepDir;
}
