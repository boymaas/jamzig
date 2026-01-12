const std = @import("std");
const types = @import("../../types.zig");
const state = @import("../../state.zig");
const tracing = @import("tracing");

const trace = tracing.scoped(.reports);
const StateTransition = @import("../../state_delta.zig").StateTransition;

pub const Error = error{
    FutureReportSlot,
    ReportEpochBeforeLast,
    InvalidRotationPeriod,
    InvalidSlotRange,
    CoreEngaged,
};

pub fn validateReportSlot(
    comptime params: @import("../../jam_params.zig").Params,
    stx: *StateTransition(params),
    guarantee: types.ReportGuarantee,
) !void {
    const span = trace.span(@src(), .validate_slot);
    defer span.deinit();

    span.debug("Validating report slot {d} against current slot {d} for core {d}", .{
        guarantee.slot,
        stx.time.current_slot,
        guarantee.report.core_index.value,
    });

    if (guarantee.slot > stx.time.current_slot) {
        span.err("Report slot {d} is in the future (current: {d})", .{ guarantee.slot, stx.time.current_slot });
        return Error.FutureReportSlot;
    }
}

pub fn validateRotationPeriod(
    comptime params: @import("../../jam_params.zig").Params,
    stx: *StateTransition(params),
    guarantee: types.ReportGuarantee,
) !void {
    const span = trace.span(@src(), .validate_rotation);
    defer span.deinit();

    const current_rotation = @divFloor(stx.time.current_slot, params.validator_rotation_period);
    const report_rotation = @divFloor(guarantee.slot, params.validator_rotation_period);

    span.debug("Validating report rotation {d} against current rotation {d} (rotation_period={d})", .{
        report_rotation,
        current_rotation,
        params.validator_rotation_period,
    });

    if (report_rotation < current_rotation -| 1) {
        span.err(
            "Report from rotation {d} is too old (current: {d})",
            .{
                report_rotation,
                current_rotation,
            },
        );
        return Error.ReportEpochBeforeLast;
    }
}

pub fn validateSlotRange(
    comptime params: @import("../../jam_params.zig").Params,
    stx: *StateTransition(params),
    guarantee: types.ReportGuarantee,
) !void {
    const span = trace.span(@src(), .validate_slot_range);
    defer span.deinit();

    const min_guarantee_slot = (@divFloor(stx.time.current_slot, params.validator_rotation_period) -| 1) * params.validator_rotation_period;
    const max_guarantee_slot = stx.time.current_slot;
    span.debug("Validating guarantee time slot {d} is between {d} and {d}", .{ guarantee.slot, min_guarantee_slot, max_guarantee_slot });

    if (!(guarantee.slot >= min_guarantee_slot and guarantee.slot <= stx.time.current_slot)) {
        span.err(
            "Guarantee time slot out of range: {d} is NOT between {d} and {d}",
            .{ guarantee.slot, min_guarantee_slot, max_guarantee_slot },
        );
        return Error.ReportEpochBeforeLast;
    }
}

pub fn validateCoreTimeout(
    comptime params: @import("../../jam_params.zig").Params,
    stx: *StateTransition(params),
    guarantee: types.ReportGuarantee,
) !void {
    const span = trace.span(@src(), .validate_timeout);
    defer span.deinit();

    const rho: *const state.Rho(params.core_count) = try stx.ensure(.rho_prime);
    if (rho.getReport(guarantee.report.core_index.value)) |entry| {
        span.debug("Checking core {d} timeout - last: {d}, current: {d}, period: {d}", .{
            guarantee.report.core_index.value,
            entry.assignment.timeout,
            guarantee.slot,
            params.work_replacement_period,
        });

        if (!entry.assignment.isTimedOut(params.work_replacement_period, guarantee.slot)) {
            span.err("Core {d} still engaged - needs {d} more slots", .{
                guarantee.report.core_index.value,
                (entry.assignment.timeout + params.work_replacement_period) - guarantee.slot,
            });
            return Error.CoreEngaged;
        }
        span.debug("Core {d} timeout validated", .{guarantee.report.core_index.value});
    } else {
        span.debug("Core {d} is free", .{guarantee.report.core_index.value});
    }
}