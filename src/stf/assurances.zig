const std = @import("std");

const types = @import("../types.zig");
const state = @import("../state.zig");
const assurances = @import("../assurances.zig");

const Params = @import("../jam_params.zig").Params;
const StateTransition = @import("../state_delta.zig").StateTransition;

const tracing = @import("../tracing.zig");
const trace = tracing.scoped(.stf);

pub const Error = error{};

pub const AssuranceResult = struct {
    available_assignments: assurances.AvailableAssignments,
    validator_indices: []const types.ValidatorIndex,
    
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.available_assignments.deinit(allocator);
        allocator.free(self.validator_indices);
        self.* = undefined;
    }
};

pub fn transition(
    comptime params: Params,
    allocator: std.mem.Allocator,
    stx: *StateTransition(params),
    extrinsic: types.AssurancesExtrinsic,
    parent_hash: types.HeaderHash,
) !AssuranceResult {
    const span = trace.span(.assurances);
    defer span.deinit();

    const kappa = try stx.ensure(.kappa);
    
    // Get pending reports AFTER dispute resolution (conceptually rho_dagger)
    // This is important: we need the state after disputes have been processed
    // We use rho_prime here since disputes.transition() has already modified it
    const pending_reports_for_validation: *state.Rho(params.core_count) = try stx.ensure(.rho_prime);

    const validated = try assurances.ValidatedAssuranceExtrinsic.validate(
        params,
        extrinsic,
        parent_hash,
        kappa.*,
        pending_reports_for_validation,
    );

    // Collect validator indices for statistics
    var validator_indices = try allocator.alloc(types.ValidatorIndex, validated.items().len);
    for (validated.items(), 0..) |assurance, i| {
        validator_indices[i] = assurance.validator_index;
    }

    const pending_reports: *state.Rho(params.core_count) = try stx.ensure(.rho_prime);

    const available_assignments = try assurances.processAssuranceExtrinsic(
        params,
        allocator,
        pending_reports,
        validated,
        stx.time.current_slot,
    );

    return AssuranceResult{
        .available_assignments = available_assignments,
        .validator_indices = validator_indices,
    };
}
