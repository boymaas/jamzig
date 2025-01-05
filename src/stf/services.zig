const std = @import("std");

const state = @import("../state.zig");
const types = @import("../types.zig");

const Params = @import("../jam_params.zig").Params;
const StateTransition = @import("../state_delta.zig").StateTransition;

pub const Error = error{};

pub fn transition(
    comptime params: Params,
    stx: *StateTransition(params),
    xtpreimages: types.PreimagesExtrinsic,
) !void {
    _ = stx;
    _ = xtpreimages;
    // Transition δ with new preimages
    @panic("Not implemented");
}
