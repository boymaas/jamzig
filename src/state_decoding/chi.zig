const std = @import("std");
const testing = std.testing;
const services_privileged = @import("../services_privileged.zig");
const Chi = services_privileged.Chi;
const decoder = @import("../codec/decoder.zig");
const codec = @import("../codec.zig");
const types = @import("../types.zig");
const state_decoding = @import("../state_decoding.zig");
const DecodingError = state_decoding.DecodingError;
const DecodingContext = state_decoding.DecodingContext;
const jam_params = @import("../jam_params.zig");

pub fn decode(
    comptime params: jam_params.Params,
    allocator: std.mem.Allocator,
    context: *DecodingContext,
    reader: anytype,
) !Chi(params.core_count) {
    try context.push(.{ .component = "chi" });
    defer context.pop();

    var chi = try Chi(params.core_count).init(allocator);
    errdefer chi.deinit();

    // Read manager index
    try context.push(.{ .field = "manager" });
    chi.manager = reader.readInt(u32, .little) catch |err| {
        return context.makeError(error.EndOfStream, "failed to read manager index: {s}", .{@errorName(err)});
    };
    context.pop();

    // Read assigners - fixed-size array (one per core)
    try context.push(.{ .field = "assign" });
    var i: usize = 0;
    while (i < params.core_count) : (i += 1) {
        const assigner_idx = reader.readInt(u32, .little) catch |err| {
            return context.makeError(error.EndOfStream, "failed to read assigner index {}: {s}", .{ i, @errorName(err) });
        };
        // Assign must have exactly C elements, including 0 values
        chi.assign[i] = assigner_idx;
    }
    context.pop();

    // Read designate index (delegator)
    try context.push(.{ .field = "designate" });
    chi.designate = reader.readInt(u32, .little) catch |err| {
        return context.makeError(error.EndOfStream, "failed to read designate index: {s}", .{@errorName(err)});
    };
    context.pop();

    // Read registrar index (v0.7.1 GP #473)
    try context.push(.{ .field = "registrar" });
    chi.registrar = reader.readInt(u32, .little) catch |err| {
        return context.makeError(error.EndOfStream, "failed to read registrar index: {s}", .{@errorName(err)});
    };
    context.pop();

    // Read always_accumulate map
    try context.push(.{ .field = "always_accumulate" });
    const map_len = codec.readInteger(reader) catch |err| {
        return context.makeError(error.EndOfStream, "failed to read map length: {s}", .{@errorName(err)});
    };

    // Read always_accumulate entries (ordered by key)
    var prev_key: ?u32 = null;
    var j: usize = 0;
    while (j < map_len) : (j += 1) {
        try context.push(.{ .array_index = j });

        const key = reader.readInt(u32, .little) catch |err| {
            return context.makeError(error.EndOfStream, "failed to read map key: {s}", .{@errorName(err)});
        };
        const value = reader.readInt(u64, .little) catch |err| {
            return context.makeError(error.EndOfStream, "failed to read map value: {s}", .{@errorName(err)});
        };

        // Validate ordering
        if (prev_key) |pk| {
            if (key <= pk) {
                return context.makeError(error.InvalidFormat, "map keys must be sorted, but {} <= {}", .{ key, pk });
            }
        }
        prev_key = key;

        chi.always_accumulate.put(key, value) catch |err| {
            return context.makeError(error.OutOfMemory, "failed to insert map entry: {s}", .{@errorName(err)});
        };

        context.pop();
    }
    context.pop(); // always_accumulate

    return chi;
}