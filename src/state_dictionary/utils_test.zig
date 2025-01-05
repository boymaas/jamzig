const std = @import("std");
const testing = std.testing;
const utils = @import("utils.zig");

// Test types
const SimpleType = struct {
    value: i32,

    pub fn init() SimpleType {
        return .{ .value = 42 };
    }
};

const AllocType = struct {
    data: []u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !AllocType {
        const data = try allocator.alloc(u8, 10);
        @memset(data, 0);
        return .{
            .data = data,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AllocType) void {
        self.allocator.free(self.data);
        self.* = undefined;
    }
};

const AllocTypeWithAllocDeinit = struct {
    data: []u8,

    pub fn init(allocator: std.mem.Allocator) !AllocTypeWithAllocDeinit {
        const data = try allocator.alloc(u8, 10);
        @memset(data, 0);
        return .{
            .data = data,
        };
    }

    pub fn deinit(self: *AllocTypeWithAllocDeinit, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        self.* = undefined;
    }
};

const CustomInitType = struct {
    x: i32,
    y: []const u8,

    pub fn init(x: i32, y: []const u8) CustomInitType {
        return .{
            .x = x,
            .y = y,
        };
    }
};

const ErrorType = struct {
    value: i32,

    pub fn init() !ErrorType {
        return error.TestError;
    }
};

test "getOrInitManaged - simple type with no value" {
    const allocator = testing.allocator;
    var maybe_value: ?SimpleType = null;

    var result = try utils.getOrInitManaged(allocator, &maybe_value, .{});
    defer result.deinit(allocator);

    try testing.expectEqual(@as(i32, 42), result.ptr.value);
    try testing.expect(result.needs_free);
}

test "getOrInitManaged - simple type with existing value" {
    const allocator = testing.allocator;
    var maybe_value: ?SimpleType = SimpleType{ .value = 100 };

    var result = try utils.getOrInitManaged(allocator, &maybe_value, .{});
    defer result.deinit(allocator);

    try testing.expectEqual(@as(i32, 100), result.ptr.value);
    try testing.expect(!result.needs_free);
}

test "getOrInitManaged - allocator type" {
    const allocator = testing.allocator;
    var maybe_value: ?AllocType = null;

    var result = try utils.getOrInitManaged(allocator, &maybe_value, .{allocator});
    defer {
        result.deinit(allocator);
    }

    try testing.expectEqual(@as(usize, 10), result.ptr.data.len);
    try testing.expect(result.needs_free);
}

test "getOrInitManaged - allocator type with existing value" {
    const allocator = testing.allocator;
    var existing_value = try AllocType.init(allocator);
    defer existing_value.deinit();

    var maybe_value: ?AllocType = existing_value;
    var result = try utils.getOrInitManaged(allocator, &maybe_value, .{allocator});
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 10), result.ptr.data.len);
    try testing.expect(!result.needs_free); // Should not need free since we're using existing value
}

test "getOrInitManaged - custom init args" {
    const allocator = testing.allocator;
    var maybe_value: ?CustomInitType = null;

    var result = try utils.getOrInitManaged(allocator, &maybe_value, .{ 123, "test" });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(i32, 123), result.ptr.x);
    try testing.expectEqualStrings("test", result.ptr.y);
    try testing.expect(result.needs_free);
}

test "getOrInitManaged - error handling" {
    const allocator = testing.allocator;
    var maybe_value: ?ErrorType = null;

    try testing.expectError(error.TestError, utils.getOrInitManaged(allocator, &maybe_value, .{}));
}

test "getOrInitManaged - compile error on non-tuple args" {
    // const allocator = testing.allocator;
    // var maybe_value: ?SimpleType = null;

    // These should fail to compile:
    // _ = try utils.getOrInitManaged(allocator, &maybe_value, 42);
    // _ = try utils.getOrInitManaged(allocator, &maybe_value, "string");
    // _ = try utils.getOrInitManaged(allocator, &maybe_value, @as(void, undefined));
}

test "getOrInitManaged - compile error on wrong maybe_value type" {
    // const allocator = testing.allocator;
    // var direct_value = SimpleType{ .value = 42 };

    // These should fail to compile:
    // _ = try utils.getOrInitManaged(allocator, direct_value, .{});
    // _ = try utils.getOrInitManaged(allocator, &direct_value, .{});
}

test "getOrInitManaged - memory management" {
    const allocator = testing.allocator;
    {
        var maybe_value: ?SimpleType = null;
        var result = try utils.getOrInitManaged(allocator, &maybe_value, .{});
        // deinit will be called at end of scope
        defer result.deinit(allocator);
        try testing.expect(result.needs_free);
    }
}

test "getOrInitManaged - type with allocator deinit" {
    const allocator = testing.allocator;
    var maybe_value: ?AllocTypeWithAllocDeinit = null;

    var result = try utils.getOrInitManaged(allocator, &maybe_value, .{allocator});
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 10), result.ptr.data.len);
    try testing.expect(result.needs_free);
}

test "getOrInitManaged - type with allocator deinit and existing value" {
    const allocator = testing.allocator;
    var existing_value = try AllocTypeWithAllocDeinit.init(allocator);
    defer existing_value.deinit(allocator);

    var maybe_value: ?AllocTypeWithAllocDeinit = existing_value;
    var result = try utils.getOrInitManaged(allocator, &maybe_value, .{allocator});
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 10), result.ptr.data.len);
    try testing.expect(!result.needs_free); // Should not need free since we're using existing value
}
