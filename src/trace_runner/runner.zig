const std = @import("std");
const testing = std.testing;

const trace_runner = @import("parsers.zig");
const state_transitions = @import("state_transitions.zig");
pub const fuzzer_mod = @import("../fuzz_protocol/fuzzer.zig");
const embedded_target = @import("../fuzz_protocol/embedded_target.zig");
const messages = @import("../fuzz_protocol/messages.zig");
const state_converter = @import("../fuzz_protocol/state_converter.zig");

const types = @import("../types.zig");
const state = @import("../state.zig");
const jam_params = @import("../jam_params.zig");
const io = @import("../io.zig");
const entropy_handler = @import("../safrole/epoch_handler.zig");
const state_diff = @import("../tests/state_diff.zig");
const state_dictionary = @import("../state_dictionary.zig");

const tracing = @import("tracing");
const trace = tracing.scoped(.trace_runner);

// Type aliases for common configurations
const EmbeddedFuzzer = fuzzer_mod.Fuzzer(
    io.SequentialExecutor,
    embedded_target.EmbeddedTarget(io.SequentialExecutor, jam_params.TINY_PARAMS),
    jam_params.TINY_PARAMS,
);

// Entropy validation function for debugging epoch 0 issues
// NOTE: I checked the eta serializatoin adn deserialization against the format
fn validateInitialEntropy(comptime params: jam_params.Params, fuzzer: *EmbeddedFuzzer, header: types.Header) !void {
    const span = trace.span(@src(), .validate_initial_entropy);
    defer span.deinit();

    // Get the fuzz protocol state from the target
    const header_hash = std.mem.asBytes(&header.parent);
    var fuzz_state = try fuzzer.getState(header_hash.*);
    defer fuzz_state.deinit(fuzzer.allocator);

    // Convert fuzz state to JAM state
    var target_state = try state_converter.fuzzStateToJamState(params, fuzzer.allocator, fuzz_state);
    defer target_state.deinit(fuzzer.allocator);

    const time = params.Time().init(target_state.tau.?, header.slot);

    // Only validate for epoch 0
    if (time.current_epoch != 0) {
        span.debug("Skipping entropy validation - not epoch 0 (epoch={d})", .{time.current_epoch});
        return;
    }

    span.debug("=== ENTROPY VALIDATION FOR EPOCH 0 ===", .{});

    // Get entropy values
    const eta = target_state.eta.?;
    span.debug("Current eta values:", .{});
    span.debug("  eta[0] (accumulator): {s}", .{std.fmt.fmtSliceHexLower(&eta[0])});
    span.debug("  eta[1] (1 epoch ago): {s}", .{std.fmt.fmtSliceHexLower(&eta[1])});
    span.debug("  eta[2] (2 epochs ago): {s}", .{std.fmt.fmtSliceHexLower(&eta[2])});
    span.debug("  eta[3] (3 epochs ago): {s}", .{std.fmt.fmtSliceHexLower(&eta[3])});

    // Show validator sets
    span.debug("Validator set info:", .{});
    span.debug("  kappa.len: {d}", .{target_state.kappa.?.len()});
    span.debug("  gamma.k.len: {d}", .{target_state.gamma.?.k.len()});

    // Generate fallback key sequence using different entropy values to debug
    const entropy_options = [_]struct { name: []const u8, value: [32]u8 }{
        .{ .name = "eta[0]", .value = eta[0] },
        .{ .name = "eta[1]", .value = eta[1] },
        .{ .name = "eta[2]", .value = eta[2] },
        .{ .name = "eta[3]", .value = eta[3] },
    };

    for (entropy_options) |entropy_option| {
        span.debug("Testing with {s}:", .{entropy_option.name});

        // Compute expected author for first 12 slots
        for (0..12) |slot| {
            const expected_index = entropy_handler.deriveKeyIndex(entropy_option.value, slot, target_state.kappa.?.len());
            span.debug("  Slot {d}: Expected author index = {d} (using {s})", .{ slot, expected_index, entropy_option.name });
        }
    }

    // Show all validator sets and their relationships
    span.debug("", .{});
    span.debug("=== VALIDATOR SETS OVERVIEW ===", .{});

    // Lambda (λ) - Archived validators
    if (target_state.lambda) |lambda| {
        span.debug("Lambda (archived validators): {d} validators", .{lambda.len()});
    } else {
        span.debug("Lambda: not set", .{});
    }

    // Kappa (κ) - Active validator set
    if (target_state.kappa) |kappa| {
        span.debug("Kappa (active validators): {d} validators", .{kappa.len()});
    } else {
        span.debug("Kappa: not set", .{});
    }

    // Gamma.k (γ.k) - Next epoch's validator set
    if (target_state.gamma) |gamma| {
        span.debug("Gamma.k (next epoch validators): {d} validators", .{gamma.k.len()});
    } else {
        span.debug("Gamma.k: not set", .{});
    }

    // Iota (ι) - Upcoming validator set (after gamma.k)
    if (target_state.iota) |iota| {
        span.debug("Iota (upcoming validators): {d} validators", .{iota.len()});
    } else {
        span.debug("Iota: not set", .{});
    }

    // Check if gamma.s contains keys (not tickets) and show their indices in all validator sets
    if (target_state.gamma) |gamma| {
        switch (gamma.s) {
            .keys => |keys| {
                span.debug("", .{});
                span.debug("=== GAMMA.S.KEYS MAPPING ACROSS ALL VALIDATOR SETS ===", .{});
                span.debug("Found {d} keys in gamma.s.keys", .{keys.len});

                // For each key in gamma.s.keys, find its index in ALL validator sets
                for (keys, 0..) |gamma_key, gamma_index| {
                    span.debug("  gamma.s.keys[{d}]:", .{gamma_index});

                    // Search in Lambda
                    if (target_state.lambda) |lambda| {
                        for (lambda.validators, 0..) |validator, index| {
                            if (std.mem.eql(u8, &gamma_key, &validator.bandersnatch)) {
                                span.debug("    -> Lambda index: {d}", .{index});
                                break;
                            }
                        }
                    }

                    // Search in Kappa
                    if (target_state.kappa) |kappa| {
                        for (kappa.validators, 0..) |validator, index| {
                            if (std.mem.eql(u8, &gamma_key, &validator.bandersnatch)) {
                                span.debug("    -> Kappa index: {d}", .{index});
                                break;
                            }
                        }
                    }

                    // Search in Gamma.k
                    for (gamma.k.validators, 0..) |validator, index| {
                        if (std.mem.eql(u8, &gamma_key, &validator.bandersnatch)) {
                            span.debug("    -> Gamma.k index: {d}", .{index});
                            break;
                        }
                    }

                    // Search in Iota
                    if (target_state.iota) |iota| {
                        for (iota.validators, 0..) |validator, index| {
                            if (std.mem.eql(u8, &gamma_key, &validator.bandersnatch)) {
                                span.debug("    -> Iota index: {d}", .{index});
                                break;
                            }
                        }
                    }
                }
                span.debug("=== END GAMMA.S.KEYS MAPPING ===", .{});
            },
            .tickets => {
                span.debug("", .{});
                span.debug("(gamma.s contains tickets, not keys - skipping validator set mapping)", .{});
            },
        }
    }

    span.debug("=== END ENTROPY VALIDATION ===", .{});
}

