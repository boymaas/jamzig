const std = @import("std");
const testing = std.testing;

const types = @import("types.zig");
const BlockInfo = types.BlockInfo;
const ReportedWorkPackage = types.ReportedWorkPackage;
const Hash = types.Hash;

const recent_blocks = @import("recent_blocks.zig");
const RecentBlock = recent_blocks.RecentBlock;
const RecentHistory = recent_blocks.RecentHistory;

const tvector = @import("jamtestvectors/history.zig");
const HistoryTestVector = tvector.HistoryTestVector;
const TestCase = tvector.TestCase;

const getSortedListOfJsonFilesInDir = @import("jamtestvectors/json_types/utils.zig").getSortedListOfJsonFilesInDir;

test "recent blocks: parsing all test cases" {
    const allocator = testing.allocator;
    const target_dir = tvector.BASE_PATH;

    var entries = try getSortedListOfJsonFilesInDir(allocator, target_dir);
    defer entries.deinit();

    for (entries.items) |entry| {
        std.debug.print("\x1b[1;32mProcessing test vector: {s}\x1b[0m\n", .{entry});

        const file_path = try std.fs.path.join(allocator, &[_][]const u8{ target_dir, entry });
        defer allocator.free(file_path);

        var vector = try HistoryTestVector(TestCase).build_from(allocator, file_path);
        defer vector.deinit();

        // Test the RecentHistory implementation, H = 8 see GP
        var recent_history = try RecentHistory.init(allocator, 8);
        defer recent_history.deinit();

        // Set up pre-state
        for (vector.expected.value.pre_state.beta) |block_info| {
            const block = try fromTestVectorBlockInfo(allocator, block_info);
            try recent_history.addBlockInfo(block);
        }

        // Process the new block
        const recent_block = try fromTestVectorInputToRecentBlock(allocator, vector.expected.value.input);
        defer recent_block.deinit(allocator);

        try recent_history.import(recent_block);

        // Verify the post-state
        try testing.expectEqual(vector.expected.value.post_state.beta.len, recent_history.blocks.items.len);
        for (vector.expected.value.post_state.beta, 0..) |expected_block, i| {
            const actual_block = recent_history.getBlockInfo(i) orelse
                return error.BlockInfoNotFoud;

            const expected_recent_block = try fromTestVectorBlockInfo(allocator, expected_block);
            defer {
                allocator.free(expected_recent_block.beefy_mmr);
                allocator.free(expected_recent_block.work_reports);
            }
            try compareBlocks(expected_recent_block, actual_block, i);
        }
    }
}

/// Transforms the test vector input into a RecentBlock, which can be used to call our
/// Beta (recent blocks) implementation.
fn fromTestVectorInputToRecentBlock(allocator: std.mem.Allocator, input: tvector.Input) !RecentBlock {
    var work_packages = try allocator.alloc(ReportedWorkPackage, input.work_packages.len);
    for (input.work_packages, 0..) |wp, i| {
        work_packages[i] = ReportedWorkPackage{
            .hash = wp.hash.bytes,
            .exports_root = wp.exports_root.bytes,
        };
    }
    return RecentBlock{
        .header_hash = input.header_hash.bytes,
        .parent_state_root = input.parent_state_root.bytes,
        .accumulate_root = input.accumulate_root.bytes,
        .work_reports = work_packages,
    };
}

/// Converts a test vector BlockInfo into our internal BlockInfo structure.
/// This function allocates memory for the beefy_mmr and work_report_hashes fields,
/// so the caller is responsible for freeing this memory when it's no longer needed.
fn fromTestVectorBlockInfo(allocator: std.mem.Allocator, block_info: tvector.BlockInfo) !BlockInfo {
    var block = BlockInfo{
        .header_hash = block_info.header_hash.bytes,
        .state_root = block_info.state_root.bytes,
        .beefy_mmr = try allocator.alloc(?Hash, block_info.mmr.peaks.len),
        .work_reports = try allocator.alloc(ReportedWorkPackage, block_info.reported.len),
    };
    for (block_info.mmr.peaks, 0..) |peak, i| {
        if (peak) |p| {
            block.beefy_mmr[i] = p.bytes;
        } else {
            block.beefy_mmr[i] = null;
        }
    }
    for (block_info.reported, 0..) |report, i| {
        block.work_reports[i] = ReportedWorkPackage{
            .hash = report.hash.bytes,
            .exports_root = report.exports_root.bytes,
        };
    }
    return block;
}

/// Compares two BlockInfo structures for equality.
/// This function checks if all fields of the expected and actual BlockInfo
/// structures match, including header_hash, state_root, beefy_mmr, and work_report_hashes.
/// It prints detailed error messages if any mismatch is found.
/// Returns an error if any field doesn't match.
fn compareBlocks(expected: BlockInfo, actual: BlockInfo, block_idx: usize) !void {
    if (!std.mem.eql(u8, &expected.header_hash, &actual.header_hash)) {
        std.debug.print("Block {d}: Header hash mismatch:\nExpected: {s}\nActual:   {s}\n", .{ block_idx, std.fmt.fmtSliceHexLower(&expected.header_hash), std.fmt.fmtSliceHexLower(&actual.header_hash) });
        return error.HeaderHashMismatch;
    }

    if (!std.mem.eql(u8, &expected.state_root, &actual.state_root)) {
        std.debug.print("Block {d}: State root mismatch:\nExpected: {s}\nActual:   {s}\n", .{ block_idx, std.fmt.fmtSliceHexLower(&expected.state_root), std.fmt.fmtSliceHexLower(&actual.state_root) });
        return error.StateRootMismatch;
    }

    std.testing.expectEqualSlices(?Hash, expected.beefy_mmr, actual.beefy_mmr) catch {
        std.debug.print("Block {d}: Beefy MMR mismatch\n", .{block_idx});
        return error.BeefyMmrMismatch;
    };

    std.testing.expectEqualSlices(ReportedWorkPackage, expected.work_reports, actual.work_reports) catch {
        return error.WorkReportHashesMismatch;
    };
}
