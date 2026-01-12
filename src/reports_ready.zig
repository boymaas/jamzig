
const std = @import("std");
const types = @import("types.zig");
const WorkReport = types.WorkReport;
const HashSet = @import("datastruct/hash_set.zig").HashSet;

pub const TimeslotEntries = std.ArrayListUnmanaged(WorkReportAndDeps);
pub const WorkPackageHashSet = std.AutoArrayHashMapUnmanaged(types.WorkPackageHash, void);

pub fn VarTheta(comptime epoch_size: usize) type {
    return struct {
        entries: [epoch_size]TimeslotEntries,
        allocator: std.mem.Allocator,

        pub const Entry = WorkReportAndDeps;

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .entries = [_]TimeslotEntries{.{}} ** epoch_size,
                .allocator = allocator,
            };
        }

        pub fn addEntryToTimeSlot(
            self: *@This(),
            time_slot: types.TimeSlot,
            entry: WorkReportAndDeps,
        ) !void {
            try self.entries[time_slot].append(self.allocator, entry);
        }

        pub fn clearTimeSlot(self: *@This(), time_slot: types.TimeSlot) void {
            for (self.entries[time_slot].items) |*entry| {
                entry.deinit(self.allocator);
            }
            self.entries[time_slot].clearRetainingCapacity();
        }

        pub fn addWorkReport(
            self: *@This(),
            time_slot: types.TimeSlot,
            work_report: WorkReport,
        ) !void {
            var entry = try WorkReportAndDeps.fromWorkReport(self.allocator, work_report);
            errdefer entry.deinit(self.allocator);

            try self.addEntryToTimeSlot(time_slot, entry);
        }

        pub fn removeReportsWithoutDependenciesAtSlot(self: *@This(), time_slot: types.TimeSlot) void {
            var slot_entries = &self.entries[time_slot];
            var i: usize = 0;
            while (i < slot_entries.items.len) {
                if (slot_entries.items[i].dependencies.count() == 0) {
                    var item = slot_entries.orderedRemove(i);
                    item.deinit(self.allocator);
                    continue;
                }
                i += 1;
            }
        }

        pub fn removeReportsWithoutDependencies(self: *@This()) void {
            for (0..self.entries.len) |slot| {
                self.removeReportsWithoutDependenciesAtSlot(@intCast(slot));
            }
        }

        pub fn getReportsAtSlot(self: *const @This(), time_slot: types.TimeSlot) []const WorkReportAndDeps {
            return self.entries[time_slot].items;
        }

        const Iterator = struct {
            starting_epoch: u32,

            processed_epochs: u32 = 0,
            processed_entry_in_epoch_entry: usize = 0,

            theta: *VarTheta(epoch_size),

            pub fn next(self: *@This()) ?*WorkReportAndDeps {
                if (self.processed_epochs >= epoch_size) {
                    return null;
                }

                const current_epoch = @mod(
                    self.starting_epoch + self.processed_epochs,
                    epoch_size,
                );
                const current_epoch_entry = self.theta.entries[current_epoch];

                if (self.processed_entry_in_epoch_entry >= current_epoch_entry.items.len) {
                    self.processed_epochs += 1;
                    self.processed_entry_in_epoch_entry = 0;
                    return self.next();
                }

                self.processed_entry_in_epoch_entry += 1;
                return &current_epoch_entry.items[self.processed_entry_in_epoch_entry - 1];
            }
        };

        /// Creates an iterator returning all the entries starting from starting epoch
        /// wrapping around until all epochs are covered
        pub fn iteratorStartingFrom(self: *@This(), starting_epoch: u32) Iterator {
            return .{ .theta = self, .starting_epoch = starting_epoch };
        }

        pub fn deepClone(self: @This(), allocator: std.mem.Allocator) !@This() {
            var cloned = @This(){
                .entries = undefined,
                .allocator = allocator,
            };
            errdefer cloned.deinit();

            cloned.entries = [_]TimeslotEntries{.{}} ** epoch_size;

            for (self.entries, 0..) |slot_entries, i| {
                try cloned.entries[i].ensureTotalCapacity(allocator, slot_entries.items.len);

                for (slot_entries.items) |entry| {
                    const cloned_entry = try entry.deepClone(allocator);
                    try cloned.entries[i].append(allocator, cloned_entry);
                }
            }

            return cloned;
        }

        pub fn deinit(self: *@This()) void {
            for (&self.entries) |*slot_entries| {
                for (slot_entries.items) |*entry| {
                    entry.deinit(self.allocator);
                }
                slot_entries.deinit(self.allocator);
            }
            self.* = undefined;
        }

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
    };
}

