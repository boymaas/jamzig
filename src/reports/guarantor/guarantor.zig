const std = @import("std");
const types = @import("../../types.zig");
const state = @import("../../state.zig");
const tracing = @import("../../tracing.zig");
const guarantor_assignments = @import("../../guarantor_assignments.zig");

const trace = tracing.scoped(.reports);
const StateTransition = @import("../../state_delta.zig").StateTransition;

/// Error types for guarantor validation
pub const Error = error{
    NotSortedOrUniqueGuarantors,
    InvalidGuarantorAssignment,
    InvalidRotationPeriod,
    InvalidSlotRange,
    InsufficientGuarantees,
    TooManyGuarantees,
};

/// Validates that guarantors are sorted and unique
pub fn validateSortedAndUnique(guarantee: types.ReportGuarantee) !void {
    const span = trace.span(.signatures_sorted_unique);
    defer span.deinit();

    span.debug("Validating {d} guarantor signatures are sorted and unique", .{guarantee.signatures.len});

    var prev_index: ?types.ValidatorIndex = null;
    for (guarantee.signatures, 0..) |sig, i| {
        span.trace("Checking validator index {d} at position {d}", .{ sig.validator_index, i });

        if (prev_index != null and sig.validator_index <= prev_index.?) {
            span.err("Guarantor validation failed: index {d} <= previous {d}", .{
                sig.validator_index,
                prev_index.?,
            });
            return Error.NotSortedOrUniqueGuarantors;
        }
        prev_index = sig.validator_index;
    }
    span.debug("All guarantor indices validated as sorted and unique", .{});
}

/// Validates signature count is within acceptable range
pub fn validateSignatureCount(guarantee: types.ReportGuarantee) !void {
    const span = trace.span(.validate_signature_count);
    defer span.deinit();

    span.debug("Checking signature count: {d} must be either 2 or 3", .{guarantee.signatures.len});

    if (guarantee.signatures.len < 2) {
        span.err("Insufficient guarantees: got {d}, minimum required is 2", .{
            guarantee.signatures.len,
        });
        return Error.InsufficientGuarantees;
    }
    if (guarantee.signatures.len > 3) {
        span.err("Too many guarantees: got {d}, maximum allowed is 3", .{
            guarantee.signatures.len,
        });
        return Error.TooManyGuarantees;
    }
}

/// Validates guarantor assignments using pre-built assignments
pub fn validateGuarantorAssignmentsWithPrebuilt(
    comptime params: @import("../../jam_params.zig").Params,
    guarantee: types.ReportGuarantee,
    assignments: *const @import("../../guarantor_assignments.zig").GuarantorAssignmentResult,
) !void {
    _ = params; // Currently unused but kept for consistency
    const span = trace.span(.validate_assignments_prebuilt);
    defer span.deinit();
    span.debug("Validating guarantor assignments for {d} signatures using pre-built assignments", .{guarantee.signatures.len});

    const expected_core = guarantee.report.core_index;

    for (guarantee.signatures) |sig| {
        const assigned_core = assignments.assignments[sig.validator_index];

        if (assigned_core != expected_core) {
            span.err("Invalid guarantor assignment for validator {d}: assigned to core {d}, expected core {d}", .{
                sig.validator_index,
                assigned_core,
                expected_core,
            });
            return Error.InvalidGuarantorAssignment;
        }

        span.trace("Validator {d} correctly assigned to core {d}", .{
            sig.validator_index,
            expected_core,
        });
    }

    span.debug("Assignment validation successful", .{});
}

