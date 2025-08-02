const std = @import("std");
const types = @import("../../types.zig");
const state = @import("../../state.zig");
const tracing = @import("../../tracing.zig");

const trace = tracing.scoped(.reports);
const StateTransition = @import("../../state_delta.zig").StateTransition;

/// Error types for authorization validation
pub const Error = error{
    CoreUnauthorized,
};

/// Check if the authorizer hash is valid
pub fn validateCoreAuthorization(
    comptime params: @import("../../jam_params.zig").Params,
    stx: *StateTransition(params),
    guarantee: types.ReportGuarantee,
) !void {
    const span = trace.span(.validate_authorization);
    defer span.deinit();

    span.debug("Checking authorization for core {d} with hash {s}", .{
        guarantee.report.core_index,
        std.fmt.fmtSliceHexLower(&guarantee.report.authorizer_hash),
    });

    const alpha: *const state.Alpha(
        params.core_count,
        params.max_authorizations_pool_items,
    ) = try stx.ensure(.alpha);
    if (!alpha.isAuthorized(guarantee.report.core_index, guarantee.report.authorizer_hash)) {
        span.err("Core {d} not authorized for hash {s}", .{
            guarantee.report.core_index,
            std.fmt.fmtSliceHexLower(&guarantee.report.authorizer_hash),
        });
        return Error.CoreUnauthorized;
    }
    span.debug("Authorization validated for core {d}", .{guarantee.report.core_index});
}