// Trace processing result types
pub const Success = struct { post_root: [32]u8 };
pub const Fork = struct { expected_parent: [32]u8, actual_parent: [32]u8 };
pub const NoOp = struct { error_name: []const u8 };
pub const Mismatch = struct { expected_root: [32]u8, actual_root: [32]u8 };
pub const ProcessError = struct { err: anyerror, context: []const u8 };

pub const TraceResult = union(enum) {
    success: Success,
    fork: Fork,
    no_op: NoOp,
    mismatch: Mismatch,
    @"error": ProcessError,
};

// Lazy-loading trace iterator
pub const TraceIterator = struct {
    allocator: std.mem.Allocator,
    loader: trace_runner.Loader,
    transitions: state_transitions.StateTransitions,
    index: usize,

    const Self = @This();

    pub fn next(self: *Self) !?trace_runner.StateTransition {
        const span = trace.span(@src(), .trace_iterator_next);
        defer span.deinit();

        if (self.index >= self.transitions.items().len) {
            span.debug("Iterator exhausted", .{});
            return null;
        }

        const transition_pair = self.transitions.items()[self.index];
        self.index += 1;

        span.debug("Loading transition {d}: {s}", .{ self.index, transition_pair.bin.name });

        // Load and parse only when requested
        return try self.loader.loadTestVector(self.allocator, transition_pair.bin.path);
    }

    pub fn count(self: *Self) usize {
        return self.transitions.count();
    }

    pub fn getCurrentStateTransitionPair(self: *Self) ?*const trace_runner.state_transitions.StateTransitionPair {
        if (self.index == 0) return null;
        return &self.transitions.items()[self.index - 1];
    }

    pub fn deinit(self: *Self) void {
        self.transitions.deinit(self.allocator);
        self.* = undefined;
    }
};

