const std = @import("std");
const testing = std.testing;
const clone = @import("clone.zig");

test "clone basic nested struct" {
    const Task = struct {
        name: []const u8,
    };

    // Test struct
    const Person = struct {
        name: []const u8,
        age: u32,
        tasks: []const Task,

        pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
            allocator.free(self.name);
            for (self.tasks) |task| {
                allocator.free(task.name);
            }
            allocator.free(self.tasks);
        }
    };

    const allocator = testing.allocator;

    const original = Person{
        .name = "John",
        .age = 30,
        .tasks = &[_]Task{ .{ .name = "Task1" }, .{ .name = "Task2" } },
    };

    const cloned = try clone.deepClone(Person, &original, allocator);
    defer cloned.deinit(allocator);
    //
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

test "clone struct with slices" {
    const allocator = testing.allocator;

    const Book = struct {
        title: []u8,
        authors: [][]u8,
        tags: []u8,
    };

    var original = Book{
        .title = try std.fmt.allocPrint(allocator, "The Book", .{}),
        .authors = try allocator.alloc([]u8, 2),
        .tags = try std.fmt.allocPrint(allocator, "fiction,adventure", .{}),
    };
    original.authors[0] = try std.fmt.allocPrint(allocator, "Author 1", .{});
    original.authors[1] = try std.fmt.allocPrint(allocator, "Author 2", .{});
    defer {
        allocator.free(original.title);
        for (original.authors) |author| {
            allocator.free(author);
        }
        allocator.free(original.authors);
        allocator.free(original.tags);
    }

    const cloned = try clone.deepClone(Book, &original, allocator);
    // Need to free all allocated memory
    defer {
        allocator.free(cloned.title);
        for (cloned.authors) |author| {
            allocator.free(author);
        }
        allocator.free(cloned.authors);
        allocator.free(cloned.tags);
    }

    try testing.expectEqualStrings("The Book", cloned.title);
    try testing.expectEqual(@as(usize, 2), cloned.authors.len);
    try testing.expectEqualStrings("Author 1", cloned.authors[0]);
    try testing.expectEqualStrings("Author 2", cloned.authors[1]);
    try testing.expectEqualStrings("fiction,adventure", cloned.tags);

    // Verify the memory is actually different
    try testing.expect(cloned.title.ptr != original.title.ptr);
    try testing.expect(cloned.authors.ptr != original.authors.ptr);
    try testing.expect(cloned.authors[0].ptr != original.authors[0].ptr);
    try testing.expect(cloned.tags.ptr != original.tags.ptr);
}

test "clone struct with const slices" {
    const allocator = testing.allocator;

    const ConstBook = struct {
        title: []const u8,
        authors: []const []const u8,
        tags: []const u8,
    };

    var original = ConstBook{
        .title = "The Book",
        .authors = &[_][]const u8{ "Author 1", "Author 2" },
        .tags = "fiction,adventure",
    };

    const cloned = try clone.deepClone(ConstBook, &original, allocator);
    defer {
        allocator.free(cloned.title);
        for (cloned.authors) |author| {
            allocator.free(author);
        }
        allocator.free(cloned.authors);
        allocator.free(cloned.tags);
    }

    try testing.expectEqualStrings("The Book", cloned.title);
    try testing.expectEqual(@as(usize, 2), cloned.authors.len);
    try testing.expectEqualStrings("Author 1", cloned.authors[0]);
    try testing.expectEqualStrings("Author 2", cloned.authors[1]);
    try testing.expectEqualStrings("fiction,adventure", cloned.tags);

    // Verify the memory is actually different
    try testing.expect(cloned.title.ptr != original.title.ptr);
    try testing.expect(cloned.authors.ptr != original.authors.ptr);
    try testing.expect(cloned.authors[0].ptr != original.authors[0].ptr);
    try testing.expect(cloned.tags.ptr != original.tags.ptr);
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
