const std = @import("std");

const converters = @import("./converters.zig");
const tvector = @import("../jamtestvectors/disputes.zig");

const disputes = @import("../disputes.zig");
const stf = @import("../stf.zig");

const helpers = @import("../tests/helpers.zig");

const Params = @import("../jam_params.zig").Params;

pub fn runDisputeTest(allocator: std.mem.Allocator, comptime params: Params, test_case: tvector.TestCase) !void {
    var current_psi = try converters.convertPsi(allocator, test_case.pre_state.psi);
    defer current_psi.deinit();
    var expected_psi = try converters.convertPsi(allocator, test_case.post_state.psi);
    defer expected_psi.deinit();

    var current_rho = try converters.convertRho(params.core_count, allocator, test_case.pre_state.rho);
    defer current_rho.deinit();
    var expected_rho = try converters.convertRho(params.core_count, allocator, test_case.post_state.rho);
    defer expected_rho.deinit();

    const current_epoch = test_case.pre_state.tau / params.epoch_length;
    const transition_result = stf.transitionDisputes(
        params.validators_count,
        params.core_count,
        allocator,
        &current_psi,
        test_case.pre_state.kappa,
        test_case.pre_state.lambda,
        &current_rho,
        current_epoch,
        test_case.input.disputes,
    );

    defer {
        if (transition_result) |psi| {
            defer @constCast(&psi).deinit();
        } else |_| {} // this needs to be here to satisfy the compiler
    }

    switch (test_case.output) {
        .err => |expected_error| {
            if (transition_result) |_| {
                std.debug.print("\nGot a success, expected error: {any}\n", .{expected_error});
                return error.UnexpectedSuccess;
            } else |actual_error| {
                const mapped_expected_error = switch (expected_error) {
                    .already_judged => error.AlreadyJudged,
                    .bad_vote_split => error.BadVoteSplit,
                    .verdicts_not_sorted_unique => error.VerdictsNotSortedUnique,
                    .judgements_not_sorted_unique => error.JudgementsNotSortedUnique,
                    .culprits_not_sorted_unique => error.CulpritsNotSortedUnique,
                    .faults_not_sorted_unique => error.FaultsNotSortedUnique,
                    .not_enough_culprits => error.NotEnoughCulprits,
                    .not_enough_faults => error.NotEnoughFaults,
                    .culprits_verdict_not_bad => error.CulpritsVerdictNotBad,
                    .fault_verdict_wrong => error.FaultVerdictWrong,
                    .offender_already_reported => error.OffenderAlreadyReported,
                    .bad_judgement_age => error.BadJudgementAge,
                    .bad_validator_index => error.BadValidatorIndex,
                    .bad_signature => error.BadSignature,
                };
                std.debug.print("\nExpected error: {any} => {any} got error {any}\n", .{ expected_error, mapped_expected_error, actual_error });
                try std.testing.expectEqual(mapped_expected_error, actual_error);
            }
        },
        .ok => |expected_marks| {
            if (transition_result) |transitioned_psi| {
                // push all expected marks in an AutoHashMap
                var expected_marks_map = std.AutoArrayHashMap(disputes.PublicKey, void).init(allocator);
                defer expected_marks_map.deinit();

                for (expected_marks.offenders_mark.items) |mark| {
                    try expected_marks_map.put(mark, {});
                }

                try helpers.expectHashMapEqual(@TypeOf(expected_marks_map), disputes.PublicKey, void, expected_marks_map, transitioned_psi.punish_set);
                // Compare the rest of the fields
                try helpers.expectHashMapEqual(@TypeOf(expected_psi.good_set), disputes.Hash, void, expected_psi.good_set, transitioned_psi.good_set);
                try helpers.expectHashMapEqual(@TypeOf(expected_psi.bad_set), disputes.Hash, void, expected_psi.bad_set, transitioned_psi.bad_set);
                try helpers.expectHashMapEqual(@TypeOf(expected_psi.wonky_set), disputes.Hash, void, expected_psi.wonky_set, transitioned_psi.wonky_set);

                // Compare the two Rho states
                try std.testing.expectEqualDeep(expected_rho, current_rho);
            } else |err| {
                std.debug.print("UnexpectedError: {any}\n", .{err});
                return error.UnexpectedError;
            }
        },
    }
}
