const std = @import("std");
const types = @import("../types.zig");
const jam_params = @import("../jam_params.zig");

const BASE_PATH = "src/jamtestvectors/data/disputes/";

pub const State = struct {
    psi: types.DisputesRecords,
    rho: types.AvailabilityAssignments,
    tau: types.TimeSlot,
    kappa: types.ValidatorSet,
    lambda: types.ValidatorSet,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        self.psi.deinit(allocator);
        self.rho.deinit(allocator);
        self.kappa.deinit(allocator);
        self.lambda.deinit(allocator);
    }
};

pub const Input = struct {
    disputes: types.DisputesExtrinsic,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        self.disputes.deinit(allocator);
    }
};

pub const ErrorCode = enum(u8) {
    already_judged = 0,
    bad_vote_split = 1,
    verdicts_not_sorted_unique = 2,
    judgements_not_sorted_unique = 3,
    culprits_not_sorted_unique = 4,
    faults_not_sorted_unique = 5,
    not_enough_culprits = 6,
    not_enough_faults = 7,
    culprits_verdict_not_bad = 8,
    fault_verdict_wrong = 9,
    offender_already_reported = 10,
    bad_judgement_age = 11,
    bad_validator_index = 12,
    bad_signature = 13,
};

pub const OutputData = struct {
    offenders_mark: types.OffendersMark,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        self.offenders_mark.deinit(allocator);
    }
};

pub const Output = union(enum) {
    ok: OutputData,
    err: ErrorCode,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ok => |*data| data.deinit(allocator),
            .err => {},
        }
    }
};

pub const TestCase = struct {
    input: Input,
    pre_state: State,
    output: Output,
    post_state: State,

    pub fn build_from(
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

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        self.input.deinit(allocator);
        self.pre_state.deinit(allocator);
        self.output.deinit(allocator);
        self.post_state.deinit(allocator);
    }
};

test "Load and dump a tiny test vector, and check the outputs" {
    const allocator = std.testing.allocator;

    const test_jsons: [1][]const u8 = .{
        BASE_PATH ++ "tiny/progress_with_no_verdicts-1.bin",
    };

    for (test_jsons) |test_json| {
        const test_vector = try TestCase.build_from(
            jam_params.TINY_PARAMS,
            allocator,
            test_json,
        );
        defer test_vector.deinit(allocator);

        std.debug.print("Test vector: {?}\n", .{test_vector.output});
    }
}

test "Correct parsing of all tiny test vectors" {
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

test "Correct parsing of all full test vectors" {
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
