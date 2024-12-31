const std = @import("std");
const ArrayList = std.ArrayList;

pub const types = @import("types.zig");
pub const safrole_types = @import("safrole/types.zig");
pub const entropy = @import("safrole/entropy.zig");
pub const state = @import("state.zig");

const crypto = @import("crypto.zig");
const ring_vrf = @import("ring_vrf.zig");

const trace = @import("tracing.zig").scoped(.safrole);

pub const Params = @import("jam_params.zig").Params;

pub const Error = error{
    /// Bad slot value.
    bad_slot,
    /// Received a ticket while in epoch's tail.
    unexpected_ticket,
    /// Tickets must be sorted.
    bad_ticket_order,
    /// Invalid ticket ring proof.
    bad_ticket_proof,
    /// Invalid ticket attempt value.
    bad_ticket_attempt,
    /// Reserved
    reserved,
    /// Found a ticket duplicate.
    duplicate_ticket,
    /// Too_many_tickets_in_extrinsic
    too_many_tickets_in_extrinsic,
} || std.mem.Allocator.Error || ring_vrf.Error;

pub const Result = struct {
    post_state: safrole_types.State,
    epoch_marker: ?types.EpochMark,
    ticket_marker: ?types.TicketsMark,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        self.post_state.deinit(allocator);
        self.deinit_markers(allocator);
    }

    pub fn deinit_markers(self: *Result, allocator: std.mem.Allocator) void {
        if (self.epoch_marker) |*marker| {
            allocator.free(marker.validators);
        }
        if (self.ticket_marker) |*marker| {
            allocator.free(marker.tickets);
        }
    }
};

