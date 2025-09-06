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
const io = @import("../io.zig");

// W3F Traces Tests

pub const RunConfig = struct {
    mode: enum { CONTINOUS_MODE, TRACE_MODE },
    quiet: bool = false,
};

pub const RunResult = struct {
    had_no_op_blocks: bool = false,
    no_op_exceptions: []const u8 = "",

    pub fn deinit(self: *RunResult, allocator: std.mem.Allocator) void {
        if (self.no_op_exceptions.len > 0) {
            allocator.free(self.no_op_exceptions);
        }
    }
};

pub fn runTracesInDir(
    comptime IOExecutor: type,
    executor: *IOExecutor,
    comptime params: jam_params.Params,
    loader: trace_runner.Loader,
    allocator: std.mem.Allocator,
    test_dir: []const u8,
    config: RunConfig,
) !RunResult {
    if (!config.quiet) {
        std.debug.print("\nRunning block import tests from: {s}\n", .{test_dir});
    }

    // Read the OFFSET env var to start from a certain offset
    const offset_str = std.process.getEnvVarOwned(allocator, "OFFSET") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    defer if (offset_str) |s| allocator.free(s);

    const offset = if (offset_str) |s| try std.fmt.parseInt(usize, s, 10) else 0;

    var state_transition_vectors = try trace_runner.state_transitions.collectStateTransitions(test_dir, allocator);
    defer state_transition_vectors.deinit(allocator);
    if (!config.quiet) {
        std.debug.print("Collected {d} state transition vectors\n", .{state_transition_vectors.items().len});
    }

    if (offset > 0) {
        if (offset >= state_transition_vectors.items().len) {
            if (!config.quiet) {
                std.debug.print("Warning: Offset {d} is >= total vectors {d}, no tests will run\n", .{ offset, state_transition_vectors.items().len });
            }
        } else {
            if (!config.quiet) {
                std.debug.print("Starting from offset: {d}\n", .{offset});
            }
        }
    }

    // Initialize block importer
    var importer = block_import.BlockImporter(IOExecutor, params).init(executor, allocator);

    var current_state: ?state.JamState(params) = null;
    defer {
        if (current_state) |*cs| cs.deinit(allocator);
    }

    // Track last post-state root to verify trace continuity
    var last_post_state_root: ?[32]u8 = null;

    // Track no-op blocks for result
    var result = RunResult{};
    var no_op_exceptions = std.ArrayList(u8).init(allocator);
    defer no_op_exceptions.deinit();

    for (state_transition_vectors.items()[offset..], offset..) |state_transition_vector, idx| {
        // This is sometimes placed in the dir
        if (std.mem.eql(u8, state_transition_vector.bin.name, "genesis.bin")) {
            continue;
        }

        if (!config.quiet) {
            std.debug.print("\n=== Processing block import {d}: {s} ===\n", .{ idx, state_transition_vector.bin.name });
        }

        var state_transition = try loader.loadTestVector(allocator, state_transition_vector.bin.path);
        defer state_transition.deinit(allocator);

        // First validate the roots
        var pre_state_mdict = try state_transition.preStateAsMerklizationDict(allocator);
        defer pre_state_mdict.deinit();

        // Validator Root Calculations
        try state_transition.validateRoots(allocator);

        // Check trace continuity: compare last post-state root with current pre-state root
        if (config.mode == .CONTINOUS_MODE) {
            if (last_post_state_root) |last_root| {
                const current_pre_root = state_transition.preStateRoot();
                if (!std.mem.eql(u8, &last_root, &current_pre_root)) {
                    if (!config.quiet) {
                        std.debug.print("\x1b[31m=== Trace continuity error ===\x1b[0m\n", .{});
                        std.debug.print("Last post-state root: {s}\n", .{std.fmt.fmtSliceHexLower(&last_root)});
                        std.debug.print("Current pre-state root: {s}\n", .{std.fmt.fmtSliceHexLower(&current_pre_root)});
                        std.debug.print("The traces are not continuous - the previous post-state root doesn't match the current pre-state root!\n", .{});
                    }
                    return error.TraceContinuityError;
                }
            }
        }

        // Initialize genesis state if needed, and in TRACE_MODE
        // we always initialize current_state to the pre_state of the trace to ensure
        // we can validate the state transition correctly.
        if (current_state == null or config.mode == .TRACE_MODE) {
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
                if (!config.quiet) {
                    std.debug.print("Genesis State Reconstruction Failed. Dict -> Reconstruct -> Dict not symmetrical. Check state encode and decode\n", .{});
                    std.debug.print("{}", .{genesis_state_diff});
                }
                return error.GenesisStateDiff;
            }
        }

        // Ensure we are starting with the same roots.
        const pre_state_root = try current_state.?.buildStateRoot(allocator);
        if (!std.mem.eql(u8, &state_transition.preStateRoot(), &pre_state_root)) {
            if (!config.quiet) {
                std.debug.print("\x1b[31m=== Pre-state root mismatch ===\x1b[0m\n", .{});
                std.debug.print("Expected: {s}\n", .{std.fmt.fmtSliceHexLower(&state_transition.preStateRoot())});
                std.debug.print("Actual: {s}\n", .{std.fmt.fmtSliceHexLower(&pre_state_root)});
            }

            // Reconstruct expected pre-state and show diff
            var expected_pre_state_mdict = try state_transition.preStateAsMerklizationDict(allocator);
            defer expected_pre_state_mdict.deinit();

            var expected_pre_state = try state_dict.reconstruct.reconstructState(params, allocator, &expected_pre_state_mdict);
            defer expected_pre_state.deinit(allocator);

            if (!config.quiet) {
                std.debug.print("\n\x1b[31m=== State Differences ===\x1b[0m\n", .{});
            }
            var state_diff = try @import("../tests/state_diff.zig").JamStateDiff(params).build(allocator, &current_state.?, &expected_pre_state);
            defer state_diff.deinit();
            if (!config.quiet) {
                state_diff.printToStdErr();
            }

            return error.PreStateRootMismatch;
        }

        // Debug: Calculate and print extrinsic hash to stderr
        const block = state_transition.block();

        // Show extrinsic contents
        if (!config.quiet) {
            std.debug.print("Extrinsic contents: tickets={d}, preimages={d}, guarantees={d}, assurances={d}, disputes(v={d},c={d},f={d})\n", .{
                block.extrinsic.tickets.data.len,
                block.extrinsic.preimages.data.len,
                block.extrinsic.guarantees.data.len,
                block.extrinsic.assurances.data.len,
                block.extrinsic.disputes.verdicts.len,
                block.extrinsic.disputes.culprits.len,
                block.extrinsic.disputes.faults.len,
            });
        }

        // Check if this is a no-op block (pre_state == post_state in test data)
        const expected_pre_root = state_transition.preStateRoot();
        const expected_post_root = state_transition.postStateRoot();
        const is_no_op_block = std.mem.eql(u8, &expected_pre_root, &expected_post_root);

        if (is_no_op_block and !config.quiet) {
            std.debug.print("\x1b[33m=== No-Op Block Detected (pre_state == post_state) ===\x1b[0m\n", .{});
            std.debug.print("This block is expected to produce no state changes\n", .{});
        }

        var import_result = importer.importBlockBuildingRoot(
            &current_state.?,
            state_transition.block(),
        ) catch |err| {
            // Check if this is expected for a no-op block
            if (is_no_op_block) {
                if (!config.quiet) {
                    std.debug.print("\x1b[33m=== Block Import Failed (Expected for No-Op Block) ===\x1b[0m\n", .{});
                    std.debug.print("Error: {s}\n", .{@errorName(err)});
                    std.debug.print("Verifying state remained unchanged...\n", .{});
                }

                // Track this no-op block and its exception
                result.had_no_op_blocks = true;
                if (no_op_exceptions.items.len > 0) {
                    try no_op_exceptions.appendSlice(", ");
                }
                try no_op_exceptions.appendSlice(@errorName(err));

                // For no-op blocks, the current state should still match the expected post-state
                // (which is the same as pre-state)
                const current_state_root = try current_state.?.buildStateRoot(allocator);

                if (std.mem.eql(u8, &expected_post_root, &current_state_root)) {
                    if (!config.quiet) {
                        std.debug.print("\x1b[32m✓ State correctly remained unchanged (no-op block validated)\x1b[0m\n", .{});
                    }
                    // Update last_post_state_root for continuity
                    last_post_state_root = expected_post_root;
                    continue; // Skip to next block
                } else {
                    if (!config.quiet) {
                        std.debug.print("\x1b[31m✗ State was modified when it shouldn't have been!\x1b[0m\n", .{});
                        std.debug.print("Current state root: {s}\n", .{std.fmt.fmtSliceHexLower(&current_state_root)});
                        std.debug.print("Expected (unchanged): {s}\n", .{std.fmt.fmtSliceHexLower(&expected_post_root)});
                    }
                    return error.UnexpectedStateChangeOnNoOpBlock;
                }
            }

            // Not a no-op block, handle error normally
            if (!config.quiet) {
                std.debug.print("\x1b[31m=== Block Import Failed ===\x1b[0m\n", .{});
                std.debug.print("Error: {s}\n", .{@errorName(err)});
                std.debug.print("Block slot: {d}\n", .{state_transition.block().header.slot});
                std.debug.print("Parent hash: {s}\n", .{std.fmt.fmtSliceHexLower(&state_transition.block().header.parent)});
                std.debug.print("Parent state root: {s}\n", .{std.fmt.fmtSliceHexLower(&state_transition.block().header.parent_state_root)});
            }

            // If runtime tracing is enabled, retry with detailed tracing
            if (comptime tracing.tracing_mode == .runtime) {
                if (!config.quiet) {
                    std.debug.print("\nRetrying with debug tracing enabled...\n\n", .{});
                }

                try tracing.runtime.setScope("block_import", .trace);
                defer tracing.runtime.disableScope("block_import") catch {};

                try tracing.runtime.setScope("block_import", .trace);
                defer tracing.runtime.disableScope("block_import") catch {};

                // Retry the import with tracing
                var retry_result = importer.importBlockBuildingRoot(
                    &current_state.?,
                    state_transition.block(),
                ) catch |retry_err| {
                    if (!config.quiet) {
                        std.debug.print("\n=== Detailed trace above shows failure context ===\n", .{});
                        std.debug.print("Error persists: {s}\n\n", .{@errorName(retry_err)});
                    }
                    // Check again if it's a no-op block
                    if (is_no_op_block) {
                        // Track the exception if not already tracked
                        if (!result.had_no_op_blocks) {
                            result.had_no_op_blocks = true;
                            if (no_op_exceptions.items.len > 0) {
                                try no_op_exceptions.appendSlice(", ");
                            }
                            try no_op_exceptions.appendSlice(@errorName(retry_err));
                        }

                        const current_root = try current_state.?.buildStateRoot(allocator);
                        if (std.mem.eql(u8, &expected_post_root, &current_root)) {
                            if (!config.quiet) {
                                std.debug.print("\x1b[32m✓ State correctly remained unchanged after retry\x1b[0m\n", .{});
                            }
                            last_post_state_root = expected_post_root;
                            continue;
                        }
                    }
                    return retry_err;
                };
                defer retry_result.deinit();
            }

            return err;
        };
        defer import_result.deinit();

        // Log seal type for debugging
        if (!config.quiet) {
            std.debug.print("Block sealed with tickets: {}\n", .{import_result.sealed_with_tickets});
        }

        // For no-op blocks, skip merging state changes
        if (is_no_op_block) {
            if (!config.quiet) {
                std.debug.print("\x1b[33mSkipping state merge for no-op block\x1b[0m\n", .{});
            }

            // Verify state hasn't changed
            const current_state_root = try current_state.?.buildStateRoot(allocator);
            if (!std.mem.eql(u8, &expected_post_root, &current_state_root)) {
                if (!config.quiet) {
                    std.debug.print("\x1b[31m✗ Warning: Block import succeeded but state changed for no-op block!\x1b[0m\n", .{});
                    std.debug.print("This may indicate the block should have been rejected\n", .{});
                }
                // Don't merge the changes
                return error.NoOpBlockChangedState;
            } else {
                if (!config.quiet) {
                    std.debug.print("\x1b[32m✓ No-op block processed successfully with no state changes\x1b[0m\n", .{});
                }
            }

            // Update last_post_state_root for continuity
            last_post_state_root = expected_post_root;
            continue; // Skip to next block
        }

        // Normal block - merge transition into base state
        try import_result.state_transition.mergePrimeOntoBase();

        // Log block information for debugging
        //
        if (!config.quiet) {
            @import("../sequoia.zig").logging.printBlockEntropyDebug(
                params,
                state_transition.block(),
                &current_state.?,
            );
        }

        // Validate against expected state
        var current_state_mdict = try current_state.?.buildStateMerklizationDictionary(allocator);
        defer current_state_mdict.deinit();

        var expected_state_mdict = try state_transition.postStateAsMerklizationDict(allocator);
        defer expected_state_mdict.deinit();

        var expected_state_diff = try current_state_mdict.diff(&expected_state_mdict);
        defer expected_state_diff.deinit();

        // Check for differences from expected state
        if (expected_state_diff.has_changes()) {
            if (!config.quiet) {
                std.debug.print("\x1b[31m=== Expected State Difference Detected ===\x1b[0m\n", .{});
                std.debug.print("{}\n\n", .{expected_state_diff});
            }

            var expected_state = try state_dict.reconstruct.reconstructState(params, allocator, &expected_state_mdict);
            defer expected_state.deinit(allocator);

            var state_diff = try @import("../tests/state_diff.zig").JamStateDiff(params).build(allocator, &current_state.?, &expected_state);
            defer state_diff.deinit();

            if (!config.quiet) {
                state_diff.printToStdErr();
            }

            return error.UnexpectedStateDiff;
        }

        // Validate state root
        const state_root = try current_state.?.buildStateRoot(allocator);

        if (std.mem.eql(u8, &expected_post_root, &state_root)) {
            if (!config.quiet) {
                std.debug.print("\x1b[32m✓ Post-state root matches: {s}\x1b[0m\n", .{std.fmt.fmtSliceHexLower(&state_root)});
            }
        } else {
            if (!config.quiet) {
                std.debug.print("\x1b[31m✗ Post-state root mismatch!\x1b[0m\n", .{});
                std.debug.print("Expected: {s}\n", .{std.fmt.fmtSliceHexLower(&expected_post_root)});
                std.debug.print("Actual: {s}\n", .{std.fmt.fmtSliceHexLower(&state_root)});
            }
        }

        try std.testing.expectEqualSlices(
            u8,
            &expected_post_root,
            &state_root,
        );

        // Save this post-state root for next iteration's continuity check
        last_post_state_root = expected_post_root;
    }

    // Build final result
    if (no_op_exceptions.items.len > 0) {
        result.no_op_exceptions = try no_op_exceptions.toOwnedSlice();
    }

    return result;
}
