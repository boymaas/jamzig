const std = @import("std");

// Internal imports (sorted by dependency depth)
const jam_params = @import("jam_params.zig");
const types = @import("types.zig");
const state = @import("state.zig");
const state_delta = @import("state_delta.zig");
const tracing = @import("tracing.zig");
const tracy = @import("tracy");

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
    
    const tracy_zone = tracy.ZoneN(@src(), "stf_state_transition");
    defer tracy_zone.End();

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

    {
        const time_zone = tracy.ZoneN(@src(), "stf_time_transition");
        defer time_zone.End();
        try time.transition(
            params,
            stx,
            block.header.slot,
        );
    }

    {
        const eta_zone = tracy.ZoneN(@src(), "stf_eta_transition");
        defer eta_zone.End();
        try eta.transition(
            params,
            stx,
            try block.header.getEntropy(),
        );
    }

    {
        const validator_stats_zone = tracy.ZoneN(@src(), "stf_validator_stats_clear");
        defer validator_stats_zone.End();
        try validator_stats.clearPerBlockStats(
            params,
            stx,
        );

        try validator_stats.transitionEpoch(
            params,
            stx,
        );
    }

    // => rho_dagger
    {
        const disputes_zone = tracy.ZoneN(@src(), "stf_disputes_transition");
        defer disputes_zone.End();
        _ = try disputes.transition(
            params,
            allocator,
            stx,
            block.extrinsic.disputes,
        );
    }

    // => rho_double_dagger
    var assurance_result = blk: {
        const assurances_zone = tracy.ZoneN(@src(), "stf_assurances_transition");
        defer assurances_zone.End();
        break :blk try assurances.transition(
            params,
            allocator,
            stx,
            block.extrinsic.assurances,
            block.header.parent,
        );
    };
    defer assurance_result.deinit(allocator);

    // Update parent block's state root before processing reports
    // This ensures guarantees can validate against the correct state root
    {
        const recent_history_zone = tracy.ZoneN(@src(), "stf_recent_history_update");
        defer recent_history_zone.End();
        try recent_history.updateParentBlockStateRoot(
            params,
            stx,
            block.header.parent_state_root,
        );
    }

    // => rho_prime
    var reports_result = blk: {
        const reports_zone = tracy.ZoneN(@src(), "stf_reports_transition");
        defer reports_zone.End();
        break :blk try reports.transition(
            params,
            allocator,
            stx,
            block,
        );
    };
    defer reports_result.deinit(allocator);

    // accumulate
    const ready_reports = try assurance_result.available_assignments.getWorkReports(allocator);
    defer @import("meta.zig").deinit.deinitEntriesAndFreeSlice(allocator, ready_reports);

    var accumulate_result = blk: {
        const accumulate_zone = tracy.ZoneN(@src(), "stf_accumulate_transition");
        defer accumulate_zone.End();
        break :blk try accumulate.transition(
            IOExecutor,
            io_executor,
            params,
            allocator,
            stx,
            ready_reports,
        );
    };
    defer accumulate_result.deinit(allocator);

    {
        const preimages_zone = tracy.ZoneN(@src(), "stf_preimages_transition");
        defer preimages_zone.End();
        try preimages.transition(
            params,
            stx,
            block.extrinsic.preimages,
            block.header.author_index,
        );
    }

    {
        const recent_history_zone = tracy.ZoneN(@src(), "stf_recent_history_transition");
        defer recent_history_zone.End();
        try recent_history.transition(
            params,
            stx,
            block,
            accumulate_result.accumulate_root,
        );
    }

    // Process authorizations using guarantees extrinsic data
    {
        const authorization_zone = tracy.ZoneN(@src(), "stf_authorization_transition");
        defer authorization_zone.End();
        try authorization.transition(
            params,
            stx,
            block.extrinsic.guarantees,
        );
    }

    var markers = blk: {
        const safrole_zone = tracy.ZoneN(@src(), "stf_safrole_transition");
        defer safrole_zone.End();
        break :blk try safrole.transition(
            params,
            stx,
            block.extrinsic.tickets,
        );
    };
    defer markers.deinit(allocator);

    // Create comprehensive ValidatorStatsInput with all collected data
    // Convert reporters to validator indices for statistics
    {
        const validator_stats_zone = tracy.ZoneN(@src(), "stf_validator_stats_final");
        defer validator_stats_zone.End();
        try validator_stats.transition(
            params,
            stx,
            block,
            &reports_result,
            &assurance_result,
            &accumulate_result,
            ready_reports,
        );
    }

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
