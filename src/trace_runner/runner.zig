const std = @import("std");
const testing = std.testing;

pub const trace_runner = @import("parsers.zig");
pub const state_transitions = @import("state_transitions.zig");

const state = @import("../state.zig");
const state_dict = @import("../state_dictionary.zig");

const jam_params = @import("../jam_params.zig");

const tracing = @import("../tracing.zig");
const trace = tracing.scoped(.trace_runner);

const block_import = @import("../block_import.zig");

// W3F Traces Tests

const ImportMode = enum { CONTINOUS_MODE, TRACE_MODE };

pub fn runTracesInDir(
    comptime params: jam_params.Params,
    loader: trace_runner.Loader,
    allocator: std.mem.Allocator,
    test_dir: []const u8,
    continuosity_check: ImportMode,
) !void {
    std.log.err("\nRunning block import tests from: {s}", .{test_dir});

    // Read the OFFSET env var to start from a certain offset
    const offset_str = std.process.getEnvVarOwned(allocator, "OFFSET") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    defer if (offset_str) |s| allocator.free(s);

    const offset = if (offset_str) |s| try std.fmt.parseInt(usize, s, 10) else 0;

    var state_transition_vectors = try trace_runner.state_transitions.collectStateTransitions(test_dir, allocator);
    defer state_transition_vectors.deinit(allocator);
    std.log.err("Collected {d} state transition vectors", .{state_transition_vectors.items().len});

    if (offset > 0) {
        if (offset >= state_transition_vectors.items().len) {
            std.debug.print("Warning: Offset {d} is >= total vectors {d}, no tests will run\n", .{ offset, state_transition_vectors.items().len });
        } else {
            std.debug.print("Starting from offset: {d}\n", .{offset});
        }
    }

    // Initialize block importer
    var importer = block_import.BlockImporter(params).init(allocator);

    var current_state: ?state.JamState(params) = null;
    defer {
        if (current_state) |*cs| cs.deinit(allocator);
    }

    // Track last post-state root to verify trace continuity
    var last_post_state_root: ?[32]u8 = null;

    for (state_transition_vectors.items()[offset..], offset..) |state_transition_vector, idx| {
        // This is sometimes placed in the dir
        if (std.mem.eql(u8, state_transition_vector.bin.name, "genesis.bin")) {
            continue;
        }

        std.debug.print("\n=== Processing block import {d}: {s} ===\n", .{ idx, state_transition_vector.bin.name });

        var state_transition = try loader.loadTestVector(allocator, state_transition_vector.bin.path);
        defer state_transition.deinit(allocator);

        // First validate the roots
        var pre_state_mdict = try state_transition.preStateAsMerklizationDict(allocator);
        defer pre_state_mdict.deinit();

        // Validator Root Calculations
        try state_transition.validateRoots(allocator);

        // Check trace continuity: compare last post-state root with current pre-state root
        if (continuosity_check == .CONTINOUS_MODE) {
            if (last_post_state_root) |last_root| {
                const current_pre_root = state_transition.preStateRoot();
                if (!std.mem.eql(u8, &last_root, &current_pre_root)) {
                    std.debug.print("\x1b[31m=== Trace continuity error ===\x1b[0m\n", .{});
                    std.debug.print("Last post-state root: {s}\n", .{std.fmt.fmtSliceHexLower(&last_root)});
                    std.debug.print("Current pre-state root: {s}\n", .{std.fmt.fmtSliceHexLower(&current_pre_root)});
                    std.debug.print("The traces are not continuous - the previous post-state root doesn't match the current pre-state root!\n", .{});
                    return error.TraceContinuityError;
                }
            }
        }

        // Initialize genesis state if needed, and in TRACE_MODE
        // we always initialize current_state to the pre_state of the trace to ensure
        // we can validate the state transition correctly.
        if (current_state == null or continuosity_check == .TRACE_MODE) {
            // std.debug.print("Initializing genesis state...\n", .{});
            var pre_state_dict = try state_transition.preStateAsMerklizationDict(allocator);
            defer pre_state_dict.deinit();

            // If we are in TRACE_MODE, we need to deinit our previous current_state
            if (current_state) |*cs| cs.deinit(allocator);

            current_state = try state_dict.reconstruct.reconstructState(
                params,
                allocator,
                &pre_state_dict,
            );

            var current_state_mdict = try current_state.?.buildStateMerklizationDictionary(allocator);
            defer current_state_mdict.deinit();

            var genesis_state_diff = try current_state_mdict.diff(&pre_state_dict);
            defer genesis_state_diff.deinit();

            if (genesis_state_diff.has_changes()) {
                std.debug.print("Genesis State Reconstruction Failed. Dict -> Reconstruct -> Dict not symmetrical. Check state encode and decode\n", .{});
                std.debug.print("{}", .{genesis_state_diff});
                return error.GenesisStateDiff;
            }
        }

        // Ensure we are starting with the same roots.
        const pre_state_root = try current_state.?.buildStateRoot(allocator);
        if (!std.mem.eql(u8, &state_transition.preStateRoot(), &pre_state_root)) {
            std.debug.print("\x1b[31m=== Pre-state root mismatch ===\x1b[0m\n", .{});
            std.debug.print("Expected: {s}\n", .{std.fmt.fmtSliceHexLower(&state_transition.preStateRoot())});
            std.debug.print("Actual: {s}\n", .{std.fmt.fmtSliceHexLower(&pre_state_root)});

            // Reconstruct expected pre-state and show diff
            var expected_pre_state_mdict = try state_transition.preStateAsMerklizationDict(allocator);
            defer expected_pre_state_mdict.deinit();

            var expected_pre_state = try state_dict.reconstruct.reconstructState(params, allocator, &expected_pre_state_mdict);
            defer expected_pre_state.deinit(allocator);

            std.debug.print("\n\x1b[31m=== State Differences ===\x1b[0m\n", .{});
            var state_diff = try @import("../tests/state_diff.zig").JamStateDiff(params).build(allocator, &current_state.?, &expected_pre_state);
            defer state_diff.deinit();
            state_diff.printToStdErr();

            return error.PreStateRootMismatch;
        }

        // Debug: Calculate and print extrinsic hash to stderr
        const block = state_transition.block();

        // Show extrinsic contents
        std.log.err("Extrinsic contents: tickets={d}, preimages={d}, guarantees={d}, assurances={d}, disputes(v={d},c={d},f={d})", .{
            block.extrinsic.tickets.data.len,
            block.extrinsic.preimages.data.len,
            block.extrinsic.guarantees.data.len,
            block.extrinsic.assurances.data.len,
            block.extrinsic.disputes.verdicts.len,
            block.extrinsic.disputes.culprits.len,
            block.extrinsic.disputes.faults.len,
        });

        var import_result = importer.importBlock(
            &current_state.?,
            state_transition.block(),
        ) catch |err| {
            // Enhanced error reporting with BlockImporter context
            std.debug.print("\x1b[31m=== Block Import Failed ===\x1b[0m\n", .{});
            std.debug.print("Error: {s}\n", .{@errorName(err)});
            std.debug.print("Block slot: {d}\n", .{state_transition.block().header.slot});
            std.debug.print("Parent hash: {s}\n", .{std.fmt.fmtSliceHexLower(&state_transition.block().header.parent)});
            std.debug.print("Parent state root: {s}\n", .{std.fmt.fmtSliceHexLower(&state_transition.block().header.parent_state_root)});

            // If runtime tracing is enabled, retry with detailed tracing
            if (comptime tracing.tracing_mode == .runtime) {
                std.debug.print("\nRetrying with debug tracing enabled...\n\n", .{});

                try tracing.runtime.setScope("block_import", .trace);
                defer tracing.runtime.disableScope("block_import") catch {};

                try tracing.runtime.setScope("block_import", .trace);
                defer tracing.runtime.disableScope("block_import") catch {};

                // Retry the import with tracing
                var result = importer.importBlock(
                    &current_state.?,
                    state_transition.block(),
                ) catch |retry_err| {
                    std.debug.print("\n=== Detailed trace above shows failure context ===\n", .{});
                    std.debug.print("Error persists: {s}\n\n", .{@errorName(retry_err)});
                    return retry_err;
                };
                defer result.deinit();
            }

            return err;
        };
        defer import_result.deinit();

        // Log seal type for debugging
        std.debug.print("Block sealed with tickets: {}\n", .{import_result.sealed_with_tickets});

        // Merge transition into base state
        try import_result.state_transition.mergePrimeOntoBase();

        // Log block information for debugging
        @import("../sequoia.zig").logging.printBlockEntropyDebug(
            params,
            state_transition.block(),
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

            var state_diff = try @import("../tests/state_diff.zig").JamStateDiff(params).build(allocator, &current_state.?, &expected_state);
            defer state_diff.deinit();

            state_diff.printToStdErr();

            return error.UnexpectedStateDiff;
        }

        // Validate state root
        const state_root = try current_state.?.buildStateRoot(allocator);
        const expected_post_root = state_transition.postStateRoot();

        if (std.mem.eql(u8, &expected_post_root, &state_root)) {
            std.debug.print("\x1b[32m✓ Post-state root matches: {s}\x1b[0m\n", .{std.fmt.fmtSliceHexLower(&state_root)});
        } else {
            std.debug.print("\x1b[31m✗ Post-state root mismatch!\x1b[0m\n", .{});
            std.debug.print("Expected: {s}\n", .{std.fmt.fmtSliceHexLower(&expected_post_root)});
            std.debug.print("Actual: {s}\n", .{std.fmt.fmtSliceHexLower(&state_root)});
        }

        try std.testing.expectEqualSlices(
            u8,
            &expected_post_root,
            &state_root,
        );

        // Save this post-state root for next iteration's continuity check
        last_post_state_root = expected_post_root;
    }
}