// TODO: swap params and allocator, use params first
pub fn transition(
    allocator: std.mem.Allocator,
    params: Params,
    pre_state: *const safrole_types.State,
    slot: types.TimeSlot,
    bandersnatch_vrf_output: types.BandersnatchVrfOutput,
    ticket_extrinsic: types.TicketsExtrinsic,
    offenders: []const types.Ed25519Public,
) Error!Result {
    const span = trace.span(.transition);
    defer span.deinit();
    span.debug("Starting state transition", .{});
    span.trace("Input parameters: slot={d}, vrf_output={any}, num_tickets={d}, num_offenders={d}", .{
        slot,
        std.fmt.fmtSliceHexLower(&bandersnatch_vrf_output),
        ticket_extrinsic.data.len,
        offenders.len,
    });

    // Equation 41: H_t ∈ N_T, P(H)_t < H_t ∧ H_t · P ≤ T
    if (slot <= pre_state.tau) {
        span.err("Invalid slot: new slot {d} <= current tau {d}", .{ slot, pre_state.tau });
        return Error.bad_slot;
    }

    // The slot inside this epoch
    const prev_epoch_slot = pre_state.tau % params.epoch_length;
    const epoch_slot = slot % params.epoch_length;

    // Chapter 6.7 Ticketing and extrensics
    // Check the number of ticket attempts in the input when more
    // than N we have a bad ticket attempt
    for (ticket_extrinsic.data) |extrinsic| {
        if (extrinsic.attempt >= params.max_ticket_entries_per_validator) {
            std.debug.print("attempt {d}\n", .{extrinsic.attempt});
            return Error.bad_ticket_attempt;
        }
    }

    // We should not have more than K tickets in the input
    if (ticket_extrinsic.data.len > params.epoch_length) {
        return Error.too_many_tickets_in_extrinsic;
    }

    // We shuold not have any tickets when the epoch slot < Y
    if (epoch_slot >= params.ticket_submission_end_epoch_slot) {
        if (ticket_extrinsic.data.len > 0) {
            return Error.unexpected_ticket;
        }
    }

    // NOTE: we are using pre_state n2 which is weird as I expected n'2 which is post state
    const verified_extrinsic = verifyTicketEnvelope(
        allocator,
        params.validators_count,
        pre_state.gamma_z,
        pre_state.eta[2],
        ticket_extrinsic.data,
    ) catch |e| {
        if (e == error.SignatureVerificationFailed) {
            return Error.bad_ticket_proof;
        } else return e;
    };
    defer allocator.free(verified_extrinsic);

    // Chapter 6.7: The tickets should be in order of their implied identifier.
    // Duplicate tickets are not allowed.
    var index: usize = 0;
    while (index < verified_extrinsic.len) : (index += 1) {
        const current_ticket = verified_extrinsic[index];

        // Since the list should be ordered, we only need to check the previous
        // ticket for order and duplicates within verified_extrinsic.
        // This replaces the O(n^2) duplicate check with an O(n) check.
        if (index > 0) {
            const order = std.mem.order(u8, &current_ticket.id, &verified_extrinsic[index - 1].id);
            switch (order) {
                .lt => return Error.bad_ticket_order, // Out of order
                .eq => return Error.duplicate_ticket, // Duplicate found
                .gt => {}, // Correct ordering
            }
        }

        // Check for duplicates in gamma_a using binary search
        // This is already efficient (O(log n)) and doesn't need modification
        // Verify gamma_a is sorted (debug only)
        // TODO: move this into a module for debug level assertions
        std.debug.assert(blk: {
            if (pre_state.gamma_a.len <= 1) break :blk true;
            var i: usize = 1;
            while (i < pre_state.gamma_a.len) : (i += 1) {
                if (!std.mem.lessThan(u8, &pre_state.gamma_a[i - 1].id, &pre_state.gamma_a[i].id)) break :blk false;
            }
            break :blk true;
        });

        // NOTE: we only check on id for duplicates
        const position = std.sort.binarySearch(types.TicketBody, pre_state.gamma_a, current_ticket, struct {
            fn order(context: types.TicketBody, item: types.TicketBody) std.math.Order {
                return std.mem.order(u8, &context.id, &item.id);
            }
        }.order);

        if (position != null) {
            span.warn("Found duplicate ticket ID: {s}", .{std.fmt.fmtSliceHexLower(&current_ticket.id)});
            span.trace("Current gamma_a contents:", .{});
            for (pre_state.gamma_a, 0..) |ticket, idx| {
                span.trace("  [{d}] ID: {s}", .{ idx, std.fmt.fmtSliceHexLower(&ticket.id) });
            }
            return Error.duplicate_ticket;
        }
    }

    var post_state = try pre_state.deepClone(allocator);
    errdefer post_state.deinit(allocator);

    // Update the tau
    post_state.tau = slot;

    // Calculate epoch and slot phase
    const prev_epoch = pre_state.tau / params.epoch_length;
    // const prev_slot_phase = pre_state.tau % EPOCH_LENGTH;
    const current_epoch = slot / params.epoch_length;
    // const current_slot_phase = input.slot % EPOCH_LENGTH;

    span.trace("Epoch transition check: current_epoch={d}, prev_epoch={d}", .{ current_epoch, prev_epoch });
    if (current_epoch > prev_epoch) {
        span.debug("Starting epoch transition", .{});
        // (67) Perform epoch transition logic here
        span.trace("Rotating entropy values: eta[2]={any}, eta[1]={any}, eta[0]={any}", .{
            std.fmt.fmtSliceHexLower(&post_state.eta[2]),
            std.fmt.fmtSliceHexLower(&post_state.eta[1]),
            std.fmt.fmtSliceHexLower(&post_state.eta[0]),
        });
        post_state.eta[3] = post_state.eta[2];
        post_state.eta[2] = post_state.eta[1];
        post_state.eta[1] = post_state.eta[0];

        // (57) Validator keys are rotated at the beginning of each epoch. The
        // current active set of validator keys κ is replaced by the queued
        // set, and any offenders (validators removed from the set) are
        // replaced with zeroed keys.
        //
        // NOTE: using post_state to update post_state as we are moving pointers around
        const lamda = post_state.lambda; // X
        const kappa = post_state.kappa; // X
        const gamma_k = post_state.gamma_k; // X
        const iota = post_state.iota; // X

        span.debug("Rotating validator keys", .{});
        span.trace("Current kappa size: {d}, gamma_k size: {d}", .{ post_state.kappa.len(), gamma_k.len() });
        post_state.kappa = gamma_k;
        span.debug("Applying offender removal to iota", .{});
        post_state.gamma_k = phiZeroOutOffenders(
            // Need to deepClone, as we also need post_state.iota to
            // stay unchanged
            try iota.deepClone(allocator),
            offenders,
        );
        post_state.lambda = kappa;
        // lambda is phasing out, so we can free it
        lamda.deinit(allocator);
        // post_state.iota seems to stay the same

        // gamma_z is the epoch’s root, a Bandersnatch ring root composed with the
        // one Bandersnatch key of each of the next epoch’s validators, defined
        // in gamma_k
        span.debug("Calculating new gamma_z from gamma_k", .{});
        post_state.gamma_z = try bandersnatchRingRoot(allocator, post_state.gamma_k);
        span.trace("New gamma_z value: {any}", .{std.fmt.fmtSliceHexLower(&post_state.gamma_z)});

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

        // NOTE: take ownership as post_state.gamma_s is going to be updated
        // but could fail. Which would trigger the errdefer which would
        // lead to a double free.
        post_state.gamma_s.deinit(allocator);
        _ = post_state.gamma_s.clearAndTakeOwnership();

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
        post_state.gamma_a = &[_]types.TicketBody{};
    }

    // GP0.3.6@(66) Combine previous entropy accumulator (η0) with new entropy
    // input η′0 ≡H(η0 ⌢ Y(Hv))
    span.debug("Updating entropy accumulator eta[0]", .{});
    span.trace("Current eta[0]={any}, vrf_output={any}", .{
        std.fmt.fmtSliceHexLower(&post_state.eta[0]),
        std.fmt.fmtSliceHexLower(&bandersnatch_vrf_output),
    });
    post_state.eta[0] = entropy.update(post_state.eta[0], bandersnatch_vrf_output);
    span.trace("New eta[0]={any}", .{std.fmt.fmtSliceHexLower(&post_state.eta[0])});

    // Section 6.7 Ticketing
    // GP0.3.6@(78) Merge the gamma_a and extrinsic tickets into a new ticket
    // within the range ticket competition is happening
    span.trace("Ticket submission check: epoch_slot={d}, submission_end={d}", .{ epoch_slot, params.ticket_submission_end_epoch_slot });
    if (epoch_slot < params.ticket_submission_end_epoch_slot) {
        span.debug("Processing ticket submissions", .{});

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

    span.debug("Determining output markers", .{});
    var epoch_marker: ?types.EpochMark = null;
    var winning_ticket_marker: ?types.TicketsMark = null;

    span.trace("Epoch marker check: current_epoch={d}, prev_epoch={d}", .{ current_epoch, prev_epoch });
    if (current_epoch > prev_epoch) {
        span.debug("Creating epoch marker", .{});
        epoch_marker = .{
            .entropy = post_state.eta[1],
            .tickets_entropy = post_state.eta[2], // TODO: check GP for what this is
            // TODO: place this function on the validator set level.
            .validators = try extractBandersnatchKeys(allocator, post_state.gamma_k),
        };
    }
    errdefer if (epoch_marker) |*marker| {
        allocator.free(marker.validators);
    };

    // (72)@GP0.3.6 e′ = e ∧ m < Y ≤ m′ ∧ ∣γa∣ = E
    // Not crossing an epoch boundary
    if (current_epoch == prev_epoch and
        // But crosses the Y boundary
        prev_epoch_slot < params.ticket_submission_end_epoch_slot and
        params.ticket_submission_end_epoch_slot <= epoch_slot and
        // And we have a full epoch worth of tickets accumulated
        post_state.gamma_a.len == params.epoch_length)
    {
        winning_ticket_marker = .{
            .tickets = try Z_outsideInOrdering(
                types.TicketBody,
                allocator,
                pre_state.gamma_a,
            ),
        };
    }

    return Result{
        .post_state = post_state,
        .epoch_marker = epoch_marker,
        .ticket_marker = winning_ticket_marker,
    };
}

fn verifyTicketEnvelope(
    allocator: std.mem.Allocator,
    ring_size: usize,
    gamma_z: types.BandersnatchVrfRoot,
    n2: types.Entropy,
    extrinsic: []const types.TicketEnvelope,
) ![]types.TicketBody {
    const span = trace.span(.verify_ticket_envelope);
    defer span.deinit();
    span.debug("Verifying {d} ticket envelopes", .{extrinsic.len});
    span.trace("Ring size: {d}, gamma_z: {any}, n2: {any}", .{
        ring_size,
        std.fmt.fmtSliceHexLower(&gamma_z),
        std.fmt.fmtSliceHexLower(&n2),
    });

    // For now, map the extrinsic to the ticket setting the ticketbody.id to all 0s
    var tickets = try allocator.alloc(types.TicketBody, extrinsic.len);
    errdefer {
        span.debug("Cleanup after error - freeing tickets", .{});
        allocator.free(tickets);
    }

    const empty_aux_data = [_]u8{};

    for (extrinsic, 0..) |extr, i| {
        // TODO: rewrite
        const vrf_input = "jam_ticket_seal" ++ n2 ++ [_]u8{extr.attempt};
        const output = try ring_vrf.verifyRingSignatureAgainstCommitment(
            gamma_z,
            ring_size,
            vrf_input,
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
    const span = trace.span(.merge_tickets);
    defer span.deinit();
    span.debug("Merging tickets into accumulator gamma_a", .{});
    span.trace("Current gamma_a size: {d}, extrinsic size: {d}, epoch length: {d}", .{
        gamma_a.len,
        extrinsic.len,
        epoch_length,
    });

    const total_tickets = @min(
        gamma_a.len + extrinsic.len,
        epoch_length,
    );
    span.debug("Will merge {d} total tickets", .{total_tickets});
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
fn bandersnatchRingRoot(
    allocator: std.mem.Allocator,
    gamma_k: types.GammaK,
) !types.GammaZ {
    const span = trace.span(.bandersnatch_ring_root);
    defer span.deinit();
    span.debug("Calculating Bandersnatch ring root from gamma_k", .{});
    span.trace("Number of validator keys in gamma_k: {d}", .{gamma_k.len()});

    // Extract the Bandersnatch public keys
    const keys = try extractBandersnatchKeys(allocator, gamma_k);
    defer {
        span.debug("Cleanup - freeing extracted keys", .{});
        allocator.free(keys);
    }

    // Create a ring verifier instance
    var verifier = try ring_vrf.RingVerifier.init(keys);
    defer verifier.deinit();

    // Get the commitment using the verifier
    const commitment = try verifier.get_commitment();
    return commitment;
}

// TODO: this can be placed on the ValidatorSet now
fn extractBandersnatchKeys(allocator: std.mem.Allocator, gamma_k: types.GammaK) ![]types.BandersnatchPublic {
    const keys = try allocator.alloc(types.BandersnatchPublic, gamma_k.len());

    for (gamma_k.items(), 0..) |validator, i| {
        keys[i] = validator.bandersnatch;
    }

    return keys;
}

// 58. PHI: Zero out any offenders on post_state.iota
fn phiZeroOutOffenders(data: types.ValidatorSet, offenders: []const types.Ed25519Public) types.ValidatorSet {
    // TODO: (58) Zero out any offenders on post_state.iota, The origin of
    // the offenders is explained in section 10.
    for (data.items()) |*validator_data| {
        // check if in offenders list
        for (offenders) |*offender| {
            if (std.mem.eql(u8, offender, &validator_data.*.ed25519)) {
                std.debug.print("Validator data to 0", .{});
                validator_data.* = std.mem.zeroes(types.ValidatorData);
            }
        }
    }
    return data;
}

/// Fallback function selects an epoch’s worth of validator Bandersnatch keys
/// from the validator key set k using the entropy collected on chain
pub fn gammaS_Fallback(
    allocator: std.mem.Allocator,
    r: types.OpaqueHash,
    epoch_length: u32,
    kappa: types.Kappa,
) ![]types.BandersnatchPublic {
    const span = trace.span(.gamma_s_fallback);
    defer span.deinit();
    span.debug("Generating fallback gamma_s", .{});
    span.trace("Input parameters: r={any}, epoch_length={d}, kappa_size={d}", .{
        std.fmt.fmtSliceHexLower(&r),
        epoch_length,
        kappa.len(),
    });

    const keys = try extractBandersnatchKeys(allocator, kappa);
    defer {
        span.debug("Cleanup - freeing extracted keys", .{});
        allocator.free(keys);
    }

    // Allocate memory of the same length as keys to return
    var result = try allocator.alloc(types.BandersnatchPublic, epoch_length);
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
pub fn Z_outsideInOrdering(comptime T: type, allocator: std.mem.Allocator, data: []const T) ![]T {
    const span = trace.span(.z_outside_in_ordering);
    defer span.deinit();
    span.debug("Performing outside-in ordering on type {s}", .{@typeName(T)});
    span.trace("Input data length: {d}", .{data.len});

    const len = data.len;
    const result = try allocator.alloc(T, len);

    if (len == 0) {
        span.debug("Empty input data, returning empty result", .{});
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