pub const WorkReportAndDeps = struct {
    /// a work report
    work_report: WorkReport,
    /// set of work package hashes
    dependencies: WorkPackageHashSet,

    pub fn initWithDependencies(
        allocator: std.mem.Allocator,
        work_report: WorkReport,
        dependencies: []const [32]u8,
    ) !WorkReportAndDeps {
        var deps = WorkPackageHashSet{};
        errdefer deps.deinit(allocator);

        for (dependencies) |dep| {
            try deps.put(allocator, dep, {});
        }

        return WorkReportAndDeps{
            .work_report = work_report,
            .dependencies = deps,
        };
    }

    pub fn fromWorkReport(allocator: std.mem.Allocator, work_report: WorkReport) !WorkReportAndDeps {
        var work_report_and_deps = @This(){ .work_report = work_report, .dependencies = .{} };
        for (work_report.context.prerequisites) |work_package_hash| {
            try work_report_and_deps.dependencies.put(allocator, work_package_hash, {});
        }
        for (work_report.segment_root_lookup) |srl| {
            try work_report_and_deps.dependencies.put(allocator, srl.work_package_hash, {});
        }
        return work_report_and_deps;
    }

    pub fn deinit(self: *WorkReportAndDeps, allocator: std.mem.Allocator) void {
        self.work_report.deinit(allocator);
        self.dependencies.deinit(allocator);
        self.* = undefined;
    }

    pub fn deepClone(self: WorkReportAndDeps, allocator: std.mem.Allocator) !WorkReportAndDeps {
        var cloned_dependencies = WorkPackageHashSet{};

        var iter = self.dependencies.iterator();
        while (iter.next()) |entry| {
            try cloned_dependencies.put(allocator, entry.key_ptr.*, {});
        }

        return WorkReportAndDeps{
            .work_report = try self.work_report.deepClone(allocator),
            .dependencies = cloned_dependencies,
        };
    }
};

const testing = std.testing;

test "Theta - getReportsAtSlot" {
    const allocator = std.testing.allocator;
    const createEmptyWorkReport = @import("tests/fixtures.zig").createEmptyWorkReport;

    var theta = VarTheta(12).init(allocator);
    defer theta.deinit();

    const work_report1 = createEmptyWorkReport([_]u8{1} ** 32);
    const work_report2 = createEmptyWorkReport([_]u8{2} ** 32);

    const entry1 = VarTheta(12).Entry{
        .work_report = work_report1,
        .dependencies = .{},
    };
    const entry2 = VarTheta(12).Entry{
        .work_report = work_report2,
        .dependencies = .{},
    };

    try theta.addEntryToTimeSlot(2, entry1);
    try theta.addEntryToTimeSlot(2, entry2);

    try testing.expectEqual(@as(usize, 0), theta.getReportsAtSlot(0).len);

    const slot_2_reports = theta.getReportsAtSlot(2);
    try testing.expectEqual(@as(usize, 2), slot_2_reports.len);
    try testing.expectEqual(work_report1, slot_2_reports[0].work_report);
    try testing.expectEqual(work_report2, slot_2_reports[1].work_report);
}

test "Theta - init, add entries, and verify" {
    const allocator = std.testing.allocator;
    const createEmptyWorkReport = @import("tests/fixtures.zig").createEmptyWorkReport;

    var theta = VarTheta(12).init(allocator);
    defer theta.deinit();

    const work_report = createEmptyWorkReport([_]u8{1} ** 32);

    var entry = VarTheta(12).Entry{
        .work_report = work_report,
        .dependencies = .{},
    };

    const dependency = [_]u8{ 1, 2, 3 } ++ [_]u8{0} ** 29;
    try entry.dependencies.put(allocator, dependency, {});

    try theta.addEntryToTimeSlot(2, entry);

    try testing.expectEqual(@as(usize, 12), theta.entries.len);
    try testing.expectEqual(@as(usize, 1), theta.entries[2].items.len);
    try testing.expectEqual(work_report, theta.entries[2].items[0].work_report);
    try testing.expectEqual(@as(usize, 1), theta.entries[2].items[0].dependencies.count());
    try testing.expect(theta.entries[2].items[0].dependencies.contains(dependency));
}

