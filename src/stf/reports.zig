const std = @import("std");
const state = @import("../state.zig");
const types = @import("../types.zig");

const Params = @import("../jam_params.zig").Params;
const StateTransition = @import("../state_delta.zig").StateTransition;

const reports = @import("../reports.zig");

pub const Error = error{};

pub fn accumulateWorkReports(
    comptime params: Params,
    stx: *StateTransition(params),
) !void {
    _ = stx;
    // Process work reports and transition δ, χ, ι, and φ
    @panic("Not implemented");
}

pub const ReportsResult = struct {
    result: reports.Result,
    validator_indices: []const types.ValidatorIndex = &.{},

    pub fn getValidatorIndices(self: *ReportsResult) []const types.ValidatorIndex {
        return self.validator_indices;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.validator_indices);
        self.result.deinit(allocator);
        self.* = undefined;
    }
};

pub fn transition(
    comptime params: Params,
    allocator: std.mem.Allocator,
    stx: *StateTransition(params),
    block: *const types.Block,
) !ReportsResult {
    const validated = try reports.ValidatedGuaranteeExtrinsic.validate(
        params,
        allocator,
        stx,
        block.extrinsic.guarantees,
    );

    // Process
    const result = try reports.processGuaranteeExtrinsic(
        params,
        allocator,
        stx,
        validated,
    );

    // Find the indices of validators who reported
    const kappa: *const state.Kappa = try stx.get(.kappa);
    const validator_indices = try kappa.findValidatorIndices(allocator, .Ed25519Public, result.reporters);

    return .{ .validator_indices = validator_indices, .result = result };
}
