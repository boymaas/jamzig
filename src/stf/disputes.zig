const std = @import("std");

const state = @import("../state.zig");
const types = @import("../types.zig");
const utils = @import("../utils.zig");
const disputes = @import("../disputes.zig");

const Params = @import("../jam_params.zig").Params;
const StateTransition = @import("../state_delta.zig").StateTransition;

pub const Error = error{};

pub fn transition(
    comptime validators_count: u32,
    comptime core_count: u16,
    allocator: std.mem.Allocator,
    current_psi: *const state.Psi,
    current_kappa: state.Kappa,
    current_lambda: state.Lambda,
    current_rho: *state.Rho(core_count),
    current_epoch: types.Epoch,
    xtdisputes: types.DisputesExtrinsic,
) !state.Psi {
    // Map current_kappa to extract Edwards public keys
    const current_kappa_keys = try utils.mapAlloc(
        types.ValidatorData,
        types.Ed25519Public,
        allocator,
        current_kappa.items(),
        validator_key,
    );
    defer allocator.free(current_kappa_keys);

    const current_lambda_keys = try utils.mapAlloc(
        types.ValidatorData,
        types.Ed25519Public,
        allocator,
        current_lambda.items(),
        validator_key,
    );
    defer allocator.free(current_lambda_keys);

    // Verify correctness of the disputes extrinsic
    try disputes.verifyDisputesExtrinsicPre(
        xtdisputes,
        current_psi,
        current_kappa_keys,
        current_lambda_keys,
        validators_count,
        current_epoch,
    );

    var posterior_state = try disputes.processDisputesExtrinsic(
        core_count,
        current_psi,
        current_rho,
        xtdisputes,
        validators_count,
    );
    errdefer posterior_state.deinit();

    try disputes.verifyDisputesExtrinsicPost(xtdisputes, &posterior_state);

    return posterior_state;
}

fn validator_key(validator: types.ValidatorData) types.Ed25519Public {
    return validator.ed25519;
}
