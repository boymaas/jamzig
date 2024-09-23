const std = @import("std");
const ArrayList = std.ArrayList;

pub const types = @import("safrole/types.zig");
pub const entropy = @import("safrole/entropy.zig");

const crypto = @import("crypto.zig");

pub const Params = struct {
    epoch_length: u32 = 600,
    // N: The number of ticket entries per validator
    max_ticket_entries_per_validator: u8 = 2,
    // Y: The number of slots into an epoch at which ticket submissions end
    ticket_submission_end_epoch_slot: u32 = 500,
    // K: The maximum tickets which may be submitted in a single extrinsic
    max_tickets_per_extrinsic: u32 = 16,
    // Validators count
    validators_count: u32,
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

    // The slot inside this epoch
    const prev_epoch_slot = pre_state.tau % params.epoch_length;
    const epoch_slot = input.slot % params.epoch_length;

    // Chapter 6.7 Ticketing and extrensics
    // Check the number of ticket attempts in the input when more
    // than N we have a bad ticket attempt
    for (input.extrinsic) |extrinsic| {
        if (extrinsic.attempt >= params.max_ticket_entries_per_validator) {
            return .{
                .output = .{ .err = .bad_ticket_attempt },
                .state = null,
            };
        }
    }

    // We should not have more than K tickets in the input
    if (input.extrinsic.len > params.epoch_length) {
        return .{
            .output = .{ .err = .too_many_tickets_in_extrinsic },
            .state = null,
        };
    }

    // We shuold not have any tickets when the epoch slot < Y
    if (epoch_slot >= params.ticket_submission_end_epoch_slot) {
        if (input.extrinsic.len > 0) {
            return .{
                .output = .{ .err = .unexpected_ticket },
                .state = null,
            };
        }
    }

    // NOTE: we are using pre_state n2 which is weird as I expected n'2 which is post state
    const verified_extrinsic = verifyTicketEnvelope(
        allocator,
        params.validators_count,
        pre_state.gamma_z,
        pre_state.eta[2],
        input.extrinsic,
    ) catch |e| {
        if (e == error.SignatureVerificationFailed) {
            return .{
                .output = .{ .err = .bad_ticket_proof },
                .state = null,
            };
        } else return e;
    };
    defer allocator.free(verified_extrinsic);

    // Chapter 6.7: The tickets should have been placed in order of their
    // implied identifier. Duplicate tickets are not allowed.
    var index: usize = 0;
    while (index < verified_extrinsic.len) : (index += 1) {
        const current_ticket = verified_extrinsic[index];

        // Check if the ticket has already been seen
        var i: usize = 0;
        while (i < index) : (i += 1) {
            if (std.mem.eql(u8, &verified_extrinsic[i].id, &current_ticket.id)) {
                return .{
                    .output = .{ .err = .duplicate_ticket },
                    .state = null,
                };
            }
        }

        // Check if we have an entry in the ordered ticket accumulator
        // gamma_a. If this is the case, we have a duplicate ticket.
        const position = std.sort.binarySearch(types.TicketBody, pre_state.gamma_a, current_ticket, struct {
            fn order(context: types.TicketBody, item: types.TicketBody) std.math.Order {
                return std.mem.order(u8, &item.id, &context.id);
            }
        }.order);
        if (position != null) {
            return .{
                .output = .{ .err = .duplicate_ticket },
                .state = null,
            };
        }

        // Check the order of tickets
        if (index > 0) {
            const prev_ticket = verified_extrinsic[index - 1];
            if (std.mem.order(u8, &current_ticket.id, &prev_ticket.id) == .lt) {
                return .{
                    .output = .{ .err = .bad_ticket_order },
                    .state = null,
                };
            }
        }
    }

    var post_state = try pre_state.deepClone(allocator);
    errdefer post_state.deinit(allocator);

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
        // NOTE: using post_state to update post_state as we are moving pointers around
        const lamda = post_state.lambda;
        const kappa = post_state.kappa;
        const gamma_k = post_state.gamma_k;
        const iota = post_state.iota;

        post_state.kappa = gamma_k;
        post_state.gamma_k = phiZeroOutOffenders(try allocator.dupe(types.ValidatorData, iota));
        post_state.lambda = kappa;
        allocator.free(lamda);

        // post_state.iota seems to stay the same

        // gamma_z is the epoch’s root, a Bandersnatch ring root composed with the
        // one Bandersnatch key of each of the next epoch’s validators, defined
        // in gamma_k
        post_state.gamma_z = try bandersnatchRingRoot(allocator, post_state.gamma_k);

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

        // Gamma_S
        // Free memory here since we are sure we are going to
        // update the value following.
        post_state.gamma_s.deinit(allocator);

        // (68) e′ = e + 1 ∧ m ≥ Y ∧ ∣γa∣ = E
        if (prev_epoch_slot >= params.ticket_submission_end_epoch_slot and
            post_state.gamma_a.len == params.epoch_length and
            // only if e' = e + 1
            current_epoch == prev_epoch + 1)
        {
            post_state.gamma_s = .{
                .tickets = try Z_outsideInOrdering(types.TicketBody, allocator, post_state.gamma_a),
            };
        } else {
            post_state.gamma_s = .{
                .keys = try gammaS_Fallback(allocator, post_state.eta[2], params.epoch_length, post_state.kappa),
            };
        }

        // On an new epoch gamma_a will be reset to 0
        allocator.free(post_state.gamma_a);
        post_state.gamma_a = try allocator.alloc(types.TicketBody, 0);
    }

    // GP0.3.6@(66) Combine previous entropy accumulator (η0) with new entropy
    // input η′0 ≡H(η0 ⌢ Y(Hv))
    post_state.eta[0] = entropy.update(post_state.eta[0], input.entropy);

    // Section 6.7 Ticketing
    // GP0.3.6@(78) Merge the gamma_a and extrinsic tickets into a new ticket
    // within the range ticket competition is happening
    if (epoch_slot < params.ticket_submission_end_epoch_slot) {

        // Merge the tickets into the ticket accumulator
        const merged_gamma_a = try mergeTicketsIntoTicketAccumulatorGammaA(
            allocator,
            post_state.gamma_a,
            verified_extrinsic,
            params.epoch_length,
        );
        allocator.free(post_state.gamma_a);
        post_state.gamma_a = merged_gamma_a;
    }

    // Determine the output
    var epoch_marker: ?types.EpochMark = null;
    var winning_ticket_marker: ?types.TicketMark = null;

    if (current_epoch > prev_epoch) {
        epoch_marker = .{
            .entropy = post_state.eta[1],
            .validators = try extractBandersnatchKeys(allocator, post_state.gamma_k),
        };
    }

    // (72)@GP0.3.6 e′ = e ∧ m < Y ≤ m′ ∧ ∣γa∣ = E
    // Not crossing an epoch boundary
    if (current_epoch == prev_epoch and
        // But crosses the Y boundary
        prev_epoch_slot < params.ticket_submission_end_epoch_slot and
        params.ticket_submission_end_epoch_slot <= epoch_slot and
        // And we have a full epoch worth of tickets accumulated
        post_state.gamma_a.len == params.epoch_length)
    {
        winning_ticket_marker =
            try Z_outsideInOrdering(
            types.TicketBody,
            allocator,
            pre_state.gamma_a,
        );
    }

    return .{
        .output = .{
            .ok = types.OutputMarks{
                .epoch_mark = epoch_marker,
                .tickets_mark = winning_ticket_marker,
            },
        },
        .state = post_state,
    };
}

