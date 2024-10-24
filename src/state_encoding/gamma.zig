const std = @import("std");
const state = @import("../state.zig");
const serialize = @import("../codec.zig").serialize;

pub fn encode(gamma: *const state.Gamma, writer: anytype) !void {
    try serialize(state.Gamma, .{}, writer, gamma.*);
}

//  _____         _   _
// |_   _|__  ___| |_(_)_ __   __ _
//   | |/ _ \/ __| __| | '_ \ / _` |
//   | |  __/\__ \ |_| | | | | (_| |
//   |_|\___||___/\__|_|_| |_|\__, |
//                            |___/

test "encode" {
    const testing = std.testing;
    const allocator = std.testing.allocator;

    // Create a sample Gamma instance
    var gamma = try state.Gamma.init(allocator);
    defer gamma.deinit(allocator);

    // Create a buffer to store the encoded data
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    // Encode the Gamma instance
    try encode(&gamma, buffer.writer());

    // Verify the encoded output
    // Here, we're just checking if the buffer is not empty.
    try testing.expect(buffer.items.len > 0);

    // TODO: add more detailed tests
}
