const std = @import("std");

const types = @import("../../types.zig");

const Params = @import("../../jam_params.zig").Params;

/// DeferredTransfer represents a transfer request generated during accumulation
/// Based on the graypaper equation 12.14: T ≡ {s ∈ N_S, d ∈ N_S, a ∈ N_B, m ∈ Y_W_T, g ∈ N_G}
pub const DeferredTransfer = struct {
    /// The service index of the sending account
    sender: types.ServiceId,

    /// The service index of the receiving account
    destination: types.ServiceId,

    /// The balance amount to be transferred
    amount: types.Balance,

    /// Memo/message attached to the transfer (fixed length W_T = 128 octets)
    memo: [128]u8,

    /// Gas limit for executing the transfer's on_transfer handler
    gas_limit: types.Gas,
};
