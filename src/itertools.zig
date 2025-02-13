const std = @import("std");

/// Collects iterator values into an owned slice
pub fn collectIter(
    comptime T: type,
    allocator: std.mem.Allocator,
    iterator: anytype,
) ![]T {
    var list = std.ArrayList(T).init(allocator);
    errdefer list.deinit();

    while (try iterator.next()) |item| {
        try list.append(item);
    }

    return try list.toOwnedSlice();
}

test "collectIter - basic usage" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create a simple number iterator
    const NumberIterator = struct {
        current: u32 = 0,
        max: u32,

        pub fn init(max: u32) @This() {
            return .{ .max = max };
        }

        pub fn next(self: *@This()) !?u32 {
            if (self.current >= self.max) return null;
            const value = self.current;
            self.current += 1;
            return value;
        }
    };

    // Test collecting numbers 0 through 4
    var iter = NumberIterator.init(5);
    const numbers = try collectIter(u32, allocator, &iter);
    defer allocator.free(numbers);

    try testing.expectEqual(@as(usize, 5), numbers.len);
    for (numbers, 0..) |num, i| {
        try testing.expectEqual(@as(u32, @intCast(i)), num);
    }
}

/// Iterates over a slice of T and returns a field on the type
pub fn MapIterator(T: type, comptime accessor: []const u8) type {
    return struct {
        slice: []T,
        position: usize = 0,

        pub fn init(slice: []T) @This() {
            return .{ .slice = slice };
        }

        pub fn next(self: *@This()) ?NestedFieldType(T, accessor) {
            if (self.position >= self.slice.len) return null;

            const result = self.slice[self.position];
            self.position += 1;

            return accessNestedField(result, accessor);
        }
    };
}

/// comptime recursive discovery of the type
fn NestedFieldType(comptime T: type, comptime field: []const u8) type {
    // If we have no dots, this is a direct field access
    if (std.mem.indexOfScalar(u8, field, '.') == null) {
        const accessor = std.meta.stringToEnum(std.meta.FieldEnum(T), field).?;
        // Get the type of the first field
        return std.meta.FieldType(T, accessor);
    }

    // For nested fields, we split at the first dot
    const first_dot = std.mem.indexOfScalar(u8, field, '.').?;
    const first_field = field[0..first_dot];
    const remaining = field[first_dot + 1 ..];

    const accessor = std.meta.stringToEnum(std.meta.FieldEnum(T), first_field).?;

    // Get the type of the first field
    const NextType = std.meta.FieldType(T, accessor);

    // Recursively get the type of the remaining path
    return NestedFieldType(NextType, remaining);
}

fn accessNestedField(value: anytype, comptime field: []const u8) NestedFieldType(@TypeOf(value), field) {
    const dot_count = comptime std.mem.count(u8, field, ".");

    if (dot_count == 0) {
        return @field(value, field);
    } else if (dot_count == 1) {
        const f = comptime blk: {
            var it = std.mem.splitScalar(u8, field, '.');
            const f1 = it.next().?;
            const f2 = it.next().?;
            break :blk .{ f1, f2 };
        };
        return @field(@field(value, f[0]), f[1]);
    } else if (dot_count == 2) {
        // Handle three levels deep
        const f = comptime blk: {
            var it = std.mem.splitScalar(u8, field, '.');
            const f1 = it.next().?;
            const f2 = it.next().?;
            const f3 = it.next().?;
            break :blk .{ f1, f2, f3 };
        };
        return @field(@field(@field(value, f[0]), f[1]), f[2]);
    } else {
        @compileError("Too many nested fields");
    }
}

test "MapIterator - simple field access" {
    const testing = std.testing;

    const Person = struct {
        name: []const u8,
        age: u32,
    };

    var people = [_]Person{
        .{ .name = "Alice", .age = 30 },
        .{ .name = "Bob", .age = 25 },
        .{ .name = "Charlie", .age = 35 },
    };

    // Test name field access
    {
        var iter = MapIterator(Person, "name").init(&people);
        try testing.expectEqualStrings("Alice", iter.next().?);
        try testing.expectEqualStrings("Bob", iter.next().?);
        try testing.expectEqualStrings("Charlie", iter.next().?);
        try testing.expectEqual(@as(?[]const u8, null), iter.next());
    }

    // Test age field access
    {
        var iter = MapIterator(Person, "age").init(&people);
        try testing.expectEqual(@as(u32, 30), iter.next().?);
        try testing.expectEqual(@as(u32, 25), iter.next().?);
        try testing.expectEqual(@as(u32, 35), iter.next().?);
        try testing.expectEqual(@as(?u32, null), iter.next());
    }
}

