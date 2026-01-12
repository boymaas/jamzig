const std = @import("std");

pub fn MapStructFieldIter(comptime T: type, comptime accessor: []const u8) type {
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

fn NestedFieldType(comptime T: type, comptime field: []const u8) type {
    if (std.mem.indexOfScalar(u8, field, '.') == null) {
        const accessor = std.meta.stringToEnum(std.meta.FieldEnum(T), field).?;
        return std.meta.FieldType(T, accessor);
    }

    const first_dot = std.mem.indexOfScalar(u8, field, '.').?;
    const first_field = field[0..first_dot];
    const remaining = field[first_dot + 1 ..];

    const accessor = std.meta.stringToEnum(std.meta.FieldEnum(T), first_field).?;
    const NextType = std.meta.FieldType(T, accessor);

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

test "MapStructFieldIter - simple field access" {
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

    {
        var iter = MapStructFieldIter(Person, "name").init(&people);
        try testing.expectEqualStrings("Alice", iter.next().?);
        try testing.expectEqualStrings("Bob", iter.next().?);
        try testing.expectEqualStrings("Charlie", iter.next().?);
        try testing.expectEqual(@as(?[]const u8, null), iter.next());
    }

    {
        var iter = MapStructFieldIter(Person, "age").init(&people);
        try testing.expectEqual(@as(u32, 30), iter.next().?);
        try testing.expectEqual(@as(u32, 25), iter.next().?);
        try testing.expectEqual(@as(u32, 35), iter.next().?);
        try testing.expectEqual(@as(?u32, null), iter.next());
    }
}

test "MapStructFieldIter - nested field access" {
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

    {
        var iter = MapStructFieldIter(Person, "address.street").init(&people);
        try testing.expectEqualStrings("Main St", iter.next().?);
        try testing.expectEqualStrings("Oak Ave", iter.next().?);
        try testing.expectEqual(@as(?[]const u8, null), iter.next());
    }

    {
        var iter = MapStructFieldIter(Person, "address.number").init(&people);
        try testing.expectEqual(@as(u32, 123), iter.next().?);
        try testing.expectEqual(@as(u32, 456), iter.next().?);
        try testing.expectEqual(@as(?u32, null), iter.next());
    }

    {
        var iter = MapStructFieldIter(Person, "address.pc.numbers").init(&people);
        try testing.expectEqual(@as(usize, 4242), iter.next().?);
        try testing.expectEqual(@as(usize, 3131), iter.next().?);
        try testing.expectEqual(@as(?usize, null), iter.next());
    }

    {
        var iter = MapStructFieldIter(Person, "address.pc.letters").init(&people);
        try testing.expectEqualSlices(u8, "AB", iter.next().?);
        try testing.expectEqualSlices(u8, "CD", iter.next().?);
        try testing.expectEqual(@as(?[]const u8, null), iter.next());
    }
}

test "MapStructFieldIter - empty slice" {
    const testing = std.testing;

    const Item = struct {
        value: u32,
    };

    var items = [_]Item{};
    var iter = MapStructFieldIter(Item, "value").init(&items);
    try testing.expectEqual(@as(?u32, null), iter.next());
}
