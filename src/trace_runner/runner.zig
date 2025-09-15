const std = @import("std");
const testing = std.testing;

pub const trace_runner = @import("parsers.zig");
pub const state_transitions = @import("state_transitions.zig");

const types = @import("../types.zig");
const state = @import("../state.zig");
const state_dict = @import("../state_dictionary.zig");
const jam_params = @import("../jam_params.zig");
const block_import = @import("../block_import.zig");
const io = @import("../io.zig");

const tracing = @import("tracing");
const trace = tracing.scoped(.trace_runner);

pub const RunConfig = struct {
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

const ForkStatus = enum {
    continuous,
    sibling_fork,
    discontinuous,
};

const ProcessResult = union(enum) {
    success: struct {
        block_hash: [32]u8,
        parent_hash: [32]u8,
        sealed_with_tickets: bool,
    },
    no_op_handled: struct {
        error_name: []const u8,
    },
    error_handled: struct {
        error_name: []const u8,
    },
};

/// Simplified trace runner that consolidates all state management and processing logic
pub fn TraceRunner(comptime IOExecutor: type, comptime params: jam_params.Params) type {
    return struct {
        allocator: std.mem.Allocator,
        importer: block_import.BlockImporter(IOExecutor, params),
        loader: trace_runner.Loader,
        config: RunConfig,

        // State management
        current_state: ?state.JamState(params) = null,
        last_block_hash: ?[32]u8 = null,
        last_parent_hash: ?[32]u8 = null,

        // Result tracking
        had_no_op_blocks: bool = false,
        no_op_exceptions: std.ArrayList(u8),

        const Self = @This();

        pub fn init(
            allocator: std.mem.Allocator,
            executor: *IOExecutor,
            loader: trace_runner.Loader,
            config: RunConfig,
        ) Self {
            return .{
                .allocator = allocator,
                .importer = block_import.BlockImporter(IOExecutor, params).init(executor, allocator),
                .loader = loader,
                .config = config,
                .no_op_exceptions = std.ArrayList(u8).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.current_state) |*cs| cs.deinit(self.allocator);
            self.no_op_exceptions.deinit();
            self.* = undefined;
        }

        /// Main entry point - run all transitions in the directory
        pub fn runTransitions(self: *Self, test_dir: []const u8) !RunResult {
            // Load all transitions
            const offset = try getStartOffset(self.allocator);
            var transitions = try state_transitions.collectStateTransitions(test_dir, self.allocator);
            defer transitions.deinit(self.allocator);

            if (!self.config.quiet) {
                std.log.info("Collected {d} state transition vectors", .{transitions.items().len});
                if (offset > 0) {
                    std.log.info("Starting from offset: {d}", .{offset});
                }
            }

            // Process each transition
            for (transitions.items()[offset..], offset..) |transition_file, idx| {
                if (shouldSkipTransition(transition_file.bin.name)) continue;

                if (!self.config.quiet) {
                    std.log.info("Processing block import {d}: {s}", .{ idx, transition_file.bin.name });
                }

                const result = try self.processTransition(transition_file);
                self.updateTracking(result);
            }

            return self.buildResult();
        }

        /// Process a single state transition
        fn processTransition(self: *Self, transition_file: state_transitions.StateTransitionPair) !ProcessResult {
            // Load the test vector
            var transition = try self.loader.loadTestVector(self.allocator, transition_file.bin.path);
            defer transition.deinit(self.allocator);

            // Check fork status
            const fork_status = self.detectFork(transition.block().header.parent);

            // Validate continuity
            if (fork_status == .discontinuous) {
                std.log.err("Trace continuity error - blocks are not continuous", .{});
                return error.TraceContinuityError;
            }

            if (fork_status == .sibling_fork) {
                std.log.warn("Fork detected - resetting to fork point", .{});
            }

            // Validate roots
            try transition.validateRoots(self.allocator);

            // Ensure state is initialized/reset if needed
            try self.ensureState(&transition, fork_status);

            // Validate pre-state root
            const pre_state_root = try self.current_state.?.buildStateRoot(self.allocator);
            const expected_pre = transition.preStateRoot();

            if (!std.mem.eql(u8, &expected_pre, &pre_state_root)) {
                std.log.err("Pre-state root mismatch", .{});
                std.log.err("Expected: {s}", .{std.fmt.fmtSliceHexLower(&expected_pre)});
                std.log.err("Actual: {s}", .{std.fmt.fmtSliceHexLower(&pre_state_root)});
                try self.showStateDiff(&transition);
                return error.PreStateRootMismatch;
            }

            // Log block info
            self.logBlockInfo(transition.block());

            // Check if this is a no-op block
            const expected_post = transition.postStateRoot();
            const is_no_op = std.mem.eql(u8, &expected_pre, &expected_post);

            if (is_no_op) {
                if (!self.config.quiet) {
                    std.log.warn("No-Op Block Detected (pre_state == post_state)", .{});
                }
                return self.processNoOpBlock(&transition, expected_post);
            } else {
                return self.processNormalBlock(&transition, expected_post);
            }
        }

        /// Process a normal (state-changing) block
        fn processNormalBlock(self: *Self, transition: *const trace_runner.StateTransition, expected_post: [32]u8) !ProcessResult {
            // Import the block with retry logic
            var import_result = self.importBlockWithRetry(transition.block()) catch |err| {
                std.log.err("Block import failed: {s}", .{@errorName(err)});
                return error.BlockImportFailed;
            };
            defer import_result.deinit();

            if (!self.config.quiet) {
                std.log.debug("Block sealed with tickets: {}", .{import_result.sealed_with_tickets});
            }

            // Merge state changes
            try import_result.state_transition.mergePrimeOntoBase();

            // Validate post-state
            try self.validatePostState(transition, expected_post);

            const block_hash = try transition.block().header.header_hash(params, self.allocator);

            return ProcessResult{
                .success = .{
                    .block_hash = block_hash,
                    .parent_hash = transition.block().header.parent,
                    .sealed_with_tickets = import_result.sealed_with_tickets,
                },
            };
        }

        /// Process a no-op block (no state changes expected)
        fn processNoOpBlock(self: *Self, transition: *const trace_runner.StateTransition, expected_post: [32]u8) !ProcessResult {
            // Try to import - we expect this to fail
            var import_result = self.importer.importBlockBuildingRoot(
                &self.current_state.?,
                transition.block(),
            ) catch |err| {
                if (!self.config.quiet) {
                    std.log.debug("Block import failed (expected for no-op): {s}", .{@errorName(err)});
                }

                // Verify state hasn't changed
                const current_root = try self.current_state.?.buildStateRoot(self.allocator);

                if (std.mem.eql(u8, &expected_post, &current_root)) {
                    if (!self.config.quiet) {
                        std.log.info("State correctly remained unchanged (no-op validated)", .{});
                    }
                    return ProcessResult{ .no_op_handled = .{ .error_name = @errorName(err) } };
                } else {
                    std.log.err("State was modified when it shouldn't have been!", .{});
                    return error.UnexpectedStateChangeOnNoOpBlock;
                }
            };
            defer import_result.deinit();

            // If import succeeded, verify no state change occurred
            const current_root = try self.current_state.?.buildStateRoot(self.allocator);

            if (!std.mem.eql(u8, &expected_post, &current_root)) {
                std.log.err("Block import succeeded but state changed for no-op block!", .{});
                return error.NoOpBlockChangedState;
            }

            if (!self.config.quiet) {
                std.log.info("No-op block processed successfully with no state changes", .{});
            }
            return ProcessResult{ .no_op_handled = .{ .error_name = "none" } };
        }

        /// Import block with retry and enhanced tracing on failure
        fn importBlockWithRetry(
            self: *Self,
            block: *const types.Block,
        ) !block_import.BlockImporter(IOExecutor, params).ImportResult {
            return self.importer.importBlockBuildingRoot(
                &self.current_state.?,
                block,
            ) catch {
                // Retry with tracing enabled
                if (!self.config.quiet) {
                    std.log.debug("Retrying with debug tracing enabled...", .{});
                }

                try tracing.setScope("block_import", .trace);
                defer tracing.disableScope("block_import");
                try tracing.setScope("stf", .trace);
                defer tracing.disableScope("stf");

                return self.importer.importBlockBuildingRoot(
                    &self.current_state.?,
                    block,
                ) catch |retry_err| {
                    std.log.err("Error persists after retry: {s}", .{@errorName(retry_err)});
                    return retry_err;
                };
            };
        }

        /// Detect fork status based on block parent hash
        fn detectFork(self: *const Self, current_parent: [32]u8) ForkStatus {
            if (self.last_block_hash) |last_hash| {
                if (!std.mem.eql(u8, &last_hash, &current_parent)) {
                    // Check if this is a sibling fork
                    if (self.last_parent_hash) |last_parent| {
                        if (std.mem.eql(u8, &last_parent, &current_parent)) {
                            return .sibling_fork;
                        }
                    }
                    return .discontinuous;
                }
            }
            return .continuous;
        }

        /// Ensure state is initialized or reset as needed
        fn ensureState(
            self: *Self,
            transition: *const trace_runner.StateTransition,
            fork_status: ForkStatus,
        ) !void {
            const needs_init = self.current_state == null or fork_status == .sibling_fork;

            if (needs_init) {
                if (self.current_state) |*cs| cs.deinit(self.allocator);

                var pre_state_dict = try transition.preStateAsMerklizationDict(self.allocator);
                defer pre_state_dict.deinit();

                self.current_state = try state_dict.reconstruct.reconstructState(
                    params,
                    self.allocator,
                    &pre_state_dict,
                );

                // Validate reconstruction
                var current_state_dict = try self.current_state.?.buildStateMerklizationDictionary(self.allocator);
                defer current_state_dict.deinit();

                var diff = try current_state_dict.diff(&pre_state_dict);
                defer diff.deinit();

                if (diff.has_changes()) {
                    return error.GenesisStateDiff;
                }
            }
        }

        /// Validate post-state matches expected
        fn validatePostState(
            self: *Self,
            transition: *const trace_runner.StateTransition,
            expected_post: [32]u8,
        ) !void {
            var current_dict = try self.current_state.?.buildStateMerklizationDictionary(self.allocator);
            defer current_dict.deinit();

            var expected_dict = try transition.postStateAsMerklizationDict(self.allocator);
            defer expected_dict.deinit();

            var diff = try current_dict.diff(&expected_dict);
            defer diff.deinit();

            if (diff.has_changes()) {
                std.log.err("Expected state difference detected", .{});
                if (!self.config.quiet) {
                    std.log.debug("{}", .{diff});
                }
                try self.showStateDiff(transition);
                return error.UnexpectedStateDiff;
            }

            const state_root = try self.current_state.?.buildStateRoot(self.allocator);

            if (std.mem.eql(u8, &expected_post, &state_root)) {
                if (!self.config.quiet) {
                    std.log.info("Post-state root matches: {s}", .{std.fmt.fmtSliceHexLower(&state_root)});
                }
            } else {
                std.log.err("Post-state root mismatch!", .{});
                std.log.err("Expected: {s}", .{std.fmt.fmtSliceHexLower(&expected_post)});
                std.log.err("Actual: {s}", .{std.fmt.fmtSliceHexLower(&state_root)});
                return error.PostStateRootMismatch;
            }
        }

        /// Update internal tracking based on process result
        fn updateTracking(self: *Self, result: ProcessResult) void {
            switch (result) {
                .success => |data| {
                    self.last_block_hash = data.block_hash;
                    self.last_parent_hash = data.parent_hash;
                },
                .no_op_handled => |data| {
                    self.had_no_op_blocks = true;
                    if (self.no_op_exceptions.items.len > 0) {
                        self.no_op_exceptions.appendSlice(", ") catch {};
                    }
                    self.no_op_exceptions.appendSlice(data.error_name) catch {};
                },
                .error_handled => {},
            }
        }

        /// Build final run result
        fn buildResult(self: *Self) !RunResult {
            return RunResult{
                .had_no_op_blocks = self.had_no_op_blocks,
                .no_op_exceptions = if (self.no_op_exceptions.items.len > 0)
                    try self.no_op_exceptions.toOwnedSlice()
                else
                    "",
            };
        }

        /// Log block information
        fn logBlockInfo(self: *const Self, block: *const types.Block) void {
            if (!self.config.quiet) {
                std.log.debug("Extrinsic contents: tickets={d}, preimages={d}, guarantees={d}, assurances={d}, disputes(v={d},c={d},f={d})", .{
                    block.extrinsic.tickets.data.len,
                    block.extrinsic.preimages.data.len,
                    block.extrinsic.guarantees.data.len,
                    block.extrinsic.assurances.data.len,
                    block.extrinsic.disputes.verdicts.len,
                    block.extrinsic.disputes.culprits.len,
                    block.extrinsic.disputes.faults.len,
                });
            }
        }

        /// Show state diff for debugging
        fn showStateDiff(self: *Self, transition: *const trace_runner.StateTransition) !void {
            var expected_dict = try transition.postStateAsMerklizationDict(self.allocator);
            defer expected_dict.deinit();

            var expected_state = try state_dict.reconstruct.reconstructState(params, self.allocator, &expected_dict);
            defer expected_state.deinit(self.allocator);

            var state_diff = try @import("../tests/state_diff.zig").JamStateDiff(params).build(
                self.allocator,
                &self.current_state.?,
                &expected_state,
            );
            defer state_diff.deinit();

            state_diff.printToStdErr();
        }
    };
}

/// Public entry point with configuration support
pub fn runTracesInDirWithConfig(
    comptime IOExecutor: type,
    executor: *IOExecutor,
    comptime params: jam_params.Params,
    loader: trace_runner.Loader,
    allocator: std.mem.Allocator,
    test_dir: []const u8,
    config: RunConfig,
) !RunResult {
    var runner = TraceRunner(IOExecutor, params).init(allocator, executor, loader, config);
    defer runner.deinit();

    return try runner.runTransitions(test_dir);
}

/// Public entry point - maintains backward compatibility
pub fn runTracesInDir(
    comptime IOExecutor: type,
    executor: *IOExecutor,
    comptime params: jam_params.Params,
    loader: trace_runner.Loader,
    allocator: std.mem.Allocator,
    test_dir: []const u8,
) !RunResult {
    return runTracesInDirWithConfig(IOExecutor, executor, params, loader, allocator, test_dir, .{});
}

// Helper functions

fn getStartOffset(allocator: std.mem.Allocator) !usize {
    const offset_str = std.process.getEnvVarOwned(allocator, "OFFSET") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return 0,
        else => return err,
    };
    defer allocator.free(offset_str);
    return try std.fmt.parseInt(usize, offset_str, 10);
}

fn shouldSkipTransition(name: []const u8) bool {
    return std.mem.eql(u8, name, "genesis.bin");
}
