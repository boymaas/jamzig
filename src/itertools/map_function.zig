const std = @import("std");

pub fn MapFunc(
    comptime T: type,
    comptime R: type,
    comptime F: fn (T) R,
) type {
    return struct {
        items: []const T,
        index: usize = 0,

        const Self = @This();

        pub fn init(items: []const T) Self {
            return .{
                .items = items,
            };
        }

        pub fn next(self: *Self) ?R {
            if (self.index >= self.items.len) return null;
            const value = F(self.items[self.index]);
            self.index += 1;
            return value;
        }
    };
}

fn double(x: u32) u32 {
    return x * 2;
}

test "MapFunc - transform numbers" {
    const testing = std.testing;

    const numbers = [_]u32{ 1, 2, 3, 4, 5 };

    var iter = MapFunc(u32, u32, double).init(&numbers);

    try testing.expectEqual(@as(?u32, 2), iter.next());
    try testing.expectEqual(@as(?u32, 4), iter.next());
    try testing.expectEqual(@as(?u32, 6), iter.next());
    try testing.expectEqual(@as(?u32, 8), iter.next());
    try testing.expectEqual(@as(?u32, 10), iter.next());

    try testing.expectEqual(@as(?u32, null), iter.next());
    try testing.expectEqual(@as(?u32, null), iter.next());
}

fn stringLen(str: []const u8) usize {
    return str.len;
}

test "MapFunc - transform strings" {
    const testing = std.testing;

    const strings = [_][]const u8{ "a", "bb", "ccc", "dddd" };

    var iter = MapFunc([]const u8, usize, stringLen).init(&strings);

    try testing.expectEqual(@as(?usize, 1), iter.next());
    try testing.expectEqual(@as(?usize, 2), iter.next());
    try testing.expectEqual(@as(?usize, 3), iter.next());
    try testing.expectEqual(@as(?usize, 4), iter.next());

    try testing.expectEqual(@as(?usize, null), iter.next());
}
