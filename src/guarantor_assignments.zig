const std = @import("std");
const types = @import("types.zig");
const tracing = @import("tracing.zig");
const trace = tracing.scoped(.guarantor);
const utils = @import("utils/sort.zig");

/// Rotate core assignments by n positions
pub fn rotateAssignments(
    cores: []u32,
    n: u32,
) void {
    // Create output array
    // Apply rotation formula from 11.20: [(x + n) mod C | x <- c]
    for (cores) |*x| {
        x.* = (x.* + n) % @as(u32, @intCast(cores.len));
    }
}

/// Create core assignments using entropy and rotation
/// Implementation of equation 11.21
pub fn permuteAssignments(
    comptime params: @import("jam_params.zig").Params,
    allocator: std.mem.Allocator,
    entropy: [32]u8,
    slot: types.TimeSlot,
) ![]u32 {
    const span = trace.span(.permute_assignments);
    defer span.deinit();

    // Create initial sequence of core indices
    var assignments = try std.ArrayList(u32).initCapacity(allocator, params.validators_count);
    errdefer assignments.deinit();

    var i: u32 = 0;
    while (i < params.validators_count) : (i += 1) {
        const core = (i * params.core_count) / params.validators_count; // C·i/V
        try assignments.append(core);
    }

    // Shuffle using Fisher-Yates
    @import("fisher_yates.zig").shuffle(u32, allocator, assignments.items, entropy);

    // Calculate rotation based on slot
    const rotation = @divFloor(@mod(slot, params.epoch_length), params.validator_rotation_period);

    // Apply rotation
    rotateAssignments(assignments.items, rotation);

    return assignments.toOwnedSlice();
}

const Result = struct {
    assignments: []u32,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.assignments);
    }
};

/// Get current guarantor assignments G
/// Implementation of equation 11.22
pub fn buildForTimeSlot(
    comptime params: @import("jam_params.zig").Params,
    allocator: std.mem.Allocator,
    entropy: [32]u8,
    slot: types.TimeSlot,
) !Result {
    // Create core assignments using current entropy
    const assignments = try permuteAssignments(params, allocator, entropy, slot);
    errdefer allocator.free(assignments);

    return .{
        .assignments = assignments,
    };
}
