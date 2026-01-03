const std = @import("std");
const types = @import("types.zig");
const tracing = @import("tracing");
const trace = tracing.scoped(.guarantor);
const utils = @import("utils/sort.zig");
const state = @import("state.zig");
const StateTransition = @import("state_delta.zig").StateTransition;

/// Combined result containing both assignments and the validator set used
pub const GuarantorAssignmentResult = struct {
    /// The permutation mapping validator index to core index
    assignments: []u32,
    /// The validator set used (reference, not owned)
    validators: *const types.ValidatorSet,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.assignments);
        // validators is a reference, not owned
        self.* = undefined;
    }
};

/// Rotate core assignments by n positions
pub fn rotateAssignments(
    comptime core_count: u32,
    cores: []u32,
    n: u32,
) void {
    // Create output array
    // Apply rotation formula from 11.20: [(x + n) mod C | x <- c]
    for (cores) |*x| {
        x.* = @mod(x.* + n, core_count);
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
    const span = trace.span(@src(), .permute_assignments);
    defer span.deinit();

    // Create initial sequence of core indices
    var assignments = try std.ArrayList(u32).initCapacity(allocator, params.validators_count);
    errdefer assignments.deinit();

    var i: u32 = 0;
    while (i < params.validators_count) : (i += 1) {
        const core = (i * params.core_count) / params.validators_count; // C·i/V
        try assignments.append(core);
    }

    // Shuffle using non-allocating Fisher-Yates with compile-time known validator count
    @import("fisher_yates.zig").shuffle(u32, params.validators_count, assignments.items, entropy);

    // Calculate rotation based on slot
    const rotation = @divFloor(@mod(slot, params.epoch_length), params.validator_rotation_period);

    // Apply rotation
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

/// Centralized function to determine guarantor assignments (G or G*)
/// This encapsulates all logic for determining which assignments and validators to use
pub fn determineGuarantorAssignments(
    comptime params: @import("jam_params.zig").Params,
    allocator: std.mem.Allocator,
    stx: *StateTransition(params),
    guarantee_slot: types.TimeSlot,
) !GuarantorAssignmentResult {
    const span = trace.span(@src(), .determine_assignments);
    defer span.deinit();

    // Step 1: Calculate rotation periods
    const current_rotation = @divFloor(stx.time.current_slot, params.validator_rotation_period);
    const guarantee_rotation = @divFloor(guarantee_slot, params.validator_rotation_period);

    span.debug("Determining assignments - current_rotation: {d}, guarantee_rotation: {d}", .{ current_rotation, guarantee_rotation });

    // Step 2: Determine if we need G or G*
    if (current_rotation == guarantee_rotation) {
        // Use G (current rotation)
        // After safrole runs, use kappa_prime (updated validators), otherwise use base kappa
        span.debug("Using current rotation G with η'₂ and κ'", .{});

        const eta_prime = try stx.ensure(.eta_prime);
        const kappa = try stx.ensure(.kappa_prime);

        const assignments = try permuteAssignments(
            params,
            allocator,
            eta_prime[2], // η'₂
            stx.time.current_slot,
        );

        return .{
            .assignments = assignments,
            .validators = kappa,
        };
    } else {
        // Use G* (previous rotation)
        const previous_slot = stx.time.current_slot - params.validator_rotation_period;

        // Check if previous rotation was in same epoch
        const current_epoch = @divFloor(stx.time.current_slot, params.epoch_length);
        const previous_epoch = @divFloor(previous_slot, params.epoch_length);

        if (current_epoch == previous_epoch) {
            // Same epoch: use current entropy and validators (prefer prime if available)
            span.debug("Using previous rotation G* with η'₂ and κ' (same epoch)", .{});

            const eta_prime = try stx.ensure(.eta_prime);
            const kappa =
                try stx.ensure(.kappa_prime);

            const assignments = try permuteAssignments(
                params,
                allocator,
                eta_prime[2], // η'₂
                previous_slot,
            );

            return .{
                .assignments = assignments,
                .validators = kappa,
            };
        } else {
            // Different epoch: use previous entropy and validators (prefer prime if available)
            span.debug("Using previous rotation G* with η'₃ and λ' (different epoch)", .{});

            const eta_prime = try stx.ensure(.eta_prime);
            const lambda = try stx.ensure(.lambda_prime);

            const assignments = try permuteAssignments(
                params,
                allocator,
                eta_prime[3], // η'₃
                previous_slot,
            );

            return .{
                .assignments = assignments,
                .validators = lambda,
            };
        }
    }
}
