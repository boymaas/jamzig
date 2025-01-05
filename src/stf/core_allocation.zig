const std = @import("std");

const state = @import("../state.zig");
const types = @import("../types.zig");

const Params = @import("../jam_params.zig").Params;
const StateTransition = @import("../state_delta.zig").StateTransition;

pub fn transitionCoreAllocations(
    comptime params: Params,
    stx: *StateTransition(params),
    xtassurances: types.AssurancesExtrinsic,
    xtguarantees: types.GuaranteesExtrinsic,
) !state.Rho {
    _ = stx;
    _ = xtassurances;
    _ = xtguarantees;
    // Transition ρ based on new assurances and guarantees
    @panic("Not implemented");
}
