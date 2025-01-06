const state = @import("state.zig");
const Params = @import("jam_params.zig").Params;

pub fn Gamma(comptime params: Params) type {
    return state.Gamma(params.validators_count, params.epoch_length);
}
