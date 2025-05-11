const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const jam_params = @import("../jam_params.zig");

pub const CoresStatistics = struct {
    stats: []state.validator_stats.CoreActivityRecord,

    pub fn stats_size(params: jam_params.Params) usize {
        return params.core_count;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.stats);
        self.* = undefined;
    }
};

pub const ServicesStatisticsMapEntry = struct {
    id: types.ServiceId,
    record: state.validator_stats.ServiceActivityRecord,
};

pub const ServiceStatistics = struct {
    stats: []ServicesStatisticsMapEntry,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.stats);
        self.* = undefined;
    }

    // encode would need to sort inplace

    pub fn decode(_: anytype, reader: anytype, allocator: std.mem.Allocator) !@This() {
        const codec = @import("../codec.zig");

        // Read the length as a variable integer
        const length = try codec.readInteger(reader);

        // Allocate memory for the service activity records
        var stats = try allocator.alloc(ServicesStatisticsMapEntry, length);
        errdefer allocator.free(stats);

        // Decode each service activity record
        for (0..length) |i| {
            stats[i] = try codec.deserializeAlloc(ServicesStatisticsMapEntry, .{}, allocator, reader);
        }

        return @This(){
            .stats = stats,
        };
    }
};
