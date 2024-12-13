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
const std = @import("std");

const types = @import("types.zig");
const WorkReport = types.WorkReport;
const TimeSlot = types.TimeSlot;
const OpaqueHash = types.OpaqueHash;
const WorkReportHash = types.WorkReportHash;
const RefineContext = types.RefineContext;
const WorkPackageSpec = types.WorkPackageSpec;
const CoreIndex = types.CoreIndex;

const trace = @import("tracing.zig").scoped(.rho);

pub const RhoEntry = struct {
    assignment: types.AvailabilityAssignment,
    core: u16,
    cached_hash: ?WorkReportHash = null,

    const Blake2b256 = std.crypto.hash.blake2.Blake2b256;

    pub fn init(core: u16, assignment: types.AvailabilityAssignment) @This() {
        const span = trace.span(.init_entry);
        defer span.deinit();
        span.debug("Initializing RhoEntry for core {d}", .{core});

        return .{
            .assignment = assignment,
            .core = core,
            .cached_hash = null,
        };
    }

    pub fn hash_uncached(self: *const @This(), allocator: std.mem.Allocator) !WorkReportHash {
        const span = trace.span(.hash_uncached);
        defer span.deinit();
        span.debug("Computing uncached hash for core {d}", .{self.core});

        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();

        const writer = buffer.writer();

        // TODO: the whitepaper specifies we should prepend the core, this does not
        // lead to a passing test vector, so now disabled for now.

        // // Write the core index (as u16/CoreIndex) in little-endian
        // try writer.writeInt(u16, self.core, .little);

        const codec = @import("codec.zig");
        try codec.serialize(WorkReport, .{}, writer, self.assignment.report);

        // Create final hash from the concatenated data
        var result: WorkReportHash = undefined;
        Blake2b256.hash(buffer.items, &result, .{});

        span.debug("Generated hash for core {d}: {s}", .{
            self.core,
            std.fmt.fmtSliceHexLower(&result),
        });
        return result;
    }

    pub fn hash(self: *@This(), allocator: std.mem.Allocator) !WorkReportHash {
        const span = trace.span(.hash);
        defer span.deinit();

        if (self.cached_hash == null) {
            span.debug("Cache miss for core {d}, computing hash", .{self.core});
            self.cached_hash = try self.hash_uncached(allocator);
        } else {
            span.debug("Using cached hash for core {d}", .{self.core});
        }

        return self.cached_hash.?;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        const span = trace.span(.deinit_entry);
        defer span.deinit();
        span.debug("Deinitializing RhoEntry for core {d}", .{self.core});

        self.assignment.deinit(allocator);
    }
};

