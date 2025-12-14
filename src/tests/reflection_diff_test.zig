const std = @import("std");
const reflection_diff = @import("reflection_diff.zig");
const state = @import("../state.zig");
const RandomStateGenerator = @import("../state_random_generator.zig").RandomStateGenerator;
const StateComplexity = @import("../state_random_generator.zig").StateComplexity;
const jam_params = @import("../jam_params.zig");
const diff = @import("diff.zig");

test "reflection_diff: identical integers" {
    const allocator = std.testing.allocator;

    const a: u32 = 42;
    const b: u32 = 42;

    var result = try reflection_diff.diffBasedOnReflection(u32, allocator, a, b, .{});
    defer result.deinit();

    try std.testing.expect(!result.hasChanges());
}

test "reflection_diff: different integers" {
    const allocator = std.testing.allocator;

    const expected: u32 = 42;
    const actual: u32 = 100;

    var result = try reflection_diff.diffBasedOnReflection(u32, allocator, expected, actual, .{ .path_context = "value" });
    defer result.deinit();

    try std.testing.expect(result.hasChanges());
    try std.testing.expectEqual(@as(usize, 1), result.entries.items.len);

    const entry = result.entries.items[0];
    try std.testing.expectEqualStrings("value", entry.path);
    try std.testing.expectEqualStrings("100", entry.actual_value);
    try std.testing.expectEqualStrings("42", entry.expected_value);
    try std.testing.expectEqual(@as(i64, 58), entry.delta.?);
}

test "reflection_diff: booleans" {
    const allocator = std.testing.allocator;

    const expected: bool = true;
    const actual: bool = false;

    var result = try reflection_diff.diffBasedOnReflection(bool, allocator, expected, actual, .{ .path_context = "flag" });
    defer result.deinit();

    try std.testing.expect(result.hasChanges());
    try std.testing.expectEqual(@as(usize, 1), result.entries.items.len);
}

test "reflection_diff: enums" {
    const allocator = std.testing.allocator;

    const Color = enum { red, green, blue };

    const expected: Color = .red;
    const actual: Color = .blue;

    var result = try reflection_diff.diffBasedOnReflection(Color, allocator, expected, actual, .{ .path_context = "color" });
    defer result.deinit();

    try std.testing.expect(result.hasChanges());
    try std.testing.expectEqual(@as(usize, 1), result.entries.items.len);

    const entry = result.entries.items[0];
    try std.testing.expectEqualStrings("color", entry.path);
    try std.testing.expectEqualStrings("blue", entry.actual_value);
    try std.testing.expectEqualStrings("red", entry.expected_value);
}

test "reflection_diff: hash arrays" {
    const allocator = std.testing.allocator;

    const expected: [32]u8 = [_]u8{0xAA} ** 32;
    const actual: [32]u8 = [_]u8{0xBB} ** 32;

    var result = try reflection_diff.diffBasedOnReflection([32]u8, allocator, expected, actual, .{ .path_context = "hash" });
    defer result.deinit();

    try std.testing.expect(result.hasChanges());
    try std.testing.expectEqual(@as(usize, 1), result.entries.items.len);

    const entry = result.entries.items[0];
    try std.testing.expectEqualStrings("hash", entry.path);
}

test "reflection_diff: simple struct" {
    const allocator = std.testing.allocator;

    const Point = struct {
        x: i32,
        y: i32,
    };

    const expected = Point{ .x = 10, .y = 20 };
    const actual = Point{ .x = 10, .y = 30 };

    var result = try reflection_diff.diffBasedOnReflection(Point, allocator, expected, actual, .{});
    defer result.deinit();

    try std.testing.expect(result.hasChanges());
    try std.testing.expectEqual(@as(usize, 1), result.entries.items.len);

    const entry = result.entries.items[0];
    try std.testing.expectEqualStrings("y", entry.path);
    try std.testing.expectEqualStrings("30", entry.actual_value);
    try std.testing.expectEqualStrings("20", entry.expected_value);
    try std.testing.expectEqual(@as(i64, 10), entry.delta.?);
}

