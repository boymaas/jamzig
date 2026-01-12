const std = @import("std");
const types = @import("../types.zig");

pub const BASE_PATH = "src/jamtestvectors/data/stf/assurances/";

/// Represents the state for assurance processing according to the GP
pub const State = struct {
    /// [ρ†] Intermediate pending reports after that any work report judged as
    /// uncertain or invalid has been removed from it. Mutated to ϱ‡.
    avail_assignments: types.AvailabilityAssignments,

    /// [κ'] Posterior active validators.
    curr_validators: types.ValidatorSet,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.avail_assignments.deinit(allocator);
        self.curr_validators.deinit(allocator);
        self.* = undefined;
    }
};

pub const Input = struct {
    /// [E_A] Assurances extrinsic.
    assurances: types.AssurancesExtrinsic,
    /// [H_t] Block's timeslot.
    slot: types.TimeSlot,
    /// [H_p] Parent hash.
    parent: types.HeaderHash,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.assurances.deinit(allocator);
        self.* = undefined;
    }
};

pub const ErrorCode = enum(u8) {
    bad_attestation_parent = 0,
    bad_validator_index = 1,
    core_not_engaged = 2,
    bad_signature = 3,
    not_sorted_or_unique_assurers = 4,
};

pub const OutputData = struct {
    reported: []types.WorkReport,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.reported) |*report| {
            report.deinit(allocator);
        }
        allocator.free(self.reported);
        self.* = undefined;
    }
};

pub const Output = union(enum) {
    ok: OutputData,
    err: ErrorCode,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ok => |*data| data.deinit(allocator),
            .err => {},
        }
        self.* = undefined;
    }

    pub fn format(
        self: Output,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        switch (self) {
            .err => |e| try writer.print("err = {s}", .{@tagName(e)}),
            .ok => |data| try writer.print("ok = {any}", .{data.reported.len}),
        }
    }
};

pub const TestCase = struct {
    input: Input,
    pre_state: State,
    output: Output,
    post_state: State,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.input.deinit(allocator);
        self.pre_state.deinit(allocator);
        self.output.deinit(allocator);
        self.post_state.deinit(allocator);
        self.* = undefined;
    }
};

test "parse.assurances.single" {
    const testing = std.testing;
    const TINY = @import("../jam_params.zig").TINY_PARAMS;

    var test_case = try loader.loadAndDeserializeTestVector(TestCase, TINY, testing.allocator, BASE_PATH ++ "tiny/no_assurances-1.bin");
    defer test_case.deinit(testing.allocator);

    try testing.expect(test_case.input.assurances.data.len == 0);
}

test "parse.assurances.tiny" {
    const dir = @import("dir.zig");
    const testing = std.testing;

    const TINY = @import("../jam_params.zig").TINY_PARAMS;

    var test_cases = try dir.scan(TestCase, TINY, testing.allocator, BASE_PATH ++ "tiny");
    defer test_cases.deinit();
}

test "parse.assurances.full" {
    const dir = @import("dir.zig");
    const testing = std.testing;

    const FULL = @import("../jam_params.zig").FULL_PARAMS;

    var test_cases = try dir.scan(TestCase, FULL, testing.allocator, BASE_PATH ++ "full");
    defer test_cases.deinit();
}

const loader = @import("loader.zig");
const OrderedFiles = @import("../tests/ordered_files.zig");
const codec = @import("../codec.zig");
const slurp = @import("../tests/slurp.zig");
const Params = @import("../jam_params.zig").Params;

fn testAssurancesRoundtrip(comptime params: Params, test_dir: []const u8, allocator: std.mem.Allocator) !void {
    var ordered_files = try OrderedFiles.getOrderedFiles(allocator, test_dir);
    defer ordered_files.deinit();

    for (ordered_files.items()) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".bin")) {
            continue;
        }

        var test_case = try loader.loadAndDeserializeTestVector(TestCase, params, allocator, entry.path);
        defer test_case.deinit(allocator);

        const binary_serialized = try codec.serializeAlloc(TestCase, params, allocator, test_case);
        defer allocator.free(binary_serialized);

        var binary_loaded = try slurp.slurpFile(allocator, entry.path);
        defer binary_loaded.deinit();

        try std.testing.expectEqualSlices(u8, binary_loaded.buffer, binary_serialized);
        std.debug.print("Successfully validated {s}\n", .{entry.path});
    }
}

test "parse.assurances.tiny.deserialize-serialize-roundtrip" {
    const TINY = @import("../jam_params.zig").TINY_PARAMS;
    try testAssurancesRoundtrip(TINY, BASE_PATH ++ "tiny", std.testing.allocator);
}

test "parse.assurances.full.deserialize-serialize-roundtrip" {
    const FULL = @import("../jam_params.zig").FULL_PARAMS;
    try testAssurancesRoundtrip(FULL, BASE_PATH ++ "full", std.testing.allocator);
}
