const std = @import("std");

const types = @import("../types.zig");
const ReportedWorkPackage = types.ReportedWorkPackage;

const encoder = @import("../codec/encoder.zig");

const recent_blocks = @import("../recent_blocks.zig");
const RecentHistory = recent_blocks.RecentHistory;

const trace = @import("../tracing.zig").scoped(.codec);

pub fn encode(self: *const RecentHistory, writer: anytype) !void {
    const span = trace.span(.encode);
    defer span.deinit();
    span.debug("Starting recent history encoding", .{});
    span.trace("Number of blocks to encode: {d}", .{self.blocks.items.len});

    // Encode the number of blocks
    try writer.writeAll(encoder.encodeInteger(self.blocks.items.len).as_slice());
    span.debug("Encoded block count", .{});

    // Encode each block
    for (self.blocks.items, 0..) |block, i| {
        const block_span = span.child(.block);
        defer block_span.deinit();
        block_span.debug("Encoding block {d}", .{i});
        block_span.trace("Header hash: {s}", .{std.fmt.fmtSliceHexLower(&block.header_hash)});

        // Encode header hash
        try writer.writeAll(&block.header_hash);
        block_span.debug("Encoded header hash", .{});

        // Encode beefy MMR
        const mmr_encoder = @import("../merkle/mmr.zig").encodePeaks;
        block_span.debug("Encoding beefy MMR", .{});
        try mmr_encoder(block.beefy_mmr, writer);
        block_span.debug("Encoded beefy MMR", .{});

        // Encode state root
        block_span.trace("State root: {s}", .{std.fmt.fmtSliceHexLower(&block.state_root)});
        try writer.writeAll(&block.state_root);
        block_span.debug("Encoded state root", .{});

        // Encode work reports
        block_span.debug("Encoding {d} work reports", .{block.work_reports.len});
        try writer.writeAll(encoder.encodeInteger(block.work_reports.len).as_slice());

        for (block.work_reports, 0..) |report, j| {
            const report_span = block_span.child(.work_report);
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

//  _____         _   _
// |_   _|__  ___| |_(_)_ __   __ _
//   | |/ _ \/ __| __| | '_ \ / _` |
//   | |  __/\__ \ |_| | | | | (_| |
//   |_|\___||___/\__|_|_| |_|\__, |
//                            |___/

const testing = std.testing;
const BlockInfo = types.BlockInfo;
const Hash = types.Hash;

test "encode" {
    const allocator = testing.allocator;
    var recent_history = try RecentHistory.init(allocator, 2);
    defer recent_history.deinit();

    // Create a test block
    const block = BlockInfo{
        .header_hash = [_]u8{1} ** 32,
        .state_root = [_]u8{2} ** 32,
        .beefy_mmr = try allocator.dupe(?Hash, &.{[_]u8{3} ** 32}),
        .work_reports = try allocator.dupe(ReportedWorkPackage, &[_]ReportedWorkPackage{
            ReportedWorkPackage{
                .hash = [_]u8{4} ** 32,
                .exports_root = [_]u8{5} ** 32,
            },
        }),
    };

    try recent_history.addBlockInfo(block);

    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try encode(&recent_history, fbs.writer());

    const encoded: []u8 = fbs.getWritten();

    // Check the number of blocks (should be 1)
    try testing.expectEqual(@as(u8, 1), encoded[0]);

    // Check the header hash
    try testing.expectEqualSlices(u8, &block.header_hash, encoded[1..33]);

    // Check the beefy MMR
    try testing.expect(encoded.len > 33);

    // Check the state root
    // 32 bytes for state root, 1 byte for work reports length, 32 bytes for work report hash
    const state_root_start = encoded.len - 32 - 1 - 32 - 32;
    try testing.expectEqualSlices(u8, &block.state_root, encoded[state_root_start .. state_root_start + 32]);

    // Check the number of work reports (should be 1)
    try testing.expectEqual(@as(u8, 1), encoded[encoded.len - 1 - 32 - 32]);

    // Check the work report hashes
    try testing.expectEqualSlices(u8, &block.work_reports[0].hash, encoded[encoded.len - 64 ..][0..32]);
    try testing.expectEqualSlices(u8, &block.work_reports[0].exports_root, encoded[encoded.len - 32 ..][0..32]);
}
