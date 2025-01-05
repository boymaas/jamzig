const std = @import("std");
const json_types = @import("json_types/types.zig");
const json_utils = @import("json_types/utils.zig");
const HexBytesFixed = json_types.hex.HexBytesFixed;

pub const JsonShuffleTest = struct {
    input: usize,
    entropy: HexBytesFixed(32),
    output: []u32,
};

pub const ShuffleTest = struct {
    input: usize,
    entropy: [32]u8,
    output: []u32,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.output);
        self.* = undefined;
    }
};

pub const ShuffleTests = struct {
    tests: []ShuffleTest,

    pub fn buildFrom(allocator: std.mem.Allocator, path: []const u8) !@This() {
        var vector = try json_utils.TestVector([]JsonShuffleTest).build_from(allocator, path);
        defer vector.deinit();

        const tests = try allocator.alloc(ShuffleTest, vector.expected.value.len);
        for (vector.expected.value, 0..) |json_test, i| {
            tests[i] = ShuffleTest{
                .input = json_test.input,
                .entropy = json_test.entropy.bytes,
                .output = try allocator.dupe(u32, json_test.output),
            };
        }

        return .{ .tests = tests };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.tests) |*t| {
            t.deinit(allocator);
        }
        allocator.free(self.tests);
        self.* = undefined;
    }
};

test "test:vectors:trie: parsing the test vector" {
    const allocator = std.testing.allocator;
    var vector = try ShuffleTests.buildFrom(allocator, "src/jamtestvectors/pulls/fisher-yates/shuffle/shuffle_tests.json");
    defer vector.deinit(allocator);

    std.debug.print("Loaded test vector with {} tests\n", .{vector.tests.len});

    for (vector.tests) |shuffle_test| {
        std.debug.print("Parsed shuffle test with {d} {s} entries\n", .{ shuffle_test.input, std.fmt.fmtSliceHexLower(&shuffle_test.entropy) });
    }
}
