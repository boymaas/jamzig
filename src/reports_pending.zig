const std = @import("std");

const types = @import("types.zig");
const WorkReport = types.WorkReport;
const TimeSlot = types.TimeSlot;
const OpaqueHash = types.OpaqueHash;
const WorkReportHash = types.WorkReportHash;
const RefineContext = types.RefineContext;
const WorkPackageSpec = types.WorkPackageSpec;
const CoreIndex = types.CoreIndex;

const trace = @import("tracing").scoped(.rho);

pub const RhoEntry = struct {
    assignment: types.AvailabilityAssignment,
    core: u16,
    cached_hash: ?WorkReportHash = null,

    const Blake2b256 = std.crypto.hash.blake2.Blake2b256;

    pub fn init(core: u16, assignment: types.AvailabilityAssignment) @This() {
        const span = trace.span(@src(), .init_entry);
        defer span.deinit();
        span.debug("Initializing RhoEntry for core {d}", .{core});

        return .{
            .assignment = assignment,
            .core = core,
            .cached_hash = null,
        };
    }

    pub fn hash_uncached(self: *const @This(), allocator: std.mem.Allocator) !WorkReportHash {
        const span = trace.span(@src(), .hash_uncached);
        defer span.deinit();
        span.debug("Computing uncached hash for core {d}", .{self.core});

        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();

        const writer = buffer.writer();

        const codec = @import("codec.zig");
        try codec.serialize(WorkReport, .{}, writer, self.assignment.report);

        var result: WorkReportHash = undefined;
        Blake2b256.hash(buffer.items, &result, .{});

        span.debug("Generated hash for core {d}: {s}", .{
            self.core,
            std.fmt.fmtSliceHexLower(&result),
        });
        return result;
    }

    pub fn hash(self: *@This(), allocator: std.mem.Allocator) !WorkReportHash {
        const span = trace.span(@src(), .hash);
        defer span.deinit();

        if (self.cached_hash == null) {
            span.debug("Cache miss for core {d}, computing hash", .{self.core});
            self.cached_hash = try self.hash_uncached(allocator);
        } else {
            span.debug("Using cached hash for core {d}", .{self.core});
        }

        return self.cached_hash.?;
    }

    pub fn deepClone(self: *const @This(), allocator: std.mem.Allocator) !RhoEntry {
        const span = trace.span(@src(), .deep_clone);
        defer span.deinit();
        span.debug("Deep cloning RhoEntry for core {d}", .{self.core});

        return RhoEntry{
            .core = self.core,
            .cached_hash = self.cached_hash,
            .assignment = try self.assignment.deepClone(allocator),
        };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        const span = trace.span(@src(), .deinit_entry);
        defer span.deinit();
        span.debug("Deinitializing RhoEntry for core {d}", .{self.core});

        self.assignment.deinit(allocator);
        self.* = undefined;
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
            const tfmt = @import("types/fmt.zig");
            const formatter = tfmt.Format(@TypeOf(self.*)){
                .value = self.*,
                .options = .{},
            };
            try formatter.format(fmt, options, writer);
        }


        pub fn init(allocator: std.mem.Allocator) @This() {
            const span = trace.span(@src(), .init);
            defer span.deinit();
            span.debug("Initializing Rho state with {d} cores", .{core_count});

            return @This(){
                .reports = [_]?RhoEntry{null} ** core_count,
                .allocator = allocator,
            };
        }

        pub fn setReport(self: *@This(), core: usize, assignment: types.AvailabilityAssignment) void {
            const span = trace.span(@src(), .set_report);
            defer span.deinit();
            span.debug("Setting report for core {d}", .{core});
            std.debug.assert(core < core_count);

            self.reports[core] = RhoEntry.init(@intCast(core), assignment);
        }

        pub fn getReport(self: *const @This(), core: usize) ?RhoEntry {
            const span = trace.span(@src(), .get_report);
            defer span.deinit();
            span.debug("Getting report for core {d}", .{core});
            std.debug.assert(core < core_count);

            return self.reports[core];
        }

        pub fn getReportCloned(self: *const @This(), allocator: std.mem.Allocator, core: usize) !?RhoEntry {
            const span = trace.span(@src(), .get_report_owned);
            defer span.deinit();
            span.debug("Getting owned (deep clone) report for core {d}", .{core});
            std.debug.assert(core < core_count);

            if (self.reports[core]) |entry| {
                return entry.deepClone(allocator);
            }
            return null;
        }

        pub fn hasReport(self: *const @This(), core: usize) bool {
            const span = trace.span(@src(), .has_report);
            defer span.deinit();
            span.debug("Checking report presence for core {d}", .{core});
            std.debug.assert(core < core_count);

            return self.reports[core] != null;
        }

        pub fn isEngaged(self: *const @This(), core: usize) bool {
            const span = trace.span(@src(), .is_engaged);
            defer span.deinit();
            span.debug("Checking if core {d} is engaged", .{core});
            std.debug.assert(core < core_count);

            return self.reports[core] != null;
        }

        pub fn takeReport(self: *@This(), core: usize) ?RhoEntry {
            const span = trace.span(@src(), .take_report);
            defer span.deinit();
            span.debug("Taking ownership of report for core {d}", .{core});
            std.debug.assert(core < core_count);

            if (self.reports[core]) |entry| {
                self.reports[core] = null;
                return entry;
            }

            return null;
        }

        pub fn clearReport(self: *@This(), core: usize) void {
            const span = trace.span(@src(), .clear_report);
            defer span.deinit();
            span.debug("Clearing report for core {d}", .{core});
            std.debug.assert(core < core_count);

            if (self.reports[core]) |report| {
                report.deinit(self.allocator);
                self.reports[core] = null;
            }
        }

        pub fn clearFromCore(self: *@This(), work_report_hash: WorkReportHash) !bool {
            const span = trace.span(@src(), .clear_from_core);
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

        pub fn deepClone(self: *const @This(), allocator: std.mem.Allocator) !@This() {
            const span = trace.span(@src(), .deep_clone);
            defer span.deinit();
            span.debug("Deep cloning Rho state with {d} cores", .{core_count});

            var cloned = @This().init(allocator);

            for (self.reports, 0..) |maybe_report, index| {
                span.trace("Processing core {d}", .{index});
                if (maybe_report) |report| {
                    span.debug("Cloning report for core {d}", .{index});
                    cloned.reports[index] = try report.deepClone(allocator);
                } else {
                    span.trace("Core {d} has no report to clone", .{index});
                    cloned.reports[index] = null;
                }
            }

            return cloned;
        }

        pub fn deinit(self: *@This()) void {
            const span = trace.span(@src(), .deinit);
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

const testing = std.testing;

const createEmptyWorkReport = @import("tests/fixtures.zig").createEmptyWorkReport;
const TEST_HASH = [_]u8{ 'T', 'E', 'S', 'T' } ++ [_]u8{0} ** 28;

test "RhoEntry - Lazy Hash Calculation" {
    const work_report = createEmptyWorkReport(TEST_HASH);
    const timeslot = 100;
    const assignment = types.AvailabilityAssignment{
        .report = work_report,
        .timeout = timeslot,
    };

    var entry = RhoEntry.init(1, assignment);
    defer entry.deinit(testing.allocator);

    try testing.expect(entry.cached_hash == null);

    const hash1 = try entry.hash(testing.allocator);

    try testing.expect(entry.cached_hash != null);

    const hash2 = try entry.hash(testing.allocator);
    try testing.expectEqualSlices(u8, &hash1, &hash2);
}
