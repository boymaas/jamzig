const std = @import("std");
const testing = std.testing;
const pending_reports = @import("../reports_pending.zig");
const types = @import("../types.zig");
const Rho = pending_reports.Rho;
const codec = @import("../codec.zig");
const createEmptyWorkReport = @import("../tests/fixtures.zig").createEmptyWorkReport;
const jam_params = @import("../jam_params.zig");

const readInteger = @import("utils.zig").readInteger;

pub fn decode(comptime params: jam_params.Params, allocator: std.mem.Allocator, reader: anytype) !Rho(params.core_count) {
    var rho = Rho(params.core_count).init(allocator);

    // For each core
    for (&rho.reports, 0..) |*maybe_entry, core_index| {
        // Read existence marker
        const exists = try reader.readByte();
        if (exists == 1) {
            const assignment = try codec.deserializeAlloc(
                types.AvailabilityAssignment,
                params,
                allocator,
                reader,
            );

            maybe_entry.* = .{
                .core = @intCast(core_index),
                .assignment = assignment,
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
}

// TODO: test encoding/decoding of the WorkResult and the WorkExecResults
test "decode rho - roundtrip" {
    const encoder = @import("../state_encoding/rho.zig");
    const core_count = 2;
    const params = @import("../jam_params.zig").TINY_PARAMS;

    // Create original rho state
    var original = Rho(core_count).init(testing.allocator);

    // Add a report
    const hash = [_]u8{1} ** 32;
    const report = createEmptyWorkReport(hash);
    original.setReport(0, .{ .report = report, .timeout = 100 });

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
    try testing.expectEqual(@as(u32, 100), entry.assignment.timeout);

    // Verify second core is null
    try testing.expect(decoded.reports[1] == null);
}
