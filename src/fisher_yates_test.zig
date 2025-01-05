const std = @import("std");
const ShuffleTests = @import("jamtestvectors/fisher_yates.zig").ShuffleTests;

const fisher_yates = @import("fisher_yates.zig");

test "entropy" {
    const allocator = std.testing.allocator;
    var vector = try ShuffleTests.buildFrom(allocator, "src/jamtestvectors/pulls/fisher-yates/shuffle/shuffle_tests.json");
    defer vector.deinit(allocator);

    std.debug.print("Loaded test vector with {} tests\n", .{vector.tests.len});

    for (vector.tests, 0..) |shuffle_test, idx| {
        // Create the initial sequence [0..input)
        var sequence = try allocator.alloc(u32, shuffle_test.input);
        defer allocator.free(sequence);

        for (0..shuffle_test.input) |i| {
            sequence[i] = @intCast(i);
        }

        // Perform the shuffle
        fisher_yates.shuffleWithHash(u32, allocator, sequence, shuffle_test.entropy);

        // Verify the result matches expected output
        try std.testing.expectEqualSlices(u32, shuffle_test.output, sequence);

        std.debug.print("Test case {}: Input={} passed\n", .{ idx + 1, shuffle_test.input });
    }
}
