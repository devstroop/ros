//! The wire tests' aggregator.
//!
//! The package's test root is `src/tests.zig`; it imports this file and
//! the pure core tests. This file lists the wire files, which need
//! nothing but `std`.

test {
    _ = @import("protocol.zig");
    _ = @import("cursor.zig");
    _ = @import("record.zig");
    _ = @import("snapshot.zig");
    _ = @import("outbox.zig");
    _ = @import("server.zig");
    _ = @import("client.zig");
    _ = @import("discovery.zig");
}
