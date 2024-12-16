const std = @import("std");
const converters = @import("./converters.zig");
const tvector = @import("../jamtestvectors/assurances.zig");
const assurances = @import("../assurances.zig");
const state = @import("../state.zig");
const types = @import("../types.zig");
const helpers = @import("../tests/helpers.zig");
const diff = @import("../tests/diff.zig");
const Params = @import("../jam_params.zig").Params;

pub fn validateAndProcessAssuranceExtrinsic(
    comptime params: Params,
    allocator: std.mem.Allocator,
    test_case: *const tvector.TestCase,
    rho: *state.Rho(params.core_count),
    kappa: types.ValidatorSet,
) !assurances.AvailableAssignments {
    const valid_extrinsic = try assurances.ValidatedAssuranceExtrinsic.validate(
        params,
        test_case.input.assurances,
        test_case.input.parent,
        kappa,
    );

    // Process the validated extrinsic
    const available_assignments = try assurances.processAssuranceExtrinsic(
        params,
        allocator,
        valid_extrinsic,
        test_case.input.slot,
        rho,
    );
    return available_assignments;
}

pub fn runAssuranceTest(comptime params: Params, allocator: std.mem.Allocator, test_case: tvector.TestCase) !void {
    // Convert pre-state from test vector format to native format
    var pre_state_assignments = try converters.convertAvailabilityAssignments(
        params.core_count,
        allocator,
        test_case.pre_state.avail_assignments,
    );
    defer pre_state_assignments.deinit();

    var pre_state_validators = try converters.convertValidatorSet(allocator, test_case.pre_state.curr_validators);
    defer pre_state_validators.deinit(allocator);

    // Convert post-state for later comparison
    var expected_assignments = try converters.convertAvailabilityAssignments(
        params.core_count,
        allocator,
        test_case.post_state.avail_assignments,
    );
    defer expected_assignments.deinit();

    var expected_validators = try converters.convertValidatorSet(allocator, test_case.post_state.curr_validators);
    defer expected_validators.deinit(allocator);

    // First validate the assurance extrinsic

    const process_result = validateAndProcessAssuranceExtrinsic(
        params,
        allocator,
        &test_case,
        &pre_state_assignments,
        pre_state_validators,
    );
    defer {
        if (process_result) |available_assignments| {
            available_assignments.deinit(allocator);
        } else |_| {}
    }

    switch (test_case.output) {
        .err => |expected_error| {
            if (process_result) |_| {
                std.debug.print("\nGot a success, expected error: {any}\n", .{expected_error});
                return error.UnexpectedSuccess;
            } else |actual_error| {
                const mapped_expected_error = switch (expected_error) {
                    .bad_attestation_parent => error.InvalidAnchorHash,
                    .bad_validator_index => error.InvalidValidatorIndex,
                    .core_not_engaged => error.CoreNotEngaged,
                    .bad_signature => error.InvalidSignature,
                    .not_sorted_or_unique_assurers => error.NotSortedOrUniqueValidatorIndex,
                };
                if (mapped_expected_error != actual_error) {
                    std.debug.print("\nExpected error: {any} => {any} got error {any}\n", .{ expected_error, mapped_expected_error, actual_error });
                }
                try std.testing.expectEqual(mapped_expected_error, actual_error);
            }
        },
        .ok => |expected_marks| {
            if (process_result) |available_assignments| {
                const state_rho = &pre_state_assignments;
                const state_kappa = &pre_state_validators;

                const available_reports = try @import("../utils.zig").mapAlloc(
                    types.AvailabilityAssignment,
                    types.WorkReport,
                    allocator,
                    available_assignments.inner,
                    struct {
                        pub fn map(assignment: types.AvailabilityAssignment) types.WorkReport {
                            return assignment.report;
                        }
                    }.map,
                );
                // NOTE: only slice needs to be freed, available_assignments.deinit will free
                // inner memory
                defer allocator.free(available_reports);

                // Verify outputs match expected results
                diff.expectTypesFmtEqual([]types.WorkReport, allocator, available_reports, expected_marks.reported) catch {
                    std.debug.print("Mismatch: available reports != expected reports\n", .{});
                    return error.ReportMismatch;
                };

                // Verify state matches expected state
                diff.expectFormattedEqual(*state.Rho(params.core_count), allocator, state_rho, &expected_assignments) catch {
                    std.debug.print("Mismatch: actual Rho != expected Rho\n", .{});
                    return error.StateRhoMismatch;
                };

                diff.expectTypesFmtEqual(*types.ValidatorSet, allocator, state_kappa, &expected_validators) catch {
                    std.debug.print("Mismatch: actual Kappa != expected Kappa\n", .{});
                    return error.StateKappaMismatch;
                };
            } else |err| {
                std.debug.print("UnexpectedError: {any}\n", .{err});
                return error.UnexpectedError;
            }
        },
    }
}
