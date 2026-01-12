const std = @import("std");
const types = @import("../../types.zig");
const tracing = @import("tracing");

const trace = tracing.scoped(.reports);

pub const Error = error{
    WorkReportTooBig,
};

pub fn validateOutputSize(
    comptime params: @import("../../jam_params.zig").Params,
    guarantee: types.ReportGuarantee,
) !void {
    const span = trace.span(@src(), .validate_output_sizes);
    defer span.deinit();

    span.debug("Starting output size validation", .{});
    span.trace("Auth output size: {d} bytes", .{guarantee.report.auth_output.len});

    var total_size: usize = guarantee.report.auth_output.len;

    for (guarantee.report.results, 0..) |result, i| {
        const result_size = result.result.len();
        span.trace("Result[{d}] size: {d} bytes", .{ i, result_size });
        total_size += result_size;
    }

    const max_size = params.max_work_report_size;
    span.debug("Total size: {d} bytes, limit: {d} bytes", .{ total_size, max_size });

    if (total_size > max_size) {
        span.err("Total output size {d} exceeds limit {d}", .{ total_size, max_size });
        return Error.WorkReportTooBig;
    }
    span.debug("Output size validation passed", .{});
}