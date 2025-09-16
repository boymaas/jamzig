const std = @import("std");
const types = @import("../../types.zig");
const state = @import("../../state.zig");
const tracing = @import("tracing");

const trace = tracing.scoped(.reports);
const StateTransition = @import("../../state_delta.zig").StateTransition;
const Ancestry = state.Ancestry;

/// Error types for anchor validation
pub const Error = error{
    AnchorNotRecent,
    AnchorTooOld,
    BadBeefyMmrRoot,
    BadStateRoot,
    BadAnchor,
    AnchorAncestryTimeslotMismatch,
    AnchorNotInAncestry,
};

/// Validate anchor is recent and roots match
pub fn validateAnchor(
    comptime params: @import("../../jam_params.zig").Params,
    stx: *StateTransition(params),
    guarantee: types.ReportGuarantee,
) !void {
    const span = trace.span(@src(), .validate_anchor);
    defer span.deinit();

    // Check if the timeslot of the anchor is within the recent history
    if (guarantee.report.context.lookup_anchor_slot < stx.time.current_slot -| params.max_lookup_anchor_age) {
        span.err("Anchor timeslot {d} is too old (current: {d}, max age: {d})", .{
            guarantee.report.context.lookup_anchor_slot,
            stx.time.current_slot,
            params.max_lookup_anchor_age,
        });
        return Error.AnchorTooOld;
    }

    const beta: *const state.Beta = try stx.ensure(.beta_prime);
    if (beta.getBlockInfoByHash(guarantee.report.context.anchor)) |binfo| {
        const bv_span = span.child(@src(), .beta_validation);
        defer bv_span.deinit();

        bv_span.debug("Found anchor block, validating roots", .{});
        bv_span.trace("Block info - hash: {s}, state root: {s}", .{
            std.fmt.fmtSliceHexLower(&binfo.header_hash),
            std.fmt.fmtSliceHexLower(&binfo.state_root),
        });

        if (!std.mem.eql(u8, &guarantee.report.context.beefy_root, &binfo.beefyMmrRoot())) {
            bv_span.err("Beefy MMR root mismatch - expected: {s}, got: {s}", .{
                std.fmt.fmtSliceHexLower(&binfo.beefyMmrRoot()),
                std.fmt.fmtSliceHexLower(&guarantee.report.context.beefy_root),
            });
            return Error.BadBeefyMmrRoot;
        }

        if (!std.mem.eql(u8, &guarantee.report.context.state_root, &binfo.state_root)) {
            bv_span.err("State root mismatch - expected: {s}, got: {s}", .{
                std.fmt.fmtSliceHexLower(&binfo.state_root),
                std.fmt.fmtSliceHexLower(&guarantee.report.context.state_root),
            });
            return Error.BadStateRoot;
        }

        if (!std.mem.eql(u8, &guarantee.report.context.anchor, &binfo.header_hash)) {
            bv_span.err("Anchor hash mismatch - expected: {s}, got: {s}", .{
                std.fmt.fmtSliceHexLower(&binfo.header_hash),
                std.fmt.fmtSliceHexLower(&guarantee.report.context.anchor),
            });
            return Error.BadAnchor;
        }

        bv_span.debug("Anchor validation successful", .{});
        return; // Success - anchor found and validated in beta, no need to check ancestry
    }

    // Anchor not found in recent history (beta), check ancestry if available
    const av_span = span.child(@src(), .ancestry_validation);
    defer av_span.deinit();

    av_span.debug("Anchor not found in recent history, checking ancestry", .{});

    // Fall back to ancestry for older blocks
    if (stx.base.ancestry) |anc| {
        if (anc.lookupTimeslot(guarantee.report.context.anchor)) |timeslot| {
            if (guarantee.report.context.lookup_anchor_slot != timeslot) {
                av_span.err("Anchor timeslot mismatch in ancestry - expected(ancestry): {d}, got: {d}", .{
                    guarantee.report.context.lookup_anchor_slot,
                    timeslot,
                });
                return Error.AnchorAncestryTimeslotMismatch;
            }
            av_span.debug("Anchor found in ancestry and timeslot {d} matches", .{timeslot});
        } else {
            av_span.err("Anchor not found in ancestry: {s}", .{
                std.fmt.fmtSliceHexLower(&guarantee.report.context.anchor),
            });
            return Error.AnchorNotInAncestry;
        }
    } else {
        // No ancestry available - this means ancestry feature is disabled
        av_span.debug("No ancestry available, skipping ancestry validation per graypaper spec", .{});
        span.err("Anchor block not found in recent history: {s}", .{
            std.fmt.fmtSliceHexLower(&guarantee.report.context.anchor),
        });
        return Error.AnchorNotRecent;
    }
}