test "MapIterator - nested field access" {
    const testing = std.testing;

    const PostalCode = struct {
        numbers: usize,
        letters: []const u8,
    };

    const Address = struct {
        street: []const u8,
        number: u32,
        pc: PostalCode,
    };

    const Person = struct {
        name: []const u8,
        address: Address,
    };

    var people = [_]Person{
        .{
            .name = "Alice",
            .address = .{ .street = "Main St", .number = 123, .pc = .{ .numbers = 4242, .letters = "AB" } },
        },
        .{
            .name = "Bob",
            .address = .{ .street = "Oak Ave", .number = 456, .pc = .{ .numbers = 3131, .letters = "CD" } },
        },
    };

    // Test nested street field access
    {
        var iter = MapIterator(Person, "address.street").init(&people);
        try testing.expectEqualStrings("Main St", iter.next().?);
        try testing.expectEqualStrings("Oak Ave", iter.next().?);
        try testing.expectEqual(@as(?[]const u8, null), iter.next());
    }

    // Test nested number field access
    {
        var iter = MapIterator(Person, "address.number").init(&people);
        try testing.expectEqual(@as(u32, 123), iter.next().?);
        try testing.expectEqual(@as(u32, 456), iter.next().?);
        try testing.expectEqual(@as(?u32, null), iter.next());
    }

    // Test nested postal code numbers field access
    {
        var iter = MapIterator(Person, "address.pc.numbers").init(&people);
        try testing.expectEqual(@as(usize, 4242), iter.next().?);
        try testing.expectEqual(@as(usize, 3131), iter.next().?);
        try testing.expectEqual(@as(?usize, null), iter.next());
    }

    // Test nested postal code letters field access
    {
        var iter = MapIterator(Person, "address.pc.letters").init(&people);
        try testing.expectEqualSlices(u8, "AB", iter.next().?);
        try testing.expectEqualSlices(u8, "CD", iter.next().?);
        try testing.expectEqual(@as(?[]const u8, null), iter.next());
    }
}

test "MapIterator - empty slice" {
    const testing = std.testing;

    const Item = struct {
        value: u32,
    };

    var items = [_]Item{};
    var iter = MapIterator(Item, "value").init(&items);
    try testing.expectEqual(@as(?u32, null), iter.next());
}

/// Iterates over multiple slices
pub fn ConcatSlicesIterator(T: type) type {
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

test "ConcatSlicesIterator - empty slices" {
    const testing = std.testing;
    var iter = ConcatSlicesIterator(u8).init(&[_][]const u8{});
    try testing.expectEqual(@as(?u8, null), iter.next());
}

test "ConcatSlicesIterator - single empty slice" {
    const testing = std.testing;
    var iter = ConcatSlicesIterator(u8).init(&[_][]const u8{&[_]u8{}});
    try testing.expectEqual(@as(?u8, null), iter.next());
}

test "ConcatSlicesIterator - single slice with elements" {
    const testing = std.testing;
    var iter = ConcatSlicesIterator(u8).init(&[_][]const u8{&[_]u8{ 1, 2, 3 }});
    try testing.expectEqual(@as(?u8, 1), iter.next());
    try testing.expectEqual(@as(?u8, 2), iter.next());
    try testing.expectEqual(@as(?u8, 3), iter.next());
    try testing.expectEqual(@as(?u8, null), iter.next());
}

test "ConcatSlicesIterator - multiple slices" {
    const testing = std.testing;
    var iter = ConcatSlicesIterator(u8).init(&[_][]const u8{
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

test "ConcatSlicesIterator - mixed empty and non-empty slices" {
    const testing = std.testing;
    var iter = ConcatSlicesIterator(u8).init(&[_][]const u8{
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

test "ConcatSlicesIterator - different types" {
    const testing = std.testing;
    var iter = ConcatSlicesIterator([]const u8).init(&[_][]const []const u8{
        &[_][]const u8{ "hello", "world" },
        &[_][]const u8{ "zig", "lang" },
    });

    try testing.expectEqualStrings("hello", iter.next().?);
    try testing.expectEqualStrings("world", iter.next().?);
    try testing.expectEqualStrings("zig", iter.next().?);
    try testing.expectEqualStrings("lang", iter.next().?);
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
}
