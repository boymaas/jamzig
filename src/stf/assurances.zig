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
) !void {
    const span = trace.span(.assurances);
    defer span.deinit();

    const kappa = try stx.ensure(.kappa);

    const validated = try assurances.ValidatedAssuranceExtrinsic.validate(
        params,
        extrinsic,
        parent_hash,
        kappa.*,
    );

    const pending_reports = try stx.ensureT(state.Rho(params.core_count), .rho_prime);

    var result = try assurances.processAssuranceExtrinsic(
        params,
        allocator,
        validated,
        stx.time.current_slot,
        pending_reports,
    );
    defer result.deinit(allocator);
}
