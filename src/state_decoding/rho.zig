const std = @import("std");
const testing = std.testing;
const pending_reports = @import("../pending_reports.zig");
const types = @import("../types.zig");
const Rho = pending_reports.Rho;
const codec = @import("../codec.zig");
const createEmptyWorkReport = @import("../tests/fixtures.zig").createEmptyWorkReport;
const jam_params = @import("../jam_params.zig");

const readInteger = @import("utils.zig").readInteger;

pub fn decode(comptime params: jam_params.Params, allocator: std.mem.Allocator, reader: anytype) !Rho(params.core_count) {
    var rho = Rho(params.core_count).init();

    // For each core
    for (&rho.reports) |*maybe_entry| {
        // Read existence marker
        const exists = try reader.readByte();
        if (exists == 1) {
            // Read report entry
            var hash: [32]u8 = undefined;
            try reader.readNoEof(&hash);

            // TODO: deserialize the work_report
            const work_report = try codec.deserializeAlloc(types.WorkReport, params, allocator, reader);

            const timeslot = try reader.readInt(u32, .little);

            maybe_entry.* = .{
                .hash = hash,
                .work_report = work_report,
                .timeslot = timeslot,
            };
        } else if (exists == 0) {
            maybe_entry.* = null;
        } else {
            return error.InvalidExistenceMarker;
        }
    }

    return rho;
}

test "decode rho - empty state" {
    const core_count = 2;

    // Create buffer with all null entries
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // Write existence marker 0 for each core
    for (0..core_count) |_| {
        try buffer.append(0);
    }

    var fbs = std.io.fixedBufferStream(buffer.items);
    const rho = try decode(.{ .core_count = core_count }, std.testing.allocator, fbs.reader());

    // Verify all entries are null
    for (rho.reports) |maybe_entry| {
        try testing.expect(maybe_entry == null);
    }
}

test "decode rho - with reports" {
    const core_count = 2;

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // Write report for first core
    try buffer.append(1); // exists
    try buffer.appendSlice(&[_]u8{1} ** 32); // hash

    const report1 = createEmptyWorkReport([_]u8{1} ** 32);
    try codec.serialize(types.WorkReport, {}, buffer.writer(), report1);
    try buffer.writer().writeInt(u32, 100, .little); // timeslot

    // Write null for second core
    try buffer.append(0);

    var fbs = std.io.fixedBufferStream(buffer.items);
    const rho = try decode(.{ .core_count = core_count }, std.testing.allocator, fbs.reader());

    // Verify first core report
    const entry1 = rho.reports[0].?;
    try testing.expectEqualSlices(u8, &[_]u8{1} ** 32, &entry1.hash);
    try testing.expectEqualSlices(u8, &[_]u8{1} ** 32, &entry1.work_report.package_spec.hash);
    try testing.expectEqual(@as(u32, 100), entry1.timeslot);

    // Verify second core is null
    try testing.expect(rho.reports[1] == null);
}

test "decode rho - invalid existence marker" {
    const core_count = 1;

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // Write invalid existence marker
    try buffer.append(2);

    var fbs = std.io.fixedBufferStream(buffer.items);
    try testing.expectError(error.InvalidExistenceMarker, decode(
        .{ .core_count = core_count },
        std.testing.allocator,
        fbs.reader(),
    ));
}

test "decode rho - insufficient data" {
    const core_count = 1;

    // Test truncated hash
    {
        var buffer = std.ArrayList(u8).init(testing.allocator);
        defer buffer.deinit();

        try buffer.append(1); // exists
        try buffer.appendSlice(&[_]u8{1} ** 16); // partial hash

        var fbs = std.io.fixedBufferStream(buffer.items);
        try testing.expectError(error.EndOfStream, decode(
            .{ .core_count = core_count },
            std.testing.allocator,
            fbs.reader(),
        ));
    }

    // Test truncated timeslot
    {
        var buffer = std.ArrayList(u8).init(testing.allocator);
        defer buffer.deinit();

        try buffer.append(1); // exists
        try buffer.appendSlice(&[_]u8{1} ** 32); // hash
        const report = createEmptyWorkReport([_]u8{1} ** 32);
        try codec.serialize(types.WorkReport, {}, buffer.writer(), report);
        try buffer.appendSlice(&[_]u8{1} ** 2); // partial timeslot

        var fbs = std.io.fixedBufferStream(buffer.items);
        try testing.expectError(error.EndOfStream, decode(.{ .core_count = core_count }, std.testing.allocator, fbs.reader()));
    }
}

test "decode rho - roundtrip" {
    const encoder = @import("../state_encoding/rho.zig");
    const core_count = 2;
    const params = @import("../jam_params.zig").TINY_PARAMS;

    // Create original rho state
    var original = Rho(core_count).init();

    // Add a report
    const hash = [_]u8{1} ** 32;
    const report = createEmptyWorkReport(hash);
    original.setReport(0, hash, report, 100);

    // Encode
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();
    try encoder.encode(params, &original, buffer.writer());

    // Decode
    var fbs = std.io.fixedBufferStream(buffer.items);
    const decoded = try decode(params, std.testing.allocator, fbs.reader());

    // Verify first core
    try testing.expect(decoded.reports[0] != null);
    const entry = decoded.reports[0].?;
    try testing.expectEqualSlices(u8, &hash, &entry.hash);
    try testing.expectEqualSlices(u8, &hash, &entry.work_report.package_spec.hash);
    try testing.expectEqual(@as(u32, 100), entry.timeslot);

    // Verify second core is null
    try testing.expect(decoded.reports[1] == null);
}
