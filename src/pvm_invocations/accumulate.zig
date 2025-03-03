const std = @import("std");

const types = @import("../types.zig");
const state = @import("../state.zig");

const pvm_invocation = @import("../pvm/invocation.zig");

const Params = @import("../jam_params.zig").Params;

// 12.13 State components needed for Accumulation
fn AccumulationContext(params: Params) type {
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

/// 12.18 AccumulationOperand represents a wrangled tuple of operands used by the PVM Accumulation function.
/// It contains the rephrased work items for a specific service within work reports.
const AccumulationOperand = struct {
    /// The output or error of the work item execution.
    /// Can be either an octet sequence (Y) or an error (J).
    output: union(enum) {
        /// Successful execution output as an octet sequence
        success: []const u8,
        /// Error code if execution failed
        err: WorkExecutionError,
    },

    /// The hash of the payload within the work item
    /// that was executed in the refine stage
    payload_hash: [32]u8,

    /// The hash of the work package
    work_package_hash: [32]u8,

    /// The authorization output blob for the work item
    authorization_output: []const u8,
};

/// Represents possible error types from work execution
const WorkExecutionError = enum {
    OutOfGas, // ∞
    ProgramTermination, // ☇
    InvalidExportCount, // ⊚
    ServiceCodeUnavailable, // BAD
    ServiceCodeTooLarge, // BIG
};

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

/// Return type for the accumulation invoke function,
pub const AccumulationResult = struct {
    /// Updated state context after accumulation
    state_context: AccumulationContext,

    /// Sequence of deferred transfers resulting from accumulation
    transfers: []DeferredTransfer,

    /// Optional accumulation output hash (null if no output was produced)
    accumulation_output: ?types.AccumulateRoot,

    /// Amount of gas consumed during accumulation
    gas_used: types.Gas,
};

/// Accumulate PVM invoke functions
pub fn invoke(
    context: AccumulationContext,
    tau: types.TimeSlot,
    service_id: types.ServiceId,
    gas_limit: types.Gas,
    accumulation_operands: []AccumulationOperand,
) AccumulationResult {
    // Implementation will go here

    return .{
        .state_context = context,
        .transfers = &[_]DeferredTransfer{},
        .accumulation_output = null,
        .gas_used = 0,
    };
}