// Create iterator for lazy trace loading
pub fn traceIterator(
    allocator: std.mem.Allocator,
    loader: trace_runner.Loader,
    dir: []const u8,
) !TraceIterator {
    const span = trace.span(@src(), .create_trace_iterator);
    defer span.deinit();

    // Collect state transition file pairs (but don't load content)
    var transitions = try state_transitions.collectStateTransitions(dir, allocator);
    span.debug("Found {d} transition files in {s}", .{ transitions.items().len, dir });

    return TraceIterator{
        .allocator = allocator,
        .loader = loader,
        .transitions = transitions,
        .index = 0,
    };
}

// Main trace processing function
pub fn processTrace(
    comptime params: jam_params.Params,
    fuzzer: *EmbeddedFuzzer,
    transition: trace_runner.StateTransition,
    is_first: bool,
) !TraceResult {
    const span = trace.span(@src(), .process_trace);
    defer span.deinit();

    if (is_first) {
        span.debug("Processing first trace - initializing state", .{});

        // Initialize state from pre-state dictionary
        var pre_dict = transition.preStateAsMerklizationDict(fuzzer.allocator) catch |err| {
            span.err("Failed to get pre-state dictionary: {s}", .{@errorName(err)});
            return TraceResult{ .@"error" = .{ .err = err, .context = "Failed to load pre-state dictionary" } };
        };
        defer pre_dict.deinit();

        var fuzz_state = state_converter.dictionaryToFuzzState(fuzzer.allocator, &pre_dict) catch |err| {
            span.err("Failed to convert dictionary to fuzz state: {s}", .{@errorName(err)});
            return TraceResult{ .@"error" = .{ .err = err, .context = "Failed to convert pre-state to fuzz format" } };
        };
        defer fuzz_state.deinit(fuzzer.allocator);

        // Get block header for setState call
        const block = transition.block();

        // Send state to embedded target
        const actual_state_root = fuzzer.setState(block.*.header, fuzz_state) catch |err| {
            span.err("Failed to set state on target: {s}", .{@errorName(err)});
            return TraceResult{ .@"error" = .{ .err = err, .context = "Failed to initialize target state" } };
        };

        // Verify pre-state root matches
        const expected_pre_root = transition.preStateRoot();
        if (!std.mem.eql(u8, &expected_pre_root, &actual_state_root)) {
            span.err("Pre-state root mismatch", .{});
            return TraceResult{ .mismatch = .{
                .expected_root = expected_pre_root,
                .actual_root = actual_state_root,
            } };
        }

        span.debug("State initialized successfully", .{});

        // Validate initial entropy for epoch 0 debugging
        try validateInitialEntropy(params, fuzzer, block.*.header);
    }

    // Get both pre and post state roots for no-op detection
    const expected_pre_root = transition.preStateRoot();
    const expected_post_root = transition.postStateRoot();

    // Check if this is expected to be a no-op (post-state should equal pre-state)
    const is_expected_no_op = std.mem.eql(u8, &expected_pre_root, &expected_post_root);

    // Import the block
    const block = transition.block();

    // Send the block
    var block_result = try fuzzer.sendBlock(block);
    defer block_result.deinit(fuzzer.allocator);

    const send_block_target_state_root = switch (block_result) {
        .success => |root| root,
        .import_error => |err_msg| {
            // Block import error - check if this was expected (no-op) or an actual error
            if (is_expected_no_op) {
                span.debug("Block import failed as expected (no-op): {s}", .{err_msg});
                return TraceResult{ .no_op = .{ .error_name = err_msg } };
            } else {
                span.err("Block import failed: {s}", .{err_msg});
                return TraceResult{ .@"error" = .{
                    .err = error.BlockImportFailed,
                    .context = try fuzzer.allocator.dupe(u8, err_msg),
                } };
            }
        },
    };

    // If this is an expected no_op and sendBlock send_block_target_state_root is not expected_pre_root
    // we can give an explantory error here
    if (is_expected_no_op and !std.mem.eql(u8, &expected_pre_root, &send_block_target_state_root)) {
        span.err("Expected no-op but state changed unexpectedly", .{});
        span.err("Pre-state root:  {s}", .{std.fmt.fmtSliceHexLower(&expected_pre_root)});
        span.err("Post-state root: {s}", .{std.fmt.fmtSliceHexLower(&send_block_target_state_root)});
        span.err("Block should not have changed state but did", .{});
        return TraceResult{ .@"error" = .{ .err = error.UnexpectedStateChange, .context = "Block was expected to be no-op but changed state" } };
    }

    // Block processed successfully - compare the target state root with expected
    if (!std.mem.eql(u8, &expected_post_root, &send_block_target_state_root)) {
        span.err("Post-state root mismatch", .{});
        span.err("Trace post state root: {s}", .{std.fmt.fmtSliceHexLower(&expected_post_root)});
        span.err("SendBlock  state root   : {s}", .{std.fmt.fmtSliceHexLower(&send_block_target_state_root)});

        span.err("Post-state root mismatch", .{});
        span.err("Trace pre state root    : {s}", .{std.fmt.fmtSliceHexLower(&expected_pre_root)});

        // Print detailed state diff
        span.debug("Fetching states for diff analysis...", .{});

        // Get actual state from fuzzer
        const header_hash = try block.header.header_hash(params, fuzzer.allocator);
        var fuzz_target_state = try fuzzer.getState(header_hash);
        defer fuzz_target_state.deinit(fuzzer.allocator);

        var fuzz_target_jam_state = try state_converter.fuzzStateToJamState(params, fuzzer.allocator, fuzz_target_state);
        defer fuzz_target_jam_state.deinit(fuzzer.allocator);

        // Get expected state from transition
        var expected_dict = transition.postStateAsMerklizationDict(fuzzer.allocator) catch |err| {
            span.err("Failed to get expected state dictionary for diff: {s}", .{@errorName(err)});
            return TraceResult{ .mismatch = .{
                .expected_root = expected_post_root,
                .actual_root = send_block_target_state_root,
            } };
        };
        defer expected_dict.deinit();

        var expected_jam_state = try state_dictionary.reconstruct.reconstructState(params, fuzzer.allocator, &expected_dict);
        defer expected_jam_state.deinit(fuzzer.allocator);

        // Ensure that the state we got from the fuzz target has the same root we got back from
        // the sendBlock command
        const fuzz_target_jam_state_root = try fuzz_target_jam_state.buildStateRoot(fuzzer.allocator);
        if (!std.mem.eql(u8, &fuzz_target_jam_state_root, &send_block_target_state_root)) {
            std.debug.print("\x1b[31mInternal fuzz target consistency check failed: state root from sendBlock() does not match getState() result\x1b[0m\n", .{});
            std.debug.print("\x1b[31mState root received from  sendBlock: {any}\x1b[0m\n", .{std.fmt.fmtSliceHexLower(&send_block_target_state_root)});
            std.debug.print("\x1b[31mState root calculated from getState: {any}\x1b[0m\n", .{std.fmt.fmtSliceHexLower(&fuzz_target_jam_state_root)});
            std.debug.print("\x1b[31mThis indicates a potential issue with the fuzz target's state management\x1b[0m\n", .{});

            return error.FuzzTargetStateMismatch;
        }

        // Build and print diff
        // IMPORTANT: state_diff.build(allocator, expected, actual) - order matters for correct labels!
        // - expected_jam_state: the correct state from the trace file (what we SHOULD produce)
        // - fuzz_target_jam_state: our computed state (what we ACTUALLY produced)
        std.debug.print("\n=== STATE MISMATCH DIFF ===\n", .{});
        var diff = try state_diff.JamStateDiff(params).build(fuzzer.allocator, &expected_jam_state, &fuzz_target_jam_state);
        defer diff.deinit();
        diff.printToStdErr();
        std.debug.print("=== END DIFF ===\n\n", .{});

        return TraceResult{ .mismatch = .{
            .expected_root = expected_post_root,
            .actual_root = send_block_target_state_root,
        } };
    }

    span.debug("Block processed successfully", .{});
    return TraceResult{ .success = .{ .post_root = send_block_target_state_root } };
}

