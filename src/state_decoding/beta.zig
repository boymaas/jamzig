const std = @import("std");
const testing = std.testing;
const types = @import("../types.zig");
const BlockInfo = types.BlockInfo;
const ReportedWorkPackage = types.ReportedWorkPackage;
const Hash = types.Hash;

const recent_blocks = @import("../recent_blocks.zig");
const RecentHistory = recent_blocks.RecentHistory;

const decoder = @import("../codec/decoder.zig");
const mmr = @import("../merkle/mmr.zig");
const codec = @import("../codec.zig");
const state_decoding = @import("../state_decoding.zig");
const DecodingError = state_decoding.DecodingError;
const DecodingContext = state_decoding.DecodingContext;

const trace = @import("../tracing.zig").scoped(.decode_beta);

pub fn decode(
    allocator: std.mem.Allocator,
    context: *DecodingContext,
    reader: anytype,
) !RecentHistory {
    const span = trace.span(.decode);
    defer span.deinit();
    span.debug("Starting history decoding", .{});
    
    try context.push(.{ .component = "beta" });
    defer context.pop();

    // Read number of blocks
    try context.push(.{ .field = "blocks_count" });
    const blocks_len = codec.readInteger(reader) catch |err| {
        return context.makeError(error.EndOfStream, "failed to read blocks count: {s}", .{@errorName(err)});
    };
    span.debug("History contains {d} blocks", .{blocks_len});
    context.pop();

    var history = try RecentHistory.init(allocator, 8); // Using constant 8 from original
    span.debug("Initialized RecentHistory with capacity 8", .{});
    errdefer history.deinit();

    // Read each block
    try context.push(.{ .field = "blocks" });
    var i: usize = 0;
    while (i < blocks_len) : (i += 1) {
        try context.push(.{ .array_index = i });
        
        const block_span = span.child(.block);
        defer block_span.deinit();
        block_span.debug("Decoding block {d} of {d}", .{ i + 1, blocks_len });

        // Read header hash
        try context.push(.{ .field = "header_hash" });
        var header_hash: Hash = undefined;
        reader.readNoEof(&header_hash) catch |err| {
            return context.makeError(error.EndOfStream, "failed to read header hash: {s}", .{@errorName(err)});
        };
        block_span.trace("Read header hash: {s}", .{std.fmt.fmtSliceHexLower(&header_hash)});
        context.pop();

        // Read beefy MMR
        try context.push(.{ .field = "beefy_mmr" });
        const mmr_span = block_span.child(.mmr);
        defer mmr_span.deinit();

        const mmr_len = codec.readInteger(reader) catch |err| {
            return context.makeError(error.EndOfStream, "failed to read MMR length: {s}", .{@errorName(err)});
        };
        mmr_span.debug("Reading MMR peaks, length: {d}", .{mmr_len});

        var mmr_peaks = try allocator.alloc(?Hash, mmr_len);
        errdefer allocator.free(mmr_peaks);

        var j: usize = 0;
        while (j < mmr_len) : (j += 1) {
            try context.push(.{ .array_index = j });
            
            const peak_span = mmr_span.child(.peak);
            defer peak_span.deinit();

            const exists = reader.readByte() catch |err| {
                return context.makeError(error.EndOfStream, "failed to read MMR peak existence flag: {s}", .{@errorName(err)});
            };
            
            if (exists == 1) {
                var hash: Hash = undefined;
                reader.readNoEof(&hash) catch |err| {
                    return context.makeError(error.EndOfStream, "failed to read MMR peak hash: {s}", .{@errorName(err)});
                };
                mmr_peaks[j] = hash;
                peak_span.trace("Peak {d}: {s}", .{ j, std.fmt.fmtSliceHexLower(&hash) });
            } else if (exists == 0) {
                mmr_peaks[j] = null;
                peak_span.trace("Peak {d}: null", .{j});
            } else {
                return context.makeError(error.InvalidValue, "invalid MMR peak existence flag: {}", .{exists});
            }
            
            context.pop();
        }
        context.pop(); // beefy_mmr

        // Read state root
        try context.push(.{ .field = "state_root" });
        var state_root: Hash = undefined;
        reader.readNoEof(&state_root) catch |err| {
            return context.makeError(error.EndOfStream, "failed to read state root: {s}", .{@errorName(err)});
        };
        block_span.trace("Read state root: {s}", .{std.fmt.fmtSliceHexLower(&state_root)});
        context.pop();

        // Read work reports
        try context.push(.{ .field = "work_reports" });
        const reports_span = block_span.child(.work_reports);
        defer reports_span.deinit();

        const reports_len = codec.readInteger(reader) catch |err| {
            return context.makeError(error.EndOfStream, "failed to read work reports count: {s}", .{@errorName(err)});
        };
        reports_span.debug("Reading {d} work reports", .{reports_len});

        const work_reports = try allocator.alloc(ReportedWorkPackage, reports_len);
        errdefer allocator.free(work_reports);

        for (work_reports, 0..) |*report, report_idx| {
            try context.push(.{ .array_index = report_idx });
            
            const report_span = reports_span.child(.report);
            defer report_span.deinit();
            report_span.debug("Reading work report {d} of {d}", .{ report_idx + 1, reports_len });

            try context.push(.{ .field = "hash" });
            reader.readNoEof(&report.hash) catch |err| {
                return context.makeError(error.EndOfStream, "failed to read work report hash: {s}", .{@errorName(err)});
            };
            report_span.trace("Work report hash: {s}", .{std.fmt.fmtSliceHexLower(&report.hash)});
            context.pop();
            
            try context.push(.{ .field = "exports_root" });
            reader.readNoEof(&report.exports_root) catch |err| {
                return context.makeError(error.EndOfStream, "failed to read exports root: {s}", .{@errorName(err)});
            };
            report_span.trace("Exports root: {s}", .{std.fmt.fmtSliceHexLower(&report.exports_root)});
            context.pop();
            
            context.pop(); // array_index
        }
        context.pop(); // work_reports

        // Create BlockInfo and add to history
        const block_info = BlockInfo{
            .header_hash = header_hash,
            .state_root = state_root,
            .beefy_mmr = mmr_peaks,
            .work_reports = work_reports,
        };

        try history.addBlockInfo(block_info);
        block_span.debug("Successfully added block to history", .{});
        
        context.pop(); // array_index
    }
    context.pop(); // blocks

    span.debug("Successfully decoded complete history with {d} blocks", .{blocks_len});
    return history;
}

