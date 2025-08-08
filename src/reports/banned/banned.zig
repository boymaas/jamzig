const std = @import("std");
const types = @import("../../types.zig");
const state = @import("../../state.zig");
const tracing = @import("../../tracing.zig");
const disputes = @import("../../disputes.zig");

const trace = tracing.scoped(.reports);
const StateTransition = @import("../../state_delta.zig").StateTransition;

/// Error types for banned validator checks
pub const Error = error{
    BannedValidators,
};

/// Check if any guarantor is in the punish_set (banned validators)
pub fn checkBannedValidators(
    comptime params: @import("../../jam_params.zig").Params,
    guarantee: types.ReportGuarantee,
    stx: *StateTransition(params),
    assignments: *const @import("../../guarantor_assignments.zig").GuarantorAssignmentResult,
) !void {
    const span = trace.span(.check_banned_validators);
    defer span.deinit();

    // Get the Psi (disputes state) from the state transition
    const psi: *const state.Psi = try stx.get(.psi);

    span.debug("Checking {d} guarantors against {d} banned validators", .{
        guarantee.signatures.len,
        psi.punish_set.count(),
    });

    // Check each guarantor
    for (guarantee.signatures) |sig| {
        const validator_index = sig.validator_index;

        // Get the validator's Ed25519 public key
        if (validator_index >= params.validators_count) {
            continue; // This should have been caught by earlier validation
        }

        const validator = assignments.validators.validators[validator_index];
        const ed25519_key = validator.ed25519;

        // Check if this validator is in the punish_set
        if (psi.isOffender(ed25519_key)) {
            span.err("Validator {d} with key {s} is banned", .{
                validator_index,
                std.fmt.fmtSliceHexLower(&ed25519_key),
            });
            return Error.BannedValidators;
        }

        span.trace("Validator {d} is not banned", .{validator_index});
    }

    span.debug("No banned validators found among guarantors", .{});
}

