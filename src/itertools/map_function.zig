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

// Test function that doubles a number
fn double(x: u32) u32 {
    return x * 2;
}

test "MapFunc - transform numbers" {
    const testing = std.testing;

    // Create test data
    const numbers = [_]u32{ 1, 2, 3, 4, 5 };

    // Create iterator that doubles each number
    var iter = MapFunc(u32, u32, double).init(&numbers);

    // Check each transformed value
    try testing.expectEqual(@as(?u32, 2), iter.next()); // 1 -> 2
    try testing.expectEqual(@as(?u32, 4), iter.next()); // 2 -> 4
    try testing.expectEqual(@as(?u32, 6), iter.next()); // 3 -> 6
    try testing.expectEqual(@as(?u32, 8), iter.next()); // 4 -> 8
    try testing.expectEqual(@as(?u32, 10), iter.next()); // 5 -> 10

    // Verify iterator is exhausted
    try testing.expectEqual(@as(?u32, null), iter.next());
    try testing.expectEqual(@as(?u32, null), iter.next());
}

// Test function that returns string length
fn stringLen(str: []const u8) usize {
    return str.len;
}
test "MapFunc - transform strings" {
    const testing = std.testing;

    // Create test data
    const strings = [_][]const u8{ "a", "bb", "ccc", "dddd" };

    // Create iterator that gets length of each string
    var iter = MapFunc([]const u8, usize, stringLen).init(&strings);

    // Check each transformed value
    try testing.expectEqual(@as(?usize, 1), iter.next()); // "a" -> 1
    try testing.expectEqual(@as(?usize, 2), iter.next()); // "bb" -> 2
    try testing.expectEqual(@as(?usize, 3), iter.next()); // "ccc" -> 3
    try testing.expectEqual(@as(?usize, 4), iter.next()); // "dddd" -> 4

    // Verify iterator is exhausted
    try testing.expectEqual(@as(?usize, null), iter.next());
}
