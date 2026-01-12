const std = @import("std");
const types = @import("types.zig");
const tracing = @import("tracing");
const guarantor_assignments = @import("guarantor_assignments.zig");

const trace = tracing.scoped(.reports);

const StateTransition = @import("state_delta.zig").StateTransition;

pub const Error = error{
    InvalidGuarantorAssignment,
    InvalidRotationPeriod,
    InvalidSlotRange,
};

pub fn validateGuarantorAssignment(
    comptime params: @import("jam_params.zig").Params,
    allocator: std.mem.Allocator,
    stx: *StateTransition(params),
    validator_index: types.ValidatorIndex,
    core_index: types.CoreIndex,
    guarantee_slot: types.TimeSlot,
) !bool {
    const span = trace.span(@src(), .validate_assignment);
    defer span.deinit();

    span.debug("Validating assignment @ current_slot {d}", .{stx.time.current_slot});
    span.debug("Validating assignment for validator {d} on core {d} at guarantee.slot {d}", .{ validator_index, core_index, guarantee_slot });

    const current_rotation = @divFloor(stx.time.current_slot, params.validator_rotation_period);
    const report_rotation = @divFloor(guarantee_slot, params.validator_rotation_period);

    span.debug("Current rotation: {d}, Report rotation: {d}", .{ current_rotation, report_rotation });

    const is_current_rotation = (current_rotation == report_rotation);
    span.debug("Building assignments using {s} rotation entropy", .{if (is_current_rotation) "current" else "previous"});

    var result = if (is_current_rotation)
        try guarantor_assignments.buildForTimeSlot(
            params,
            allocator,
            (try stx.ensure(.eta_prime))[2],
            stx.time.current_slot,
        )
    else
    if (@divFloor(stx.time.current_slot -| params.validator_rotation_period, params.epoch_length) ==
        @divFloor(stx.time.current_slot, params.epoch_length))
        try guarantor_assignments.buildForTimeSlot(
            params,
            allocator,
            (try stx.ensure(.eta_prime))[2],
            stx.time.current_slot - params.validator_rotation_period,
        )
    else
        try guarantor_assignments.buildForTimeSlot(
            params,
            allocator,
            (try stx.ensure(.eta_prime))[3],
            stx.time.current_slot - params.validator_rotation_period,
        );

    defer result.deinit(allocator);

    span.debug("Built guarantor assignments successfully", .{});

    const is_assigned = result.assignments[validator_index] == core_index;

    if (is_assigned) {
        span.debug("Validator {d} correctly assigned to core {d}", .{ validator_index, core_index });
    } else {
        span.err("Validator {d} not assigned to core {d} (assigned to core {d})", .{ validator_index, core_index, result.assignments[validator_index] });
    }

    return is_assigned;
}

pub fn validateGuarantors(
    comptime params: @import("jam_params.zig").Params,
    allocator: std.mem.Allocator,
    stx: *StateTransition(params),
    guarantee: types.ReportGuarantee,
) !void {
    const span = trace.span(@src(), .validate_guarantors);
    defer span.deinit();

    span.debug("Validating {d} guarantor signatures for slot {d}", .{ guarantee.signatures.len, guarantee.slot });

    for (guarantee.signatures) |sig| {
        const is_valid = try validateGuarantorAssignment(
            params,
            allocator,
            stx,
            sig.validator_index,
            guarantee.report.core_index.value,
            guarantee.slot,
        );

        if (!is_valid) {
            span.err("Invalid guarantor assignment for validator {d} on core {d}", .{
                sig.validator_index,
                guarantee.report.core_index.value,
            });
            return Error.InvalidGuarantorAssignment;
        }
    }
}
