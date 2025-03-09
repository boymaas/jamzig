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

    // Now update the stats
    const pi: *state.Pi = try stx.ensure(.pi_prime);
    var stats = try pi.getValidatorStats(author_index);
    stats.updatePreimagesIntroduced(preimages_extrinsic.count());
    stats.updateOctetsAcrossPreimages(preimages_extrinsic.calcOctetsAcrossPreimages());
}
