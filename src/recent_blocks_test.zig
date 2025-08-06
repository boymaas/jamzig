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
const TestCase = tvector.TestCase;
const jam_params = @import("jam_params.zig");

test "recent blocks: parsing all test cases" {
    const allocator = testing.allocator;
    const target_dir = tvector.BASE_PATH;

    var dir = try std.fs.cwd().openDir(target_dir, .{ .iterate = true });
    defer dir.close();

    var dir_iterator = dir.iterate();
    while (try dir_iterator.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".bin")) continue;
        
        std.debug.print("\n\x1b[1;32mProcessing test vector: {s}\x1b[0m\n", .{entry.name});

        const file_path = try std.fs.path.join(allocator, &[_][]const u8{ target_dir, entry.name });
        defer allocator.free(file_path);

        var test_case = try TestCase.buildFrom(
            jam_params.TINY_PARAMS,
            allocator,
            file_path,
        );
        defer test_case.deinit(allocator);

        // Test the RecentHistory implementation, H = 8 see GP
        var recent_history = try RecentHistory.init(allocator, 8);
        defer recent_history.deinit();

        // Set up pre-state
        for (test_case.pre_state.beta.history) |block_info| {
            const block = try fromTestVectorBlockInfo(allocator, block_info);
            try recent_history.addBlockInfo(block);
        }

        // Process the new block
        const recent_block = try fromTestVectorInputToRecentBlock(allocator, test_case.input);
        errdefer recent_block.deinit(allocator);

        try recent_history.import(recent_block);

        // Verify the post-state
        try testing.expectEqual(test_case.post_state.beta.history.len, recent_history.blocks.items.len);
        for (test_case.post_state.beta.history, 0..) |expected_block, i| {
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
            .hash = wp.hash,
            .exports_root = wp.exports_root,
        };
    }
    return RecentBlock{
        .header_hash = input.header_hash,
        .parent_state_root = input.parent_state_root,
        .accumulate_root = input.accumulate_root,
        .work_reports = work_packages,
    };
}

/// Converts a test vector BlockInfo into our internal BlockInfo structure.
/// This function allocates memory for the beefy_mmr and work_report_hashes fields,
/// so the caller is responsible for freeing this memory when it's no longer needed.
fn fromTestVectorBlockInfo(allocator: std.mem.Allocator, block_info: tvector.BlockInfoTestVector) !BlockInfo {
    var block = BlockInfo{
        .header_hash = block_info.header_hash,
        .state_root = block_info.state_root,
        // Test vectors have a single beefy_root instead of MMR peaks
        .beefy_mmr = try allocator.alloc(?Hash, 1),
        .work_reports = try allocator.alloc(ReportedWorkPackage, block_info.reported.len),
    };
    // Store the beefy_root as the single element
    block.beefy_mmr[0] = block_info.beefy_root;
    for (block_info.reported, 0..) |report, i| {
        block.work_reports[i] = ReportedWorkPackage{
            .hash = report.hash,
            .exports_root = report.exports_root,
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
