//! One print job: encode, send, spool on failure (ADR-0026).
//!
//! The sale is never blocked by a printer. The job returns an error
//! only after the bytes have been safely spooled, so the caller can
//! tell the operator "printed" vs "queued".

const std = @import("std");
const escpos = @import("escpos.zig");
const tcp = @import("tcp.zig");
const spool = @import("spool.zig");

pub fn run(
    io: std.Io,
    host: []const u8,
    port: u16,
    order_no: []const u8,
    total_minor: i64,
    decimals: u8,
    attempts: usize,
) !void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try escpos.receipt(&w, order_no, total_minor, decimals);
    const bytes = w.buffered();

    tcp.sendWithRetry(io, host, port, bytes, attempts) catch {
        var path_buf: [128]u8 = undefined;
        const path = try spool.path(&path_buf, order_no, std.Io.Clock.now(.real, io).toMilliseconds());
        try spool.write(io, path, bytes);
        return error.Spooled;
    };
}

test "job module compiles" {
    _ = run;
}
