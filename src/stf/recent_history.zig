const std = @import("std");

const types = @import("../types.zig");
const state = @import("../state.zig");

const Params = @import("../jam_params.zig").Params;
const StateTransition = @import("../state_delta.zig").StateTransition;

const tracing = @import("tracing");
const trace = tracing.scoped(.stf);

pub const Error = error{};

pub fn updateParentBlockStateRoot(
    comptime params: Params,
    stx: *StateTransition(params),
    parent_state_root: types.Hash,
) !void {
    const span = trace.span(@src(), .update_parent_block_state_root);
    defer span.deinit();

    var beta_prime: *state.Beta = try stx.ensure(.beta_prime);
    beta_prime.updateParentBlockStateRoot(parent_state_root);
}

pub fn transition(
    comptime params: Params,
    stx: *StateTransition(params),
    new_block: *const types.Block,
    accumulate_root: types.AccumulateRoot,
) !void {
    const span = trace.span(@src(), .recent_history);
    defer span.deinit();

    var beta_prime: *state.Beta = try stx.ensure(.beta_prime);

    const RecentBlock = @import("../recent_blocks.zig").RecentBlock;
    try beta_prime.import(try RecentBlock.fromBlock(params, stx.allocator, new_block, accumulate_root));
}
