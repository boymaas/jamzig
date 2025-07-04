const std = @import("std");
const testing = std.testing;

pub const parsers = @import("jamtestnet/parsers.zig");
pub const state_transitions = @import("jamtestnet/state_transitions.zig");

const stf = @import("stf.zig");
const types = @import("types.zig");
const state = @import("state.zig");
const state_dict = @import("state_dictionary.zig");
const state_delta = @import("state_delta.zig");
const codec = @import("codec.zig");
const services = @import("services.zig");

const jam_params = @import("jam_params.zig");

const jamtestnet = @import("jamtestnet/parsers.zig");

const tracing = @import("tracing.zig");
const trace = tracing.scoped(.stf_test);

// we derive from the normal settings
// see: https://github.com/jam-duna/jamtestnet/blob/main/chainspecs.json#L2
pub const JAMDUNA_PARAMS = jam_params.Params{
    .epoch_length = 12,
    .ticket_submission_end_epoch_slot = 10,
    .validators_count = 6,
    .validators_super_majority = 5,
    .validator_rotation_period = 4,
    .core_count = 2,
    .avail_bitfield_bytes = (2 + 7) / 8,
    // JAMDUNA changes
    .max_tickets_per_extrinsic = 3, // K
    .max_ticket_entries_per_validator = 3, // N
    .max_authorizations_queue_items = 80, // Q
    .max_authorizations_pool_items = 8, // O
    .preimage_expungement_period = 6, // D
};

// TODO: add these
// {
//     "tiny": {
//         "segment_size": 4104,
//         "ec_piece_size": 4,
//         "num_ec_pieces_per_segment": 1026,
//     },
//
// test "jamduna:fallback" {
//     const allocator = std.testing.allocator;
//     const loader = jamtestnet.jamduna.Loader(JAMDUNA_PARAMS){};
//     try runStateTransitionTests(
//         JAMDUNA_PARAMS,
//         loader.loader(),
//         allocator,
//         "src/jamtestnet/teams/jamduna/data/fallback/state_transitions",
//     );
// }
//
// test "jamduna:safrole" {
//     const allocator = std.testing.allocator;
//     const loader = jamtestnet.jamduna.Loader(JAMDUNA_PARAMS){};
//     try runStateTransitionTests(
//         JAMDUNA_PARAMS,
//         loader.loader(),
//         allocator,
//         "src/jamtestnet/teams/jamduna/data/safrole/state_transitions",
//     );
// }
//
// test "jamduna:assurances" {
//     const allocator = std.testing.allocator;
//
//     const loader = jamtestnet.jamduna.Loader(JAMDUNA_PARAMS){};
//     try runStateTransitionTests(
//         JAMDUNA_PARAMS,
//         loader.loader(),
//         allocator,
//         "src/jamtestnet/teams/jamduna/data/assurances/state_transitions",
//     );
// }
//
// test "jamduna:orderedaccumulation" {
//     const allocator = std.testing.allocator;
//
//     const loader = jamtestnet.jamduna.Loader(JAMDUNA_PARAMS){};
//     try runStateTransitionTests(
//         JAMDUNA_PARAMS,
//         loader.loader(),
//         allocator,
//         "src/jamtestnet/teams/jamduna/data/orderedaccumulation/state_transitions",
//     );
// }

// // TODO: update
// test "javajam:stf" {
//     const allocator = std.testing.allocator;
//     const loader = jamtestnet.jamduna.Loader(JAMDUNA_PARAMS){};
//     try runStateTransitionTests(
//         JAMDUNA_PARAMS,
//         loader.loader(),
//         allocator,
//         "src/jamtestnet/teams/javajam/stf/state_transitions",
//     );
// }

// TODO: update
// test "jamzig:safrole" {
//     const allocator = std.testing.allocator;
//     const loader = jamtestnet.jamzig.Loader(JAMDUNA_PARAMS){};
//     try runStateTransitionTests(
//         JAMDUNA_PARAMS,
//         loader.loader(),
//         allocator,
//         "src/jamtestnet/teams/jamzig/safrole/state_transitions",
//     );
// }

// W3F Traces Tests
const W3F_PARAMS = jam_params.TINY_PARAMS;

test "w3f:traces:fallback" {
    const allocator = std.testing.allocator;
    const loader = jamtestnet.w3f.Loader(W3F_PARAMS){};
    try runStateTransitionTests(
        W3F_PARAMS,
        loader.loader(),
        allocator,
        "src/jamtestvectors/data/traces/fallback",
    );
}

test "w3f:traces:safrole" {
    const allocator = std.testing.allocator;
    const loader = jamtestnet.w3f.Loader(W3F_PARAMS){};
    try runStateTransitionTests(
        W3F_PARAMS,
        loader.loader(),
        allocator,
        "src/jamtestvectors/data/traces/safrole",
    );
}

test "w3f:traces:reports-l0" {
    const allocator = std.testing.allocator;
    const loader = jamtestnet.w3f.Loader(W3F_PARAMS){};
    try runStateTransitionTests(
        W3F_PARAMS,
        loader.loader(),
        allocator,
        "src/jamtestvectors/data/traces/reports-l0",
    );
}

