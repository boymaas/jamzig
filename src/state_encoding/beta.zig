const std = @import("std");

const types = @import("../types.zig");
const ReportedWorkPackage = types.ReportedWorkPackage;

const encoder = @import("../codec/encoder.zig");

const beta_component = @import("../beta.zig");
const Beta = beta_component.Beta;
const RecentHistory = beta_component.RecentHistory;
const BeefyBelt = beta_component.BeefyBelt;

const mmr = @import("../merkle/mmr.zig");

const trace = @import("tracing").scoped(.codec);

/// Encode Beta component (v0.6.7: contains recent_history and beefy_belt)
/// As per graypaper: encode(recent_history, encode_MMR(beefy_belt))
pub fn encode(self: *const Beta, writer: anytype) !void {
    const span = trace.span(@src(), .encode);
    defer span.deinit();
    span.debug("Starting beta encoding (v0.6.7)", .{});

    try encodeRecentHistory(&self.recent_history, writer);

    span.debug("Encoding beefy_belt MMR", .{});
    try mmr.encodePeaks(self.beefy_belt.peaks, writer);

    span.debug("Beta encoding complete", .{});
}

/// Encode the recent history sub-component
fn encodeRecentHistory(self: *const RecentHistory, writer: anytype) !void {
    const span = trace.span(@src(), .encode);
    defer span.deinit();
    span.debug("Starting recent history encoding", .{});
    span.trace("Number of blocks to encode: {d}", .{self.blocks.items.len});

    try writer.writeAll(encoder.encodeInteger(self.blocks.items.len).as_slice());
    span.debug("Encoded block count", .{});

    for (self.blocks.items, 0..) |block, i| {
        const block_span = span.child(@src(), .block);
        defer block_span.deinit();
        block_span.debug("Encoding block {d}", .{i});
        block_span.trace("Header hash: {s}", .{std.fmt.fmtSliceHexLower(&block.header_hash)});

        try writer.writeAll(&block.header_hash);
        block_span.debug("Encoded header hash", .{});

        block_span.trace("Beefy root: {s}", .{std.fmt.fmtSliceHexLower(&block.beefy_root)});
        try writer.writeAll(&block.beefy_root);
        block_span.debug("Encoded beefy root", .{});

        block_span.trace("State root: {s}", .{std.fmt.fmtSliceHexLower(&block.state_root)});
        try writer.writeAll(&block.state_root);
        block_span.debug("Encoded state root", .{});

        block_span.debug("Encoding {d} work reports", .{block.work_reports.len});
        try writer.writeAll(encoder.encodeInteger(block.work_reports.len).as_slice());

        for (block.work_reports, 0..) |report, j| {
            const report_span = block_span.child(@src(), .work_report);
            defer report_span.deinit();
            report_span.debug("Encoding work report {d}", .{j});
            report_span.trace("Report hash: {s}", .{std.fmt.fmtSliceHexLower(&report.hash)});
            report_span.trace("Exports root: {s}", .{std.fmt.fmtSliceHexLower(&report.exports_root)});

            try writer.writeAll(&report.hash);
            try writer.writeAll(&report.exports_root);
            report_span.debug("Work report encoded", .{});
        }
        block_span.debug("Block encoding complete", .{});
    }
    span.debug("Recent history encoding complete", .{});
}
