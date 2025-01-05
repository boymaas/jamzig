const std = @import("std");
const types = @import("../types.zig");
const jam_params = @import("../jam_params.zig");

pub const BASE_PATH = "src/jamtestvectors/data/reports/";

pub const AuthPools = struct {
    pools: [][]types.OpaqueHash,

    pub fn pools_size(params: jam_params.Params) usize {
        return params.core_count;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.pools) |pool| {
            allocator.free(pool);
        }
        allocator.free(self.pools);
        self.* = undefined;
    }
};

/// State for reports processing according to the GP
pub const State = struct {
    /// [ρ‡] Intermediate pending reports after removal of uncertain/invalid reports
    /// and processing availability assurances
    avail_assignments: types.AvailabilityAssignments,

    /// [κ'] Posterior active validators
    curr_validators: types.ValidatorSet,

    /// [λ'] Posterior previous validators
    prev_validators: types.ValidatorSet,

    /// [η'] Posterior entropy buffer
    entropy: types.EntropyBuffer,

    /// [ψ'_o] Posterior offenders
    offenders: []types.Ed25519Public,

    /// [β] Recent blocks
    recent_blocks: types.BlocksHistory,

    /// [α] Authorization pools per core
    auth_pools: AuthPools,

    /// [δ] Services dictionary
    services: []ServiceItem,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.avail_assignments.deinit(allocator);
        self.curr_validators.deinit(allocator);
        self.prev_validators.deinit(allocator);
        for (self.offenders) |*offender| {
            _ = offender;
        }
        allocator.free(self.offenders);
        for (self.recent_blocks) |*block| {
            block.deinit(allocator);
        }
        allocator.free(self.recent_blocks);
        self.auth_pools.deinit(allocator);
        for (self.services) |*service| {
            _ = service; // TODO what here
        }
        allocator.free(self.services);
        self.* = undefined;
    }
};

pub const ServiceItem = struct {
    id: types.ServiceId,
    info: types.ServiceInfo,
};

pub const Input = struct {
    /// [E_G] Guarantees extrinsic
    guarantees: types.GuaranteesExtrinsic,
    /// [H_t] Block's timeslot
    slot: types.TimeSlot,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.guarantees.deinit(allocator);
        self.* = undefined;
    }
};

pub const OutputData = struct {
    /// Reported packages hash and segment tree root
    reported: []types.ReportedWorkPackage,
    /// Reporters for reported packages
    reporters: []types.Ed25519Public,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.reported);
        allocator.free(self.reporters);
        self.* = undefined;
    }
};

pub const ErrorCode = enum(u8) {
    bad_core_index = 0,
    future_report_slot = 1,
    report_epoch_before_last = 2,
    insufficient_guarantees = 3,
    out_of_order_guarantee = 4,
    not_sorted_or_unique_guarantors = 5,
    wrong_assignment = 6,
    core_engaged = 7,
    anchor_not_recent = 8,
    bad_service_id = 9,
    bad_code_hash = 10,
    dependency_missing = 11,
    duplicate_package = 12,
    bad_state_root = 13,
    bad_beefy_mmr_root = 14,
    core_unauthorized = 15,
    bad_validator_index = 16,
    work_report_gas_too_high = 17,
    service_item_gas_too_low = 18,
    too_many_dependencies = 19,
    segment_root_lookup_invalid = 20,
    bad_signature = 21,
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
