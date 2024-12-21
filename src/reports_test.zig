const std = @import("std");
const tvector = @import("jamtestvectors/reports.zig");
const runReportTest = @import("reports_test/runner.zig").runReportTest;
const diffz = @import("disputes_test/diffz.zig");

const BASE_PATH = "src/jamtestvectors/data/reports/";

pub const jam_params = @import("jam_params.zig");

pub const TINY_PARAMS = jam_params.TINY_PARAMS;
pub const FULL_PARAMS = jam_params.FULL_PARAMS;

// Individual tiny test cases
test "tiny/anchor_not_recent-1.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/anchor_not_recent-1.bin");
}
test "tiny/bad_beefy_mmr-1.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/bad_beefy_mmr-1.bin");
}
test "tiny/bad_code_hash-1.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/bad_code_hash-1.bin");
}
test "tiny/bad_core_index-1.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/bad_core_index-1.bin");
}
test "tiny/bad_service_id-1.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/bad_service_id-1.bin");
}
test "tiny/bad_signature-1.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/bad_signature-1.bin");
}
test "tiny/bad_state_root-1.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/bad_state_root-1.bin");
}
test "tiny/bad_validator_index-1.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/bad_validator_index-1.bin");
}
test "tiny/consume_authorization_once-1.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/consume_authorization_once-1.bin");
}
test "tiny/core_engaged-1.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/core_engaged-1.bin");
}
test "tiny/dependency_missing-1.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/dependency_missing-1.bin");
}
test "tiny/duplicate_package_in_recent_history-1.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/duplicate_package_in_recent_history-1.bin");
}
test "tiny/duplicated_package_in_report-1.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/duplicated_package_in_report-1.bin");
}
test "tiny/future_report_slot-1.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/future_report_slot-1.bin");
}
test "tiny/high_work_report_gas-1.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/high_work_report_gas-1.bin");
}
test "tiny/many_dependencies-1.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/many_dependencies-1.bin");
}
test "tiny/multiple_reports-1.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/multiple_reports-1.bin");
}
test "tiny/no_enough_guarantees-1.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/no_enough_guarantees-1.bin");
}
test "tiny/not_authorized-1.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/not_authorized-1.bin");
}
test "tiny/not_authorized-2.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/not_authorized-2.bin");
}
test "tiny/not_sorted_guarantor-1.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/not_sorted_guarantor-1.bin");
}
test "tiny/out_of_order_guarantees-1.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/out_of_order_guarantees-1.bin");
}
test "tiny/report_before_last_rotation-1.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/report_before_last_rotation-1.bin");
}
test "tiny/report_curr_rotation-1.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/report_curr_rotation-1.bin");
}
test "tiny/report_prev_rotation-1.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/report_prev_rotation-1.bin");
}
test "tiny/reports_with_dependencies-1.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/reports_with_dependencies-1.bin");
}
test "tiny/reports_with_dependencies-2.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/reports_with_dependencies-2.bin");
}
test "tiny/reports_with_dependencies-3.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/reports_with_dependencies-3.bin");
}
test "tiny/reports_with_dependencies-4.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/reports_with_dependencies-4.bin");
}
test "tiny/reports_with_dependencies-5.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/reports_with_dependencies-5.bin");
}
test "tiny/reports_with_dependencies-6.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/reports_with_dependencies-6.bin");
}
test "tiny/segment_root_lookup_invalid-1.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/segment_root_lookup_invalid-1.bin");
}
test "tiny/segment_root_lookup_invalid-2.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/segment_root_lookup_invalid-2.bin");
}
test "tiny/service_item_gas_too_low-1.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/service_item_gas_too_low-1.bin");
}
test "tiny/too_high_work_report_gas-1.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/too_high_work_report_gas-1.bin");
}
test "tiny/too_many_dependencies-1.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/too_many_dependencies-1.bin");
}
test "tiny/wrong_assignment-1.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/wrong_assignment-1.bin");
}
//
// // Run all tiny test vectors
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

// Helper function to run individual tests
fn runTest(comptime params: jam_params.Params, allocator: std.mem.Allocator, test_bin: []const u8) !void {
    std.debug.print("\nRunning test: {s}\n", .{test_bin});

    const test_vector = try @import("jamtestvectors/loader.zig").loadAndDeserializeTestVector(
        tvector.TestCase,
        params,
        allocator,
        test_bin,
    );
    defer test_vector.deinit(allocator);

    try runReportTest(params, allocator, test_vector);
}

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