// Report generation types
pub const Summary = struct {
    total: usize,
    success: usize,
    forks: usize,
    no_ops: usize,
    mismatches: usize,
    errors: usize,
};

pub const FailureDetail = struct {
    index: usize,
    trace_name: []const u8,
    result: TraceResult,
};

pub const NoOpDetail = struct {
    index: usize,
    trace_name: []const u8,
    error_name: []const u8,
};

pub const ConformanceReport = struct {
    allocator: std.mem.Allocator,
    summary: Summary,
    failures: []FailureDetail,
    no_op_blocks: []NoOpDetail,

    const Self = @This();

    pub fn format(self: *const Self) ![]u8 {
        var output = std.ArrayList(u8).init(self.allocator);
        defer output.deinit();

        const writer = output.writer();

        // Summary section
        try writer.print("\n=== Conformance Test Results ===\n");
        try writer.print("Total: {d} traces\n", .{self.summary.total});
        try writer.print("Success: {d}\n", .{self.summary.success});
        try writer.print("Forks: {d}\n", .{self.summary.forks});
        try writer.print("No-ops: {d}\n", .{self.summary.no_ops});
        try writer.print("Mismatches: {d}\n", .{self.summary.mismatches});
        try writer.print("Errors: {d}\n", .{self.summary.errors});
        try writer.print("\n");

        // No-op blocks section
        if (self.no_op_blocks.len > 0) {
            try writer.print("=== No-op Blocks ===\n");
            for (self.no_op_blocks) |no_op| {
                try writer.print("[{d:3}] {s}: {s}\n", .{ no_op.index, no_op.trace_name, no_op.error_name });
            }
            try writer.print("\n");
        }

        // Failures section
        if (self.failures.len > 0) {
            try writer.print("=== Failures ===\n");
            for (self.failures) |failure| {
                try writer.print("[{d:3}] {s}: ", .{ failure.index, failure.trace_name });
                switch (failure.result) {
                    .mismatch => |mismatch| {
                        try writer.print("State root mismatch\n");
                        try writer.print("      Expected: {s}\n", .{std.fmt.fmtSliceHexLower(&mismatch.expected_root)});
                        try writer.print("      Actual:   {s}\n", .{std.fmt.fmtSliceHexLower(&mismatch.actual_root)});
                    },
                    .fork => |fork| {
                        try writer.print("Fork detected\n");
                        try writer.print("      Expected parent: {s}\n", .{std.fmt.fmtSliceHexLower(&fork.expected_parent)});
                        try writer.print("      Actual parent:   {s}\n", .{std.fmt.fmtSliceHexLower(&fork.actual_parent)});
                    },
                    .@"error" => |err_info| {
                        try writer.print("Error: {s} - {s}\n", .{ @errorName(err_info.err), err_info.context });
                    },
                    else => try writer.print("Other failure\n"),
                }
            }
            try writer.print("\n");
        }

        return try output.toOwnedSlice();
    }

    pub fn deinit(self: *Self) void {
        for (self.failures) |failure| {
            self.allocator.free(failure.trace_name);
        }
        self.allocator.free(self.failures);

        for (self.no_op_blocks) |no_op| {
            self.allocator.free(no_op.trace_name);
            self.allocator.free(no_op.error_name);
        }
        self.allocator.free(self.no_op_blocks);

        self.* = undefined;
    }
};

