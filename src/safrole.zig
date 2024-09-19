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

    // Update the tau
    post_state.tau = input.slot;

    // Calculate epoch and slot phase
    const prev_epoch = pre_state.tau / params.epoch_length;
    // const prev_slot_phase = pre_state.tau % EPOCH_LENGTH;
    const current_epoch = input.slot / params.epoch_length;
    // const current_slot_phase = input.slot % EPOCH_LENGTH;

    // Check for epoch transition
    if (current_epoch > prev_epoch) {
        // (67) Perform epoch transition logic here
        post_state.eta[3] = post_state.eta[2];
        post_state.eta[2] = post_state.eta[1];
        post_state.eta[1] = post_state.eta[0];

        // (57) Validator keys are rotated at the beginning of each epoch. The
        // current active set of validator keys κ is replaced by the queued
        // set, and any offenders (validators removed from the set) are
        // replaced with zeroed keys.
        //
        const lamda = post_state.lambda;
        const kappa = post_state.kappa;
        const gamma_k = post_state.gamma_k;
        const iota = post_state.iota;

        post_state.kappa = gamma_k;
        post_state.gamma_k = phiZeroOutOffenders(try allocator.dupe(types.ValidatorData, iota));
        post_state.lambda = kappa;
        allocator.free(lamda);

        post_state.gamma_z = bandersnatchRingRoot(gamma_k);

        // Check the state of gamma_s union
        //
        // (48) either keys or ticketsare in fallback mode.
        // γs is the current epoch’s slot-sealer series, which is either a
        // full complement of E tickets or, in the case of a fallback
        // mode, a series of E Bandersnatch keys:

        // (68) The posterior slot key sequence gamma_s' is one of three expressions
        // depending on the circumstance of the block. If the block is not the
        // first in an epoch, then it remains unchanged from the prior γs. If
        // the block signals the next epoch (by epoch index) and the previous
        // block’s slot was within the closing period of the previous epoch,
        // then it takes the value of the prior ticket accumulator γa.

        // TODO: determine if this is the first block in the new epoch
        switch (post_state.gamma_s) {
            .tickets => |tickets| {
                // We can use the Z_outsideInOrdering algorithm on tickets
                post_state.gamma_s.tickets = try Z_outsideInOrdering(types.TicketBody, allocator, tickets);
                allocator.free(tickets);
            },
            // fallback
            .keys => |keys| {
                // We are in fallback mode
                post_state.gamma_s.keys = try gammaS_Fallback(allocator, post_state.eta[2], keys);
                allocator.free(keys);
            },
        }
    }

    // (66) Combine previous entropy accumulator (η0) with new entropy
    // input η′0 ≡H(η0 ⌢ Y(Hv))
    post_state.eta[0] = entropy.update(post_state.eta[0], input.entropy);

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

// O: See section 3.8 and appendix G
// O(⟦HB⟧) ∈ Yr ≡ KZG_commitment(⟦HB⟧)
fn bandersnatchRingRoot(gamma_k: types.GammaK) types.GammaZ {
    _ = gamma_k;
    return [_]u8{0} ** 144;
}

// 58. PHI: Zero out any offenders on post_state.iota
fn phiZeroOutOffenders(data: []types.ValidatorData) []types.ValidatorData {
    // TODO: (58) Zero out any offenders on post_state.iota, The origin of
    // the offenders is explained in section 10.
    return data;
}

fn gammaS_Fallback(
    allocator: std.mem.Allocator,
    r: types.OpaqueHash,
    keys: []types.BandersnatchKey,
) ![]types.BandersnatchKey {
    // Allocate memory of the same length as keys to return
    var result = try allocator.alloc(types.BandersnatchKey, keys.len);
    errdefer allocator.free(result);

    for (keys, 0..) |_, i| {
        // Step 1: Encode the index i into 4 bytes (u32)
        var encoded_index: [4]u8 = undefined;
        std.mem.writeInt(u32, &encoded_index, @intCast(i), .little);

        // Step 2: Concatenate r with the encoded value
        const concatenated = r ++ encoded_index;

        // Step 3: Hash the concatenated value and take the first 4 bytes
        var hashed = entropy.hash(&concatenated);
        var first_4_bytes: [4]u8 = hashed[0..4].*;

        // Step 4: Decode the result
        const decoded = std.mem.readInt(u32, &first_4_bytes, .little);

        // Step 5: Take the modulus over the length of the keys
        const index = decoded % keys.len;

        std.debug.print("Index: {}\n", .{index});

        // Step 6: Use this index to add that key to the result
        result[i] = keys[index];
    }

    return result;
}

// (69) Outside in ordering function
fn Z_outsideInOrdering(comptime T: type, allocator: std.mem.Allocator, data: []const T) ![]T {
    const len = data.len;
    const result = try allocator.alloc(T, len);

    if (len == 0) {
        return result;
    }

    var left: usize = 0;
    var right: usize = len - 1;
    var index: usize = 0;

    while (left <= right) : (index += 1) {
        if (index % 2 == 0) {
            result[index] = data[left];
            left += 1;
        } else {
            result[index] = data[right];
            right -= 1;
        }
    }

    return result;
}

test "Z_outsideInOrdering" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test case 1: Even number of elements
    {
        const input = [_]u32{ 1, 2, 3, 4, 5, 6 };
        const result = try Z_outsideInOrdering(u32, allocator, &input);
        defer allocator.free(result);

        try testing.expectEqualSlices(u32, &[_]u32{ 1, 6, 2, 5, 3, 4 }, result);
    }

    // Test case 2: Odd number of elements
    {
        const input = [_]u32{ 1, 2, 3, 4, 5 };
        const result = try Z_outsideInOrdering(u32, allocator, &input);
        defer allocator.free(result);

        try testing.expectEqualSlices(u32, &[_]u32{ 1, 5, 2, 4, 3 }, result);
    }

    // Test case 3: Single element
    {
        const input = [_]u32{1};
        const result = try Z_outsideInOrdering(u32, allocator, &input);
        defer allocator.free(result);

        try testing.expectEqualSlices(u32, &[_]u32{1}, result);
    }

    // Test case 4: Empty input
    {
        const input = [_]u32{};
        const result = try Z_outsideInOrdering(u32, allocator, &input);
        defer allocator.free(result);

        try testing.expectEqualSlices(u32, &[_]u32{}, result);
    }
}
