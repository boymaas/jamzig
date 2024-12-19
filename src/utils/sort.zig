/// Sorting utilities
/// This module provides generic sorting functionality for various types.
/// It includes a function to create a less-than comparator for slices of different types,
/// which can be used with Zig's standard library sorting functions.
const std = @import("std");

pub fn makeLessThanSliceOfFn(comptime T: type) fn (void, T, T) bool {
    return struct {
        pub fn lessThan(_: void, a: T, b: T) bool {
            return switch (@typeInfo(T)) {
                .array => |info| std.mem.lessThan(info.child, &a, &b),
                .pointer => |info| switch (info.size) {
                    .Slice => std.mem.lessThan(info.child, a, b),
                    else => @compileError("Unsupported pointer type"),
                },
                else => a < b,
            };
        }
    }.lessThan;
}

pub const lessThanSliceOfU8 = makeLessThanSliceOfFn(u8);
pub const ascHashFn = makeLessThanSliceOfFn([32]u8);

const testing = std.testing;

test makeLessThanSliceOfFn {
    const lessThanI32 = makeLessThanSliceOfFn(i32);
    try testing.expect(lessThanI32({}, 1, 2));
    try testing.expect(!lessThanI32({}, 2, 1));
    try testing.expect(!lessThanI32({}, 1, 1));

    const lessThanF32 = makeLessThanSliceOfFn(f32);
    try testing.expect(lessThanF32({}, 1.0, 2.0));
    try testing.expect(!lessThanF32({}, 2.0, 1.0));
    try testing.expect(!lessThanF32({}, 1.0, 1.0));

    const lessThanSlice = makeLessThanSliceOfFn([]const u8);
    try testing.expect(lessThanSlice({}, "abc", "def"));
    try testing.expect(!lessThanSlice({}, "def", "abc"));
    try testing.expect(!lessThanSlice({}, "abc", "abc"));
}
