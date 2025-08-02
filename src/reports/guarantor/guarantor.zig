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

/// Validates if a validator is assigned to a core for a specific timeslot
pub fn validateGuarantorAssignment(
    comptime params: @import("../../jam_params.zig").Params,
    allocator: std.mem.Allocator,
    stx: *StateTransition(params),
    validator_index: types.ValidatorIndex,
    core_index: types.CoreIndex,
    guarantee_slot: types.TimeSlot,
) !bool {
    const span = trace.span(.validate_assignment);
    defer span.deinit();

    span.debug("Validating assignment @ current_slot {d}", .{stx.time.current_slot});
    span.debug("Validating assignment for validator {d} on core {d} at guarantee.slot {d}", .{ validator_index, core_index, guarantee_slot });

    // Calculate current and report rotations
    const current_rotation = @divFloor(stx.time.current_slot, params.validator_rotation_period);
    const report_rotation = @divFloor(guarantee_slot, params.validator_rotation_period);

    span.debug("Current rotation: {d}, Report rotation: {d}", .{ current_rotation, report_rotation });

    // NOTE: slots are already within range, checked in the validation stage

    // Determine which assignments to use based on rotation period
    const is_current_rotation = (current_rotation == report_rotation);
    span.debug("Building assignments using {s} rotation entropy", .{if (is_current_rotation) "current" else "previous"});

    var result = if (is_current_rotation)
        // current rotation
        try guarantor_assignments.buildForTimeSlot(
            params,
            allocator,
            (try stx.ensure(.eta_prime))[2], // new eta
            stx.time.current_slot,
        )
    else
    // previous rotation
    if (@divFloor(stx.time.current_slot -| params.validator_rotation_period, params.epoch_length) ==
        @divFloor(stx.time.current_slot, params.epoch_length))
        try guarantor_assignments.buildForTimeSlot(
            params,
            allocator,
            (try stx.ensure(.eta_prime))[2], // prev eta
            stx.time.current_slot - params.validator_rotation_period,
        )
    else
        try guarantor_assignments.buildForTimeSlot(
            params,
            allocator,
            (try stx.ensure(.eta_prime))[3], // prev eta
            stx.time.current_slot - params.validator_rotation_period,
        );

    defer result.deinit(allocator);

    span.debug("Built guarantor assignments successfully", .{});

    // Check if validator is assigned to the core
    const is_assigned = result.assignments[validator_index] == core_index;
    // TODO: check if validator keys match

    if (is_assigned) {
        span.debug("Validator {d} correctly assigned to core {d}", .{ validator_index, core_index });
    } else {
        span.err("Validator {d} not assigned to core {d} (assigned to core {d})", .{ validator_index, core_index, result.assignments[validator_index] });
    }

    return is_assigned;
}

/// Validates guarantor assignments for all signatures in a guarantee
pub fn validateGuarantorAssignments(
    comptime params: @import("../../jam_params.zig").Params,
    allocator: std.mem.Allocator,
    stx: *StateTransition(params),
    guarantee: types.ReportGuarantee,
) !void {
    const span = trace.span(.validate_assignments);
    defer span.deinit();
    span.debug("Validating guarantor assignments for {d} signatures", .{guarantee.signatures.len});

    for (guarantee.signatures) |sig| {
        const is_valid = try validateGuarantorAssignment(
            params,
            allocator,
            stx,
            sig.validator_index,
            guarantee.report.core_index,
            guarantee.slot,
        );

        if (!is_valid) {
            span.err("Invalid guarantor assignment for validator {d} on core {d}", .{
                sig.validator_index,
                guarantee.report.core_index,
            });
            return Error.InvalidGuarantorAssignment;
        }
    }

    span.debug("Assignment validation successful", .{});
}