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

        pub fn deinit(self: *@This()) void {
            for (self.entries) |slot_entries| {
                for (slot_entries.items) |*entry| {
                    @constCast(entry).deinit(self.allocator);
                }
                @constCast(&slot_entries).deinit(self.allocator);
            }
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

        /// Add a new work report with its dependencies
        pub fn addEntryToTimeSlot(
            self: *@This(),
            time_slot: types.TimeSlot,
            entry: Entry,
        ) !void {
            try self.entries[time_slot].append(self.allocator, entry);
        }
    };
}

pub const SlotEntries = std.ArrayListUnmanaged(Entry);

pub const Entry = struct {
    /// a work report
    work_report: WorkReport,
    /// set of work package hashes
    dependencies: std.AutoHashMapUnmanaged([32]u8, void),

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        self.dependencies.deinit(allocator);
    }
};

const testing = std.testing;

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