pub fn Rho(comptime core_count: u16) type {
    return struct {
        reports: [core_count]?RhoEntry,
        allocator: std.mem.Allocator,

        pub fn format(
            self: *const @This(),
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            try @import("state_format/rho.zig").format(core_count, self, fmt, options, writer);
        }

        pub fn jsonStringify(self: *const @This(), jw: anytype) !void {
            try @import("state_json/pending_reports.zig").jsonStringify(core_count, self, jw);
        }

        pub fn init(allocator: std.mem.Allocator) @This() {
            const span = trace.span(.init);
            defer span.deinit();
            span.debug("Initializing Rho state with {d} cores", .{core_count});

            return @This(){
                .reports = [_]?RhoEntry{null} ** core_count,
                .allocator = allocator,
            };
        }

        pub fn setReport(self: *@This(), core: usize, assignment: types.AvailabilityAssignment) void {
            const span = trace.span(.set_report);
            defer span.deinit();
            span.debug("Setting report for core {d}", .{core});

            if (core >= core_count) {
                span.err("Core index {d} out of bounds (max {d})", .{ core, core_count - 1 });
                @panic("Core index out of bounds");
            }
            self.reports[core] = RhoEntry.init(@intCast(core), assignment);
        }

        pub fn getReport(self: *const @This(), core: usize) ?RhoEntry {
            const span = trace.span(.get_report);
            defer span.deinit();
            span.debug("Getting report for core {d}", .{core});

            if (core >= core_count) {
                span.err("Core index {d} out of bounds (max {d})", .{ core, core_count - 1 });
                @panic("Core index out of bounds");
            }
            return if (self.reports[core]) |entry| entry else null;
        }

        pub fn clearReport(self: *@This(), core: usize) void {
            const span = trace.span(.clear_report);
            defer span.deinit();
            span.debug("Clearing report for core {d}", .{core});

            if (core >= core_count) {
                span.err("Core index {d} out of bounds (max {d})", .{ core, core_count - 1 });
                @panic("Core index out of bounds");
            }
            self.reports[core] = null;
        }

        pub fn clearFromCore(self: *@This(), work_report_hash: WorkReportHash) !bool {
            const span = trace.span(.clear_from_core);
            defer span.deinit();
            span.debug("Searching for hash: {s}", .{std.fmt.fmtSliceHexLower(&work_report_hash)});

            for (&self.reports, 0..) |*report, index| {
                if (report.*) |*entry| {
                    const hash = try entry.hash(self.allocator);
                    span.trace("Core {d}: comparing entry hash: {s}", .{
                        index,
                        std.fmt.fmtSliceHexLower(&hash),
                    });

                    if (std.mem.eql(u8, &hash, &work_report_hash)) {
                        span.debug("Found matching hash at core {d}, clearing entry", .{index});
                        entry.deinit(self.allocator);
                        report.* = null;
                        return true;
                    }
                } else {
                    span.trace("Core {d}: empty entry", .{index});
                }
            }
            span.debug("Hash not found in any core", .{});
            return false;
        }

        pub fn deinit(self: *@This()) void {
            const span = trace.span(.deinit);
            defer span.deinit();
            span.debug("Deinitializing Rho state", .{});

            for (&self.reports) |*report| {
                if (report.*) |*entry| {
                    entry.deinit(self.allocator);
                }
            }
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
    const allocator = std.testing.allocator;

    var rho = Rho(TEST_C).init(allocator);
    defer rho.deinit();

    try testing.expectEqual(@as(usize, TEST_C), rho.reports.len);
    for (rho.reports) |report| {
        try testing.expectEqual(@as(?RhoEntry, null), report);
    }
}

test "Rho - Set and Get Report" {
    var rho = Rho(TEST_C).init(testing.allocator);
    defer rho.deinit();

    const work_report = createEmptyWorkReport(TEST_HASH);
    const timeslot = 100;

    // Test setting a report
    const assignment = types.AvailabilityAssignment{
        .report = work_report,
        .timeout = timeslot,
    };
    rho.setReport(0, assignment);
    const report = rho.getReport(0);
    try testing.expect(report != null);
    if (report) |r| {
        try testing.expectEqual(r.assignment.report.package_spec.hash, TEST_HASH);
        try testing.expectEqual(r.assignment.timeout, 100);
    }

    // Test getting a non-existent report
    const empty_report = rho.getReport(1);
    try testing.expectEqual(@as(?RhoEntry, null), empty_report);
}

test "Rho - Clear Report" {
    var rho = Rho(TEST_C).init(testing.allocator);
    defer rho.deinit();

    const work_report = createEmptyWorkReport(TEST_HASH);
    const timeslot = 100;

    // Set a report
    const assignment = types.AvailabilityAssignment{
        .report = work_report,
        .timeout = timeslot,
    };
    rho.setReport(0, assignment);
    try testing.expect(rho.getReport(0) != null);

    // Clear the report
    rho.clearReport(0);
    try testing.expectEqual(@as(?RhoEntry, null), rho.getReport(0));
}

test "Rho - Clear From Core" {
    var rho = Rho(TEST_C).init(testing.allocator);
    defer rho.deinit();

    const work_report1 = createEmptyWorkReport(TEST_HASH);
    const test_hash2 = [_]u8{ 'T', 'E', 'S', 'T', '2' } ++ [_]u8{0} ** 27;
    const work_report2 = createEmptyWorkReport(test_hash2);
    const timeslot = 100;

    // Set reports
    const assignment1 = types.AvailabilityAssignment{
        .report = work_report1,
        .timeout = timeslot,
    };
    const assignment2 = types.AvailabilityAssignment{
        .report = work_report2,
        .timeout = timeslot,
    };
    rho.setReport(0, assignment1);
    rho.setReport(1, assignment2);
    try testing.expect(rho.getReport(0) != null);
    try testing.expect(rho.getReport(1) != null);

    var entry_core_0 = rho.getReport(0);

    const cleared = try rho.clearFromCore(try entry_core_0.?.hash(testing.allocator));
    try testing.expect(cleared);

    // Check that the first report is cleared and the second is still present
    try testing.expectEqual(@as(?RhoEntry, null), rho.getReport(0));
    try testing.expect(rho.getReport(1) != null);
}

test "RhoEntry - Lazy Hash Calculation" {
    const work_report = createEmptyWorkReport(TEST_HASH);
    const timeslot = 100;
    const assignment = types.AvailabilityAssignment{
        .report = work_report,
        .timeout = timeslot,
    };

    var entry = RhoEntry.init(1, assignment);
    defer entry.deinit(testing.allocator);

    // Initially the hash should be null
    try testing.expect(entry.cached_hash == null);

    // Calculate hash
    const hash1 = try entry.hash(testing.allocator);

    // Hash should now be cached
    try testing.expect(entry.cached_hash != null);

    // Second calculation should use cached value
    const hash2 = try entry.hash(testing.allocator);
    try testing.expectEqualSlices(u8, &hash1, &hash2);
}
