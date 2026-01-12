
const std = @import("std");
const types = @import("types.zig");
const tracing = @import("tracing");
const trace = tracing.scoped(.guarantor);
const utils = @import("utils/sort.zig");
const state = @import("state.zig");
const StateTransition = @import("state_delta.zig").StateTransition;

pub const GuarantorAssignmentResult = struct {
    assignments: []u32,
    validators: *const types.ValidatorSet,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.assignments);
        self.* = undefined;
    }
};

pub fn rotateAssignments(
    comptime core_count: u32,
    cores: []u32,
    n: u32,
) void {
    for (cores) |*x| {
        x.* = @mod(x.* + n, core_count);
    }
}

/// Equation 11.21
pub fn permuteAssignments(
    comptime params: @import("jam_params.zig").Params,
    allocator: std.mem.Allocator,
    entropy: [32]u8,
    slot: types.TimeSlot,
) ![]u32 {
    const span = trace.span(@src(), .permute_assignments);
    defer span.deinit();

    var assignments = try std.ArrayList(u32).initCapacity(allocator, params.validators_count);
    errdefer assignments.deinit();

    var i: u32 = 0;
    while (i < params.validators_count) : (i += 1) {
        const core = (i * params.core_count) / params.validators_count;
        try assignments.append(core);
    }

    @import("fisher_yates.zig").shuffle(u32, params.validators_count, assignments.items, entropy);

    const rotation = @divFloor(@mod(slot, params.epoch_length), params.validator_rotation_period);

    rotateAssignments(params.core_count, assignments.items, rotation);

    return assignments.toOwnedSlice();
}

const Result = struct {
    assignments: []u32,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.assignments);
        self.* = undefined;
    }
};

/// Equation 11.22
pub fn buildForTimeSlot(
    comptime params: @import("jam_params.zig").Params,
    allocator: std.mem.Allocator,
    entropy: [32]u8,
    slot: types.TimeSlot,
) !Result {
    const assignments = try permuteAssignments(params, allocator, entropy, slot);
    errdefer allocator.free(assignments);

    return .{
        .assignments = assignments,
    };
}

pub fn determineGuarantorAssignments(
    comptime params: @import("jam_params.zig").Params,
    allocator: std.mem.Allocator,
    stx: *StateTransition(params),
    guarantee_slot: types.TimeSlot,
) !GuarantorAssignmentResult {
    const span = trace.span(@src(), .determine_assignments);
    defer span.deinit();

    const current_rotation = @divFloor(stx.time.current_slot, params.validator_rotation_period);
    const guarantee_rotation = @divFloor(guarantee_slot, params.validator_rotation_period);

    span.debug("Determining assignments - current_rotation: {d}, guarantee_rotation: {d}", .{ current_rotation, guarantee_rotation });

    if (current_rotation == guarantee_rotation) {
        span.debug("Using current rotation G with η'₂ and κ'", .{});

        const eta_prime = try stx.ensure(.eta_prime);
        const kappa = try stx.ensure(.kappa_prime);

        const assignments = try permuteAssignments(
            params,
            allocator,
            eta_prime[2],
            stx.time.current_slot,
        );

        return .{
            .assignments = assignments,
            .validators = kappa,
        };
    } else {
        const previous_slot = stx.time.current_slot - params.validator_rotation_period;

        const current_epoch = @divFloor(stx.time.current_slot, params.epoch_length);
        const previous_epoch = @divFloor(previous_slot, params.epoch_length);

        if (current_epoch == previous_epoch) {
            span.debug("Using previous rotation G* with η'₂ and κ' (same epoch)", .{});

            const eta_prime = try stx.ensure(.eta_prime);
            const kappa =
                try stx.ensure(.kappa_prime);

            const assignments = try permuteAssignments(
                params,
                allocator,
                eta_prime[2],
                previous_slot,
            );

            return .{
                .assignments = assignments,
                .validators = kappa,
            };
        } else {
            span.debug("Using previous rotation G* with η'₃ and λ' (different epoch)", .{});

            const eta_prime = try stx.ensure(.eta_prime);
            const lambda = try stx.ensure(.lambda_prime);

            const assignments = try permuteAssignments(
                params,
                allocator,
                eta_prime[3],
                previous_slot,
            );

            return .{
                .assignments = assignments,
                .validators = lambda,
            };
        }
    }
}
