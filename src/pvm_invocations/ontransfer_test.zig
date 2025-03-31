const std = @import("std");
const testing = std.testing;

const types = @import("../types.zig");
const state = @import("../state.zig");
const jam_params = @import("../jam_params.zig");

const ontransfer = @import("ontransfer.zig");

const Params = jam_params.TINY_PARAMS;

const JAMDUNA_PARAMS = @import("../jamtestnet.zig").JAMDUNA_PARAMS;
const jamtestnet = @import("../jamtestnet/parsers.zig");
const state_dict = @import("../state_dictionary.zig");

const state_diff = @import("../tests/state_diff.zig");

const JamdunaLoader = jamtestnet.jamduna.Loader(JAMDUNA_PARAMS);

test "ontransfer_invocation" {
    const allocator = std.testing.allocator;

    const loader = (JamdunaLoader{}).loader();

    // The point where the work report is introduced in the Guarantee Extrinsic
    var state_transition_guarantee = try loader.loadTestVector(
        allocator,
        "src/jamtestnet/teams/jamduna/data/assurances/state_transitions/1_004.bin",
    );
    defer state_transition_guarantee.deinit(allocator);

    const work_report = state_transition_guarantee.block().extrinsic.guarantees.data[0].report;

    // The point in assurances we should accumulate 1 immediate report
    var state_transition = try loader.loadTestVector(
        allocator,
        "src/jamtestnet/teams/jamduna/data/assurances/state_transitions/1_005.bin",
    );
    defer state_transition.deinit(allocator);

    const block = state_transition.block();

    // Reconstruct our state
    var pre_state_mdict = try state_transition.preStateAsMerklizationDict(allocator);
    defer pre_state_mdict.deinit();
    var pre_state = try state_dict.reconstruct.reconstructState(
        JAMDUNA_PARAMS,
        allocator,
        &pre_state_mdict,
    );
    defer pre_state.deinit(allocator);

    // Get the expected post-state that we should compare against
    var post_state_mdict = try state_transition.postStateAsMerklizationDict(allocator);
    defer post_state_mdict.deinit();
    var post_state = try state_dict.reconstruct.reconstructState(
        JAMDUNA_PARAMS,
        allocator,
        &post_state_mdict,
    );
    defer post_state.deinit(allocator);

    // This has to be H_t
    const current_tau = block.header.slot;

    // Use the service ID from the first result, we should iterate over all of the
    const service_id = work_report.results[0].service_id;
    // Since we have only one report use this gas, normally we would add privileged services and ..
    // const gas_limit = work_report.results[0].accumulate_gas;

    const DeltaSnapshot = @import("../services_snapshot.zig").DeltaSnapshot;

    // Build accumulation context
    var ontransfer_context = ontransfer.OnTransferContext{
        .service_id = service_id,
        .service_accounts = DeltaSnapshot.init(&pre_state.delta.?),
        .allocator = allocator,
    };
    defer ontransfer_context.deinit();

    // Invoke accumulation
    //
    var result = try ontransfer.invoke(
        JAMDUNA_PARAMS,
        allocator,
        &ontransfer_context,
        current_tau,
        service_id,
        &[_]ontransfer.DeferredTransfer{},
    );
    defer result.deinit(allocator);

    try ontransfer_context.commit();
}
