const std = @import("std");
const testing = std.testing;
const clone = @import("clone.zig");

// Test struct
const Person = struct {
    name: []const u8,
    age: u32,

    pub fn deepClone(self: *const Person, allocator: std.mem.Allocator) Person {
        return .{
            .name = allocator.dupe(u8, self.name) catch unreachable,
            .age = self.age,
        };
    }
};

test "clone basic struct" {
    const allocator = testing.allocator;

    const original = Person{
        .name = "John",
        .age = 30,
    };

    const cloned = try clone.deepClone(Person, &original, allocator);
    defer allocator.free(cloned.name);

    try testing.expectEqualStrings("John", cloned.name);
    try testing.expectEqual(@as(u32, 30), cloned.age);
}

test "clone slice" {
    const allocator = testing.allocator;

    const original = [_]u32{ 1, 2, 3, 4, 5 };
    // NOTE: we need to specify the slice type explictly otherwise
    // zig will put the type to *const [5]u32
    const slice: []const u32 = original[0..];

    const cloned = try clone.deepClone([]const u32, &slice, allocator);
    defer allocator.free(cloned);

    try testing.expectEqual(@as(usize, 5), cloned.len);
    try testing.expectEqual(@as(u32, 1), cloned[0]);
    try testing.expectEqual(@as(u32, 5), cloned[4]);
}

test "clone optional" {
    const allocator = testing.allocator;

    const value: u32 = 42;
    const optional: ?u32 = value;

    const cloned = try clone.deepClone(?u32, &optional, allocator);
    try testing.expectEqual(@as(?u32, 42), cloned);

    const null_optional: ?u32 = null;
    const cloned_null = try clone.deepClone(?u32, &null_optional, allocator);
    try testing.expectEqual(@as(?u32, null), cloned_null);
}
