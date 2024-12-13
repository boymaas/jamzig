const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");

pub fn convertAvailabilityAssignments(
    comptime core_count: u16,
    allocator: std.mem.Allocator,
    assignments: types.AvailabilityAssignments,
) !state.Rho(core_count) {
    var rho = state.Rho(core_count).init(allocator);
    errdefer rho.deinit(allocator);

    for (assignments.items, 0..) |assignment, core| {
        if (assignment) |a| {
            try rho.setReport(core, try a.deepClone(allocator));
        }
    }
    return rho;
}

pub fn convertValidatorSet(
    allocator: std.mem.Allocator,
    validator_set: types.ValidatorSet,
) !types.ValidatorSet {
    return try validator_set.deepClone(allocator);
}
