const std = @import("std");
const diff = @import("diff.zig");

pub fn expectFormattedEqual(actual: anytype, expected: anytype) !void {
    const T = @TypeOf(actual);
    try diff.expectFormattedEqual(T, std.testing.allocator, actual, expected);
}

pub fn expectTypesFmtEqual(actual: anytype, expected: anytype) !void {
    const T = @TypeOf(actual);
    try diff.expectTypesFmtEqual(T, std.testing.allocator, actual, expected);
}