fn verifyTicketEnvelope(allocator: std.mem.Allocator, ring_size: usize, gamma_z: types.BandersnatchVrfRoot, n2: types.Entropy, extrinsic: []const types.TicketEnvelope) ![]types.TicketBody {
    // For now, map the extrinsic to the ticket setting the ticketbody.id to all 0s
    var tickets = try allocator.alloc(types.TicketBody, extrinsic.len);
    errdefer allocator.free(tickets);

    const empty_aux_data = [_]u8{};

    for (extrinsic, 0..) |extr, i| {
        const X_t = [_]u8{ 'j', 'a', 'm', '_', 't', 'i', 'c', 'k', 'e', 't', '_', 's', 'e', 'a', 'l' };

        const vrf_input = X_t ++ n2 ++ [_]u8{extr.attempt};
        const output = try crypto.verifyRingSignatureAgainstCommitment(
            gamma_z,
            ring_size,
            &vrf_input,
            &empty_aux_data,
            &extr.signature,
        );

        tickets[i].attempt = extr.attempt;
        tickets[i].id = output;
    }

    return tickets;
}

// GP0.3.6@(78) Merges the gamma_a and extrinsic tickets into a new ticket
// accumulator, limited by the epoch length.
fn mergeTicketsIntoTicketAccumulatorGammaA(
    allocator: std.mem.Allocator,
    gamma_a: []types.TicketBody,
    extrinsic: []types.TicketBody,
    epoch_length: u32,
) ![]types.TicketBody {
    const total_tickets = @min(
        gamma_a.len + extrinsic.len,
        epoch_length,
    );
    var merged_tickets = try allocator.alloc(types.TicketBody, total_tickets);

    var i: usize = 0;
    var j: usize = 0;
    var k: usize = 0;

    while (i < gamma_a.len and j < extrinsic.len and k < epoch_length) {
        if (std.mem.lessThan(u8, &gamma_a[i].id, &extrinsic[j].id)) {
            merged_tickets[k] = gamma_a[i];
            i += 1;
        } else {
            merged_tickets[k] = extrinsic[j];
            j += 1;
        }
        k += 1;
    }

    while (i < gamma_a.len and k < epoch_length) {
        merged_tickets[k] = gamma_a[i];
        i += 1;
        k += 1;
    }

    while (j < extrinsic.len and k < epoch_length) {
        merged_tickets[k] = extrinsic[j];
        j += 1;
        k += 1;
    }

    return merged_tickets;
}

