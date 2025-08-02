const std = @import("std");
const types = @import("../../types.zig");
const state = @import("../../state.zig");
const tracing = @import("../../tracing.zig");

const trace = tracing.scoped(.reports);
const StateTransition = @import("../../state_delta.zig").StateTransition;

/// Error types for service validation
pub const Error = error{
    BadServiceId,
    BadCodeHash,
    ServiceItemGasTooLow,
};

/// Validates service results in a work report
pub fn validateServices(
    comptime params: @import("../../jam_params.zig").Params,
    stx: *StateTransition(params),
    guarantee: types.ReportGuarantee,
) !void {
    const span = trace.span(.validate_services);
    defer span.deinit();
    span.debug("Validating {d} service results", .{guarantee.report.results.len});

    const delta: *const state.Delta = try stx.ensure(.delta);
    for (guarantee.report.results, 0..) |result, i| {
        const result_span = span.child(.validate_service_result);
        defer result_span.deinit();

        result_span.debug("Validating service ID {d} for result {d}", .{ result.service_id, i });
        result_span.trace("Code hash: {s}, gas: {d}", .{
            std.fmt.fmtSliceHexLower(&result.code_hash),
            result.accumulate_gas,
        });

        if (delta.getAccount(result.service_id)) |service| {
            result_span.debug("Found service account, validating code hash and gas", .{});
            result_span.trace("Service code hash: {s}, min gas: {d}", .{
                std.fmt.fmtSliceHexLower(&service.code_hash),
                service.min_gas_accumulate,
            });

            // Validate code hash matches
            if (!std.mem.eql(u8, &service.code_hash, &result.code_hash)) {
                result_span.err("Code hash mismatch - expected: {s}, got: {s}", .{
                    std.fmt.fmtSliceHexLower(&service.code_hash),
                    std.fmt.fmtSliceHexLower(&result.code_hash),
                });
                return Error.BadCodeHash;
            }

            // Check gas limits
            if (result.accumulate_gas < service.min_gas_accumulate) {
                result_span.err("Insufficient gas: {d} < minimum {d}", .{
                    result.accumulate_gas,
                    service.min_gas_accumulate,
                });
                return Error.ServiceItemGasTooLow;
            }

            result_span.debug("Service validation successful", .{});
        } else {
            result_span.err("Service ID {d} not found", .{result.service_id});
            return Error.BadServiceId;
        }
    }

    span.debug("All service validations passed", .{});
}