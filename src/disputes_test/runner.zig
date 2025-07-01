const std = @import("std");

const converters = @import("./converters.zig");
const tvector = @import("../jamtestvectors/disputes.zig");

const disputes = @import("../disputes.zig");
const stf = @import("../stf.zig");
const state = @import("../state.zig");

const helpers = @import("../tests/helpers.zig");

const Params = @import("../jam_params.zig").Params;

pub fn runDisputeTest(allocator: std.mem.Allocator, comptime params: Params, test_case: tvector.TestCase) !void {
    var pre_state_psi = try converters.convertPsi(allocator, test_case.pre_state.psi);
    defer pre_state_psi.deinit();
    var post_state_psi = try converters.convertPsi(allocator, test_case.post_state.psi);
    defer post_state_psi.deinit();

    var pre_state_rho = try converters.convertRho(params.core_count, allocator, test_case.pre_state.rho);
    defer pre_state_rho.deinit();
    var post_state_rho = try converters.convertRho(params.core_count, allocator, test_case.post_state.rho);
    defer post_state_rho.deinit();

    // Build our state transition
    const StateTransition = @import("../state_delta.zig").StateTransition;
    var current_state = state.JamState(params){
        .psi = try pre_state_psi.deepClone(),
        .rho = try pre_state_rho.deepClone(allocator),
        .tau = test_case.pre_state.tau,
        .kappa = try test_case.pre_state.kappa.deepClone(allocator),
        .lambda = try test_case.pre_state.lambda.deepClone(allocator),
    };
    defer current_state.deinit(allocator);

    const time = params.Time().init(
        test_case.pre_state.tau,
        test_case.pre_state.tau + 1, // alluming + 1
    );
    var stx = try StateTransition(params).init(allocator, &current_state, time);
    defer stx.deinit();

    const result = stf.disputes.transition(
        params,
        allocator,
        &stx,
        test_case.input.disputes,
    );

    switch (test_case.output) {
        .err => |expected_error| {
            if (result) |_| {
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
                    .bad_guarantor_key => error.BadGuarantorKey,
                    .bad_auditor_key => error.BadAuditorKey,
                };
                std.debug.print("\nExpected error: {any} => {any} got error {any}\n", .{ expected_error, mapped_expected_error, actual_error });
                try std.testing.expectEqual(mapped_expected_error, actual_error);
            }
        },
        .ok => |expected_marks| {
            if (result) |_| {
                const transitioned_psi = stx.prime.psi.?;
                const transitioned_rho = stx.prime.rho.?;

                // push all expected marks in an AutoHashMap
                var expected_marks_map = std.AutoArrayHashMap(disputes.PublicKey, void).init(allocator);
                defer expected_marks_map.deinit();

                for (expected_marks.offenders_mark) |mark| {
                    try expected_marks_map.put(mark, {});
                }

                try helpers.expectHashMapEqual(@TypeOf(expected_marks_map), disputes.PublicKey, void, expected_marks_map, transitioned_psi.punish_set);
                // Compare the rest of the fields
                try helpers.expectHashMapEqual(@TypeOf(post_state_psi.good_set), disputes.Hash, void, post_state_psi.good_set, transitioned_psi.good_set);
                try helpers.expectHashMapEqual(@TypeOf(post_state_psi.bad_set), disputes.Hash, void, post_state_psi.bad_set, transitioned_psi.bad_set);
                try helpers.expectHashMapEqual(@TypeOf(post_state_psi.wonky_set), disputes.Hash, void, post_state_psi.wonky_set, transitioned_psi.wonky_set);

                // Compare the two Rho states
                try std.testing.expectEqualDeep(post_state_rho, transitioned_rho);
            } else |err| {
                std.debug.print("UnexpectedError: {any}\n", .{err});
                return error.UnexpectedError;
            }
        },
    }
}
