const std = @import("std");

const types = @import("../types.zig");
const state = @import("../state.zig");

const Params = @import("../jam_params.zig").Params;
const StateTransition = @import("../state_delta.zig").StateTransition;

const tracing = @import("../tracing.zig");
const trace = tracing.scoped(.stf);

pub const Error = error{};

pub fn transition(
    comptime params: Params,
    stx: *StateTransition(params),
    new_block: *const types.Block,
) !void {
    const span = trace.span(.transition_recent_history);
    defer span.deinit();

    var beta_prime: *state.Beta = try stx.ensure(.beta_prime);

    span.debug("Starting recent history transition", .{});
    span.trace("Current beta block count: {d}", .{beta_prime.blocks.items.len});

    const RecentBlock = @import("../recent_blocks.zig").RecentBlock;
    // Transition β with information from the new block
    try beta_prime.import(try RecentBlock.fromBlock(params, stx.allocator, new_block));
}
