const std = @import("std");

pub fn expectHashMapEqual(comptime K: type, comptime V: type, expected: std.AutoHashMap(K, V), actual: std.AutoHashMap(K, V)) !void {
    if (expected.count() != actual.count()) {
        std.debug.print("HashMap counts do not match: expected {} != actual {}\n", .{ expected.count(), actual.count() });
        try printHashMapDifferences(K, V, expected, actual);
        return error.HashMapNotEqual;
    }

    var it = expected.iterator();
    while (it.next()) |entry| {
        const actual_value = actual.get(entry.key_ptr.*);
        if (actual_value == null or actual_value.? != entry.value_ptr.*) {
            try printHashMapDifferences(K, V, expected, actual);
            return error.HashMapNotEqual;
        }
    }
}

fn printHashMapDifferences(comptime K: type, comptime V: type, expected: std.AutoHashMap(K, V), actual: std.AutoHashMap(K, V)) !void {
    // Collect all unique keys
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var all_keys = std.ArrayList(K).init(allocator);
    defer all_keys.deinit();

    var it = expected.iterator();
    while (it.next()) |entry| {
        try all_keys.append(entry.key_ptr.*);
    }

    it = actual.iterator();
    while (it.next()) |entry| {
        if (!expected.contains(entry.key_ptr.*)) {
            try all_keys.append(entry.key_ptr.*);
        }
    }

    // Print sorted keys and values
    std.debug.print("\nSorted keys and values:\n", .{});
    for (all_keys.items) |key| {
        try printKey(K, key);

        if (V == void) {
            // This is a set
            const in_expected = expected.contains(key);
            const in_actual = actual.contains(key);
            if (in_expected and in_actual) {
                std.debug.print(": In both sets\n", .{});
            } else if (in_expected) {
                std.debug.print(": Only in expected set\n", .{});
            } else if (in_actual) {
                std.debug.print(": Only in actual set\n", .{});
            }
        } else {
            const expected_value = expected.get(key);
            const actual_value = actual.get(key);
            if (expected_value == null and actual_value == null) {
                std.debug.print(": Both null\n", .{});
            } else if (expected_value == null) {
                std.debug.print(": expected: null, actual: {any}\n", .{actual_value.?});
            } else if (actual_value == null) {
                std.debug.print(": expected: {any}, actual: null\n", .{expected_value.?});
            } else if (expected_value.? != actual_value.?) {
                std.debug.print(": expected: {any}, actual: {any} (DIFFERENT)\n", .{ expected_value.?, actual_value.? });
            } else {
                std.debug.print(": {any}\n", .{expected_value.?});
            }
        }
    }
}

fn printKey(comptime K: type, key: K) !void {
    if (K == [32]u8 or (K == []const u8 and key.len <= 64)) {
        // Print full hex for [32]u8 or short []u8
        std.debug.print("\x1b[32m", .{}); // Green color
        for (key) |byte| {
            std.debug.print("{x:0>2}", .{byte});
        }
        std.debug.print("\x1b[0m", .{}); // Reset color
    } else if (K == []const u8) {
        // Print truncated hex for long []u8
        std.debug.print("\x1b[33m", .{}); // Yellow color
        for (key[0..32]) |byte| {
            std.debug.print("{x:0>2}", .{byte});
        }
        std.debug.print("...", .{});
        for (key[key.len - 32 ..]) |byte| {
            std.debug.print("{x:0>2}", .{byte});
        }
        std.debug.print("\x1b[0m", .{}); // Reset color
    } else {
        // For other types, use the default formatting
        std.debug.print("{any}", .{key});
    }
}
