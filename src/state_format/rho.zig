const std = @import("std");
const Rho = @import("../pending_reports.zig").Rho;

const tfmt = @import("../types/fmt.zig");

pub fn format(
    comptime core_count: u32,
    self: *const Rho(core_count),
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;

    var indented_writer = tfmt.IndentedWriter(@TypeOf(writer)).init(writer);
    var iw = indented_writer.writer();

    try iw.writeAll("Rho: (omitted cores are null)\n");
    iw.context.indent();
    defer iw.context.outdent();

    for (self.reports, 0..) |entry, i| {
        if (entry) |e| {
            const hash = e.cached_hash orelse try e.hash_uncached(self.allocator);
            try iw.print("Core {d}:\n", .{i});
            iw.context.indent();
            defer iw.context.outdent();

            try iw.print("work_package_hash: {s}\n", .{std.fmt.fmtSliceHexLower(&hash)});
            try iw.print("assignment: ", .{});

            // Format the assignment
            iw.context.indent();
            defer iw.context.outdent();

            try tfmt.formatValue(e.assignment, iw);
        } else {
            // try iw.print("Core {d}: no pending reports\n", .{i});
        }
    }
}

const testing = std.testing;
const createEmptyWorkReport = @import("../tests/fixtures.zig").createEmptyWorkReport;
const types = @import("../types.zig");

test "Rho - Format Output" {
    // Initialize test allocator
    const allocator = testing.allocator;

    // Create a test Rho instance with a small number of cores for readability
    const TEST_CORES: u16 = 3;
    var rho = Rho(TEST_CORES).init(allocator);
    defer rho.deinit();

    // Create some test data
    const TEST_HASH_1 = [_]u8{ 'T', 'E', 'S', 'T', '1' } ++ [_]u8{0} ** 27;
    const TEST_HASH_2 = [_]u8{ 'T', 'E', 'S', 'T', '2' } ++ [_]u8{0} ** 27;
    const work_report1 = createEmptyWorkReport(TEST_HASH_1);
    const work_report2 = createEmptyWorkReport(TEST_HASH_2);
    const timeslot1: u64 = 100;
    const timeslot2: u64 = 200;

    // Set up assignments for different cores
    const assignment1 = types.AvailabilityAssignment{
        .report = work_report1,
        .timeout = timeslot1,
    };
    const assignment2 = types.AvailabilityAssignment{
        .report = work_report2,
        .timeout = timeslot2,
    };

    // Populate some cores, leaving one empty
    rho.setReport(0, assignment1);
    rho.setReport(2, assignment2);
    // Core 1 remains empty

    std.debug.print("\n{s}\n", .{rho});
}
