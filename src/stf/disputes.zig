const std = @import("std");

const state = @import("../state.zig");
const types = @import("../types.zig");
const disputes = @import("../disputes.zig");

const Params = @import("../jam_params.zig").Params;
const StateTransition = @import("../state_delta.zig").StateTransition;

pub const Error = error{};

pub fn transition(
    comptime params: Params,
    allocator: std.mem.Allocator,
    stx: *StateTransition(params),
    xtdisputes: types.DisputesExtrinsic,
) !void {
    const current_kappa: *const types.ValidatorSet = try stx.ensure(.kappa);
    const current_lambda: *const types.ValidatorSet = try stx.ensure(.lambda);
    const current_psi: *const state.Psi = try stx.ensure(.psi);

    const rho_prime: *state.Rho(params.core_count) = try stx.ensure(.rho_prime);

    // Map current_kappa to extract Edwards public keys
    const current_kappa_keys = try current_kappa.getEd25519PublicKeys(allocator);
    defer allocator.free(current_kappa_keys);

    const current_lambda_keys = try current_lambda.getEd25519PublicKeys(allocator);
    defer allocator.free(current_lambda_keys);

    // Verify correctness of the disputes extrinsic
    try disputes.verifyDisputesExtrinsicPre(
        xtdisputes,
        current_psi,
        current_kappa_keys,
        current_lambda_keys,
        params.validators_count,
        stx.time.current_epoch,
    );

    try disputes.processDisputesExtrinsic(
        params.core_count,
        current_psi,
        rho_prime,
        xtdisputes,
        params.validators_count,
    );

    try disputes.verifyDisputesExtrinsicPost(xtdisputes, current_psi);
}