test "w3f:traces:reports-l1" {
    const allocator = std.testing.allocator;
    const loader = jamtestnet.w3f.Loader(W3F_PARAMS){};
    try runStateTransitionTests(
        W3F_PARAMS,
        loader.loader(),
        allocator,
        "src/jamtestvectors/data/traces/reports-l1",
    );
}

/// Run state transition tests using vectors from the specified directory
pub fn runStateTransitionTests(
    comptime params: jam_params.Params,
    loader: jamtestnet.Loader,
    allocator: std.mem.Allocator,
    test_dir: []const u8,
) !void {
    std.debug.print("\nRunning state transition tests from: {s}\n", .{test_dir});

    var state_transition_vectors = try jamtestnet.state_transitions.collectStateTransitions(test_dir, allocator);
    defer state_transition_vectors.deinit(allocator);
    std.debug.print("Collected {d} state transition vectors\n", .{state_transition_vectors.items().len});

    var current_state: ?state.JamState(params) = null;
    defer {
        if (current_state) |*cs| cs.deinit(allocator);
    }

    for (state_transition_vectors.items()) |state_transition_vector| {
        // This is sometimes placed in the dir
        if (std.mem.eql(u8, state_transition_vector.bin.name, "genesis.bin")) {
            continue;
        }

        std.debug.print("\nProcessing transition: {s}\n\n", .{state_transition_vector.bin.name});

        var state_transition = try loader.loadTestVector(allocator, state_transition_vector.bin.path);
        defer state_transition.deinit(allocator);

        // First validate the roots
        var pre_state_mdict = try state_transition.preStateAsMerklizationDict(allocator);
        defer pre_state_mdict.deinit();

        // std.debug.print("{}", .{types.fmt.format(pre_state_mdict)});
        // std.debug.print("{}", .{types.fmt.format(state_transition.block())});

        // Validator Root Calculations
        try state_transition.validateRoots(allocator);

        // std.debug.print("Block header slot: {d}\n", .{state_transition.block.header.slot});

        // Initialize genesis state if needed
        if (current_state == null) {
            // std.debug.print("Initializing genesis state...\n", .{});
            var dict = try state_transition.preStateAsMerklizationDict(allocator);
            defer dict.deinit();
            current_state = try state_dict.reconstruct.reconstructState(
                params,
                allocator,
                &dict,
            );

            var current_state_mdict = try current_state.?.buildStateMerklizationDictionary(allocator);
            defer current_state_mdict.deinit();
            var genesis_state_diff = try current_state_mdict.diff(&dict);
            defer genesis_state_diff.deinit();

            if (genesis_state_diff.has_changes()) {
                std.debug.print("Genesis State Reconstruction Failed. Dict -> Reconstruct -> Dict not symmetrical. Check state encode and decode\n", .{});
                std.debug.print("{}", .{genesis_state_diff});
                return error.GenesisStateDiff;
            }
        }

        // Ensure we are starting with the same roots.
        const pre_state_root = try current_state.?.buildStateRoot(allocator);
        try std.testing.expectEqualSlices(
            u8,
            &state_transition.preStateRoot(),
            &pre_state_root,
        );

        // Print this
        // std.debug.print("{s}\n", .{current_state.?});

        // std.debug.print("Executing state transition...\n", .{});
        // Try state transition, with automatic retry on failure if runtime tracing is enabled
        var transition = try executeStateTransitionWithTracing(
            params,
            allocator,
            &current_state.?,
            &state_transition.block(),
            state_transition_vector.bin.name,
        );
        defer transition.deinitHeap();

        // Merge transition into base state
        try transition.mergePrimeOntoBase();

        // Log block information for debugging
        @import("sequoia.zig").logging.printBlockEntropyDebug(
            params,
            &state_transition.block(),
            &current_state.?,
        );

        // Validate against expected state
        var current_state_mdict = try current_state.?.buildStateMerklizationDictionary(allocator);
        defer current_state_mdict.deinit();

        var expected_state_mdict = try state_transition.postStateAsMerklizationDict(allocator);
        defer expected_state_mdict.deinit();

        var expected_state_diff = try current_state_mdict.diff(&expected_state_mdict);
        defer expected_state_diff.deinit();

        // Check for differences from expected state
        if (expected_state_diff.has_changes()) {
            std.debug.print("\x1b[31m=== Expected State Difference Detected ===\x1b[0m\n", .{});
            std.debug.print("{}\n\n", .{expected_state_diff});

            var expected_state = try state_dict.reconstruct.reconstructState(params, allocator, &expected_state_mdict);
            defer expected_state.deinit(allocator);

            var state_diff = try @import("tests/state_diff.zig").JamStateDiff(params).build(allocator, &current_state.?, &expected_state);
            defer state_diff.deinit();

            state_diff.printToStdErr();

            // std.debug.print("{}", .{current_state.?});
            // std.debug.print("{}", .{types.fmt.format(current_state.?.delta.?.getAccount(1065941251).?.storageFootprint())});

            return error.UnexpectedStateDiff;
        }

        // Validate state root
        const state_root = try current_state.?.buildStateRoot(allocator);
        try std.testing.expectEqualSlices(
            u8,
            &state_transition.postStateRoot(),
            &state_root,
        );
    }
}

