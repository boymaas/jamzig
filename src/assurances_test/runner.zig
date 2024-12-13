const std = @import("std");
const converters = @import("./converters.zig");
const tvector = @import("../jamtestvectors/assurances.zig");
const assurances = @import("../assurances.zig");
const types = @import("../types.zig");
const helpers = @import("../tests/helpers.zig");
const Params = @import("../jam_params.zig").Params;

pub fn runAssuranceTest(allocator: std.mem.Allocator, comptime params: Params, test_case: tvector.TestCase) !void {
    // Convert pre-state from test vector format to native format
    var pre_state_assignments = try converters.convertAvailabilityAssignments(params.core_count, allocator, test_case.pre_state.avail_assignments);
    defer pre_state_assignments.deinit(allocator);

    var pre_state_validators = try converters.convertValidatorSet(allocator, test_case.pre_state.curr_validators);
    defer pre_state_validators.deinit(allocator);

    // Convert post-state for later comparison
    var expected_assignments = try converters.convertAvailabilityAssignments(params.core_count, allocator, test_case.post_state.avail_assignments);
    defer expected_assignments.deinit(allocator);

    var expected_validators = try converters.convertValidatorSet(allocator, test_case.post_state.curr_validators);
    defer expected_validators.deinit(allocator);

    // First validate the assurance extrinsic
    const validated_extrinsic = assurances.ValidatedAssuranceExtrinsic.validate(params, test_case.input.assurances, test_case.input.parent, pre_state_validators);

    switch (test_case.output) {
        .err => |expected_error| {
            if (validated_extrinsic) |_| {
                std.debug.print("\nGot a success, expected error: {any}\n", .{expected_error});
                return error.UnexpectedSuccess;
            } else |actual_error| {
                const mapped_expected_error = switch (expected_error) {
                    .bad_attestation_parent => error.InvalidAnchorHash,
                    .bad_validator_index => error.InvalidValidatorIndex,
                    .core_not_engaged => error.InvalidBitfieldSize,
                    .bad_signature => error.InvalidSignature,
                    .not_sorted_or_unique_assurers => error.NotSortedValidatorIndex,
                };
                std.debug.print("\nExpected error: {any} => {any} got error {any}\n", .{ expected_error, mapped_expected_error, actual_error });
                try std.testing.expectEqual(mapped_expected_error, actual_error);
            }
        },
        .ok => |expected_marks| {
            if (validated_extrinsic) |valid_extrinsic| {
                // Process the validated extrinsic
                const reported = try assurances.processAssuranceExtrinsic(params, allocator, valid_extrinsic, &pre_state_assignments);
                defer allocator.free(reported);

                // Verify outputs match expected results
                try std.testing.expectEqual(reported.len, expected_marks.reported.len);
                for (reported, expected_marks.reported) |actual, expected| {
                    try std.testing.expectEqualDeep(actual, expected);
                }

                // Verify state matches expected state
                try std.testing.expectEqualDeep(pre_state_assignments, expected_assignments);
                try std.testing.expectEqualDeep(pre_state_validators, expected_validators);
            } else |err| {
                std.debug.print("UnexpectedError: {any}\n", .{err});
                return error.UnexpectedError;
            }
        },
    }
}