// Generate comprehensive report from trace results
pub fn generateReport(
    allocator: std.mem.Allocator,
    results: []TraceResult,
    trace_names: [][]const u8,
) !ConformanceReport {
    const span = trace.span(@src(), .generate_report);
    defer span.deinit();

    var summary = Summary{
        .total = results.len,
        .success = 0,
        .forks = 0,
        .no_ops = 0,
        .mismatches = 0,
        .errors = 0,
    };

    var failures = std.ArrayList(FailureDetail).init(allocator);
    var no_op_blocks = std.ArrayList(NoOpDetail).init(allocator);

    for (results, 0..) |result, i| {
        switch (result) {
            .success => summary.success += 1,
            .fork => {
                summary.forks += 1;
                try failures.append(.{
                    .index = i,
                    .trace_name = try allocator.dupe(u8, trace_names[i]),
                    .result = result,
                });
            },
            .no_op => |no_op| {
                summary.no_ops += 1;
                try no_op_blocks.append(.{
                    .index = i,
                    .trace_name = try allocator.dupe(u8, trace_names[i]),
                    .error_name = try allocator.dupe(u8, no_op.error_name),
                });
            },
            .mismatch => {
                summary.mismatches += 1;
                try failures.append(.{
                    .index = i,
                    .trace_name = try allocator.dupe(u8, trace_names[i]),
                    .result = result,
                });
            },
            .@"error" => {
                summary.errors += 1;
                try failures.append(.{
                    .index = i,
                    .trace_name = try allocator.dupe(u8, trace_names[i]),
                    .result = result,
                });
            },
        }
    }

    span.debug("Generated report - {d} total, {d} success, {d} failures", .{ summary.total, summary.success, failures.items.len });

    return ConformanceReport{
        .allocator = allocator,
        .summary = summary,
        .failures = try failures.toOwnedSlice(),
        .no_op_blocks = try no_op_blocks.toOwnedSlice(),
    };
}

