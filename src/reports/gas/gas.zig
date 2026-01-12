const std = @import("std");
const types = @import("../../types.zig");
const tracing = @import("tracing");

const trace = tracing.scoped(.reports);

pub const Error = error{
    WorkReportGasTooHigh,
};

pub fn validateGasLimits(
    comptime params: @import("../../jam_params.zig").Params,
    guarantee: types.ReportGuarantee,
) !void {
    const span = trace.span(@src(), .validate_gas);
    defer span.deinit();
    span.debug("Validating gas limits for {d} results", .{guarantee.report.results.len});

    var total_gas: u64 = 0;
    for (guarantee.report.results) |result| {
        total_gas = std.math.add(u64, total_gas, result.accumulate_gas) catch std.math.maxInt(u64);
    }

    span.debug("Total accumulate gas: {d}", .{total_gas});

    if (total_gas > params.gas_alloc_accumulation) {
        span.err("Work report gas {d} exceeds limit {d}", .{ total_gas, params.gas_alloc_accumulation });
        return Error.WorkReportGasTooHigh;
    }

    span.debug("Gas validation passed", .{});
}