// Extract the failing STF module from stack trace
fn extractFailingModuleFromStackTrace(stack_trace: *std.builtin.StackTrace) ?[]const u8 {
    // Get debug info for analyzing the stack trace
    const debug_info = std.debug.getSelfDebugInfo() catch return null;
    defer debug_info.deinit();

    // Iterate through stack frames similar to writeStackTrace
    var frame_index: usize = 0;
    var frames_left: usize = @min(stack_trace.index, stack_trace.instruction_addresses.len);

    while (frames_left != 0) : ({
        frames_left -= 1;
        frame_index = (frame_index + 1) % stack_trace.instruction_addresses.len;
    }) {
        const return_address = stack_trace.instruction_addresses[frame_index];

        // Create a buffer to capture the source location output
        var buf: [1024]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);

        // Try to print source location to our buffer
        std.debug.printSourceAtAddress(debug_info, stream.writer(), return_address - 1, .no_color) catch continue;

        const output = stream.getWritten();

        // Look for STF module patterns in the output
        if (std.mem.indexOf(u8, output, "stf/time.zig")) |_| return "time";
        if (std.mem.indexOf(u8, output, "stf/safrole.zig")) |_| return "safrole";
        if (std.mem.indexOf(u8, output, "stf/reports.zig")) |_| return "reports";
        if (std.mem.indexOf(u8, output, "stf/disputes.zig")) |_| return "disputes";
        if (std.mem.indexOf(u8, output, "stf/assurances.zig")) |_| return "assurances";
        if (std.mem.indexOf(u8, output, "stf/accumulate.zig")) |_| return "accumulate";
        if (std.mem.indexOf(u8, output, "stf/preimages.zig")) |_| return "preimages";
        if (std.mem.indexOf(u8, output, "stf/authorization.zig")) |_| return "authorization";
        if (std.mem.indexOf(u8, output, "stf/validator_stats.zig")) |_| return "validator_stats";
        if (std.mem.indexOf(u8, output, "stf/recent_history.zig")) |_| return "recent_history";
        if (std.mem.indexOf(u8, output, "stf/eta.zig")) |_| return "eta";
        if (std.mem.indexOf(u8, output, "stf/core_allocation.zig")) |_| return "core_allocation";
        if (std.mem.indexOf(u8, output, "stf/services.zig")) |_| return "services";
    }

    return null;
}

// Execute state transition with automatic tracing on failure
fn executeStateTransitionWithTracing(
    comptime params: jam_params.Params,
    allocator: std.mem.Allocator,
    current_state: *const state.JamState(params),
    block: *const types.Block,
    filename: []const u8,
) !*state_delta.StateTransition(params) {
    // First attempt without tracing
    return stf.stateTransition(params, allocator, current_state, block) catch |err| {
        // Only retry with tracing if runtime mode is enabled
        if (comptime tracing.tracing_mode == .runtime) {
            std.debug.print("\n== STATE TRANSITION FAILED ==\n", .{});
            std.debug.print("Error: {s}\n", .{@errorName(err)});
            std.debug.print("Block slot: {d}\n", .{block.header.slot});
            std.debug.print("File: {s}\n", .{filename});

            // Try to extract the failing module from stack trace, otherwise default to "stf"
            var failing_module: []const u8 = "stf";

            if (@errorReturnTrace()) |stack_trace| {
                // First try to extract module from stack trace
                if (extractFailingModuleFromStackTrace(stack_trace)) |detected_module| {
                    failing_module = detected_module;
                } else {
                    // If detection fails, fallback to "stf"
                    std.debug.print("Failed to detect module from stack trace, using default 'stf'\n", .{});
                }
            }

            // Enable debug tracing only for the specific failing module
            std.debug.print("\nDetected failure in module: {s}\n", .{failing_module});
            std.debug.print("Retrying with debug tracing enabled for {s} module...\n\n", .{failing_module});

            try tracing.runtime.setScope(failing_module, .trace);
            defer tracing.runtime.disableScope(failing_module) catch {};

            // Also enable stf scope for general transition tracking
            try tracing.runtime.setScope("stf", .debug);
            defer tracing.runtime.disableScope("stf") catch {};

            return stf.stateTransition(params, allocator, current_state, block) catch |retry_err| {
                std.debug.print("\n=== Detailed trace above shows failure context ===\n", .{});
                std.debug.print("Error persists: {s}\n\n", .{@errorName(retry_err)});
                return retry_err;
            };
        } else {
            std.debug.print("State transition failed without runtime tracing: {s}\n", .{@errorName(err)});
            return err;
        }
    };
}