test "reflection_diff: nested struct" {
    const allocator = std.testing.allocator;

    const Inner = struct {
        value: u32,
    };

    const Outer = struct {
        inner: Inner,
        flag: bool,
    };

    const expected = Outer{ .inner = Inner{ .value = 100 }, .flag = true };
    const actual = Outer{ .inner = Inner{ .value = 200 }, .flag = true };

    var result = try reflection_diff.diffBasedOnReflection(Outer, allocator, expected, actual, .{});
    defer result.deinit();

    try std.testing.expect(result.hasChanges());
    try std.testing.expectEqual(@as(usize, 1), result.entries.items.len);

    const entry = result.entries.items[0];
    try std.testing.expectEqualStrings("inner.value", entry.path);
    try std.testing.expectEqualStrings("200", entry.actual_value);
    try std.testing.expectEqualStrings("100", entry.expected_value);
}

test "reflection_diff: optional values" {
    const allocator = std.testing.allocator;

    const expected: ?u32 = 42;
    const actual: ?u32 = null;

    var result = try reflection_diff.diffBasedOnReflection(?u32, allocator, expected, actual, .{ .path_context = "opt_value" });
    defer result.deinit();

    try std.testing.expect(result.hasChanges());
    try std.testing.expectEqual(@as(usize, 1), result.entries.items.len);

    const entry = result.entries.items[0];
    try std.testing.expectEqualStrings("opt_value", entry.path);
    try std.testing.expectEqualStrings("null", entry.actual_value);
    try std.testing.expectEqualStrings("<non-null>", entry.expected_value);
}

test "reflection_diff: array elements" {
    const allocator = std.testing.allocator;

    const expected = [_]u32{ 1, 2, 3, 4, 5 };
    const actual = [_]u32{ 1, 2, 9, 4, 5 };

    var result = try reflection_diff.diffBasedOnReflection([5]u32, allocator, expected, actual, .{ .path_context = "arr" });
    defer result.deinit();

    try std.testing.expect(result.hasChanges());
    try std.testing.expectEqual(@as(usize, 1), result.entries.items.len);

    const entry = result.entries.items[0];
    try std.testing.expectEqualStrings("arr[2]", entry.path);
    try std.testing.expectEqualStrings("9", entry.actual_value);
    try std.testing.expectEqualStrings("3", entry.expected_value);
}

test "reflection_diff: byte slices" {
    const allocator = std.testing.allocator;

    const expected: []const u8 = &[_]u8{ 0xAA, 0xBB, 0xCC };
    const actual: []const u8 = &[_]u8{ 0xDD, 0xEE, 0xFF };

    var result = try reflection_diff.diffBasedOnReflection([]const u8, allocator, expected, actual, .{ .path_context = "bytes" });
    defer result.deinit();

    try std.testing.expect(result.hasChanges());
    try std.testing.expectEqual(@as(usize, 1), result.entries.items.len);
}

test "reflection_diff: tagged union" {
    const allocator = std.testing.allocator;

    const Value = union(enum) {
        int: i32,
        float: f64,
        string: []const u8,
    };

    const expected = Value{ .int = 42 };
    const actual = Value{ .float = 3.14 };

    var result = try reflection_diff.diffBasedOnReflection(Value, allocator, expected, actual, .{ .path_context = "value" });
    defer result.deinit();

    try std.testing.expect(result.hasChanges());
}

test "reflection_diff: HashMap basic" {
    const allocator = std.testing.allocator;

    var expected = std.AutoHashMap(u32, u64).init(allocator);
    defer expected.deinit();
    try expected.put(1, 100);
    try expected.put(2, 200);
    try expected.put(3, 300);

    var actual = std.AutoHashMap(u32, u64).init(allocator);
    defer actual.deinit();
    try actual.put(1, 100);
    try actual.put(2, 250);
    try actual.put(4, 400);

    var result = try reflection_diff.diffBasedOnReflection(std.AutoHashMap(u32, u64), allocator, expected, actual, .{ .path_context = "map" });
    defer result.deinit();

    try std.testing.expect(result.hasChanges());
    try std.testing.expectEqual(@as(usize, 3), result.entries.items.len);

    var found_value_diff = false;
    var found_missing_in_actual = false;
    var found_missing_in_expected = false;

    for (result.entries.items) |entry| {
        if (std.mem.indexOf(u8, entry.path, "[2]") != null) {
            try std.testing.expectEqualStrings("250", entry.actual_value);
            try std.testing.expectEqualStrings("200", entry.expected_value);
            found_value_diff = true;
        }
        if (std.mem.indexOf(u8, entry.path, "[3]") != null) {
            try std.testing.expectEqualStrings("MISSING", entry.actual_value);
            found_missing_in_actual = true;
        }
        if (std.mem.indexOf(u8, entry.path, "[4]") != null) {
            try std.testing.expectEqualStrings("MISSING", entry.expected_value);
            found_missing_in_expected = true;
        }
    }

    try std.testing.expect(found_value_diff);
    try std.testing.expect(found_missing_in_actual);
    try std.testing.expect(found_missing_in_expected);
}

