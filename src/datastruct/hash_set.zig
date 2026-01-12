const std = @import("std");

pub fn HashSet(comptime T: type) type {
    return struct {
        map: std.AutoHashMapUnmanaged(T, void),

        pub const Iterator = std.AutoHashMapUnmanaged(T, void).Iterator;

        pub fn init() @This() {
            return .{ .map = .{} };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.map.deinit(allocator);
            self.* = undefined;
        }

        pub fn add(self: *@This(), allocator: std.mem.Allocator, item: T) !void {
            try self.map.put(allocator, item, {});
        }

        pub fn contains(self: *const @This(), item: T) bool {
            return self.map.contains(item);
        }

        pub fn remove(self: *@This(), item: T) bool {
            return self.map.remove(item);
        }

        pub fn swapRemove(self: *@This(), item: T) bool {
            return self.map.swapRemove(item);
        }

        pub fn count(self: *const @This()) usize {
            return self.map.count();
        }

        pub fn iterator(self: *const @This()) Iterator {
            return self.map.iterator();
        }

        pub fn clone(self: *const @This(), allocator: std.mem.Allocator) !@This() {
            return .{ .map = try self.map.clone(allocator) };
        }

        pub fn clearRetainingCapacity(self: *@This()) void {
            self.map.clearRetainingCapacity();
        }

        pub fn clearAndFree(self: *@This(), allocator: std.mem.Allocator) void {
            self.map.clearAndFree(allocator);
        }

        pub fn ensureTotalCapacity(self: *@This(), allocator: std.mem.Allocator, new_capacity: usize) !void {
            try self.map.ensureTotalCapacity(allocator, new_capacity);
        }

        pub fn keyIterator(self: *const @This()) KeyIterator {
            return KeyIterator{ .iter = self.map.iterator() };
        }

        pub const KeyIterator = struct {
            iter: std.AutoHashMapUnmanaged(T, void).Iterator,

            pub fn next(self: *@This()) ?T {
                if (self.iter.next()) |entry| {
                    return entry.key_ptr.*;
                }
                return null;
            }
        };
    };
}

const testing = std.testing;

test "HashSet basic operations" {
    const allocator = testing.allocator;

    var set = HashSet(u32).init();
    defer set.deinit(allocator);

    try set.add(allocator, 42);
    try set.add(allocator, 100);
    try set.add(allocator, 42);

    try testing.expect(set.contains(42));
    try testing.expect(set.contains(100));
    try testing.expect(!set.contains(99));
    try testing.expectEqual(@as(usize, 2), set.count());

    try testing.expect(set.remove(42));
    try testing.expect(!set.contains(42));
    try testing.expectEqual(@as(usize, 1), set.count());

    try testing.expect(!set.remove(999));
}

test "HashSet iteration" {
    const allocator = testing.allocator;

    var set = HashSet(u32).init();
    defer set.deinit(allocator);

    try set.add(allocator, 1);
    try set.add(allocator, 2);
    try set.add(allocator, 3);

    var sum: u32 = 0;
    var iter = set.iterator();
    while (iter.next()) |entry| {
        sum += entry.key_ptr.*;
    }
    try testing.expectEqual(@as(u32, 6), sum);
}

test "HashSet clone" {
    const allocator = testing.allocator;

    var original = HashSet(u32).init();
    defer original.deinit(allocator);

    try original.add(allocator, 10);
    try original.add(allocator, 20);

    var cloned = try original.clone(allocator);
    defer cloned.deinit(allocator);

    try testing.expect(cloned.contains(10));
    try testing.expect(cloned.contains(20));
    try testing.expectEqual(original.count(), cloned.count());

    try cloned.add(allocator, 30);
    try testing.expect(cloned.contains(30));
    try testing.expect(!original.contains(30));
}