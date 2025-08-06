const std = @import("std");
const types = @import("../types.zig");
const available_reports = @import("../reports_ready.zig");
const codec = @import("../codec.zig");
const WorkReport = types.WorkReport;
const state_decoding = @import("../state_decoding.zig");
const DecodingError = state_decoding.DecodingError;
const DecodingContext = state_decoding.DecodingContext;

pub const DecoderParams = struct {
    epoch_length: u32,

    pub fn fromJamParams(comptime params: anytype) DecoderParams {
        return .{
            .epoch_length = params.epoch_length,
        };
    }
};

pub fn decode(
    comptime params: DecoderParams,
    allocator: std.mem.Allocator,
    context: *DecodingContext,
    reader: anytype,
) !available_reports.VarTheta(params.epoch_length) {
    try context.push(.{ .component = "theta" });
    defer context.pop();

    var theta = available_reports.VarTheta(params.epoch_length).init(allocator);
    errdefer theta.deinit();

    // Decode each slot's entries
    try context.push(.{ .field = "entries" });
    var slot: usize = 0;
    while (slot < params.epoch_length) : (slot += 1) {
        try context.push(.{ .array_index = slot });
        try decodeSlotEntries(allocator, context, &theta.entries[slot], reader);
        context.pop();
    }
    context.pop();

    return theta;
}

fn decodeSlotEntries(allocator: std.mem.Allocator, context: *DecodingContext, slot_entries: *available_reports.TimeslotEntries, reader: anytype) !void {
    const entry_count = codec.readInteger(reader) catch |err| {
        return context.makeError(error.EndOfStream, "failed to read entry count: {s}", .{@errorName(err)});
    };
    var i: usize = 0;
    while (i < entry_count) : (i += 1) {
        try context.push(.{ .array_index = i });
        const entry = try decodeEntry(allocator, context, reader);
        slot_entries.append(allocator, entry) catch |err| {
            return context.makeError(error.OutOfMemory, "failed to append entry: {s}", .{@errorName(err)});
        };
        context.pop();
    }
}

fn decodeEntry(allocator: std.mem.Allocator, context: *DecodingContext, reader: anytype) !available_reports.WorkReportAndDeps {
    // Decode work report
    try context.push(.{ .field = "work_report" });
    const work_report = codec.deserializeAlloc(WorkReport, {}, allocator, reader) catch |err| {
        return context.makeError(error.EndOfStream, "failed to decode work report: {s}", .{@errorName(err)});
    };
    context.pop();

    var entry = available_reports.WorkReportAndDeps{
        .work_report = work_report,
        .dependencies = .{},
    };

    // Decode dependencies
    try context.push(.{ .field = "dependencies" });
    const dependency_count = codec.readInteger(reader) catch |err| {
        return context.makeError(error.EndOfStream, "failed to read dependency count: {s}", .{@errorName(err)});
    };
    var i: usize = 0;
    while (i < dependency_count) : (i += 1) {
        try context.push(.{ .array_index = i });
        var hash: [32]u8 = undefined;
        reader.readNoEof(&hash) catch |err| {
            return context.makeError(error.EndOfStream, "failed to read dependency hash: {s}", .{@errorName(err)});
        };
        entry.dependencies.put(allocator, hash, {}) catch |err| {
            return context.makeError(error.OutOfMemory, "failed to add dependency: {s}", .{@errorName(err)});
        };
        context.pop();
    }
    context.pop();

    return entry;
}

test "encode/decode" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const createEmptyWorkReport = @import("../tests/fixtures.zig").createEmptyWorkReport;
    const params = comptime DecoderParams{
        .epoch_length = 4,
    };

    var context = DecodingContext.init(allocator);
    defer context.deinit();

    // Create test data
    var original = available_reports.Theta(params.epoch_length).init(allocator);
    defer original.deinit();

    var entry1 = available_reports.WorkReportAndDeps{
        .work_report = createEmptyWorkReport([_]u8{1} ** 32),
        .dependencies = .{},
    };
    try entry1.dependencies.put(allocator, [_]u8{3} ** 32, {});

    var entry2 = available_reports.WorkReportAndDeps{
        .work_report = createEmptyWorkReport([_]u8{2} ** 32),
        .dependencies = .{},
    };
    try entry2.dependencies.put(allocator, [_]u8{4} ** 32, {});

    try original.addEntryToTimeSlot(0, entry1);
    try original.addEntryToTimeSlot(2, entry2);

    // Encode
    var buffer: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try @import("../state_encoding/theta.zig").encode(&original, fbs.writer());

    // Decode
    var stream = std.io.fixedBufferStream(fbs.getWritten());
    var decoded = try decode(params, allocator, &context, stream.reader());
    defer decoded.deinit();

    // Verify
    try testing.expectEqual(@as(usize, 1), decoded.entries[0].items.len);
    try testing.expectEqual(@as(usize, 1), decoded.entries[2].items.len);
    try testing.expectEqualSlices(u8, &[_]u8{1} ** 32, &decoded.entries[0].items[0].work_report.package_spec.hash);
    try testing.expectEqualSlices(u8, &[_]u8{2} ** 32, &decoded.entries[2].items[0].work_report.package_spec.hash);
}