test "reflection_diff: ArrayList basic" {
    const allocator = std.testing.allocator;

    var expected = std.ArrayList(u32).init(allocator);
    defer expected.deinit();
    try expected.append(10);
    try expected.append(20);
    try expected.append(30);

    var actual = std.ArrayList(u32).init(allocator);
    defer actual.deinit();
    try actual.append(10);
    try actual.append(20);
    try actual.append(99);

    var result = try reflection_diff.diffBasedOnReflection(std.ArrayList(u32), allocator, expected, actual, .{ .path_context = "list" });
    defer result.deinit();

    try std.testing.expect(result.hasChanges());
    try std.testing.expectEqual(@as(usize, 1), result.entries.items.len);

    const entry = result.entries.items[0];
    try std.testing.expectEqualStrings("list[2]", entry.path);
    try std.testing.expectEqualStrings("99", entry.actual_value);
    try std.testing.expectEqualStrings("30", entry.expected_value);
}

test "reflection_diff: service accounts with IDs" {
    const allocator = std.testing.allocator;

    const ServiceAccount = struct {
        balance: u64,
        gas_limit: u64,
        active: bool,
    };

    var expected = std.AutoHashMap(u32, ServiceAccount).init(allocator);
    defer expected.deinit();
    try expected.put(5, .{ .balance = 1000, .gas_limit = 50000, .active = true });
    try expected.put(10, .{ .balance = 2000, .gas_limit = 60000, .active = true });

    var actual = std.AutoHashMap(u32, ServiceAccount).init(allocator);
    defer actual.deinit();
    try actual.put(5, .{ .balance = 500, .gas_limit = 50000, .active = false });
    try actual.put(10, .{ .balance = 2000, .gas_limit = 60000, .active = true });

    var result = try reflection_diff.diffBasedOnReflection(
        std.AutoHashMap(u32, ServiceAccount),
        allocator,
        expected,
        actual,
        .{ .path_context = "delta.accounts" },
    );
    defer result.deinit();

    try std.testing.expect(result.hasChanges());
    try std.testing.expectEqual(@as(usize, 2), result.entries.items.len);

    var found_balance_diff = false;
    var found_active_diff = false;

    for (result.entries.items) |entry| {
        if (std.mem.indexOf(u8, entry.path, "[5]") != null and std.mem.indexOf(u8, entry.path, "balance") != null) {
            try std.testing.expectEqualStrings("500", entry.actual_value);
            try std.testing.expectEqualStrings("1000", entry.expected_value);
            try std.testing.expectEqual(@as(i64, -500), entry.delta.?);
            found_balance_diff = true;
        }
        if (std.mem.indexOf(u8, entry.path, "[5]") != null and std.mem.indexOf(u8, entry.path, "active") != null) {
            try std.testing.expectEqualStrings("false", entry.actual_value);
            try std.testing.expectEqualStrings("true", entry.expected_value);
            found_active_diff = true;
        }
    }

    try std.testing.expect(found_balance_diff);
    try std.testing.expect(found_active_diff);

    std.debug.print("\n=== Service Account Diff Example ===\n", .{});
    try std.fmt.format(std.io.getStdErr().writer(), "{}", .{result});
}

fn testRandomStateDiff(
    allocator: std.mem.Allocator,
    comptime params: jam_params.Params,
    complexity: StateComplexity,
    seed1: u64,
    seed2: u64,
) !void {
    var prng1 = std.Random.DefaultPrng.init(seed1);
    var generator1 = RandomStateGenerator.init(allocator, prng1.random());

    var state1 = try generator1.generateRandomState(params, complexity);
    defer state1.deinit(allocator);

    var prng2 = std.Random.DefaultPrng.init(seed2);
    var generator2 = RandomStateGenerator.init(allocator, prng2.random());

    var state2 = try generator2.generateRandomState(params, complexity);
    defer state2.deinit(allocator);

    var result = try reflection_diff.diffBasedOnReflection(
        state.JamState(params),
        allocator,
        state1,
        state2,
        .{ .ignore_fields = &.{"global_index"} },
    );
    defer result.deinit();

    try std.testing.expect(result.hasChanges());

    std.debug.print("\n=== Random State Diff Output (seeds: {d} vs {d}) ===\n", .{ seed1, seed2 });
    try std.fmt.format(std.io.getStdErr().writer(), "{}", .{result});
}

