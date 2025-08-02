const std = @import("std");
const types = @import("../../types.zig");
const tracing = @import("../../tracing.zig");

const trace = tracing.scoped(.reports);

/// Error types for gas validation
pub const Error = error{
    WorkReportGasTooHigh,
};

/// Validate gas limits for all results in a work report
pub fn validateGasLimits(
    comptime params: @import("../../jam_params.zig").Params,
    guarantee: types.ReportGuarantee,
) !void {
    const span = trace.span(.validate_gas);
    defer span.deinit();
    span.debug("Validating gas limits for {d} results", .{guarantee.report.results.len});

    // Calculate total accumulate gas for this report
    var total_gas: u64 = 0;
    for (guarantee.report.results) |result| {
        total_gas += result.accumulate_gas;
    }

    span.debug("Total accumulate gas: {d}", .{total_gas});

    // Check total doesn't exceed G_A
    if (total_gas > params.gas_alloc_accumulation) {
        span.err("Work report gas {d} exceeds limit {d}", .{ total_gas, params.gas_alloc_accumulation });
        return Error.WorkReportGasTooHigh;
    }

    span.debug("Gas validation passed", .{});
}