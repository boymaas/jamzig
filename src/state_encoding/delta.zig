const std = @import("std");
const state = @import("../state.zig");
const serialize = @import("../codec.zig").serialize;

pub fn encode(delta: *const state.Delta, writer: anytype) !void {
    try serialize(state.Delta, .{}, writer, delta.*);
}

test "Delta serialization" {
    const testing = std.testing;
    const allocator = std.testing.allocator;

    var delta = state.Delta.init(allocator);
    defer delta.deinit();

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    try encode(&delta, buffer.writer());

    try testing.expect(buffer.items.len > 0);
}
