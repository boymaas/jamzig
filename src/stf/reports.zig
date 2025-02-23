const std = @import("std");
const state = @import("../state.zig");
const types = @import("../types.zig");

const Params = @import("../jam_params.zig").Params;
const StateTransition = @import("../state_delta.zig").StateTransition;

const reports = @import("../reports.zig");

pub const Error = error{};

pub fn accumulateWorkReports(
    comptime params: Params,
    stx: *StateTransition(params),
) !void {
    _ = stx;
    // Process work reports and transition δ, χ, ι, and φ
    @panic("Not implemented");
}

pub fn transition(
    comptime params: Params,
    allocator: std.mem.Allocator,
    stx: *StateTransition(params),
    guarantees: types.GuaranteesExtrinsic,
) !void {
    // Ensure we have our primes
    const rho: *state.Rho(params.core_count) = try stx.ensure(.rho_prime);
    const pi: *state.Pi = try stx.ensure(.pi_prime);

    // Build our state view for validation
    const state_view = stx.buildBaseView();

    const validated = try reports.ValidatedGuaranteeExtrinsic.validate(
        params,
        allocator,
        guarantees,
        stx.time.current_slot,
        &state_view,
    );

    // Process
    var result = try reports.processGuaranteeExtrinsic(
        params,
        allocator,
        validated,
        stx.time.current_slot,
        &state_view,
        rho,
        pi,
    );
    defer result.deinit(allocator);
}
