const std = @import("std");
const types = @import("../types.zig");
const validator_stats = @import("../validator_stats.zig");
const jam_params = @import("../jam_params.zig");

const BASE_PATH = "src/jamtestvectors/data/stf/statistics/";

/// ValidatorsStatistics is just an alias for array of ValidatorStats
pub const ValidatorsStatistics = struct {
    stats: []validator_stats.ValidatorStats,

    pub fn stats_size(params: jam_params.Params) usize {
        return params.validators_count;
    }
};

pub const State = struct {
    // [π_V] Current validators statistics
    vals_curr_stats: ValidatorsStatistics,
    // [π_L] Last validators statistics
    vals_last_stats: ValidatorsStatistics,
    // [τ] Prior timeslot
    slot: types.TimeSlot,
    // [κ'] Posterior active validators
    curr_validators: types.ValidatorSet,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.vals_curr_stats.stats);
        allocator.free(self.vals_last_stats.stats);
        self.curr_validators.deinit(allocator);
        self.* = undefined;
    }
};

pub const Input = struct {
    // [H_t] Block timeslot
    slot: types.TimeSlot,
    // [H_i] Block author
    author_index: types.ValidatorIndex,
    // [E] Extrinsic
    extrinsic: types.Extrinsic,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.extrinsic.deinit(allocator);
        self.* = undefined;
    }
};

pub const Output = void;

pub const TestCase = struct {
    input: Input,
    pre_state: State,
    output: Output,
    post_state: State,

    pub fn buildFrom(
        comptime params: jam_params.Params,
        allocator: std.mem.Allocator,
        bin_file_path: []const u8,
    ) !@This() {
        return try @import("./loader.zig").loadAndDeserializeTestVectorWithContext(
            TestCase,
            params,
            allocator,
            bin_file_path,
        );
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.input.deinit(allocator);
        self.pre_state.deinit(allocator);
        self.post_state.deinit(allocator);
        self.* = undefined;
    }
};

test "statistics_vector:tiny" {
    const allocator = std.testing.allocator;

    const dir = @import("dir.zig");
    var test_vectors = try dir.scan(
        TestCase,
        jam_params.TINY_PARAMS,
        allocator,
        BASE_PATH ++ "tiny/",
    );
    defer test_vectors.deinit();
}

test "statistics_vector:full" {
    const allocator = std.testing.allocator;

    const dir = @import("dir.zig");
    var test_vectors = try dir.scan(
        TestCase,
        jam_params.FULL_PARAMS,
        allocator,
        BASE_PATH ++ "full/",
    );
    defer test_vectors.deinit();
}

test "statistics_vector:decode_single_tiny" {
    const allocator = std.testing.allocator;

    // Load and decode a single test case to examine the decoding process
    var test_case = try TestCase.buildFrom(
        jam_params.TINY_PARAMS,
        allocator,
        BASE_PATH ++ "tiny/stats_with_empty_extrinsic-1.bin",
    );
    defer test_case.deinit(allocator);

    // Print some decoded data to verify decoding works
    std.debug.print("\n=== Statistics Test Case Decoded ===\n", .{});
    std.debug.print("Input slot: {}\n", .{test_case.input.slot});
    std.debug.print("Author index: {}\n", .{test_case.input.author_index});
    std.debug.print("Pre-state slot: {}\n", .{test_case.pre_state.slot});
    std.debug.print("Pre-state curr_validators count: {}\n", .{test_case.pre_state.curr_validators.len()});
    std.debug.print("Post-state slot: {}\n", .{test_case.post_state.slot});
    std.debug.print("Vals curr stats count: {}\n", .{test_case.pre_state.vals_curr_stats.stats.len});
    std.debug.print("Vals last stats count: {}\n", .{test_case.pre_state.vals_last_stats.stats.len});
}

