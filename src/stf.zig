const std = @import("std");
const Allocator = std.mem.Allocator;

const utils = @import("utils.zig");
const types = @import("types.zig");
const state = @import("state.zig");
const JamState = state.JamState;
const Block = types.Block;
const Header = types.Header;

const StateTransition = @import("state_delta.zig").StateTransition;
const Params = @import("jam_params.zig").Params;

pub const authorization = @import("stf/authorization.zig");
pub const core_allocation = @import("stf/core_allocation.zig");
pub const disputes = @import("stf/disputes.zig");
pub const eta = @import("stf/eta.zig");
pub const recent_history = @import("stf/recent_history.zig");
pub const safrole = @import("stf/safrole.zig");
pub const services = @import("stf/services.zig");
pub const time = @import("stf/time.zig");
pub const work_report = @import("stf/work_reports.zig");

const tracing = @import("tracing.zig");
const trace = tracing.scoped(.stf);

pub fn stateTransition(
    comptime params: Params,
    allocator: Allocator,
    current_state: *const JamState(params),
    new_block: *const Block,
) !JamState(params) {
    const span = trace.span(.state_transition);
    defer span.deinit();
    std.debug.assert(current_state.ensureFullyInitialized() catch false);

    const transition_time = params.Time().init(current_state.tau.?, new_block.header.slot);
    var state_transition = try StateTransition(params).init(allocator, current_state, transition_time);
    errdefer state_transition.deinit();

    try time.transition(
        params,
        &state_transition,
        new_block.header.slot,
    );

    try recent_history.transition(
        params,
        &state_transition,
        new_block,
    );

    try eta.transition(
        params,
        &state_transition,
        try new_block.header.getEntropy(),
    );

    var markers = try safrole.transition(
        params,
        &state_transition,
        new_block.extrinsic.tickets,
    );
    defer markers.deinit(allocator);

    span.debug("State transition completed successfully", .{});

    return try state_transition.cloneBaseAndMerge();
}

fn extractBlockEntropy(header: *const Header) !types.Entropy {
    return try @import("crypto/bandersnatch.zig")
        .Bandersnatch.Signature
        .fromBytes(header.entropy_source)
        .outputHash();
}
