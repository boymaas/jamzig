const std = @import("std");

pub fn SliceIter(comptime T: type) type {
    return struct {
        slice: []const T,
        position: usize = 0,

        pub fn init(slice: []const T) @This() {
            return .{ .slice = slice };
        }

        pub fn next(self: *@This()) ?T {
            if (self.position >= self.slice.len) {
                return null;
            }
            self.position += 1;
            return self.slice[self.position - 1];
        }
    };
}

test "SliceIter - empty slice" {
    const testing = std.testing;
    var iter = SliceIter(u8).init(&[_]u8{});
    try testing.expectEqual(@as(?u8, null), iter.next());
}

test "SliceIter - slice with elements" {
    const testing = std.testing;
    var iter = SliceIter(u8).init(&[_]u8{ 1, 2, 3 });
    try testing.expectEqual(@as(?u8, 1), iter.next());
    try testing.expectEqual(@as(?u8, 2), iter.next());
    try testing.expectEqual(@as(?u8, 3), iter.next());
    try testing.expectEqual(@as(?u8, null), iter.next());
}

test "SliceIter - string slice" {
    const testing = std.testing;
    var iter = SliceIter(u8).init("hello");
    try testing.expectEqual(@as(?u8, 'h'), iter.next());
    try testing.expectEqual(@as(?u8, 'e'), iter.next());
    try testing.expectEqual(@as(?u8, 'l'), iter.next());
    try testing.expectEqual(@as(?u8, 'l'), iter.next());
    try testing.expectEqual(@as(?u8, 'o'), iter.next());
    try testing.expectEqual(@as(?u8, null), iter.next());
}

test "SliceIter - complex types" {
    const testing = std.testing;
    var iter = SliceIter([]const u8).init(&[_][]const u8{ "hello", "world" });
    try testing.expectEqualStrings("hello", iter.next().?);
    try testing.expectEqualStrings("world", iter.next().?);
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
}
