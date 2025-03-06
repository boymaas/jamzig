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

const state_diff = @import("../tests/state_diff.zig");

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

    // Build accumulation context
    const accumulation_context = accumulate.AccumulationContext(JAMDUNA_PARAMS){
        .service_accounts = &pre_state.delta.?,
        .validator_keys = &pre_state.iota.?,
        .authorizer_queue = &pre_state.phi.?,
        .privileges = &pre_state.chi.?,
    };

    // This has to be H_t
    const current_tau = block.header.slot;

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

    // entropy (for new_service_id) n0'
    const libentropy = @import("../entropy.zig");
    const entropy = libentropy.update(pre_state.eta.?[0], try block.header.getEntropy());

    // Invoke accumulation
    //
    // ensure we free the possiblity allocated Cached HostFn map
    defer @import("accumulate/host_calls_map.zig").deinitCachedMap(allocator);
    var result = try accumulate.invoke(
        JAMDUNA_PARAMS,
        allocator,
        accumulation_context,
        current_tau,
        entropy,
        service_id,
        gas_limit,
        operands,
    );
    defer result.deinit(allocator);

    // Check basic results
    std.debug.print("Accumulation completed with gas used: {d}\n", .{result.gas_used});
    std.debug.print("Transfers count: {d}\n", .{result.transfers.len});

    // Apply the transfers, transfer already deducted from sender
    for (result.transfers) |transfer| {
        // const sender = pre_state.delta.?.getAccount(transfer.sender).?;
        const destination = pre_state.delta.?.getAccount(transfer.destination).?;

        // sender.balance -= transfer.amount;
        destination.balance += transfer.amount;
        std.debug.print("Applied transfer: {}", .{types.fmt.format(transfer)});
    }

    if (result.accumulation_output) |accum_output| {
        std.debug.print("Accumulation output: {any}\n", .{accum_output});
    } else {
        std.debug.print("No accumulation output provided\n", .{});
    }

    // Create a filtered version of both states containing only components that should be affected by accumulation
    try removeUnusedStateComponents(JAMDUNA_PARAMS, &pre_state);
    try removeUnusedStateComponents(JAMDUNA_PARAMS, &post_state);

    // Now use the state_diff to compare the filtered states
    var diff = try state_diff.JamStateDiff(JAMDUNA_PARAMS).build(allocator, &pre_state, &post_state);
    defer diff.deinit();

    // If there are differences, print them and fail the test
    if (diff.hasChanges()) {
        std.debug.print("State differences detected after accumulation:\n", .{});
        diff.printToStdErr();
        return error.UnexpectedStateDiff;
    } else {
        std.debug.print("State verification passed - accumulation produced expected state changes\n", .{});
    }
}

fn removeUnusedStateComponents(comptime params: jam_params.Params, jam_state: *state.JamState(params)) !void {
    const callDeinit = @import("../meta.zig").callDeinit;

    // Define which components we want to keep (relevant for accumulation)
    const componentsToKeep = [_][]const u8{
        "delta", // Service accounts
        "chi", // Privileges
        "phi", // Authorizer queue
    };

    // Use metaprogramming to iterate through all fields in the JamState struct
    inline for (std.meta.fields(state.JamState(params))) |field| {
        // Skip the fields we want to keep
        const shouldKeep = blk: {
            for (componentsToKeep) |keep| {
                if (std.mem.eql(u8, keep, field.name)) {
                    break :blk true;
                }
            }
            break :blk false;
        };

        if (!shouldKeep) {
            // Check if the field is not null (initialized)
            if (@field(jam_state, field.name)) |*value| {
                // Use the existing deinitField helper
                callDeinit(value, std.testing.allocator);

                // Set the field to null (deinitField doesn't do this for us)
                @field(jam_state, field.name) = null;
            }
        }
    }
}
