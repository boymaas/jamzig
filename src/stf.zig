const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("types.zig");
const JamState = @import("state.zig").JamState;
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
pub const reports = @import("stf/reports.zig");
pub const validator_stats = @import("stf/validator_stats.zig");
pub const assurances = @import("stf/assurances.zig");
pub const accumulate = @import("stf/accumulate.zig");
pub const preimages = @import("stf/preimages.zig");

const tracing = @import("tracing.zig");
const trace = tracing.scoped(.stf);

pub fn stateTransition(
    comptime params: Params,
    allocator: Allocator,
    current_state: *const JamState(params),
    new_block: *const Block,
) !*StateTransition(params) {
    const span = trace.span(.state_transition);
    defer span.deinit();

    // Ensure we have a fully initialized state at the start
    if (@import("builtin").mode == .Debug) {
        if (!try current_state.checkIfFullyInitialized()) {
            return error.StateNotFullyInitialized;
        }
    }

    const transition_time = params.Time().init(
        current_state.tau.?,
        new_block.header.slot,
    );
    var state_transition = try StateTransition(params).initHeap(allocator, current_state, transition_time);
    errdefer state_transition.deinitHeap();

    try time.transition(
        params,
        state_transition,
        new_block.header.slot,
    );

    try eta.transition(
        params,
        state_transition,
        try new_block.header.getEntropy(),
    );

    try validator_stats.transition(
        params,
        state_transition,
        new_block,
    );

    // => rho_dagger
    _ = try disputes.transition(
        params,
        allocator,
        state_transition,
        new_block.extrinsic.disputes,
    );

    // => rho_double_dagger
    var available_assignments = try assurances.transition(
        params,
        allocator,
        state_transition,
        new_block.extrinsic.assurances,
        new_block.header.parent,
    );
    defer available_assignments.deinit(allocator);

    // => rho_prime
    try reports.transition(
        params,
        allocator,
        state_transition,
        new_block,
    );

    // accumulate
    const work_reports = try available_assignments.getWorkReports(allocator);
    defer {
        for (work_reports) |*report| {
            report.deinit(allocator);
        }
        allocator.free(work_reports);
    }
    const accumulate_root = try accumulate.transition(
        params,
        allocator,
        state_transition,
        work_reports,
    );

    try preimages.transition(
        params,
        state_transition,
        new_block.extrinsic.preimages,
        new_block.header.author_index,
    );

    try recent_history.transition(
        params,
        state_transition,
        new_block,
        accumulate_root,
    );

    // Process authorizations using guarantees extrinsic data
    try authorization.transition(
        params,
        state_transition,
        new_block.extrinsic.guarantees,
    );

    var markers = try safrole.transition(
        params,
        state_transition,
        new_block.extrinsic.tickets,
    );
    defer markers.deinit(allocator);

    return state_transition;
}

fn extractBlockEntropy(header: *const Header) !types.Entropy {
    return try @import("crypto/bandersnatch.zig")
        .Bandersnatch.Signature
        .fromBytes(header.entropy_source)
        .outputHash();
}