test "reflection_diff: random state minimal complexity" {
    const allocator = std.testing.allocator;
    const TINY = jam_params.TINY_PARAMS;

    try testRandomStateDiff(allocator, TINY, .minimal, 100, 200);
}

test "reflection_diff: random state moderate complexity" {
    const allocator = std.testing.allocator;
    const TINY = jam_params.TINY_PARAMS;

    try testRandomStateDiff(allocator, TINY, .moderate, 300, 400);
}

test "reflection_diff: random state maximal complexity" {
    const allocator = std.testing.allocator;
    const TINY = jam_params.TINY_PARAMS;

    try testRandomStateDiff(allocator, TINY, .maximal, 500, 600);
}

test "reflection_diff: stress test with multiple random states" {
    const allocator = std.testing.allocator;
    const TINY = jam_params.TINY_PARAMS;

    for (0..10) |i| {
        var prng1 = std.Random.DefaultPrng.init(i * 2);
        var generator1 = RandomStateGenerator.init(allocator, prng1.random());

        var state1 = try generator1.generateRandomState(TINY, .moderate);
        defer state1.deinit(allocator);

        var prng2 = std.Random.DefaultPrng.init(i * 2 + 1);
        var generator2 = RandomStateGenerator.init(allocator, prng2.random());

        var state2 = try generator2.generateRandomState(TINY, .moderate);
        defer state2.deinit(allocator);

        var result = try reflection_diff.diffBasedOnReflection(
            state.JamState(TINY),
            allocator,
            state1,
            state2,
            .{ .ignore_fields = &.{"global_index"} },
        );
        defer result.deinit();

        try std.testing.expect(result.hasChanges());
    }
}

test "reflection_diff: integration with diff.zig wrapper" {
    const allocator = std.testing.allocator;

    const Point = struct {
        x: i32,
        y: i32,
    };

    const expected = Point{ .x = 10, .y = 20 };
    const actual = Point{ .x = 10, .y = 30 };

    var result = try diff.diffBasedOnReflection(Point, allocator, expected, actual);
    defer result.deinit(allocator);

    try std.testing.expect(result.hasChanges());

    switch (result) {
        .Diff => |output| {
            try std.testing.expect(output.len > 0);
            std.debug.print("\nIntegration test output:\n{s}\n", .{output});
        },
        .EmptyDiff => {
            try std.testing.expect(false);
        },
    }
}

test "reflection_diff: identical states should return EmptyDiff" {
    const allocator = std.testing.allocator;

    const Point = struct {
        x: i32,
        y: i32,
    };

    const expected = Point{ .x = 10, .y = 20 };
    const actual = Point{ .x = 10, .y = 20 };

    var result = try reflection_diff.diffBasedOnReflection(Point, allocator, expected, actual, .{});
    defer result.deinit();

    try std.testing.expect(!result.hasChanges());
}

test "reflection_diff: ignore_fields option" {
    const allocator = std.testing.allocator;

    const Data = struct {
        important: u32,
        global_index: u32,
    };

    const expected = Data{ .important = 100, .global_index = 1 };
    const actual = Data{ .important = 100, .global_index = 999 };

    var result = try reflection_diff.diffBasedOnReflection(
        Data,
        allocator,
        expected,
        actual,
        .{ .ignore_fields = &.{"global_index"} },
    );
    defer result.deinit();

    try std.testing.expect(!result.hasChanges());
}

test "reflection_diff: max_depth limit" {
    const allocator = std.testing.allocator;

    const Nested = struct {
        level1: struct {
            level2: struct {
                level3: struct {
                    value: u32,
                },
            },
        },
    };

    const expected = Nested{
        .level1 = .{
            .level2 = .{
                .level3 = .{
                    .value = 100,
                },
            },
        },
    };

    const actual = Nested{
        .level1 = .{
            .level2 = .{
                .level3 = .{
                    .value = 200,
                },
            },
        },
    };

    var result_limited = try reflection_diff.diffBasedOnReflection(
        Nested,
        allocator,
        expected,
        actual,
        .{ .max_depth = 2 },
    );
    defer result_limited.deinit();

    var result_full = try reflection_diff.diffBasedOnReflection(
        Nested,
        allocator,
        expected,
        actual,
        .{ .max_depth = 20 },
    );
    defer result_full.deinit();

    try std.testing.expect(result_full.hasChanges());
}
