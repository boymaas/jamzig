const std = @import("std");

const state = @import("../state.zig");
const types = @import("../types.zig");

const Params = @import("../jam_params.zig").Params;
const StateTransition = @import("../state_delta.zig").StateTransition;

pub const Error = error{
    invalid_guarantees,
};

pub fn transition(
    comptime params: Params,
    stx: *StateTransition(params),
    xtguarantees: types.GuaranteesExtrinsic,
) !void {
    _ = stx;
    _ = xtguarantees;
    // Transition α based on new authorizations
    @panic("Not implemented");
}