test "decode beta - empty history" {
    const allocator = testing.allocator;
    
    var context = DecodingContext.init(allocator);
    defer context.deinit();

    // Create buffer with zero blocks
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    try buffer.append(0); // No blocks

    var fbs = std.io.fixedBufferStream(buffer.items);
    var history = try decode(allocator, &context, fbs.reader());
    defer history.deinit();

    try testing.expectEqual(@as(usize, 0), history.blocks.items.len);
}

test "decode beta - with blocks" {
    const allocator = testing.allocator;
    
    var context = DecodingContext.init(allocator);
    defer context.deinit();

    // Create test data
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    // Write number of blocks (1)
    try buffer.append(1);

    // Write header hash
    try buffer.appendSlice(&[_]u8{1} ** 32);

    // Write MMR (length 1)
    try buffer.append(1); // MMR length
    try buffer.append(1); // Has value
    try buffer.appendSlice(&[_]u8{2} ** 32);

    // Write state root
    try buffer.appendSlice(&[_]u8{3} ** 32);

    // Write work reports (length 1)
    try buffer.append(1);
    try buffer.appendSlice(&[_]u8{4} ** 32);
    try buffer.appendSlice(&[_]u8{5} ** 32);

    var fbs = std.io.fixedBufferStream(buffer.items);
    var history = try decode(allocator, &context, fbs.reader());
    defer history.deinit();

    // Verify block count
    try testing.expectEqual(@as(usize, 1), history.blocks.items.len);

    // Verify block contents
    const block = history.blocks.items[0];
    try testing.expectEqualSlices(u8, &[_]u8{1} ** 32, &block.header_hash);
    try testing.expectEqualSlices(u8, &[_]u8{3} ** 32, &block.state_root);
    try testing.expectEqual(@as(usize, 1), block.beefy_mmr.len);
    try testing.expectEqualSlices(u8, &[_]u8{2} ** 32, &block.beefy_mmr[0].?);
    try testing.expectEqual(@as(usize, 1), block.work_reports.len);
    try testing.expectEqualSlices(u8, &[_]u8{4} ** 32, &block.work_reports[0].hash);
    try testing.expectEqualSlices(u8, &[_]u8{5} ** 32, &block.work_reports[0].exports_root);
}

test "decode beta - roundtrip" {
    const allocator = testing.allocator;
    const encoder = @import("../state_encoding/beta.zig");
    
    var context = DecodingContext.init(allocator);
    defer context.deinit();

    // Create original history
    var original = try RecentHistory.init(allocator, 8);
    defer original.deinit();

    // Add a test block
    const block_info = BlockInfo{
        .header_hash = [_]u8{1} ** 32,
        .state_root = [_]u8{2} ** 32,
        .beefy_mmr = try allocator.dupe(?Hash, &[_]?Hash{[_]u8{3} ** 32}),
        .work_reports = try allocator.dupe(ReportedWorkPackage, &[_]ReportedWorkPackage{
            ReportedWorkPackage{
                .hash = [_]u8{4} ** 32,
                .exports_root = [_]u8{5} ** 32,
            },
        }),
    };
    try original.addBlockInfo(block_info);

    // Encode
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    try encoder.encode(&original, buffer.writer());

    // Decode
    var fbs = std.io.fixedBufferStream(buffer.items);
    var decoded = try decode(allocator, &context, fbs.reader());
    defer decoded.deinit();

    // Verify contents
    try testing.expectEqual(original.blocks.items.len, decoded.blocks.items.len);

    const orig_block = original.blocks.items[0];
    const dec_block = decoded.blocks.items[0];

    try testing.expectEqualSlices(u8, &orig_block.header_hash, &dec_block.header_hash);
    try testing.expectEqualSlices(u8, &orig_block.state_root, &dec_block.state_root);
    try testing.expectEqual(orig_block.beefy_mmr.len, dec_block.beefy_mmr.len);
    try testing.expectEqualSlices(u8, &orig_block.beefy_mmr[0].?, &dec_block.beefy_mmr[0].?);
    try testing.expectEqualSlices(ReportedWorkPackage, orig_block.work_reports, dec_block.work_reports);
}

test "decode beta - error cases" {
    const allocator = testing.allocator;

    // Test truncated length
    {
        var context = DecodingContext.init(allocator);
        defer context.deinit();
        
        var buffer = [_]u8{0xFF}; // Invalid varint
        var fbs = std.io.fixedBufferStream(&buffer);
        try testing.expectError(error.EndOfStream, decode(allocator, &context, fbs.reader()));
    }

    // Test truncated block data
    {
        var context = DecodingContext.init(allocator);
        defer context.deinit();
        
        var buffer = [_]u8{1} ++ [_]u8{1} ** 16; // Only half header hash
        var fbs = std.io.fixedBufferStream(&buffer);
        try testing.expectError(error.EndOfStream, decode(allocator, &context, fbs.reader()));
    }
}
