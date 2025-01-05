const std = @import("std");
const state = @import("../state.zig");
const types = @import("../types.zig");

const Params = @import("../jam_params.zig").Params;
const StateTransition = @import("../state_delta.zig").StateTransition;

pub fn accumulateWorkReports(
    comptime params: Params,
    stx: *StateTransition(params),
) !void {
    _ = stx;
    // Process work reports and transition δ, χ, ι, and φ
    @panic("Not implemented");
}

pub fn transitionValidatorStatistics(
    comptime params: Params,
    stx: *StateTransition(params),
    new_block: types.Block,
) !state.Pi {
    _ = stx;
    _ = new_block;
    // Transition π with new validator statistics
    @panic("Not implemented");
}
