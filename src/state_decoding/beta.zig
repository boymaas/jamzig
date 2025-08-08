const std = @import("std");
const testing = std.testing;
const types = @import("../types.zig");
const ReportedWorkPackage = types.ReportedWorkPackage;
const Hash = types.Hash;

const beta_component = @import("../beta.zig");
const Beta = beta_component.Beta;
const RecentHistory = beta_component.RecentHistory;
const BeefyBelt = beta_component.BeefyBelt;

const decoder = @import("../codec/decoder.zig");
const mmr = @import("../merkle/mmr.zig");
const codec = @import("../codec.zig");
const state_decoding = @import("../state_decoding.zig");
const DecodingError = state_decoding.DecodingError;
const DecodingContext = state_decoding.DecodingContext;

const trace = @import("../tracing.zig").scoped(.decode_beta);

/// Decode Beta component (v0.6.7: contains recent_history and beefy_belt)
pub fn decode(
    allocator: std.mem.Allocator,
    context: *DecodingContext,
    reader: anytype,
) !Beta {
    const span = trace.span(.decode);
    defer span.deinit();
    span.debug("Starting beta decoding (v0.6.7)", .{});

    try context.push(.{ .component = "beta" });
    defer context.pop();

    // Decode recent_history
    try context.push(.{ .field = "recent_history" });
    const recent_history = try decodeRecentHistory(allocator, context, reader);
    context.pop();

    // Decode beefy_belt MMR
    try context.push(.{ .field = "beefy_belt" });
    const beefy_belt = try decodeBeefyBelt(allocator, context, reader);
    context.pop();

    return Beta{
        .recent_history = recent_history,
        .beefy_belt = beefy_belt,
        .allocator = allocator,
    };
}

/// Decode the recent history sub-component
fn decodeRecentHistory(
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

        // Read beefy root (v0.6.7: just the root, not full MMR)
        try context.push(.{ .field = "beefy_root" });
        var beefy_root: Hash = undefined;
        reader.readNoEof(&beefy_root) catch |err| {
            return context.makeError(error.EndOfStream, "failed to read beefy root: {s}", .{@errorName(err)});
        };
        block_span.trace("Read beefy root: {s}", .{std.fmt.fmtSliceHexLower(&beefy_root)});
        context.pop();

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

        // Create BlockInfo and add to history (v0.6.7 structure)
        const block_info = RecentHistory.BlockInfo{
            .header_hash = header_hash,
            .beefy_root = beefy_root,
            .state_root = state_root,
            .work_reports = work_reports,
        };

        try history.addBlock(block_info);
        block_span.debug("Successfully added block to history", .{});

        context.pop(); // array_index
    }
    context.pop(); // blocks

    span.debug("Successfully decoded complete history with {d} blocks", .{blocks_len});
    return history;
}

/// Decode the BeefyBelt MMR sub-component
fn decodeBeefyBelt(
    allocator: std.mem.Allocator,
    context: *DecodingContext,
    reader: anytype,
) !BeefyBelt {
    const span = trace.span(.decode_beefy_belt);
    defer span.deinit();
    span.debug("Starting beefy belt decoding", .{});

    // Read MMR peaks
    const peaks_len = codec.readInteger(reader) catch |err| {
        return context.makeError(error.EndOfStream, "failed to read MMR peaks length: {s}", .{@errorName(err)});
    };
    span.debug("Reading {d} MMR peaks", .{peaks_len});

    var peaks = try allocator.alloc(?Hash, peaks_len);
    errdefer allocator.free(peaks);

    var i: usize = 0;
    while (i < peaks_len) : (i += 1) {
        try context.push(.{ .array_index = i });

        const exists = reader.readByte() catch |err| {
            return context.makeError(error.EndOfStream, "failed to read peak existence flag: {s}", .{@errorName(err)});
        };

        if (exists == 1) {
            var hash: Hash = undefined;
            reader.readNoEof(&hash) catch |err| {
                return context.makeError(error.EndOfStream, "failed to read peak hash: {s}", .{@errorName(err)});
            };
            peaks[i] = hash;
            span.trace("Peak {d}: {s}", .{ i, std.fmt.fmtSliceHexLower(&hash) });
        } else if (exists == 0) {
            peaks[i] = null;
            span.trace("Peak {d}: null", .{i});
        } else {
            return context.makeError(error.InvalidValue, "invalid peak existence flag: {}", .{exists});
        }

        context.pop();
    }

    return BeefyBelt{
        .peaks = peaks,
        .allocator = allocator,
    };
}
