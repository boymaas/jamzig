const std = @import("std");
const types = @import("types.zig");
const WorkReport = types.WorkReport;

// We also maintain knowledge of ready (i.e. available and/or audited) but
// not-yet-accumulated work-reports in the state item ϑ. Each of these were
// made available at most one epoch ago but have or had unfulfilled dependen-
// cies. Alongside the work-report itself, we retain its un- accumulated
// dependencies, a set of work-package hashes.
pub fn Theta(comptime epoch_size: usize) type {
    return struct {
        entries: [epoch_size]SlotEntries,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .entries = [_]SlotEntries{.{}} ** epoch_size,
                .allocator = allocator,
            };
        }

        /// Add a new work report with its dependencies
        pub fn addEntryToTimeSlot(
            self: *@This(),
            time_slot: types.TimeSlot,
            entry: Entry,
        ) !void {
            try self.entries[time_slot].append(self.allocator, entry);
        }

        pub fn getReportsAtSlot(self: *const @This(), time_slot: types.TimeSlot) []const Entry {
            return self.entries[time_slot].items;
        }

        // pub fn resolveDependency(self: *@This()) !void {}

        /// Iterator wich will walk form starting epoch up and will
        /// return a pointer to each entry containin
        const Iterator = struct {
            starting_epoch: u32,

            processed_epochs: u32 = 0,
            processed_entry_in_epoch_entry: usize = 0,

            theta: *Theta(epoch_size),

            pub fn next(self: *@This()) ?*Entry {
                // If we exhausted all epochs we are done
                if (self.processed_epochs >= epoch_size) {
                    return null;
                }

                // We are going around the clock as defined in the GP
                const current_epoch = @mod(
                    self.starting_epoch + self.processed_epochs,
                    epoch_size,
                );
                const current_epoch_entry = self.theta.entries[current_epoch];

                // If we exhausted this entry increase and recurse
                if (self.processed_entry_in_epoch_entry >= current_epoch_entry.items.len) {
                    self.processed_epochs += 1;
                    self.processed_entry_in_epoch_entry = 0;
                    return self.next();
                }

                self.processed_entry_in_epoch_entry += 1;
                return &current_epoch_entry.items[self.processed_entry_in_epoch_entry - 1];
            }
        };

        /// Creates an iterator returning all the Entries start from epoch
        pub fn iterator(self: *@This(), starting_epoch: u32) Iterator {
            return .{ .theta = self, .starting_epoch = starting_epoch };
        }

        pub fn deepClone(self: @This(), allocator: std.mem.Allocator) !@This() {
            var cloned = @This(){
                .entries = undefined,
                .allocator = allocator,
            };
            errdefer cloned.deinit();

            // Initialize the entries array with empty SlotEntries
            cloned.entries = [_]SlotEntries{.{}} ** epoch_size;

            // Clone each SlotEntries and their contained Entry items
            for (self.entries, 0..) |slot_entries, i| {
                // Ensure we have enough capacity in the new list
                try cloned.entries[i].ensureTotalCapacity(allocator, slot_entries.items.len);

                // Clone each Entry in the slot
                for (slot_entries.items) |entry| {
                    const cloned_entry = try entry.deepClone(allocator);
                    try cloned.entries[i].append(allocator, cloned_entry);
                }
            }

            return cloned;
        }

        pub fn deinit(self: *@This()) void {
            for (self.entries) |slot_entries| {
                for (slot_entries.items) |*entry| {
                    @constCast(entry).deinit(self.allocator);
                }
                @constCast(&slot_entries).deinit(self.allocator);
            }
            self.* = undefined;
        }

        pub fn jsonStringify(self: *const @This(), jw: anytype) !void {
            try @import("state_json/available_reports.zig").jsonStringify(epoch_size, self, jw);
        }

        pub fn format(
            self: *const @This(),
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            try @import("state_format/available_reports.zig").format(epoch_size, self, fmt, options, writer);
        }
    };
}

pub const SlotEntries = std.ArrayListUnmanaged(Entry);

