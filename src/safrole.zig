const std = @import("std");
const ArrayList = std.ArrayList;

pub const types = @import("safrole/types.zig");
pub const entropy = @import("safrole/entropy.zig");

pub const Params = struct {
    epoch_length: u32 = 600,
};

const Safrole = struct {
    allocator: std.mem.Allocator,
    state: types.State,

    epoch_length: u32,

    pub fn init(allocator: std.mem.Allocator, state: types.State, params: Params) Safrole {
        return .{
            .allocator = allocator,
            .state = state,
            .params = params,
        };
    }

    pub fn Y(self: *@This(), input: types.Input) !TransitionResult {
        const result = try transition(self.allocator, self.params, self.state, input);
        if (result.state) |new_state| {
            self.state.deinit(self.allocator);
            self.state = new_state;
        }
        return result;
    }

    pub fn deinit(self: Safrole) void {
        self.state.deinit(self.allocator);
    }
};

// Constant
pub const TransitionResult = struct {
    output: types.Output,
    state: ?types.State,

    pub fn deinit(self: TransitionResult, allocator: std.mem.Allocator) void {
        if (self.state != null) {
            self.state.?.deinit(allocator);
        }
        self.output.deinit(allocator);
    }
};

pub fn transition(
    allocator: std.mem.Allocator,
    params: Params,
    pre_state: types.State,
    input: types.Input,
) !TransitionResult {
    // Equation 41: H_t ∈ N_T, P(H)_t < H_t ∧ H_t · P ≤ T
    if (input.slot <= pre_state.tau) {
        return .{
            .output = .{ .err = .bad_slot },
            .state = null,
        };
    }

    var post_state = try pre_state.deepClone(allocator);

    post_state.tau = input.slot;

    // Combine previous entropy accumulator (η0) with new entropy
    // input η′0 ≡H(η0 ⌢ Y(Hv))
    post_state.eta[0] = entropy.update(post_state.eta[0], input.entropy);

    // Calculate epoch and slot phase
    const prev_epoch = pre_state.tau / params.epoch_length;
    // const prev_slot_phase = pre_state.tau % EPOCH_LENGTH;
    const current_epoch = input.slot / params.epoch_length;
    // const current_slot_phase = input.slot % EPOCH_LENGTH;

    // Check for epoch transition
    if (current_epoch > prev_epoch) {
        // Perform epoch transition logic here
        // This might include updating gamma_k, kappa, lambda, gamma_z, etc.
        // You'll need to implement this based on the specific requirements in the whitepaper
    }

    // Additional logic for other state updates can be added here

    // Create empty ArrayLists for epoch_mark and tickets_mark

    return .{
        .output = .{
            .ok = types.OutputMarks{
                .epoch_mark = types.EpochMark{
                    .entropy = [_]u8{0} ** 32, // Initialize with 32 zero bytes
                    .validators = try allocator.alloc(types.BandersnatchKey, 0),
                },
                .tickets_mark = null,
            },
        },
        .state = post_state,
    };
}
