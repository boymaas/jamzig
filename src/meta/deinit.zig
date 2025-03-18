const std = @import("std");
const calls = @import("calls.zig");

pub fn deinitEntriesAndAggregate(allocator: std.mem.Allocator, aggregate: anytype) void {
    for (aggregate.items) |*item| {
        calls.callDeinit(item, allocator);
    }
    calls.callDeinit(aggregate, allocator);
}

pub fn allocFreeEntriesAndAggregate(allocator: std.mem.Allocator, aggregate: anytype) void {
    for (aggregate.items) |item| {
        allocator.free(item);
    }
    calls.callDeinit(aggregate, allocator);
}

pub fn deinitHashMapValuesAndMap(allocator: std.mem.Allocator, map: anytype) void {
    var value_iterator = map.valueIterator();
    while (value_iterator.next()) |value| {
        calls.callDeinit(value, allocator);
    }
    calls.callDeinit(map, allocator);
}
