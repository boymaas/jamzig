const std = @import("std");
const types = @import("../types.zig");

pub fn encode(tau: types.TimeSlot, writer: anytype) !void {
    try writer.writeInt(u32, tau, .little);
}

test "encode" {
    var buffer: [4]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    const writer = fbs.writer();

    const test_tau: types.TimeSlot = 42;
    try encode(test_tau, writer);

    // Check if the encoded value is correct (little-endian u32)
    try std.testing.expectEqual(@as(u32, 42), std.mem.readInt(u32, &buffer, .little));
}
