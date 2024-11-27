/// Rho (ρ) State Implementation
///
/// This file implements the rho (ρ) state for the Jam protocol. Rho is a critical
/// component of the reporting and availability system in Jam.
///
/// Purpose:
/// - Rho tracks work-reports that have been reported but are not yet known to be
///   available to a super-majority of validators.
/// - It maintains a mapping of cores to their currently assigned work-reports and
///   the time at which each report was made.
///
/// Key characteristics:
/// - There are C (341) cores, each capable of having one assigned work-report.
/// - Only one report may be assigned to a core at any given time.
/// - Each entry in rho contains a work-report and its reporting timeslot.
/// - Rho is used in the block production process to manage the lifecycle of
///   work-reports from reporting to availability confirmation.
///
/// This implementation provides functionality to:
/// - Initialize the rho state
/// - Set a work-report for a specific core
/// - Retrieve a work-report for a specific core
/// - Clear a work-report from a specific core
///
const std = @import("std");

const types = @import("types.zig");
const WorkReport = types.WorkReport;
const TimeSlot = types.TimeSlot;
const OpaqueHash = types.OpaqueHash;
const WorkReportHash = types.WorkReportHash;
const RefineContext = types.RefineContext;
const WorkPackageSpec = types.WorkPackageSpec;
const CoreIndex = types.CoreIndex;

const ReportEntry = struct {
    hash: WorkReportHash,
    work_report: WorkReport,
    timeslot: TimeSlot,
};

// Rho state
pub fn Rho(comptime core_count: u16) type {
    return struct {
        reports: [core_count]?ReportEntry,

        pub fn format(
            self: *const @This(),
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            try @import("state_format/rho.zig").format(self, fmt, options, writer);
        }

        pub fn init() @This() {
            return @This(){
                .reports = [_]?ReportEntry{null} ** core_count,
            };
        }

        pub fn setReport(self: *@This(), core: usize, hash: WorkReportHash, report: WorkReport, timeslot: TimeSlot) void {
            if (core >= core_count) {
                @panic("Core index out of bounds");
            }
            self.reports[core] = ReportEntry{ .hash = hash, .work_report = report, .timeslot = timeslot };
        }

        pub fn getReport(self: *const @This(), core: usize) ?ReportEntry {
            if (core >= core_count) {
                @panic("Core index out of bounds");
            }
            return self.reports[core];
        }

        pub fn clearReport(self: *@This(), core: usize) void {
            if (core >= core_count) {
                @panic("Core index out of bounds");
            }
            self.reports[core] = null;
        }

        pub fn clearFromCore(self: *@This(), work_report: WorkReportHash) bool {
            for (&self.reports) |*report| {
                if (report.*) |*entry| {
                    if (std.mem.eql(u8, &entry.hash, &work_report)) {
                        report.* = null;
                        return true;
                    }
                }
            }
            return false;
        }
    };
}

//  _____         _
// |_   _|__  ___| |_ ___
//   | |/ _ \/ __| __/ __|
//   | |  __/\__ \ |_\__ \
//   |_|\___||___/\__|___/
//

const testing = std.testing;

const createEmptyWorkReport = @import("tests/fixtures.zig").createEmptyWorkReport;

const TEST_C: u16 = 341; // Standard number of cores for testing
const TEST_HASH = [_]u8{ 'T', 'E', 'S', 'T' } ++ [_]u8{0} ** 28;

test "Rho - Initialization" {
    const rho = Rho(TEST_C).init();
    try testing.expectEqual(@as(usize, TEST_C), rho.reports.len);
    for (rho.reports) |report| {
        try testing.expectEqual(@as(?ReportEntry, null), report);
    }
}

test "Rho - Set and Get Report" {
    var rho = Rho(TEST_C).init();
    const work_report = createEmptyWorkReport(TEST_HASH);
    const timeslot = 100;

    // Test setting a report
    rho.setReport(0, TEST_HASH, work_report, timeslot);
    const report = rho.getReport(0);
    try testing.expect(report != null);
    if (report) |r| {
        try testing.expectEqual(r.work_report.package_spec.hash, TEST_HASH);
        try testing.expectEqual(r.timeslot, 100);
    }

    // Test getting a non-existent report
    const empty_report = rho.getReport(1);
    try testing.expectEqual(@as(?ReportEntry, null), empty_report);
}

test "Rho - Clear Report" {
    var rho = Rho(TEST_C).init();
    const work_report = createEmptyWorkReport(TEST_HASH);
    const timeslot = 100;

    // Set a report
    rho.setReport(0, TEST_HASH, work_report, timeslot);
    try testing.expect(rho.getReport(0) != null);

    // Clear the report
    rho.clearReport(0);
    try testing.expectEqual(@as(?ReportEntry, null), rho.getReport(0));
}

test "Rho - Clear From Core" {
    var rho = Rho(TEST_C).init();
    const work_report1 = createEmptyWorkReport(TEST_HASH);
    const test_hash2 = [_]u8{ 'T', 'E', 'S', 'T', '2' } ++ [_]u8{0} ** 27;
    const work_report2 = createEmptyWorkReport(test_hash2);
    const timeslot = 100;

    // Set reports
    rho.setReport(0, TEST_HASH, work_report1, timeslot);
    rho.setReport(1, test_hash2, work_report2, timeslot);
    try testing.expect(rho.getReport(0) != null);
    try testing.expect(rho.getReport(1) != null);

    // Clear report with TEST_HASH
    const cleared = rho.clearFromCore(TEST_HASH);
    try testing.expect(cleared);

    // Check that the first report is cleared and the second is still present
    try testing.expectEqual(@as(?ReportEntry, null), rho.getReport(0));
    try testing.expect(rho.getReport(1) != null);
    if (rho.getReport(1)) |report| {
        try testing.expectEqualSlices(u8, &report.hash, &test_hash2);
    }
}
