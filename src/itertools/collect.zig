const std = @import("std");

pub fn collectIntoArrayList(
    comptime T: type,
    allocator: std.mem.Allocator,
    iterator: anytype,
    options: struct {
        initial_capacity: ?usize = null,
    },
) !std.ArrayList(T) {
    var list = if (options.initial_capacity) |capacity|
        try std.ArrayList(T).initCapacity(allocator, capacity)
    else
        std.ArrayList(T).init(allocator);
    errdefer list.deinit();

    try collectIntoAppendable(iterator, &list);
    return list;
}

test "collectIntoArrayList - basic usage" {
    const testing = std.testing;
    const allocator = testing.allocator;

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

    var iter = NumberIterator.init(5);
    var list = try collectIntoArrayList(
        u32,
        allocator,
        &iter,
        .{ .initial_capacity = 8 },
    );
    defer list.deinit();

    try testing.expectEqual(@as(usize, 5), list.items.len);
    for (list.items, 0..) |num, i| {
        try testing.expectEqual(@as(u32, @intCast(i)), num);
    }
}

test "collectIntoArrayList - empty iterator" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const EmptyIterator = struct {
        pub fn next(self: *@This()) !?u32 {
            _ = self;
            return null;
        }
    };

    var iter = EmptyIterator{};
    var list = try collectIntoArrayList(
        u32,
        allocator,
        &iter,
        .{},
    );
    defer list.deinit();

    try testing.expectEqual(@as(usize, 0), list.items.len);
}

pub fn collectIntoAppendable(
    iterator: anytype,
    container: anytype,
) !void {
    while (try iterator.next()) |item| {
        try container.append(item);
    }
}

pub fn collectIntoSet(
    iterator: anytype,
    set: anytype,
) !void {
    while (try iterator.next()) |item| {
        try set.put(item, {});
    }
}

test "collectIntoAppendable - basic usage" {
    const testing = std.testing;
    const allocator = testing.allocator;

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

    var iter = NumberIterator.init(5);
    var list = std.ArrayList(u32).init(allocator);
    defer list.deinit();

    try collectIntoAppendable(&iter, &list);
    const numbers = list.items;

    try testing.expectEqual(@as(usize, 5), numbers.len);
    for (numbers, 0..) |num, i| {
        try testing.expectEqual(@as(u32, @intCast(i)), num);
    }
}

test "collectIntoSet - basic usage" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const NumberIterator = struct {
        numbers: []const u32,
        position: usize = 0,

        pub fn init(numbers: []const u32) @This() {
            return .{ .numbers = numbers };
        }

        pub fn next(self: *@This()) !?u32 {
            if (self.position >= self.numbers.len) return null;
            const value = self.numbers[self.position];
            self.position += 1;
            return value;
        }
    };

    const numbers = [_]u32{ 1, 2, 2, 3, 3, 3, 4, 4, 4, 4 };
    var iter = NumberIterator.init(&numbers);
    var set = std.AutoHashMap(u32, void).init(allocator);
    defer set.deinit();

    try collectIntoSet(&iter, &set);

    try testing.expectEqual(@as(usize, 4), set.count());

    try testing.expect(set.contains(1));
    try testing.expect(set.contains(2));
    try testing.expect(set.contains(3));
    try testing.expect(set.contains(4));

    try testing.expect(!set.contains(5));
}
