const std = @import("std");
const types = @import("../../types.zig");
const state = @import("../../state.zig");
const tracing = @import("tracing");
const disputes = @import("../../disputes.zig");

const trace = tracing.scoped(.reports);
const StateTransition = @import("../../state_delta.zig").StateTransition;

pub const Error = error{
    BannedValidators,
};

pub fn checkBannedValidators(
    comptime params: @import("../../jam_params.zig").Params,
    guarantee: types.ReportGuarantee,
    stx: *StateTransition(params),
    assignments: *const @import("../../guarantor_assignments.zig").GuarantorAssignmentResult,
) !void {
    const span = trace.span(@src(), .check_banned_validators);
    defer span.deinit();

    // Get the Psi (disputes state) from the state transition
    const psi: *const state.Psi = try stx.get(.psi);

    span.debug("Checking {d} guarantors against {d} banned validators", .{
        guarantee.signatures.len,
        psi.punish_set.count(),
    });

    for (guarantee.signatures) |sig| {
        const validator_index = sig.validator_index;

        if (validator_index >= params.validators_count) {
            continue;
        }

        const validator = assignments.validators.validators[validator_index];
        const ed25519_key = validator.ed25519;

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

