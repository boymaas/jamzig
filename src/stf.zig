const std = @import("std");

// Internal imports (sorted by dependency depth)
const jam_params = @import("jam_params.zig");
const types = @import("types.zig");
const state = @import("state.zig");
const state_delta = @import("state_delta.zig");
const tracing = @import("tracing.zig");

// Type aliases
const Allocator = std.mem.Allocator;
const Params = jam_params.Params;
const JamState = state.JamState;
const Block = types.Block;
const Header = types.Header;
const StateTransition = state_delta.StateTransition;

// Tracing setup
const trace = tracing.scoped(.stf);

pub fn stateTransition(
    comptime IOExecutor: type,
    io_executor: *IOExecutor,
    comptime params: Params,
    allocator: Allocator,
    current_state: *const JamState(params),
    block: *const Block,
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
        block.header.slot,
    );
    var stx = try StateTransition(params).create(allocator, current_state, transition_time);
    errdefer stx.destroy(allocator);

    try time.transition(
        params,
        stx,
        block.header.slot,
    );

    try eta.transition(
        params,
        stx,
        try block.header.getEntropy(),
    );

    try validator_stats.clearPerBlockStats(
        params,
        stx,
    );

    try validator_stats.transitionEpoch(
        params,
        stx,
    );

    // => rho_dagger
    _ = try disputes.transition(
        params,
        allocator,
        stx,
        block.extrinsic.disputes,
    );

    // => rho_double_dagger
    var assurance_result = try assurances.transition(
        params,
        allocator,
        stx,
        block.extrinsic.assurances,
        block.header.parent,
    );
    defer assurance_result.deinit(allocator);

    // Update parent block's state root before processing reports
    // This ensures guarantees can validate against the correct state root
    try recent_history.updateParentBlockStateRoot(
        params,
        stx,
        block.header.parent_state_root,
    );

    // => rho_prime
    var reports_result = try reports.transition(
        params,
        allocator,
        stx,
        block,
    );
    defer reports_result.deinit(allocator);

    // accumulate
    const ready_reports = try assurance_result.available_assignments.getWorkReports(allocator);
    defer @import("meta.zig").deinit.deinitEntriesAndFreeSlice(allocator, ready_reports);

    var accumulate_result = try accumulate.transition(
        IOExecutor,
        io_executor,
        params,
        allocator,
        stx,
        ready_reports,
    );
    defer accumulate_result.deinit(allocator);

    try preimages.transition(
        params,
        stx,
        block.extrinsic.preimages,
        block.header.author_index,
    );

    try recent_history.transition(
        params,
        stx,
        block,
        accumulate_result.accumulate_root,
    );

    // Process authorizations using guarantees extrinsic data
    try authorization.transition(
        params,
        stx,
        block.extrinsic.guarantees,
    );

    var markers = try safrole.transition(
        params,
        stx,
        block.extrinsic.tickets,
    );
    defer markers.deinit(allocator);

    // Create comprehensive ValidatorStatsInput with all collected data
    // Convert reporters to validator indices for statistics

    try validator_stats.transition(
        params,
        stx,
        block,
        &reports_result,
        &assurance_result,
        &accumulate_result,
        ready_reports,
    );

    return stx;
}

// Public exports
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
