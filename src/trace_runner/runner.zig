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

const tracing = @import("tracing");
const trace = tracing.scoped(.trace_runner);

// Type aliases for common configurations
const EmbeddedFuzzer = fuzzer_mod.Fuzzer(
    io.SequentialExecutor,
    embedded_target.EmbeddedTarget(io.SequentialExecutor, jam_params.TINY_PARAMS),
    jam_params.TINY_PARAMS,
);

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
    }

    // Import the block
    const block = transition.block();
    const target_state_root = fuzzer.sendBlock(block) catch |err| {
        span.err("Failed to send block: {s}", .{@errorName(err)});
        return TraceResult{ .@"error" = .{ .err = err, .context = "Failed to send block to target" } };
    };

    // Compare the target state root with the expected post-state root
    const expected_post_root = transition.postStateRoot();
    if (!std.mem.eql(u8, &expected_post_root, &target_state_root)) {
        span.err("Post-state root mismatch", .{});
        return TraceResult{ .mismatch = .{
            .expected_root = expected_post_root,
            .actual_root = target_state_root,
        } };
    }

    span.debug("Block processed successfully", .{});
    return TraceResult{ .success = .{ .post_root = target_state_root } };

    // Note: We don't currently detect no-ops in this simplified version.
    // The fuzzer's trace mode only detects when the state root doesn't change,
    // but we don't have access to the previous state root in this function.
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

        const result = try processTrace(fuzzer, transition, is_first);
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
