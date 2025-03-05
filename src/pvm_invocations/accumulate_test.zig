const std = @import("std");
const testing = std.testing;

const types = @import("../types.zig");
const state = @import("../state.zig");
const jam_params = @import("../jam_params.zig");

const accumulate = @import("accumulate.zig");

const Params = jam_params.TINY_PARAMS;

const JAMDUNA_PARAMS = @import("../jamtestnet.zig").JAMDUNA_PARAMS;
const jamtestnet = @import("../jamtestnet/parsers.zig");
const state_dict = @import("../state_dictionary.zig");

const JamdunaLoader = jamtestnet.jamduna.Loader(JAMDUNA_PARAMS);

test "accumulate_invocation" {
    const allocator = std.testing.allocator;

    const loader = (JamdunaLoader{}).loader();

    // The point where the work report is introduced in the Guarantee Extrinsic
    var state_transition_guarantee = try loader.loadTestVector(
        allocator,
        "src/jamtestnet/teams/jamduna/data/assurances/state_transitions/1_004.bin",
    );
    defer state_transition_guarantee.deinit(allocator);

    const block = state_transition_guarantee.block();
    const work_report = block.extrinsic.guarantees.data[0].report;

    // The point in assurances we should accumulate 1 immediate report
    var state_transition = try loader.loadTestVector(
        allocator,
        "src/jamtestnet/teams/jamduna/data/assurances/state_transitions/1_005.bin",
    );
    defer state_transition.deinit(allocator);

    // Reconstruct our state
    var pre_state_mdict = try state_transition.preStateAsMerklizationDict(allocator);
    defer pre_state_mdict.deinit();
    var pre_state = try state_dict.reconstruct.reconstructState(
        JAMDUNA_PARAMS,
        allocator,
        &pre_state_mdict,
    );
    defer pre_state.deinit(allocator);

    // Build accumulation context
    const accumulation_context = accumulate.AccumulationContext(JAMDUNA_PARAMS){
        .service_accounts = &pre_state.delta.?,
        .validator_keys = &pre_state.iota.?,
        .authorizer_queue = &pre_state.phi.?,
        .privileges = &pre_state.chi.?,
    };

    // "results": [
    //     {
    //         "service_id": 0,
    //         "code_hash": "0xbd87fb6de829abf2bb25a15b82618432c94e82848d9dd204f5d775d4b880ae0d",
    //         "payload_hash": "0x1696c28b7d5556f392dd7e882ab52cd49994fe6c5a3f5c80d4fa52302dff0b6b",
    //         "accumulate_gas": 9111,
    //         "result": {
    //             "ok": "0xda81fb234123c13b77808557789a8716de33f226e25b9a26d669eabf8d56fec397040000"
    //         }
    //     }

    // Get the single result

    // Invoke accumulation with the current time slot from the pre-state
    const current_tau = pre_state.tau.?;

    // Use the service ID from the first result, we should iterate over all of the
    const service_id = work_report.results[0].service_id;
    // Since we have only one report use this gas, normally we would add privileged services and ..
    const gas_limit = work_report.results[0].accumulate_gas;

    const operands = try accumulate.AccumulationOperand.fromWorkReport(allocator, work_report);
    defer {
        for (operands) |*op| {
            op.deinit(allocator);
        }
        allocator.free(operands);
    }

    // entropy (for new_service_id)
    const entropy = pre_state.eta.?[0];

    // Invoke accumulation
    const result = try accumulate.invoke(
        JAMDUNA_PARAMS,
        allocator,
        accumulation_context,
        current_tau,
        entropy,
        service_id,
        gas_limit,
        operands,
    );

    // Check basic results
    std.debug.print("Accumulation completed with gas used: {d}\n", .{result.gas_used});
    std.debug.print("Transfers count: {d}\n", .{result.transfers.len});

    if (result.accumulation_output) |accum_output| {
        std.debug.print("Accumulation output: {any}\n", .{accum_output});
    } else {
        std.debug.print("No accumulation output provided\n", .{});
    }
}
