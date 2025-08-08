const std = @import("std");
const types = @import("../../types.zig");
const state = @import("../../state.zig");
const tracing = @import("../../tracing.zig");
const crypto = std.crypto;

const trace = tracing.scoped(.reports);
const StateTransition = @import("../../state_delta.zig").StateTransition;

/// Error types for signature validation
pub const Error = error{
    BadValidatorIndex,
    BadSignature,
    InvalidValidatorPublicKey,
};

/// Validate all validator indices are in range
pub fn validateValidatorIndices(
    comptime params: @import("../../jam_params.zig").Params,
    guarantee: types.ReportGuarantee,
) !void {
    for (guarantee.signatures) |sig| {
        if (sig.validator_index >= params.validators_count) {
            const span = trace.span(.validate_validator_index);
            defer span.deinit();
            span.err("Invalid validator index {d} >= {d}", .{
                sig.validator_index,
                params.validators_count,
            });
            return Error.BadValidatorIndex;
        }
    }
}

/// Validate signatures using pre-built assignments and validators
pub fn validateSignaturesWithAssignments(
    comptime params: @import("../../jam_params.zig").Params,
    allocator: std.mem.Allocator,
    guarantee: types.ReportGuarantee,
    assignments: *const @import("../../guarantor_assignments.zig").GuarantorAssignmentResult,
) !void {
    const span = trace.span(.validate_signatures_prebuilt);
    defer span.deinit();

    span.debug("Validating {d} guarantor signatures using pre-built assignments", .{guarantee.signatures.len});

    // Use the validators from the assignment result
    const validators = assignments.validators;

    for (guarantee.signatures) |sig| {
        const sig_detail_span = span.child(.validate_signature);
        defer sig_detail_span.deinit();

        sig_detail_span.debug("Validating signature for validator index {d}", .{sig.validator_index});
        sig_detail_span.trace("Signature: {s}", .{std.fmt.fmtSliceHexLower(&sig.signature)});

        // Get validator from the pre-determined set
        const validator = validators.validators[sig.validator_index];
        const public_key = validator.ed25519;
        sig_detail_span.trace("Validator public key: {s}", .{std.fmt.fmtSliceHexLower(&public_key)});

        // Create message to verify using Blake2b
        // The message is: "jam_guarantee" ++ H(E(anchor, bitfield))
        const prefix: []const u8 = "jam_guarantee";
        const w = try @import("../../codec.zig").serializeAlloc(types.WorkReport, params, allocator, guarantee.report);
        defer allocator.free(w);
        var hasher = std.crypto.hash.blake2.Blake2b256.init(.{});
        hasher.update(w);
        var hash: [32]u8 = undefined;
        hasher.final(&hash);

        const validator_pub_key = crypto.sign.Ed25519.PublicKey.fromBytes(public_key) catch {
            return Error.InvalidValidatorPublicKey;
        };

        const signature = crypto.sign.Ed25519.Signature.fromBytes(sig.signature);

        signature.verify(prefix ++ &hash, validator_pub_key) catch {
            return Error.BadSignature;
        };
    }
}

