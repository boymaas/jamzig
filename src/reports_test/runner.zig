const std = @import("std");
const converters = @import("./converters.zig");
const tvector = @import("../jamtestvectors/reports.zig");
const reports = @import("../reports.zig");
const state = @import("../state.zig");
const types = @import("../types.zig");
const helpers = @import("../tests/helpers.zig");
const diff = @import("../tests/diff.zig");
const Params = @import("../jam_params.zig").Params;

pub fn validateAndProcessGuaranteeExtrinsic(
    comptime params: Params,
    allocator: std.mem.Allocator,
    test_case: *const tvector.TestCase,
    jam_state: *state.JamState(params),
) !reports.Result {
    // First validate the guarantee extrinsic
    const validated_extrinsic = try reports.ValidatedGuaranteeExtrinsic.validate(
        params,
        allocator,
        test_case.input.guarantees,
        test_case.input.slot,
        jam_state,
    );

    // Process the validated extrinsic
    const result = try reports.processGuaranteeExtrinsic(
        params,
        allocator,
        validated_extrinsic,
        test_case.input.slot,
        jam_state,
    );

    return result;
}

pub fn runReportTest(comptime params: Params, allocator: std.mem.Allocator, test_case: tvector.TestCase) !void {
    // Convert pre-state from test vector format to native format
    var pre_state = try converters.convertState(params, allocator, test_case.pre_state);
    defer pre_state.deinit(allocator);

    // Convert post-state for later comparison
    var expected_state = try converters.convertState(params, allocator, test_case.post_state);
    defer expected_state.deinit(allocator);

    var process_result = validateAndProcessGuaranteeExtrinsic(
        params,
        allocator,
        &test_case,
        &pre_state,
    );
    defer {
        if (process_result) |*result| {
            result.deinit(allocator);
        } else |_| {}
    }

    switch (test_case.output) {
        .err => |expected_error| {
            if (process_result) |_| {
                std.debug.print("\nGot success, expected error: {any}\n", .{expected_error});
                return error.UnexpectedSuccess;
            } else |actual_error| {
                // Map the error
                const mapped_expected_error = switch (expected_error) {
                    .bad_core_index => error.BadCoreIndex,
                    .future_report_slot => error.FutureReportSlot,
                    .report_epoch_before_last => error.ReportEpochBeforeLast,
                    .insufficient_guarantees => error.InsufficientGuarantees,
                    .out_of_order_guarantee => error.OutOfOrderGuarantee,
                    .not_sorted_or_unique_guarantors => error.NotSortedOrUniqueGuarantors,
                    .wrong_assignment => error.WrongAssignment,
                    .core_engaged => error.CoreEngaged,
                    .anchor_not_recent => error.AnchorNotRecent,
                    .bad_service_id => error.BadServiceId,
                    .bad_code_hash => error.BadCodeHash,
                    .dependency_missing => error.DependencyMissing,
                    .duplicate_package => error.DuplicatePackage,
                    .bad_state_root => error.BadStateRoot,
                    .bad_beefy_mmr_root => error.BadBeefyMmrRoot,
                    .core_unauthorized => error.CoreUnauthorized,
                    .bad_validator_index => error.BadValidatorIndex,
                    .work_report_gas_too_high => error.WorkReportGasTooHigh,
                    .service_item_gas_too_low => error.ServiceItemGasTooLow,
                    .too_many_dependencies => error.TooManyDependencies,
                    .segment_root_lookup_invalid => error.SegmentRootLookupInvalid,
                    .bad_signature => error.BadSignature,
                    .work_report_too_big => error.WorkReportTooBig,
                };
                if (mapped_expected_error != actual_error) {
                    std.debug.print("\nExpected error: {any} => {any} got error {any}\n", .{ expected_error, mapped_expected_error, actual_error });
                }
                try std.testing.expectEqual(mapped_expected_error, actual_error);
            }
        },
        .ok => |expected_output| {
            if (process_result) |result| {
                // Verify outputs match expected results

                // ensure results are sorted so we can match
                std.mem.sortUnstable(types.ReportedWorkPackage, result.reported, {}, struct {
                    pub fn inner(_: void, a: types.ReportedWorkPackage, b: types.ReportedWorkPackage) bool {
                        return std.mem.order(u8, &a.hash, &b.hash) == .lt;
                    }
                }.inner);
                diff.expectTypesFmtEqual(
                    []types.ReportedWorkPackage,
                    allocator,
                    result.reported,
                    expected_output.reported,
                ) catch {
                    std.debug.print("Mismatch Reported: actual output != expected output\n", .{});
                    return error.OutputMismatch;
                };

                // ensure reporters are sorted so we can match
                std.mem.sortUnstable(types.Ed25519Public, result.reporters, {}, struct {
                    pub fn inner(_: void, a: types.Ed25519Public, b: types.Ed25519Public) bool {
                        return std.mem.order(u8, &a, &b) == .lt;
                    }
                }.inner);
                diff.expectTypesFmtEqual(
                    []types.Ed25519Public,
                    allocator,
                    result.reporters,
                    expected_output.reporters,
                ) catch {
                    std.debug.print("Mismatch Reporters: actual output != expected output\n", .{});
                    return error.OutputMismatch;
                };

                // Verify state matches expected state
                diff.expectFormattedEqual(*state.JamState(params), allocator, &pre_state, &expected_state) catch {
                    std.debug.print("Mismatch: actual state != expected state\n", .{});
                    return error.StateMismatch;
                };
            } else |err| {
                std.debug.print("UnexpectedError: {any}\n", .{err});
                return error.UnexpectedError;
            }
        },
    }
}
