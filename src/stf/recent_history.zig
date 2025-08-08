const std = @import("std");

const types = @import("../types.zig");
const state = @import("../state.zig");

const Params = @import("../jam_params.zig").Params;
const StateTransition = @import("../state_delta.zig").StateTransition;

const tracing = @import("../tracing.zig");
const trace = tracing.scoped(.stf);

pub const Error = error{};

/// Updates the parent block's state root in Beta before reports transition
/// This ensures that guarantees can validate against the correct state root
pub fn updateParentBlockStateRoot(
    comptime params: Params,
    stx: *StateTransition(params),
    parent_state_root: types.Hash,
) !void {
    const span = trace.span(.update_parent_block_state_root);
    defer span.deinit();

    // Get beta_prime to ensure we're modifying the state
    var beta_prime: *state.Beta = try stx.ensure(.beta_prime);

    span.debug("Updating parent block state root in beta_prime", .{});
    span.debug("Parent state root from header: {s}", .{std.fmt.fmtSliceHexLower(&parent_state_root)});

    // Log current state of blocks
    if (beta_prime.recent_history.blocks.items.len > 0) {
        const last_block = beta_prime.recent_history.blocks.items[beta_prime.recent_history.blocks.items.len - 1];
        span.debug("Last block hash: {s}, current state root: {s}", .{
            std.fmt.fmtSliceHexLower(&last_block.header_hash),
            std.fmt.fmtSliceHexLower(&last_block.state_root),
        });
    }

    beta_prime.updateParentBlockStateRoot(parent_state_root);
}

pub fn transition(
    comptime params: Params,
    stx: *StateTransition(params),
    new_block: *const types.Block,
    accumulate_root: types.AccumulateRoot,
) !void {
    const span = trace.span(.transition_recent_history);
    defer span.deinit();

    var beta_prime: *state.Beta = try stx.ensure(.beta_prime);

    span.debug("Starting recent history transition", .{});
    span.trace("Current beta block count: {d}", .{beta_prime.recent_history.blocks.items.len});

    const RecentBlock = @import("../recent_blocks.zig").RecentBlock;
    // Transition β with information from the new block
    try beta_prime.import(try RecentBlock.fromBlock(params, stx.allocator, new_block, accumulate_root));
}
