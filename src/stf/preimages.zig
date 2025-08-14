const std = @import("std");

const types = @import("../types.zig");
const state = @import("../state.zig");
const preimages = @import("../preimages.zig");

const Params = @import("../jam_params.zig").Params;
const StateTransition = @import("../state_delta.zig").StateTransition;

const tracing = @import("../tracing.zig");
const trace = tracing.scoped(.stf);

pub fn transition(
    comptime params: Params,
    stx: *StateTransition(params),
    preimages_extrinsic: types.PreimagesExtrinsic,
    author_index: types.ValidatorIndex,
) !void {
    const span = trace.span(.preimages);
    defer span.deinit();

    // Process the preimages extrinsic
    try preimages.processPreimagesExtrinsic(
        params,
        stx,
        preimages_extrinsic,
    );

    _ = author_index;
}