test "Theta - iterator basic functionality" {
    const allocator = std.testing.allocator;
    const createEmptyWorkReport = @import("tests/fixtures.zig").createEmptyWorkReport;

    var theta = VarTheta(12).init(allocator);
    defer theta.deinit();

    const work_report1 = createEmptyWorkReport([_]u8{1} ** 32);
    const work_report2 = createEmptyWorkReport([_]u8{2} ** 32);
    const work_report3 = createEmptyWorkReport([_]u8{3} ** 32);

    const entry1 = VarTheta(12).Entry{
        .work_report = work_report1,
        .dependencies = .{},
    };
    const entry2 = VarTheta(12).Entry{
        .work_report = work_report2,
        .dependencies = .{},
    };
    const entry3 = VarTheta(12).Entry{
        .work_report = work_report3,
        .dependencies = .{},
    };

    try theta.addEntryToTimeSlot(2, entry1);
    try theta.addEntryToTimeSlot(5, entry2);
    try theta.addEntryToTimeSlot(11, entry3);

    var iterator = theta.iteratorStartingFrom(0);
    try testing.expect(std.mem.eql(u8, &iterator.next().?.work_report.package_spec.hash, &[_]u8{1} ** 32));
    try testing.expect(std.mem.eql(u8, &iterator.next().?.work_report.package_spec.hash, &[_]u8{2} ** 32));
    try testing.expect(std.mem.eql(u8, &iterator.next().?.work_report.package_spec.hash, &[_]u8{3} ** 32));
    try testing.expect(iterator.next() == null);

    iterator = theta.iteratorStartingFrom(8);
    try testing.expect(std.mem.eql(u8, &iterator.next().?.work_report.package_spec.hash, &[_]u8{3} ** 32));
    try testing.expect(std.mem.eql(u8, &iterator.next().?.work_report.package_spec.hash, &[_]u8{1} ** 32));
    try testing.expect(std.mem.eql(u8, &iterator.next().?.work_report.package_spec.hash, &[_]u8{2} ** 32));
    try testing.expect(iterator.next() == null);
}

test "Theta - iterator multiple entries per slot" {
    const allocator = std.testing.allocator;
    const createEmptyWorkReport = @import("tests/fixtures.zig").createEmptyWorkReport;

    var theta = VarTheta(12).init(allocator);
    defer theta.deinit();

    const entry1 = VarTheta(12).Entry{
        .work_report = createEmptyWorkReport([_]u8{1} ** 32),
        .dependencies = .{},
    };
    const entry2 = VarTheta(12).Entry{
        .work_report = createEmptyWorkReport([_]u8{2} ** 32),
        .dependencies = .{},
    };
    const entry3 = VarTheta(12).Entry{
        .work_report = createEmptyWorkReport([_]u8{3} ** 32),
        .dependencies = .{},
    };
    const entry4 = VarTheta(12).Entry{
        .work_report = createEmptyWorkReport([_]u8{4} ** 32),
        .dependencies = .{},
    };
    const entry5 = VarTheta(12).Entry{
        .work_report = createEmptyWorkReport([_]u8{5} ** 32),
        .dependencies = .{},
    };

    try theta.addEntryToTimeSlot(3, entry1);
    try theta.addEntryToTimeSlot(5, entry2);
    try theta.addEntryToTimeSlot(5, entry3);
    try theta.addEntryToTimeSlot(8, entry4);
    try theta.addEntryToTimeSlot(8, entry5);

    {
        var iterator = theta.iteratorStartingFrom(2);

        const first = iterator.next().?;
        try testing.expect(std.mem.eql(u8, &first.work_report.package_spec.hash, &[_]u8{1} ** 32));

        const second = iterator.next().?;
        try testing.expect(std.mem.eql(u8, &second.work_report.package_spec.hash, &[_]u8{2} ** 32));
        const third = iterator.next().?;
        try testing.expect(std.mem.eql(u8, &third.work_report.package_spec.hash, &[_]u8{3} ** 32));

        const fourth = iterator.next().?;
        try testing.expect(std.mem.eql(u8, &fourth.work_report.package_spec.hash, &[_]u8{4} ** 32));
        const fifth = iterator.next().?;
        try testing.expect(std.mem.eql(u8, &fifth.work_report.package_spec.hash, &[_]u8{5} ** 32));

        try testing.expect(iterator.next() == null);
    }

    {
        var iterator = theta.iteratorStartingFrom(6);

        const first = iterator.next().?;
        try testing.expect(std.mem.eql(u8, &first.work_report.package_spec.hash, &[_]u8{4} ** 32));
        const second = iterator.next().?;
        try testing.expect(std.mem.eql(u8, &second.work_report.package_spec.hash, &[_]u8{5} ** 32));

        const third = iterator.next().?;
        try testing.expect(std.mem.eql(u8, &third.work_report.package_spec.hash, &[_]u8{1} ** 32));

        const fourth = iterator.next().?;
        try testing.expect(std.mem.eql(u8, &fourth.work_report.package_spec.hash, &[_]u8{2} ** 32));
        const fifth = iterator.next().?;
        try testing.expect(std.mem.eql(u8, &fifth.work_report.package_spec.hash, &[_]u8{3} ** 32));

        try testing.expect(iterator.next() == null);
    }
}
