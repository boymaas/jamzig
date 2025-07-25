const std = @import("std");

const types = @import("../types.zig");
const state = @import("../state.zig");
const assurances = @import("../assurances.zig");

const Params = @import("../jam_params.zig").Params;
const StateTransition = @import("../state_delta.zig").StateTransition;

const tracing = @import("../tracing.zig");
const trace = tracing.scoped(.stf);

pub const Error = error{};

pub fn transition(
    comptime params: Params,
    allocator: std.mem.Allocator,
    stx: *StateTransition(params),
    extrinsic: types.AssurancesExtrinsic,
    parent_hash: types.HeaderHash,
) !assurances.AvailableAssignments {
    const span = trace.span(.assurances);
    defer span.deinit();

    const kappa = try stx.ensure(.kappa);

    const validated = try assurances.ValidatedAssuranceExtrinsic.validate(
        params,
        extrinsic,
        parent_hash,
        kappa.*,
    );

    // Register updated validator stats
    const pi: *state.Pi = try stx.ensure(.pi_prime);
    for (validated.items()) |assurance| {
        var stats = try pi.getValidatorStats(assurance.validator_index);
        stats.updateAvailabilityAssurances(1);
    }

    const pending_reports: *state.Rho(params.core_count) = try stx.ensure(.rho_prime);

    return try assurances.processAssuranceExtrinsic(
        params,
        allocator,
        pending_reports,
        validated,
        stx.time.current_slot,
    );
}
