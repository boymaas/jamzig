const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const jam_params = @import("../jam_params.zig");

pub const BASE_PATH = "src/jamtestvectors/data/stf/reports/";

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

pub const ServiceInfoTestVector = struct {
    version: u8,
    code_hash: types.OpaqueHash,
    balance: types.Balance,
    min_item_gas: types.Gas,
    min_memo_gas: types.Gas,
    bytes: types.U64,
    deposit_offset: types.U64,
    items: types.U32,
    creation_slot: types.U32,
    last_accumulation_slot: types.U32,
    parent_service: types.U32,

    pub fn toCore(self: @This()) types.ServiceInfo {
        return .{
            .code_hash = self.code_hash,
            .balance = self.balance,
            .min_item_gas = self.min_item_gas,
            .min_memo_gas = self.min_memo_gas,
            .bytes = self.bytes,
            .items = self.items,
        };
    }
};

pub const BlockInfoTestVector = struct {
    header_hash: types.Hash,
    beefy_root: types.OpaqueHash,
    state_root: types.StateRoot,
    reported: []types.ReportedWorkPackage,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.reported);
        self.* = undefined;
    }
};

pub const Account = struct {
    service: ServiceInfoTestVector,
};

pub const AccountsMapEntry = struct {
    id: types.ServiceId,
    data: Account,
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

pub const CoresStatistics = struct {
    stats: []state.validator_stats.CoreActivityRecord,

    pub fn stats_size(params: jam_params.Params) usize {
        return params.core_count;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.stats);
        self.* = undefined;
    }
};

pub const ServicesStatisticsMapEntry = struct {
    id: types.ServiceId,
    record: state.validator_stats.ServiceActivityRecord,
};

pub const ServiceStatistics = struct {
    stats: []ServicesStatisticsMapEntry,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.stats);
        self.* = undefined;
    }

    pub fn decode(_: anytype, reader: anytype, allocator: std.mem.Allocator) !@This() {
        const codec = @import("../codec.zig");

        const length = try codec.readInteger(reader);

        var stats = try allocator.alloc(ServicesStatisticsMapEntry, length);
        errdefer allocator.free(stats);

        for (0..length) |i| {
            stats[i] = try codec.deserializeAlloc(ServicesStatisticsMapEntry, .{}, allocator, reader);
        }

        return @This(){
            .stats = stats,
        };
    }
};

pub const State = struct {
    avail_assignments: types.AvailabilityAssignments,

    curr_validators: types.ValidatorSet,

    prev_validators: types.ValidatorSet,

    entropy: types.EntropyBuffer,

    offenders: []types.Ed25519Public,

    recent_blocks: RecentBlocks,

    auth_pools: AuthPools,

    accounts: []AccountsMapEntry,

    cores_statistics: CoresStatistics,

    services_statistics: ServiceStatistics,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.avail_assignments.deinit(allocator);
        self.curr_validators.deinit(allocator);
        self.prev_validators.deinit(allocator);
        self.cores_statistics.deinit(allocator);
        self.services_statistics.deinit(allocator);
        allocator.free(self.offenders);
        self.recent_blocks.deinit(allocator);
        allocator.free(self.accounts);
        self.auth_pools.deinit(allocator);
        self.* = undefined;
    }
};

pub const ServiceItem = struct {
    id: types.ServiceId,
    info: ServiceInfoTestVector,
};

pub const Input = struct {
    guarantees: types.GuaranteesExtrinsic,
    slot: types.TimeSlot,
    known_packages: []types.WorkPackageHash,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.guarantees.deinit(allocator);
        allocator.free(self.known_packages);
        self.* = undefined;
    }
};

pub const OutputData = struct {
    reported: []types.ReportedWorkPackage,
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
    work_report_too_big = 22,
    banned_validators = 23,
    lookup_anchor_not_recent = 24,  // v0.7.2
    missing_work_results = 25,  // v0.7.2
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
