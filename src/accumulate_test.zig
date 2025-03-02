const std = @import("std");

const tvector = @import("jamtestvectors/accumulate.zig");
const runAccumulateTest = @import("accumulate_test/runner.zig").runAccumulateTest;

const diffz = @import("disputes_test/diffz.zig");

const BASE_PATH = "src/jamtestvectors/data/accumulate/";

// Debug helper function
fn printStateDiff(allocator: std.mem.Allocator, pre_state: *const tvector.State, post_state: *const tvector.State) !void {
    const state_diff = try diffz.diffStates(allocator, pre_state, post_state);
    defer allocator.free(state_diff);
    std.debug.print("\nState Diff: {s}\n", .{state_diff});
}

//  _____ _           __     __        _
// |_   _(_)_ __  _   \ \   / /__  ___| |_ ___  _ __ ___
//   | | | | '_ \| | | \ \ / / _ \/ __| __/ _ \| '__/ __|
//   | | | | | | | |_| |\ V /  __/ (__| || (_) | |  \__ \
//   |_| |_|_| |_|\__, | \_/ \___|\___|\__\___/|_|  |___/
//                |___/

pub const jam_params = @import("jam_params.zig");

// Tiny test vectors
pub const TINY_PARAMS = jam_params.TINY_PARAMS;

const loader = @import("jamtestvectors/loader.zig");

test "tiny/no_available_reports-1.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/no_available_reports-1.bin");
}

test "tiny/process_one_immediate_report-1.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/process_one_immediate_report-1.bin");
}

test "tiny/enqueue_and_unlock_simple-1.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/enqueue_and_unlock_simple-1.bin");
}

test "tiny/enqueue_and_unlock_simple-2.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/enqueue_and_unlock_simple-2.bin");
}

test "tiny/enqueue_and_unlock_with_sr_lookup-1.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/enqueue_and_unlock_with_sr_lookup-1.bin");
}

test "tiny/enqueue_and_unlock_with_sr_lookup-2.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/enqueue_and_unlock_with_sr_lookup-2.bin");
}

test "tiny/enqueue_and_unlock_chain-1.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/enqueue_and_unlock_chain-1.bin");
}

test "tiny/enqueue_and_unlock_chain-2.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/enqueue_and_unlock_chain-2.bin");
}

test "tiny/enqueue_and_unlock_chain-3.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/enqueue_and_unlock_chain-3.bin");
}

test "tiny/enqueue_and_unlock_chain-4.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/enqueue_and_unlock_chain-4.bin");
}
//
// test "tiny/enqueue_and_unlock_chain_wraps-1.bin" {
//     const allocator = std.testing.allocator;
//     try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/enqueue_and_unlock_chain_wraps-1.bin");
// }
//
// test "tiny/enqueue_and_unlock_chain_wraps-2.bin" {
//     const allocator = std.testing.allocator;
//     try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/enqueue_and_unlock_chain_wraps-2.bin");
// }
//
// test "tiny/enqueue_and_unlock_chain_wraps-3.bin" {
//     const allocator = std.testing.allocator;
//     try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/enqueue_and_unlock_chain_wraps-3.bin");
// }
//
// test "tiny/enqueue_and_unlock_chain_wraps-4.bin" {
//     const allocator = std.testing.allocator;
//     try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/enqueue_and_unlock_chain_wraps-4.bin");
// }
//
// test "tiny/enqueue_and_unlock_chain_wraps-5.bin" {
//     const allocator = std.testing.allocator;
//     try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/enqueue_and_unlock_chain_wraps-5.bin");
// }
//
//
// test "tiny/enqueue_self_referential-1.bin" {
//     const allocator = std.testing.allocator;
//     try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/enqueue_self_referential-1.bin");
// }
//
// test "tiny/enqueue_self_referential-2.bin" {
//     const allocator = std.testing.allocator;
//     try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/enqueue_self_referential-2.bin");
// }
//
// test "tiny/enqueue_self_referential-3.bin" {
//     const allocator = std.testing.allocator;
//     try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/enqueue_self_referential-3.bin");
// }
//
// test "tiny/enqueue_self_referential-4.bin" {
//     const allocator = std.testing.allocator;
//     try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/enqueue_self_referential-4.bin");
// }
//

// Full test vectors
pub const FULL_PARAMS = jam_params.FULL_PARAMS;

fn runTest(comptime params: jam_params.Params, allocator: std.mem.Allocator, test_bin: []const u8) !void {
    std.debug.print("\nRunning test: {s}\n", .{test_bin});

    var test_vector = try loader.loadAndDeserializeTestVector(
        tvector.TestCase,
        params,
        allocator,
        test_bin,
    );
    defer test_vector.deinit(allocator);

    // std.debug.print("{}", .{@import("./types/fmt.zig").format(test_vector)});

    try runAccumulateTest(params, allocator, test_vector);
}

// test "all.tiny.vectors" {
//     const allocator = std.testing.allocator;
//
//     var tiny_test_files = try @import("tests/ordered_files.zig").getOrderedFiles(allocator, BASE_PATH ++ "tiny");
//     defer tiny_test_files.deinit();
//
//     for (tiny_test_files.items()) |test_file| {
//         if (!std.mem.endsWith(u8, test_file.path, ".bin")) {
//             continue;
//         }
//         try runTest(TINY_PARAMS, allocator, test_file.path);
//     }
// }

//  _____      _ _  __     __        _
// |  ___|   _| | | \ \   / /__  ___| |_ ___  _ __ ___
// | |_ | | | | | |  \ \ / / _ \/ __| __/ _ \| '__/ __|
// |  _|| |_| | | |   \ V /  __/ (__| || (_) | |  \__ \
// |_|   \__,_|_|_|    \_/ \___|\___|\__\___/|_|  |___/

// test "all.full.vectors" {
//     const allocator = std.testing.allocator;
//
//     var full_test_files = try @import("tests/ordered_files.zig").getOrderedFiles(allocator, BASE_PATH ++ "full");
//     defer full_test_files.deinit();
//
//     for (full_test_files.items()) |test_file| {
//         if (!std.mem.endsWith(u8, test_file.path, ".bin")) {
//             continue;
//         }
//         try runTest(FULL_PARAMS, allocator, test_file.path);
//     }
// }
