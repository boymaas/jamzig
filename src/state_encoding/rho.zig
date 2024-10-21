const std = @import("std");

const types = @import("../types.zig");
const WorkReport = types.WorkReport;

const encoder = @import("../codec/encoder.zig");
const codec = @import("../codec.zig");

const pending_reports = @import("../pending_reports.zig");
const Rho = pending_reports.Rho;

pub fn encode(self: *const Rho, writer: anytype) !void {
    // The number of cores (C) is not encoded as it is a constant

    // Encode each report entry
    for (self.reports) |maybe_entry| {
        if (maybe_entry) |entry| {
            // Entry exists
            try writer.writeByte(1);

            // Encode hash
            try writer.writeAll(&entry.hash);

            // Encode work report
            try codec.serialize(WorkReport, .{}, writer, entry.work_report);

            // Encode timeslot
            var buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &buf, entry.timeslot, .little);
            try writer.writeAll(&buf);
        } else {
            // No entry
            try writer.writeByte(0);
        }
    }
}

const createEmptyWorkReport = @import("../tests/fixtures.zig").createEmptyWorkReport;

const TEST_HASH = [_]u8{ 'T', 'E', 'S', 'T' } ++ [_]u8{0} ** 28;

test "encode" {
    var rho = Rho.init();
    const work_report1 = createEmptyWorkReport(TEST_HASH);
    const test_hash2 = [_]u8{ 'T', 'E', 'S', 'T', '2' } ++ [_]u8{0} ** 27;
    const work_report2 = createEmptyWorkReport(test_hash2);
    const timeslot = 100;

    // Set reports
    rho.setReport(0, TEST_HASH, work_report1, timeslot);
    rho.setReport(1, test_hash2, work_report2, timeslot);

    // Mock writer
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();
    var writer = buffer.writer();

    // Encode the Rho state
    try encode(&rho, &writer);

    // TODO: test the encode output in more detail
    // // Verify the encoded output
    // const expected_output = &[_]u8{
    //     1, // Entry exists
    //     'T', 'E', 'S', 'T', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // Hash
    //     // WorkReport serialization would go here
    //     100, 0, 0, 0, // Timeslot in little-endian
    //     1, // Entry exists
    //     'T', 'E', 'S', 'T', '2', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // Hash
    //     // WorkReport serialization would go here
    //     100, 0, 0, 0, // Timeslot in little-endian
    //     0, // No entry
    //     // Remaining entries would be 0
    // };
    //
    // try testing.expectEqualSlices(u8, expected_output, buffer.items);
}
