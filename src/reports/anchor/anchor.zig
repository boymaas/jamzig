const std = @import("std");
const types = @import("../../types.zig");
const state = @import("../../state.zig");
const tracing = @import("../../tracing.zig");

const trace = tracing.scoped(.reports);
const StateTransition = @import("../../state_delta.zig").StateTransition;

/// Error types for anchor validation
pub const Error = error{
    AnchorNotRecent,
    BadBeefyMmrRoot,
    BadStateRoot,
    BadAnchor,
};

/// Validate anchor is recent and roots match
pub fn validateAnchor(
    comptime params: @import("../../jam_params.zig").Params,
    stx: *StateTransition(params),
    guarantee: types.ReportGuarantee,
) !void {
    const span = trace.span(.validate_anchor);
    defer span.deinit();

    const beta: *const state.Beta = try stx.ensure(.beta_prime);
    if (beta.getBlockInfoByHash(guarantee.report.context.anchor)) |binfo| {
        span.debug("Found anchor block, validating roots", .{});
        span.trace("Block info - hash: {s}, state root: {s}", .{
            std.fmt.fmtSliceHexLower(&binfo.header_hash),
            std.fmt.fmtSliceHexLower(&binfo.state_root),
        });

        if (!std.mem.eql(u8, &guarantee.report.context.beefy_root, &binfo.beefyMmrRoot())) {
            span.err("Beefy MMR root mismatch - expected: {s}, got: {s}", .{
                std.fmt.fmtSliceHexLower(&binfo.beefyMmrRoot()),
                std.fmt.fmtSliceHexLower(&guarantee.report.context.beefy_root),
            });
            return Error.BadBeefyMmrRoot;
        }

        if (!std.mem.eql(u8, &guarantee.report.context.state_root, &binfo.state_root)) {
            span.err("State root mismatch - expected: {s}, got: {s}", .{
                std.fmt.fmtSliceHexLower(&binfo.state_root),
                std.fmt.fmtSliceHexLower(&guarantee.report.context.state_root),
            });
            return Error.BadStateRoot;
        }

        if (!std.mem.eql(u8, &guarantee.report.context.anchor, &binfo.header_hash)) {
            span.err("Anchor hash mismatch - expected: {s}, got: {s}", .{
                std.fmt.fmtSliceHexLower(&binfo.header_hash),
                std.fmt.fmtSliceHexLower(&guarantee.report.context.anchor),
            });
            return Error.BadAnchor;
        }

        span.debug("Anchor validation successful", .{});
    } else {
        span.err("Anchor block not found in recent history: {s}", .{
            std.fmt.fmtSliceHexLower(&guarantee.report.context.anchor),
        });
        return Error.AnchorNotRecent;
    }
}