const std = @import("std");
const state = @import("../state.zig");
const serialize = @import("../codec.zig").serialize;
const encoder = @import("../codec/encoder.zig");
const codec = @import("../codec.zig");
const types = @import("../types.zig");
const jam_params = @import("../jam_params.zig");

const trace = @import("../tracing.zig").scoped(.codec);

pub fn encode(chi: *const state.Chi, writer: anytype) !void {
    const span = trace.span(.encode);
    defer span.deinit();
    span.debug("Starting Chi state encoding", .{});

    // TODO: Chi should store core_count when constructed
    // For now, use TINY_PARAMS core count
    const core_count = jam_params.TINY_PARAMS.core_count;

    // Encode the simple fields
    const manager_value = chi.manager orelse 0;
    const designate_value = chi.designate orelse 0;

    span.trace("Encoding manager: {d}, designate: {d}", .{
        manager_value,
        designate_value,
    });

    try writer.writeInt(u32, manager_value, .little);

    // Encode the assigners as a fixed-size array (one per core)
    // The graypaper expects exactly C (core_count) assigners
    span.trace("Encoding {} assigners (core_count)", .{core_count});
    var i: usize = 0;
    while (i < core_count) : (i += 1) {
        // Write the assigner for this core, or 0 if not assigned
        const assigner = if (i < chi.assign.items.len) chi.assign.items[i] else 0;
        try writer.writeInt(u32, assigner, .little);
    }

    try writer.writeInt(u32, designate_value, .little);

    // Encode X_g with ordered keys
    // TODO: this could be a method in encoder, map encoder which orders
    // the keys
    const map_span = span.child(.map_encode);
    defer map_span.deinit();
    map_span.debug("Encoding always_accumulate map", .{});

    var keys = std.ArrayList(u32).init(chi.allocator);
    defer keys.deinit();

    var it = chi.always_accumulate.keyIterator();
    while (it.next()) |key| {
        try keys.append(key.*);
    }

    map_span.debug("Collected {d} keys from map", .{keys.items.len});
    map_span.trace("Unsorted keys: {any}", .{keys.items});

    std.sort.insertion(u32, keys.items, {}, std.sort.asc(u32));
    map_span.trace("Sorted keys: {any}", .{keys.items});

    try writer.writeAll(encoder.encodeInteger(keys.items.len).as_slice());

    for (keys.items) |key| {
        const value = chi.always_accumulate.get(key).?;
        const entry_span = map_span.child(.entry);
        defer entry_span.deinit();
        entry_span.debug("Encoding map entry", .{});
        entry_span.trace("key: {d}, value: {d}", .{ key, value });

        try writer.writeInt(u32, key, .little);
        try writer.writeInt(u64, value, .little);
    }

    span.debug("Successfully encoded Chi state", .{});
}