pub const Entry = struct {
    /// a work report
    work_report: WorkReport,
    /// set of work package hashes
    dependencies: std.AutoHashMapUnmanaged([32]u8, void),

    pub fn initWithDependencies(
        allocator: std.mem.Allocator,
        work_report: WorkReport,
        dependencies: []const [32]u8,
    ) !Entry {
        var deps = std.AutoHashMapUnmanaged([32]u8, void){};
        errdefer deps.deinit(allocator);

        // Add all dependencies to the hash map
        for (dependencies) |dep| {
            try deps.put(allocator, dep, {});
        }

        return Entry{
            .work_report = work_report,
            .dependencies = deps,
        };
    }

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        self.dependencies.deinit(allocator);
        self.* = undefined;
    }

    pub fn deepClone(self: Entry, allocator: std.mem.Allocator) !Entry {
        // Create a new dependencies map
        var cloned_dependencies = std.AutoHashMapUnmanaged([32]u8, void){};

        // Clone each dependency key-value pair
        var iterator = self.dependencies.iterator();
        while (iterator.next()) |entry| {
            try cloned_dependencies.put(allocator, entry.key_ptr.*, {});
        }

        return Entry{
            .work_report = try self.work_report.deepClone(allocator),
            .dependencies = cloned_dependencies,
        };
    }
};

const testing = std.testing;

test "Theta - getReportsAtSlot" {
    const allocator = std.testing.allocator;
    const createEmptyWorkReport = @import("tests/fixtures.zig").createEmptyWorkReport;

    var theta = Theta(12).init(allocator);
    defer theta.deinit();

    // Create two sample WorkReports
    const work_report1 = createEmptyWorkReport([_]u8{1} ** 32);
    const work_report2 = createEmptyWorkReport([_]u8{2} ** 32);

    // Create two sample Entries
    const entry1 = Entry{
        .work_report = work_report1,
        .dependencies = .{},
    };
    const entry2 = Entry{
        .work_report = work_report2,
        .dependencies = .{},
    };

    // Add entries to different slots
    try theta.addEntryToTimeSlot(2, entry1);
    try theta.addEntryToTimeSlot(2, entry2);

    // Test empty slot
    try testing.expectEqual(@as(usize, 0), theta.getReportsAtSlot(0).len);

    // Test slot with entries
    const slot_2_reports = theta.getReportsAtSlot(2);
    try testing.expectEqual(@as(usize, 2), slot_2_reports.len);
    try testing.expectEqual(work_report1, slot_2_reports[0].work_report);
    try testing.expectEqual(work_report2, slot_2_reports[1].work_report);
}

test "Theta - init, add entries, and verify" {
    const allocator = std.testing.allocator;
    const createEmptyWorkReport = @import("tests/fixtures.zig").createEmptyWorkReport;

    var theta = Theta(12).init(allocator);
    defer theta.deinit();

    // Create a sample WorkReport
    const work_report = createEmptyWorkReport([_]u8{1} ** 32);

    // Create a sample Entry
    var entry = Entry{
        .work_report = work_report,
        .dependencies = .{},
    };

    // Add a dependency
    const dependency = [_]u8{ 1, 2, 3 } ++ [_]u8{0} ** 29;
    try entry.dependencies.put(allocator, dependency, {});

    // Add the slot_entries to theta
    try theta.addEntryToTimeSlot(2, entry);

    // Verify the contents
    try testing.expectEqual(@as(usize, 12), theta.entries.len);
    try testing.expectEqual(@as(usize, 1), theta.entries[2].items.len);
    try testing.expectEqual(work_report, theta.entries[2].items[0].work_report);
    try testing.expectEqual(@as(usize, 1), theta.entries[2].items[0].dependencies.count());
    try testing.expect(theta.entries[2].items[0].dependencies.contains(dependency));
}

test "Theta - iterator basic functionality" {
    const allocator = std.testing.allocator;
    const createEmptyWorkReport = @import("tests/fixtures.zig").createEmptyWorkReport;

    var theta = Theta(12).init(allocator);
    defer theta.deinit();

    // Create sample work reports with distinct IDs
    const work_report1 = createEmptyWorkReport([_]u8{1} ** 32);
    const work_report2 = createEmptyWorkReport([_]u8{2} ** 32);
    const work_report3 = createEmptyWorkReport([_]u8{3} ** 32);

    // Create entries and add them to different slots
    const entry1 = Entry{
        .work_report = work_report1,
        .dependencies = .{},
    };
    const entry2 = Entry{
        .work_report = work_report2,
        .dependencies = .{},
    };
    const entry3 = Entry{
        .work_report = work_report3,
        .dependencies = .{},
    };

    // Add entries to slots 2, 5, and 11
    try theta.addEntryToTimeSlot(2, entry1);
    try theta.addEntryToTimeSlot(5, entry2);
    try theta.addEntryToTimeSlot(11, entry3);

    // Test iterator starting from slot 0
    var iterator = theta.iterator(0);
    try testing.expect(std.mem.eql(u8, &iterator.next().?.work_report.package_spec.hash, &[_]u8{1} ** 32));
    try testing.expect(std.mem.eql(u8, &iterator.next().?.work_report.package_spec.hash, &[_]u8{2} ** 32));
    try testing.expect(std.mem.eql(u8, &iterator.next().?.work_report.package_spec.hash, &[_]u8{3} ** 32));
    try testing.expect(iterator.next() == null);

    // Test iterator starting from slot 8
    iterator = theta.iterator(8);
    try testing.expect(std.mem.eql(u8, &iterator.next().?.work_report.package_spec.hash, &[_]u8{3} ** 32));
    try testing.expect(std.mem.eql(u8, &iterator.next().?.work_report.package_spec.hash, &[_]u8{1} ** 32));
    try testing.expect(std.mem.eql(u8, &iterator.next().?.work_report.package_spec.hash, &[_]u8{2} ** 32));
    try testing.expect(iterator.next() == null);
}

