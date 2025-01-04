const std = @import("std");
const types = @import("types.zig");

const WorkReportHash = types.Hash;
const SegmentRootHash = types.Hash;

pub fn Xi(comptime epoch_size: usize) type {
    return struct {
        entries: [epoch_size]std.AutoHashMapUnmanaged(WorkReportHash, SegmentRootHash),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .entries = [_]std.AutoHashMapUnmanaged(types.WorkReportHash, types.Hash){.{}} ** epoch_size,
                .allocator = allocator,
            };
        }

        pub fn deepClone(self: *const @This(), allocator: std.mem.Allocator) !@This() {
            var cloned = @This(){
                .entries = undefined,
                .allocator = allocator,
            };

            for (self.entries, 0..) |slot_entries, i| {
                cloned.entries[i] = std.AutoHashMapUnmanaged(types.WorkReportHash, types.Hash){};

                var iterator = slot_entries.iterator();
                while (iterator.next()) |entry| {
                    try cloned.entries[i].put(allocator, entry.key_ptr.*, entry.value_ptr.*);
                }
            }

            return cloned;
        }

        pub fn deinit(self: *@This()) void {
            for (self.entries) |slot_entries| {
                @constCast(&slot_entries).deinit(self.allocator);
            }
        }

        pub fn jsonStringify(self: *const @This(), jw: anytype) !void {
            try @import("state_json/accumulated_reports.zig").jsonStringify(epoch_size, self, jw);
        }

        pub fn format(
            self: *const @This(),
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            try @import("state_format/accumulated_reports.zig").format(epoch_size, self, fmt, options, writer);
        }

        pub fn addEntryToTimeSlot(
            self: *@This(),
            time_slot: types.TimeSlot,
            key: types.Hash,
            value: types.Hash,
        ) !void {
            try self.entries[time_slot].put(self.allocator, key, value);
        }
    };
}

const testing = std.testing;

test "Xi - init, add entries, and verify" {
    const allocator = std.testing.allocator;
    var xi = Xi(12).init(allocator);
    defer xi.deinit();

    // Create sample key-value pairs
    const key = [_]u8{1} ** 32;
    const value = [_]u8{2} ** 32;

    // Add entry to time slot
    try xi.addEntryToTimeSlot(2, key, value);

    // Verify the contents
    try testing.expectEqual(@as(usize, 12), xi.entries.len);
    try testing.expectEqual(@as(usize, 1), xi.entries[2].count());

    const stored_value = xi.entries[2].get(key) orelse return error.TestUnexpectedNull;
    try testing.expectEqualSlices(u8, &value, &stored_value);
}
