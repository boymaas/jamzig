const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const HeaderHash = types.HeaderHash;
const TimeSlot = types.TimeSlot;

pub const Ancestry = struct {
    headers: std.AutoHashMap(HeaderHash, TimeSlot),
    allocator: Allocator,

    pub fn init(allocator: Allocator) Ancestry {
        return .{
            .headers = std.AutoHashMap(HeaderHash, TimeSlot).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Ancestry) void {
        self.headers.deinit();
        self.* = undefined;
    }

    pub fn deepClone(self: *const Ancestry, allocator: Allocator) !Ancestry {
        var new_ancestry = Ancestry.init(allocator);
        errdefer new_ancestry.deinit();

        var iterator = self.headers.iterator();
        while (iterator.next()) |entry| {
            try new_ancestry.headers.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        return new_ancestry;
    }

    pub fn addHeader(self: *Ancestry, hash: HeaderHash, timeslot: TimeSlot) !void {
        try self.headers.put(hash, timeslot);
    }

    pub fn lookupTimeslot(self: *const Ancestry, hash: HeaderHash) ?TimeSlot {
        return self.headers.get(hash);
    }

    pub fn pruneOldEntries(self: *Ancestry, current_slot: TimeSlot, max_age: u32) !void {
        const cutoff_slot = current_slot -| max_age;

        var entries_to_remove = std.ArrayList(HeaderHash).init(self.allocator);
        defer entries_to_remove.deinit();

        var iterator = self.headers.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.* < cutoff_slot) {
                try entries_to_remove.append(entry.key_ptr.*);
            }
        }

        for (entries_to_remove.items) |hash| {
            _ = self.headers.remove(hash);
        }
    }

    pub fn count(self: *const Ancestry) u32 {
        return @intCast(self.headers.count());
    }
};