test "Theta - iterator multiple entries per slot" {
    const allocator = std.testing.allocator;
    const createEmptyWorkReport = @import("tests/fixtures.zig").createEmptyWorkReport;

    var theta = Theta(12).init(allocator);
    defer theta.deinit();

    // Create entries with distinct IDs
    const entry1 = Entry{
        .work_report = createEmptyWorkReport([_]u8{1} ** 32),
        .dependencies = .{},
    };
    const entry2 = Entry{
        .work_report = createEmptyWorkReport([_]u8{2} ** 32),
        .dependencies = .{},
    };
    const entry3 = Entry{
        .work_report = createEmptyWorkReport([_]u8{3} ** 32),
        .dependencies = .{},
    };
    const entry4 = Entry{
        .work_report = createEmptyWorkReport([_]u8{4} ** 32),
        .dependencies = .{},
    };
    const entry5 = Entry{
        .work_report = createEmptyWorkReport([_]u8{5} ** 32),
        .dependencies = .{},
    };

    // Add entries to multiple slots:
    // Slot 3: entry1
    // Slot 5: entry2, entry3
    // Slot 8: entry4, entry5
    try theta.addEntryToTimeSlot(3, entry1);
    try theta.addEntryToTimeSlot(5, entry2);
    try theta.addEntryToTimeSlot(5, entry3);
    try theta.addEntryToTimeSlot(8, entry4);
    try theta.addEntryToTimeSlot(8, entry5);

    // Test iterator starting from slot 2
    {
        var iterator = theta.iterator(2);

        // Should find entry in slot 3
        const first = iterator.next().?;
        try testing.expect(std.mem.eql(u8, &first.work_report.package_spec.hash, &[_]u8{1} ** 32));

        // Should find two entries in slot 5
        const second = iterator.next().?;
        try testing.expect(std.mem.eql(u8, &second.work_report.package_spec.hash, &[_]u8{2} ** 32));
        const third = iterator.next().?;
        try testing.expect(std.mem.eql(u8, &third.work_report.package_spec.hash, &[_]u8{3} ** 32));

        // Should find two entries in slot 8
        const fourth = iterator.next().?;
        try testing.expect(std.mem.eql(u8, &fourth.work_report.package_spec.hash, &[_]u8{4} ** 32));
        const fifth = iterator.next().?;
        try testing.expect(std.mem.eql(u8, &fifth.work_report.package_spec.hash, &[_]u8{5} ** 32));

        // No more entries
        try testing.expect(iterator.next() == null);
    }

    // Test iterator starting from slot 6 (should wrap around)
    {
        var iterator = theta.iterator(6);

        // Should find two entries in slot 8
        const first = iterator.next().?;
        try testing.expect(std.mem.eql(u8, &first.work_report.package_spec.hash, &[_]u8{4} ** 32));
        const second = iterator.next().?;
        try testing.expect(std.mem.eql(u8, &second.work_report.package_spec.hash, &[_]u8{5} ** 32));

        // Should wrap around and find entry in slot 3
        const third = iterator.next().?;
        try testing.expect(std.mem.eql(u8, &third.work_report.package_spec.hash, &[_]u8{1} ** 32));

        // Should find two entries in slot 5
        const fourth = iterator.next().?;
        try testing.expect(std.mem.eql(u8, &fourth.work_report.package_spec.hash, &[_]u8{2} ** 32));
        const fifth = iterator.next().?;
        try testing.expect(std.mem.eql(u8, &fifth.work_report.package_spec.hash, &[_]u8{3} ** 32));

        // No more entries
        try testing.expect(iterator.next() == null);
    }
}
