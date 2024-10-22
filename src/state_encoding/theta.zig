const std = @import("std");
const types = @import("../types.zig");
const WorkReport = types.WorkReport;
const encoder = @import("../codec/encoder.zig");
const codec = @import("../codec.zig");
const sort = std.sort;

const available_reports = @import("../available_reports.zig");
const Theta = available_reports.Theta;

const makeLessThanSliceOfFn = @import("../utils/sort.zig").makeLessThanSliceOfFn;
const lessThanSliceOfHashes = makeLessThanSliceOfFn(types.Hash);

/// Theta (ϑ) is defined as a sequence of work reports and their dependencies: ⟦(W, {H})⟧E
/// where W is a work report and H is a set of 32-byte hashes representing unaccumulated dependencies
pub fn encode(theta: anytype, writer: anytype) !void {
    // Encode each entry
    for (theta.entries) |slot_entry| {
        // Encode the dependencies set
        // First write number of dependencies
        try writer.writeAll(encoder.encodeInteger(slot_entry.items.len).as_slice());
        for (slot_entry.items) |entry| {
            try encodeEntry(theta.allocator, entry, writer);
        }
    }
}

pub fn encodeSlotEntry(allocator: std.mem.Allocator, slot_entries: Theta.SlotEntries, writer: anytype) !void {
    try writer.writeAll(encoder.encodeInteger(slot_entries.items.len).as_slice());
    for (slot_entries.items) |entry| {
        try encodeEntry(allocator, entry, writer);
    }
}

pub fn encodeEntry(allocator: std.mem.Allocator, entry: available_reports.Entry, writer: anytype) !void {
    // Encode the work report
    try codec.serialize(WorkReport, {}, writer, entry.work_report);

    // Encode the dependencies
    const dependency_count = entry.dependencies.count();
    try writer.writeAll(encoder.encodeInteger(dependency_count).as_slice());

    // TODO: this pattern of having a dictionary and needing to sort by key
    // is all over the place, we need a utility for this.
    var keys = entry.dependencies.keyIterator();
    var key_list = try std.ArrayList(types.Hash).initCapacity(allocator, dependency_count);
    defer key_list.deinit();

    while (keys.next()) |hash| {
        try key_list.append(hash.*);
    }

    // NOTE: assuming short lists of deps
    sort.insertion([32]u8, key_list.items, {}, lessThanSliceOfHashes);

    for (key_list.items) |hash| {
        try writer.writeAll(&hash);
    }
}

// Tests

const testing = std.testing;

test "encode" {
    const allocator = testing.allocator;
    const createEmptyWorkReport = @import("../tests/fixtures.zig").createEmptyWorkReport;

    // Create a sample ThetaEntry slice
    var entry1 = available_reports.Entry{
        .work_report = createEmptyWorkReport([_]u8{1} ** 32),
        .dependencies = .{},
    };
    // Note out of order
    try entry1.dependencies.put(allocator, [_]u8{4} ** 32, {});
    try entry1.dependencies.put(allocator, [_]u8{3} ** 32, {});

    var entry2 = available_reports.Entry{
        .work_report = createEmptyWorkReport([_]u8{5} ** 32),
        .dependencies = .{},
    };
    try entry2.dependencies.put(allocator, [_]u8{7} ** 32, {});

    var theta = Theta(12).init(allocator);
    defer theta.deinit();

    try theta.addEntryToTimeSlot(0, entry1);
    try theta.addEntryToTimeSlot(3, entry2);

    // Buffer
    var buffer: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);

    try encode(&theta, fbs.writer());

    const written = fbs.getWritten();

    const expected = // The expected payout
        [_]u8{0x01} // Number of entries Slot 0
    ++ [_]u8{0x01} ** 32 ++ [_]u8{0} ** (269 - 32) // Empty Work report
    ++ [_]u8{0x02} // Number of dependencies}
    ++ [_]u8{3} ** 32 // Dependency 2 => sorted
    ++ [_]u8{4} ** 32 // Dependency 1
    ++ [_]u8{0x00} // Number of entries Slot 1
    ++ [_]u8{0x00} // Number of entries Slot 2
    ++ [_]u8{0x01} // Number of entries Slot 1
    ++ [_]u8{0x05} ** 32 ++ [_]u8{0} ** (269 - 32) // Empty Work report
    ++ [_]u8{0x01} // Number of dependencies}
    ++ [_]u8{7} ** 32 // Dependency 1
    ;

    try testing.expectEqualSlices(u8, &expected, written[0..expected.len]);
    // Check that the rest of the written memory is all zeros
    for (written[expected.len..]) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }

    // Check that the total length is as expected, just 0 lengths for all the other slots
    try testing.expectEqual(@as(usize, expected.len + 12 - 4), written.len);
}
