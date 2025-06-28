const std = @import("std");

pub const jam_params = @import("jam_params.zig");

const tvector = @import("jamtestvectors/preimages.zig");
const runPreimagesTest = @import("preimages_test/runner.zig").runPreimagesTest;

const BASE_PATH = "src/jamtestvectors/data/stf/preimages/";

// Debug helper function
fn printStateDiff(allocator: std.mem.Allocator, pre_state: *const tvector.State, post_state: *const tvector.State) !void {
    const state_diff = try @import("disputes_test/diffz.zig").diffStates(allocator, pre_state, post_state);
    defer allocator.free(state_diff);
    std.debug.print("\nState Diff: {s}\n", .{state_diff});
}

// Tiny test vectors
pub const TINY_PARAMS = jam_params.TINY_PARAMS;

const loader = @import("jamtestvectors/loader.zig");

fn runTest(comptime params: jam_params.Params, allocator: std.mem.Allocator, test_bin: []const u8) !void {
    std.debug.print("\nRunning test: {s}\n", .{test_bin});

    var test_vector = try loader.loadAndDeserializeTestVector(
        tvector.TestCase,
        params,
        allocator,
        test_bin,
    );
    defer test_vector.deinit(allocator);

    std.debug.print("{}", .{@import("./types/fmt.zig").format(test_vector)});

    try runPreimagesTest(params, allocator, test_vector);
}

test "all.vectors" {
    const allocator = std.testing.allocator;

    var tiny_test_files = try @import("tests/ordered_files.zig").getOrderedFiles(allocator, BASE_PATH ++ "data");
    defer tiny_test_files.deinit();

    for (tiny_test_files.items()) |test_file| {
        if (!std.mem.endsWith(u8, test_file.path, ".bin")) {
            continue;
        }
        try runTest(TINY_PARAMS, allocator, test_file.path);
    }
}
