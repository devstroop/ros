//! The snapshot page header.
//!
//! A snapshot is NDJSON: one header line, then synthetic operation
//! records that describe the current order state. The header names the
//! per-device clocks the snapshot was taken at, and where the next page
//! starts.
//!
//! The operations are ordinary `record.Op` lines on purpose. Applying a
//! snapshot is the same idempotent path as applying a live op - a
//! create is a no-op when the origin is already present, a status only
//! moves forward, and a payment is keyed by the order. The snapshot
//! does not invent a second way to write an order.

const std = @import("std");

/// The header format. A peer refuses a format it does not know rather
/// than guessing at fields.
pub const format_version: u64 = 1;

pub const Header = struct {
    /// The header format, not the snapshot generation.
    snapshot: u64 = format_version,
    /// The generation. It moves when the log is compacted again.
    version: u64,
    /// The vector cursor the snapshot covers, in `dev:clock,...` form.
    clocks: []const u8,
    /// The page the requester asked for.
    after: i64,
    /// The last sequence in this page. The next page asks for `after=next`.
    next: i64,
    /// True when this is the last page.
    done: bool,
};

pub fn encode(writer: *std.Io.Writer, header: Header) !void {
    try std.json.Stringify.value(.{
        .snapshot = header.snapshot,
        .version = header.version,
        .clocks = header.clocks,
        .after = header.after,
        .next = header.next,
        .done = header.done,
    }, .{}, writer);
    try writer.writeByte('\n');
}

/// Read one header line. The returned slices are owned by `arena`.
pub fn decode(arena: std.mem.Allocator, line: []const u8) !Header {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return error.SnapshotEmpty;

    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, trimmed, .{}) catch
        return error.SnapshotNotJson;
    if (root != .object) return error.SnapshotNotAnObject;

    const snapshot = intField(root.object, "snapshot") orelse return error.SnapshotFormatMissing;
    if (snapshot != format_version) return error.SnapshotFormatUnknown;

    const version = intField(root.object, "version") orelse return error.SnapshotVersionMissing;
    if (version <= 0) return error.SnapshotVersionInvalid;

    const clocks = textField(root.object, "clocks") orelse return error.SnapshotClocksMissing;
    const after = intField(root.object, "after") orelse 0;
    const next = intField(root.object, "next") orelse after;
    if (after < 0 or next < after) return error.SnapshotPageInvalid;

    const done = boolField(root.object, "done") orelse return error.SnapshotDoneMissing;

    return .{
        .snapshot = @intCast(snapshot),
        .version = @intCast(version),
        .clocks = clocks,
        .after = after,
        .next = next,
        .done = done,
    };
}

fn intField(object: std.json.ObjectMap, name: []const u8) ?i64 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .integer => |number| number,
        else => null,
    };
}

fn textField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn boolField(object: std.json.ObjectMap, name: []const u8) ?bool {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .bool => |flag| flag,
        else => null,
    };
}

// ------------------------------------------------------------------ tests

test "a snapshot header round-trips and carries the clocks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out = std.Io.Writer.Allocating.init(arena);
    try encode(&out.writer, .{
        .version = 4,
        .clocks = "dev-a:12,dev-b:7",
        .after = 8,
        .next = 16,
        .done = false,
    });

    const header = try decode(arena, out.written());
    try std.testing.expectEqual(format_version, header.snapshot);
    try std.testing.expectEqual(@as(u64, 4), header.version);
    try std.testing.expectEqualStrings("dev-a:12,dev-b:7", header.clocks);
    try std.testing.expectEqual(@as(i64, 8), header.after);
    try std.testing.expectEqual(@as(i64, 16), header.next);
    try std.testing.expect(!header.done);
}

test "a header from another format is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.SnapshotFormatUnknown, decode(arena,
        \\{"snapshot":2,"version":1,"clocks":"","after":0,"next":0,"done":true}
    ));
    try std.testing.expectError(error.SnapshotPageInvalid, decode(arena,
        \\{"snapshot":1,"version":1,"clocks":"","after":4,"next":2,"done":false}
    ));
}
