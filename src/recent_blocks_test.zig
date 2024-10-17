const std = @import("std");
const testing = std.testing;
const RecentHistory = @import("recent_blocks.zig").RecentHistory;
const RecentBlock = @import("recent_blocks.zig").RecentBlock;
const Hash = @import("recent_blocks.zig").Hash;
const HistoryTestVector = @import("tests/vectors/libs/history.zig").HistoryTestVector;
const TestCase = @import("tests/vectors/libs/history.zig").TestCase;
const getSortedListOfJsonFilesInDir = @import("tests/vectors/libs/utils.zig").getSortedListOfJsonFilesInDir;

fn fromBlockInfo(allocator: std.mem.Allocator, block_info: anytype) !RecentBlock {
    var block = RecentBlock{
        .header_hash = block_info.header_hash.bytes,
        .state_root = block_info.state_root.bytes,
        .beefy_mmr = try allocator.alloc(Hash, block_info.mmr.peaks.len),
        .work_report_hashes = try allocator.alloc(Hash, block_info.reported.len),
    };
    for (block_info.mmr.peaks, 0..) |peak, i| {
        if (peak) |p| {
            block.beefy_mmr[i] = p.bytes;
        } else {
            @memset(&block.beefy_mmr[i], 0);
        }
    }
    for (block_info.reported, 0..) |report, i| {
        block.work_report_hashes[i] = report.bytes;
    }
    return block;
}

fn compareBlocks(expected: RecentBlock, actual: RecentBlock) !void {
    if (!std.mem.eql(u8, &expected.header_hash, &actual.header_hash)) {
        std.debug.print("Header hash mismatch:\nExpected: {s}\nActual:   {s}\n", .{ std.fmt.fmtSliceHexLower(&expected.header_hash), std.fmt.fmtSliceHexLower(&actual.header_hash) });
        return error.HeaderHashMismatch;
    }
    if (!std.mem.eql(u8, &expected.state_root, &actual.state_root)) {
        std.debug.print("State root mismatch:\nExpected: {s}\nActual:   {s}\n", .{ std.fmt.fmtSliceHexLower(&expected.state_root), std.fmt.fmtSliceHexLower(&actual.state_root) });
        return error.StateRootMismatch;
    }
    if (!std.mem.eql(Hash, expected.beefy_mmr, actual.beefy_mmr)) {
        std.debug.print("Beefy MMR mismatch:\nExpected: {s}\nActual:   {s}\n", .{ std.fmt.fmtSliceHexLower(std.mem.sliceAsBytes(expected.beefy_mmr)), std.fmt.fmtSliceHexLower(std.mem.sliceAsBytes(actual.beefy_mmr)) });
        return error.BeefyMmrMismatch;
    }
    if (!std.mem.eql(Hash, expected.work_report_hashes, actual.work_report_hashes)) {
        std.debug.print("Work report hashes mismatch:\nExpected: {s}\nActual:   {s}\n", .{ std.fmt.fmtSliceHexLower(std.mem.sliceAsBytes(expected.work_report_hashes)), std.fmt.fmtSliceHexLower(std.mem.sliceAsBytes(actual.work_report_hashes)) });
        return error.WorkReportHashesMismatch;
    }
}

test "recent blocks: parsing all test cases" {
    const allocator = testing.allocator;
    const target_dir = "src/tests/vectors/history/history/data";

    var entries = try getSortedListOfJsonFilesInDir(allocator, target_dir);
    defer entries.deinit();

    for (entries.items) |entry| {
        std.debug.print("\x1b[1;32mProcessing test vector: {s}\x1b[0m\n", .{entry});

        const file_path = try std.fs.path.join(allocator, &[_][]const u8{ target_dir, entry });
        defer allocator.free(file_path);

        const vector = try HistoryTestVector(TestCase).build_from(allocator, file_path);
        defer vector.deinit();

        // Test the RecentHistory implementation
        var recent_history = try RecentHistory.init(allocator, 341);
        defer recent_history.deinit();

        // Set up pre-state
        for (vector.expected.value.pre_state.beta) |block_info| {
            const block = try fromBlockInfo(allocator, block_info);
            try recent_history.addBlock(block);
        }

        // Process the new block
        const new_block = RecentBlock{
            .header_hash = vector.expected.value.input.header_hash.bytes,
            .state_root = vector.expected.value.input.parent_state_root.bytes,
            .beefy_mmr = try allocator.alloc(Hash, 1),
            .work_report_hashes = try allocator.alloc(Hash, vector.expected.value.input.work_packages.len),
        };
        new_block.beefy_mmr[0] = vector.expected.value.input.accumulate_root.bytes;
        for (vector.expected.value.input.work_packages, 0..) |work_package, i| {
            new_block.work_report_hashes[i] = work_package.bytes;
        }
        try recent_history.addBlock(new_block);

        // Verify the post-state
        try testing.expectEqual(vector.expected.value.post_state.beta.len, recent_history.blocks.items.len);
        for (vector.expected.value.post_state.beta, 0..) |expected_block, i| {
            const actual_block = recent_history.getBlock(i).?;
            const expected_recent_block = try fromBlockInfo(allocator, expected_block);
            defer {
                allocator.free(expected_recent_block.beefy_mmr);
                allocator.free(expected_recent_block.work_report_hashes);
            }
            try compareBlocks(expected_recent_block, actual_block);
        }
    }
}
