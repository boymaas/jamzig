const std = @import("std");
const types = @import("../types.zig");
const jam_params = @import("../jam_params.zig");

const BASE_PATH = "src/jamtestvectors/data/stf/history/";

/// ReportedWorkPackage for test vectors
pub const ReportedWorkPackage = struct {
    hash: types.OpaqueHash,
    exports_root: types.OpaqueHash,

    pub fn deinit(self: *@This(), _: std.mem.Allocator) void {
        self.* = undefined;
    }
};

/// BlockInfo type for test vectors with beefy_root instead of mmr
pub const BlockInfoTestVector = struct {
    header_hash: types.OpaqueHash,
    beefy_root: types.OpaqueHash,  // Changed from mmr to beefy_root
    state_root: types.StateRoot,
    reported: []ReportedWorkPackage,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.reported) |*pkg| {
            pkg.deinit(allocator);
        }
        allocator.free(self.reported);
        self.* = undefined;
    }

    pub fn toCore(self: @This()) types.BlockInfo {
        // Note: Core BlockInfo still uses mmr field, but test vectors use beefy_root
        // This is a test-specific change that doesn't affect core types
        return .{
            .header_hash = self.header_hash,
            .mmr = types.Mmr{ .peaks = &[_]?types.OpaqueHash{} }, // Empty MMR for now
            .state_root = self.state_root,
            .reported = &[_]types.ReportedWorkPackage{}, // Convert if needed
        };
    }
};

/// RecentBlocks composite type for test vectors
pub const RecentBlocks = struct {
    history: []BlockInfoTestVector,
    mmr: types.Mmr,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.history) |*block| {
            block.deinit(allocator);
        }
        allocator.free(self.history);
        allocator.free(self.mmr.peaks);
        self.* = undefined;
    }
};

pub const State = struct {
    beta: RecentBlocks,  // Changed from []BlockInfo to RecentBlocks

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.beta.deinit(allocator);
        self.* = undefined;
    }
};

pub const Input = struct {
    header_hash: types.OpaqueHash,
    parent_state_root: types.StateRoot,
    accumulate_root: types.OpaqueHash,
    work_packages: []ReportedWorkPackage,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.work_packages) |*pkg| {
            pkg.deinit(allocator);
        }
        allocator.free(self.work_packages);
        self.* = undefined;
    }
};

pub const Output = void;

pub const TestCase = struct {
    input: Input,
    pre_state: State,
    // output: Output, // in this case, the output is always null
    post_state: State,

    pub fn buildFrom(
        comptime params: jam_params.Params,
        allocator: std.mem.Allocator,
        bin_file_path: []const u8,
    ) !@This() {
        return try @import("./loader.zig").loadAndDeserializeTestVector(
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

test "history: load single test vector" {
    const allocator = std.testing.allocator;

    const test_bins: [1][]const u8 = .{
        BASE_PATH ++ "tiny/progress_blocks_history-1.bin",
    };

    for (test_bins) |test_bin| {
        var test_vector = try TestCase.buildFrom(
            jam_params.TINY_PARAMS,
            allocator,
            test_bin,
        );
        defer test_vector.deinit(allocator);

        // Test if the pre_state is empty
        try std.testing.expectEqual(@as(usize, 0), test_vector.pre_state.beta.history.len);

        // Test if the post_state contains one block
        try std.testing.expectEqual(@as(usize, 1), test_vector.post_state.beta.history.len);
    }
}

test "history_vector:tiny" {
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

test "history_vector:full" {
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