// Simple result struct for compatibility with jamtestvectors
pub const TraceRunResult = struct {
    results: []TraceResult,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        _ = allocator; // Use self.allocator instead
        self.allocator.free(self.results);
        self.* = undefined;
    }
};

// Compatibility function for jamtestvectors.zig
pub fn runTracesInDir(
    comptime IOExecutor: type,
    executor: *IOExecutor,
    comptime params: jam_params.Params,
    loader: trace_runner.Loader,
    allocator: std.mem.Allocator,
    test_dir: []const u8,
) !TraceRunResult {
    // Create embedded fuzzer
    var fuzzer = try fuzzer_mod.createEmbeddedFuzzer(params, executor, allocator, 0);
    defer fuzzer.destroy();

    // Connect and handshake
    try fuzzer.connectToTarget();
    try fuzzer.performHandshake();

    // Create trace iterator
    var iter = try traceIterator(allocator, loader, test_dir);
    defer iter.deinit();

    // Get total count for progress output
    const total_traces = iter.count();

    // Collect results
    var results = std.ArrayList(TraceResult).init(allocator);
    errdefer results.deinit();

    // Process traces
    var is_first = true;
    var trace_count: usize = 0;
    while (try iter.next()) |transition| {
        defer transition.deinit(allocator);

        trace_count += 1;

        // Extract filename from the current transition path
        const current_pair = iter.getCurrentStateTransitionPair().?;
        const full_path = current_pair.bin.path;
        const filename = std.fs.path.basename(full_path);

        // Show progress
        std.debug.print("Processing trace {d}/{d}: {s}\n", .{ trace_count, total_traces, filename });

        const result = try processTrace(params, fuzzer, transition, is_first);
        try results.append(result);

        // Fail on errors or mismatches (keeps original behavior)
        switch (result) {
            .@"error" => |err| return err.err,
            .mismatch => return error.StateMismatch,
            else => {},
        }

        is_first = false;
    }

    return TraceRunResult{
        .results = try results.toOwnedSlice(),
        .allocator = allocator,
    };
}
