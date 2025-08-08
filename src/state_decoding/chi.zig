const std = @import("std");
const testing = std.testing;
const services_privileged = @import("../services_priviledged.zig");
const Chi = services_privileged.Chi;
const decoder = @import("../codec/decoder.zig");
const codec = @import("../codec.zig");
const types = @import("../types.zig");
const state_decoding = @import("../state_decoding.zig");
const DecodingError = state_decoding.DecodingError;
const DecodingContext = state_decoding.DecodingContext;
const jam_params = @import("../jam_params.zig");

pub fn decode(
    allocator: std.mem.Allocator,
    context: *DecodingContext,
    reader: anytype,
) !Chi {
    try context.push(.{ .component = "chi" });
    defer context.pop();

    // TODO: Chi should store core_count when constructed
    // For now, use TINY_PARAMS core count
    const core_count = jam_params.TINY_PARAMS.core_count;

    var chi = Chi.init(allocator);
    errdefer chi.deinit();

    // Read manager index
    try context.push(.{ .field = "manager" });
    const manager_idx = reader.readInt(u32, .little) catch |err| {
        return context.makeError(error.EndOfStream, "failed to read manager index: {s}", .{@errorName(err)});
    };
    chi.manager = if (manager_idx == 0) null else manager_idx;
    context.pop();

    // Read assigners - fixed-size array (one per core)
    try context.push(.{ .field = "assign" });
    var i: usize = 0;
    while (i < core_count) : (i += 1) {
        const assigner_idx = reader.readInt(u32, .little) catch |err| {
            return context.makeError(error.EndOfStream, "failed to read assigner index {}: {s}", .{ i, @errorName(err) });
        };
        // Only add non-zero assigners to the list
        if (assigner_idx != 0) {
            chi.assign.append(allocator, assigner_idx) catch |err| {
                return context.makeError(error.OutOfMemory, "failed to append assigner: {s}", .{@errorName(err)});
            };
        }
    }
    context.pop();

    // Read designate index
    try context.push(.{ .field = "designate" });
    const designate_idx = reader.readInt(u32, .little) catch |err| {
        return context.makeError(error.EndOfStream, "failed to read designate index: {s}", .{@errorName(err)});
    };
    chi.designate = if (designate_idx == 0) null else designate_idx;
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
