const std = @import("std");

pub extern fn is_whitespace(c: u8) bool;

pub fn main() !void {
    const chars = [_]u8{ 'a', ' ', 'A', 0x09, 0x0A, 0x0D };

    for (chars, 0..) |char, idx| {
        std.debug.print("{}: is '{c}' whitespace?: {}\n", .{ idx, char, is_whitespace(char) });
    }
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "failing test" {
    // try std.testing.expectEqual(@as(i32, 42), 43);
}
