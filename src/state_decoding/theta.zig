const std = @import("std");
const types = @import("../types.zig");
const available_reports = @import("../available_reports.zig");
const codec = @import("../codec.zig");
const WorkReport = types.WorkReport;

pub fn decode(comptime epoch_size: usize, allocator: std.mem.Allocator, reader: anytype) !available_reports.Theta(epoch_size) {
    var theta = available_reports.Theta(epoch_size).init(allocator);
    errdefer theta.deinit();

    // Decode each slot's entries
    var slot: usize = 0;
    while (slot < epoch_size) : (slot += 1) {
        try decodeSlotEntries(allocator, &theta.entries[slot], reader);
    }

    return theta;
}

fn decodeSlotEntries(allocator: std.mem.Allocator, slot_entries: *available_reports.SlotEntries, reader: anytype) !void {
    const entry_count = try codec.readInteger(reader);
    var i: usize = 0;
    while (i < entry_count) : (i += 1) {
        const entry = try decodeEntry(allocator, reader);
        try slot_entries.append(allocator, entry);
    }
}

fn decodeEntry(allocator: std.mem.Allocator, reader: anytype) !available_reports.Entry {
    // Decode work report
    const work_report = try codec.deserializeAlloc(WorkReport, {}, allocator, reader);

    var entry = available_reports.Entry{
        .work_report = work_report,
        .dependencies = .{},
    };

    // Decode dependencies
    const dependency_count = try codec.readInteger(reader);
    var i: usize = 0;
    while (i < dependency_count) : (i += 1) {
        var hash: [32]u8 = undefined;
        try reader.readNoEof(&hash);
        try entry.dependencies.put(allocator, hash, {});
    }

    return entry;
}

test "encode/decode" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const createEmptyWorkReport = @import("../tests/fixtures.zig").createEmptyWorkReport;

    // Create test data
    var original = available_reports.Theta(4).init(allocator);
    defer original.deinit();

    var entry1 = available_reports.Entry{
        .work_report = createEmptyWorkReport([_]u8{1} ** 32),
        .dependencies = .{},
    };
    try entry1.dependencies.put(allocator, [_]u8{3} ** 32, {});

    var entry2 = available_reports.Entry{
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
    var decoded = try decode(4, allocator, stream.reader());
    defer decoded.deinit();

    // Verify
    try testing.expectEqual(@as(usize, 1), decoded.entries[0].items.len);
    try testing.expectEqual(@as(usize, 1), decoded.entries[2].items.len);
    try testing.expectEqualSlices(u8, &[_]u8{1} ** 32, &decoded.entries[0].items[0].work_report.package_spec.hash);
    try testing.expectEqualSlices(u8, &[_]u8{2} ** 32, &decoded.entries[2].items[0].work_report.package_spec.hash);
}
