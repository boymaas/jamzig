const std = @import("std");
const converters = @import("./converters.zig");
const tvector = @import("../jamtestvectors/reports.zig");
const reports = @import("../reports.zig");
const stats = @import("../stf/validator_stats.zig");
const state = @import("../state.zig");
const types = @import("../types.zig");
const helpers = @import("../tests/helpers.zig");
const diff = @import("../tests/diff.zig");
const Params = @import("../jam_params.zig").Params;
const StateTransition = @import("../state_delta.zig").StateTransition;

pub fn buildValidatorStatsInput(test_case: *const tvector.TestCase) stats.ValidatorStatsInput {
    return stats.ValidatorStatsInput{
        .author_index = null, // Use a default value since test vectors don't specify an author
        .guarantees = test_case.input.guarantees.data,
        .assurances = &[_]types.AvailAssurance{}, // Empty as test vectors don't include assurances
        .tickets_count = 0, // No tickets in the test vector
        .preimages = &[_]types.Preimage{}, // No preimages in the test vector
        .guarantor_reporters = &[_]types.Ed25519Public{}, // Empty for test vectors
        .assurance_validators = &[_]types.ValidatorIndex{}, // Empty for test vectors
    };
}

pub fn validateAndProcessGuaranteeExtrinsic(
    comptime params: Params,
    allocator: std.mem.Allocator,
    test_case: *const tvector.TestCase,
    jam_state: *const state.JamState(params),
) !reports.Result {
    const time = params.Time().init(
        test_case.input.slot - 1,
        test_case.input.slot,
    );

    var stx = try StateTransition(params).init(allocator, jam_state, time);
    defer stx.deinit();

    const validated_extrinsic = try reports.ValidatedGuaranteeExtrinsic.validate(
        params,
        allocator,
        &stx,
        test_case.input.guarantees,
    );

    const result = try reports.processGuaranteeExtrinsic(
        params,
        allocator,
        &stx,
        validated_extrinsic,
    );

    var empty_accumulate_stats = std.AutoHashMap(types.ServiceId, @import("../accumulate.zig").execution.AccumulationServiceStats).init(allocator);
    defer empty_accumulate_stats.deinit();
    var empty_invoked_services = std.AutoArrayHashMap(types.ServiceId, void).init(allocator);
    defer empty_invoked_services.deinit();

    const accumulate_result = @import("../accumulate.zig").ProcessAccumulationResult{
        .accumulate_root = [_]u8{0} ** 32,
        .accumulation_stats = empty_accumulate_stats,
        .invoked_services = empty_invoked_services,
    };

    try stats.transitionWithInput(
        params,
        &stx,
        buildValidatorStatsInput(test_case),
        &accumulate_result,
        &[_]types.WorkReport{},
    );

    try stx.mergePrimeOntoBase();

    return result;
}

pub fn runReportTest(comptime params: Params, allocator: std.mem.Allocator, test_case: tvector.TestCase) !void {
    var current_state = try converters.convertState(params, allocator, test_case.pre_state);
    defer current_state.deinit(allocator);

    var expected_state = try converters.convertState(params, allocator, test_case.post_state);
    defer expected_state.deinit(allocator);

    var process_result = validateAndProcessGuaranteeExtrinsic(
        params,
        allocator,
        &test_case,
        &current_state,
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
                const mapped_expected_error = switch (expected_error) {
                    .bad_core_index => error.BadCoreIndex,
                    .future_report_slot => error.FutureReportSlot,
                    .report_epoch_before_last => error.ReportEpochBeforeLast,
                    .insufficient_guarantees => error.InsufficientGuarantees,
                    .out_of_order_guarantee => error.OutOfOrderGuarantee,
                    .not_sorted_or_unique_guarantors => error.NotSortedOrUniqueGuarantors,
                    .wrong_assignment => error.InvalidGuarantorAssignment,
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
                    .banned_validators => error.BannedValidators,
                    .lookup_anchor_not_recent => error.LookupAnchorNotRecent,  // v0.7.2
                    .missing_work_results => error.MissingWorkResults,  // v0.7.2
                };
                if (mapped_expected_error != actual_error) {
                    std.debug.print("\nExpected error: {any} => {any} got error {any}\n", .{ expected_error, mapped_expected_error, actual_error });
                }
                try std.testing.expectEqual(mapped_expected_error, actual_error);
            }
        },
        .ok => |expected_output| {
            if (process_result) |result| {
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

                diff.expectFormattedEqual(
                    *state.JamState(params),
                    allocator,
                    &current_state,
                    &expected_state,
                ) catch {
                    std.debug.print("Mismatch: actual state != expected state\n", .{});
                    std.debug.print("{}", .{expected_state});
                    return error.StateMismatch;
                };
            } else |err| {
                std.debug.print("UnexpectedError: {any}\n", .{err});
                return error.UnexpectedError;
            }
        },
    }
}
