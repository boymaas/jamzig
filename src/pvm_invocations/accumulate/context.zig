const std = @import("std");

const types = @import("../../types.zig");
const state = @import("../../state.zig");

const Params = @import("../../jam_params.zig").Params;

// 12.13 State components needed for Accumulation
pub fn AccumulationContext(params: Params) type {
    return struct {
        service_accounts: *state.Delta, // d ∈ D⟨N_S → A⟩
        validator_keys: *state.Iota, // i ∈ ⟦K⟧_V
        authorizer_queue: *state.Phi(params.core_count, params.max_authorizations_queue_items), // q ∈ _C⟦H⟧^Q_H_C
        privileges: *state.Chi, // x ∈ (N_S, N_S, N_S, D⟨N_S → N_G⟩)

        pub fn buildFromState(jam_state: state.JamState(params)) @This() {
            return @This(){
                .service_accounts = &jam_state.delta.?,
                .validator_keys = &jam_state.iota.?,
                .authorizer_queue = &jam_state.phi.?,
                .privileges = &jam_state.chi.?,
            };
        }
    };
}
