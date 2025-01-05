const std = @import("std");
const types = @import("types.zig");
const tracing = @import("tracing.zig");
const guarantor_assignments = @import("guarantor_assignments.zig");

const trace = tracing.scoped(.guarantor_validation);

/// Error types specific to guarantor validation
pub const Error = error{
    InvalidGuarantorAssignment,
    InvalidRotationPeriod,
    InvalidSlotRange,
};

/// Validates if a validator is assigned to a core for a specific timeslot
/// This implements the validation part of equation 11.27
pub fn validateGuarantorAssignment(
    comptime params: @import("jam_params.zig").Params,
    allocator: std.mem.Allocator,
    validator_index: types.ValidatorIndex,
    core_index: types.CoreIndex,
    guarantee_slot: types.TimeSlot,
    current_slot: types.TimeSlot,
    current_entropy: [32]u8,
    previous_entropy: [32]u8,
) !bool {
    const span = trace.span(.validate_assignment);
    defer span.deinit();

    span.debug("Validating assignemnt @ current_slot {d}", .{current_slot});
    span.debug("Validating assignment for validator {d} on core {d} at guarantee.slot {d}", .{ validator_index, core_index, guarantee_slot });

    // Calculate current and report rotations
    const current_rotation = @divFloor(current_slot, params.validator_rotation_period);
    const report_rotation = @divFloor(guarantee_slot, params.validator_rotation_period);

    span.debug("Current rotation: {d}, Report rotation: {d}", .{ current_rotation, report_rotation });

    // Check if slots are within valid range
    // TODO: -1 could lead to overflow
    const min_slot = (current_rotation - 1) * params.validator_rotation_period;
    if (guarantee_slot < min_slot or guarantee_slot > current_slot) {
        span.err("Invalid slot range: guarantee_slot {d} not within [{d}, {d}]", .{ guarantee_slot, min_slot, current_slot });
        return Error.InvalidSlotRange;
    }

    span.debug("Slot range validation passed: {d} within [{d}, {d}]", .{ guarantee_slot, min_slot, current_slot });

    // Determine which assignments to use based on rotation period
    const is_current_rotation = (current_rotation == report_rotation);
    span.debug("Building assignments using {s} rotation entropy", .{if (is_current_rotation) "current" else "previous"});

    var result = if (is_current_rotation)
        try guarantor_assignments.buildForTimeSlot(params, allocator, current_entropy, current_slot)
    else
        try guarantor_assignments.buildForTimeSlot(params, allocator, previous_entropy, guarantee_slot);
    defer result.deinit(allocator);

    span.debug("Built guarantor assignments successfully", .{});

    // Check if validator is assigned to the core
    const is_assigned = result.assignments[validator_index] == core_index;

    if (is_assigned) {
        span.debug("Validator {d} correctly assigned to core {d}", .{ validator_index, core_index });
    } else {
        span.err("Validator {d} not assigned to core {d} (assigned to core {d})", .{ validator_index, core_index, result.assignments[validator_index] });
    }

    return is_assigned;
}

/// Validates all guarantor signatures for a work report
pub fn validateGuarantors(
    comptime params: @import("jam_params.zig").Params,
    allocator: std.mem.Allocator,
    guarantee: types.ReportGuarantee,
    current_slot: types.TimeSlot,
    current_entropy: [32]u8,
    previous_entropy: [32]u8,
) !void {
    const span = trace.span(.validate_guarantors);
    defer span.deinit();

    span.debug("Validating {d} guarantor signatures for slot {d}", .{ guarantee.signatures.len, guarantee.slot });

    for (guarantee.signatures) |sig| {
        const is_valid = try validateGuarantorAssignment(
            params,
            allocator,
            sig.validator_index,
            guarantee.report.core_index,
            guarantee.slot,
            current_slot,
            current_entropy,
            previous_entropy,
        );

        if (!is_valid) {
            span.err("Invalid guarantor assignment for validator {d} on core {d}", .{
                sig.validator_index,
                guarantee.report.core_index,
            });
            return Error.InvalidGuarantorAssignment;
        }
    }
}
