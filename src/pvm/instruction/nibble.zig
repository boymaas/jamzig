const std = @import("std");

pub inline fn getHighNibble(byte: u8) u4 {
    return @intCast((byte & 0xf0) >> 4);
}

pub inline fn getLowNibble(byte: u8) u4 {
    return @intCast(byte & 0x0f);
}

test "pvm:args:nibble: getHighNibble" {
    try std.testing.expectEqual(@as(u4, 0x0), getHighNibble(0x0F));
    try std.testing.expectEqual(@as(u4, 0x1), getHighNibble(0x1F));
    try std.testing.expectEqual(@as(u4, 0xA), getHighNibble(0xAB));
    try std.testing.expectEqual(@as(u4, 0xF), getHighNibble(0xFF));
}

test "pvm:args:nibble:getLowNibble" {
    try std.testing.expectEqual(@as(u4, 0xF), getLowNibble(0x0F));
    try std.testing.expectEqual(@as(u4, 0x5), getLowNibble(0x15));
    try std.testing.expectEqual(@as(u4, 0xB), getLowNibble(0xAB));
    try std.testing.expectEqual(@as(u4, 0x0), getLowNibble(0xF0));
}
