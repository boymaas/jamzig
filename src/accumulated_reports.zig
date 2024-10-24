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

        pub fn deinit(self: *@This()) void {
            for (self.entries) |slot_entries| {
                @constCast(&slot_entries).deinit(self.allocator);
            }
        }

        pub fn jsonStringify(self: *const @This(), jw: anytype) !void {
            try jw.beginArray();
            for (self.entries) |slot_entries| {
                try jw.beginObject();
                var iterator = slot_entries.iterator();
                while (iterator.next()) |entry| {
                    var buffer: [128]u8 = undefined;
                    const hexStr = std.fmt.bufPrint(&buffer, "0x{s}", .{std.fmt.fmtSliceHexLower(&entry.key_ptr.*)}) catch unreachable;
                    try jw.objectField(hexStr);
                    try jw.write(std.fmt.fmtSliceHexLower(&entry.value_ptr.*));
                }
                try jw.endObject();
            }
            try jw.endArray();
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
