const std = @import("std");
const state = @import("../state.zig");
const serialize = @import("../codec.zig").serialize;
const encoder = @import("../codec/encoder.zig");
const codec = @import("../codec.zig");
const types = @import("../types.zig");
const jam_params = @import("../jam_params.zig");

const trace = @import("tracing").scoped(.codec);

pub fn encode(
    comptime params: jam_params.Params,
    chi: *const state.Chi(params.core_count),
    writer: anytype,
) !void {
    const span = trace.span(@src(), .encode);
    defer span.deinit();
    span.debug("Starting Chi state encoding", .{});

    span.trace("Encoding manager: {d}, designate: {d}", .{
        chi.manager,
        chi.designate,
    });

    try writer.writeInt(u32, chi.manager, .little);

    span.trace("Encoding {} assigners (core_count)", .{params.core_count});
    for (chi.assign) |assigner| {
        try writer.writeInt(u32, assigner, .little);
    }

    try writer.writeInt(u32, chi.designate, .little);

    span.trace("Encoding registrar: {d}", .{chi.registrar});
    try writer.writeInt(u32, chi.registrar, .little);
    const map_span = span.child(@src(), .map_encode);
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
        const entry_span = map_span.child(@src(), .entry);
        defer entry_span.deinit();
        entry_span.debug("Encoding map entry", .{});
        entry_span.trace("key: {d}, value: {d}", .{ key, value });

        try writer.writeInt(u32, key, .little);
        try writer.writeInt(u64, value, .little);
    }

    span.debug("Successfully encoded Chi state", .{});
}