// O: See section 3.8 and appendix G
// O(⟦HB⟧) ∈ Yr ≡ KZG_commitment(⟦HB⟧)
fn bandersnatchRingRoot(allocator: std.mem.Allocator, gamma_k: types.GammaK) !types.GammaZ {
    const keys = try extractBandersnatchKeys(allocator, gamma_k);
    defer allocator.free(keys);

    const commitment = try crypto.getVerifierCommitment(keys);
    return commitment;
}

fn extractBandersnatchKeys(allocator: std.mem.Allocator, gamma_k: types.GammaK) ![]types.BandersnatchKey {
    const keys = try allocator.alloc(types.BandersnatchKey, gamma_k.len);
    errdefer allocator.free(keys);

    for (gamma_k, 0..) |validator, i| {
        keys[i] = validator.bandersnatch;
    }

    return keys;
}

// 58. PHI: Zero out any offenders on post_state.iota
fn phiZeroOutOffenders(data: []types.ValidatorData) []types.ValidatorData {
    // TODO: (58) Zero out any offenders on post_state.iota, The origin of
    // the offenders is explained in section 10.
    return data;
}

/// Fallback function selects an epoch’s worth of validator Bandersnatch keys
/// from the validator key set k using the entropy collected on chain
fn gammaS_Fallback(
    allocator: std.mem.Allocator,
    r: types.OpaqueHash,
    epoch_length: u32,
    kappa: types.Kappa,
) ![]types.BandersnatchKey {
    const keys = try extractBandersnatchKeys(allocator, kappa);
    defer allocator.free(keys);

    // Allocate memory of the same length as keys to return
    var result = try allocator.alloc(types.BandersnatchKey, epoch_length);
    errdefer allocator.free(result);

    for (0..epoch_length) |i| {
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
