const std = @import("std");

pub fn MultiSliceIter(comptime T: type) type {
    return struct {
        slices: []const []const T,
        current_slice: usize = 0,
        position_in_slice: usize = 0,

        pub fn init(slices: []const []const T) @This() {
            return .{ .slices = slices };
        }

        pub fn next(self: *@This()) ?T {
            if (self.current_slice >= self.slices.len) {
                return null;
            }

            if (self.position_in_slice >= self.slices[self.current_slice].len) {
                self.current_slice += 1;
                self.position_in_slice = 0;
                return self.next();
            }

            self.position_in_slice += 1;
            return self.slices[self.current_slice][self.position_in_slice - 1];
        }
    };
}

test "MultiSliceIterator - empty slices" {
    const testing = std.testing;
    var iter = MultiSliceIter(u8).init(&[_][]const u8{});
    try testing.expectEqual(@as(?u8, null), iter.next());
}

test "MultiSliceIterator - single empty slice" {
    const testing = std.testing;
    var iter = MultiSliceIter(u8).init(&[_][]const u8{&[_]u8{}});
    try testing.expectEqual(@as(?u8, null), iter.next());
}

test "MultiSliceIterator - single slice with elements" {
    const testing = std.testing;
    var iter = MultiSliceIter(u8).init(&[_][]const u8{&[_]u8{ 1, 2, 3 }});
    try testing.expectEqual(@as(?u8, 1), iter.next());
    try testing.expectEqual(@as(?u8, 2), iter.next());
    try testing.expectEqual(@as(?u8, 3), iter.next());
    try testing.expectEqual(@as(?u8, null), iter.next());
}

test "MultiSliceIterator - multiple slices" {
    const testing = std.testing;
    var iter = MultiSliceIter(u8).init(&[_][]const u8{
        &[_]u8{ 1, 2 },
        &[_]u8{ 3, 4 },
        &[_]u8{ 5, 6 },
    });

    try testing.expectEqual(@as(?u8, 1), iter.next());
    try testing.expectEqual(@as(?u8, 2), iter.next());
    try testing.expectEqual(@as(?u8, 3), iter.next());
    try testing.expectEqual(@as(?u8, 4), iter.next());
    try testing.expectEqual(@as(?u8, 5), iter.next());
    try testing.expectEqual(@as(?u8, 6), iter.next());
    try testing.expectEqual(@as(?u8, null), iter.next());
}

test "MultiSliceIterator - mixed empty and non-empty slices" {
    const testing = std.testing;
    var iter = MultiSliceIter(u8).init(&[_][]const u8{
        &[_]u8{},
        &[_]u8{ 1, 2 },
        &[_]u8{},
        &[_]u8{3},
        &[_]u8{},
    });

    try testing.expectEqual(@as(?u8, 1), iter.next());
    try testing.expectEqual(@as(?u8, 2), iter.next());
    try testing.expectEqual(@as(?u8, 3), iter.next());
    try testing.expectEqual(@as(?u8, null), iter.next());
}

test "MultiSliceIterator - different types" {
    const testing = std.testing;
    var iter = MultiSliceIter([]const u8).init(&[_][]const []const u8{
        &[_][]const u8{ "hello", "world" },
        &[_][]const u8{ "zig", "lang" },
    });

    try testing.expectEqualStrings("hello", iter.next().?);
    try testing.expectEqualStrings("world", iter.next().?);
    try testing.expectEqualStrings("zig", iter.next().?);
    try testing.expectEqualStrings("lang", iter.next().?);
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
}
