const std = @import("std");
const state = @import("../state.zig");
const serialize = @import("../codec.zig").serialize;

pub fn encode(beta: *const state.Beta, writer: anytype) !void {
    try serialize(state.Beta, .{}, writer, beta.*);
}

test "Beta serialization" {
    const testing = std.testing;
    const allocator = std.testing.allocator;

    var beta = try state.Beta.init(allocator, 10);
    defer beta.deinit();

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    try encode(&beta, buffer.writer());

    try testing.expect(buffer.items.len > 0);
}
