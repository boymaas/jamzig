const std = @import("std");
const ArrayList = std.ArrayList;

pub const types = @import("types.zig");
pub const safrole_types = @import("safrole/types.zig");
pub const state = @import("state.zig");
pub const time = @import("time.zig");

const state_d = @import("state_delta.zig");
const StateTransition = state_d.StateTransition;

pub const entropy = @import("entropy.zig");

pub const jam_params = @import("jam_params.zig");

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
} || std.mem.Allocator.Error || ring_vrf.Error || state_d.Error;

pub const Result = struct {
    epoch_marker: ?types.EpochMark,
    ticket_marker: ?types.TicketsMark,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.deinit_markers(allocator);
    }

    // TODO: this can be removed
    pub fn deinit_markers(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.epoch_marker) |*marker| {
            allocator.free(marker.validators);
        }
        if (self.ticket_marker) |*marker| {
            allocator.free(marker.tickets);
        }
    }

    /// Takes ownership of the epoch marker and sets it to null
    pub fn takeEpochMarker(self: *@This()) ?types.EpochMark {
        const marker = self.epoch_marker;
        self.epoch_marker = null;
        return marker;
    }

    /// Takes ownership of the ticket marker and sets it to null
    pub fn takeTicketMarker(self: *@This()) ?types.TicketsMark {
        const marker = self.ticket_marker;
        self.ticket_marker = null;
        return marker;
    }
};

// Extracted ticket processing logic
fn processTicketExtrinsic(
    comptime params: Params,
    stx: *StateTransition(params),
    ticket_extrinsic: types.TicketsExtrinsic,
) Error![]types.TicketBody {
    const span = trace.span(.process_ticket_extrinsic);
    defer span.deinit();
    span.debug("Processing ticket extrinsic", .{});

    // Process tickets if not in epoch's tail
    if (stx.time.current_slot >= params.ticket_submission_end_epoch_slot) {
        if (ticket_extrinsic.data.len > 0) {
            span.err("Received ticket extrinsic in epoch's tail", .{});
            return Error.unexpected_ticket;
        }
    }

    // Chapter 6.7 Ticketing and extrensics
    // Check the number of ticket attempts in the input when more than N we have a bad ticket attempt
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

    // Verify ticket envelope
    const gamma = try stx.ensure(.gamma);
    const eta_prime = try stx.ensure(.eta_prime);
    const verified_extrinsic = verifyTicketEnvelope(
        stx.allocator,
        params.validators_count,
        &gamma.z,
        eta_prime[2],
        ticket_extrinsic.data,
    ) catch |e| {
        if (e == error.SignatureVerificationFailed) {
            return Error.bad_ticket_proof;
        } else return e;
    };
    errdefer stx.allocator.free(verified_extrinsic);

    // Chapter 6.7: The tickets should be in order of their implied identifier
    var index: usize = 0;
    while (index < verified_extrinsic.len) : (index += 1) {
        const current_ticket = verified_extrinsic[index];

        // Check order and duplicates with previous ticket
        if (index > 0) {
            const order = std.mem.order(u8, &current_ticket.id, &verified_extrinsic[index - 1].id);
            switch (order) {
                .lt => return Error.bad_ticket_order,
                .eq => return Error.duplicate_ticket,
                .gt => {},
            }
        }

        // Check for duplicates in gamma_a using binary search
        std.debug.assert(blk: {
            if (gamma.a.len <= 1) break :blk true;
            var i: usize = 1;
            while (i < gamma.a.len) : (i += 1) {
                if (!std.mem.lessThan(u8, &gamma.a[i - 1].id, &gamma.a[i].id)) break :blk false;
            }
            break :blk true;
        });

        const position = std.sort.binarySearch(types.TicketBody, gamma.a, current_ticket, struct {
            fn order(context: types.TicketBody, item: types.TicketBody) std.math.Order {
                return std.mem.order(u8, &context.id, &item.id);
            }
        }.order);

        if (position != null) {
            span.warn("Found duplicate ticket ID: {s}", .{std.fmt.fmtSliceHexLower(&current_ticket.id)});
            span.trace("Current gamma_a contents:", .{});
            for (gamma.a, 0..) |ticket, idx| {
                span.trace("  [{d}] ID: {s}", .{ idx, std.fmt.fmtSliceHexLower(&ticket.id) });
            }
            return Error.duplicate_ticket;
        }
    }

    return verified_extrinsic;
}

// Extracted epoch transition logic
fn transitionEpoch(
    comptime params: Params,
    allocator: std.mem.Allocator,
    stx: *StateTransition(params),
) !void {
    const span = trace.span(.transition_epoch);
    defer span.deinit();
    span.debug("Starting epoch transition", .{});

    // Get current states we need
    const current_kappa = try stx.ensure(.kappa);
    const current_gamma = try stx.ensure(.gamma);
    const current_iota = try stx.ensure(.iota);
    const eta_prime = try stx.ensure(.eta_prime);

    // Rotate validator keys
    span.debug("Rotating validator keys", .{});

    // λ gets current κ
    try stx.initialize(.lambda_prime, try current_kappa.deepClone(allocator));

    // κ gets current γ.k
    try stx.initialize(.kappa_prime, try current_gamma.k.deepClone(allocator));

    // Create new gamma state
    var gamma_prime: *state.Gamma(params.validators_count, params.epoch_length) //
        = try stx.ensure(.gamma_prime);

    // γ.k gets ι (with offenders zeroed out)
    const current_psi = try stx.ensure(.psi);
    gamma_prime.k.deinit(allocator);
    gamma_prime.k = phiZeroOutOffenders(
        try current_iota.deepClone(allocator),
        current_psi.offendersSlice(),
    );

    // Calculate new gamma_z
    span.debug("Calculating new gamma_z from gamma_k", .{});
    gamma_prime.z = try bandersnatchRingRoot(allocator, gamma_prime.k);
    span.trace("New gamma_z value: {any}", .{std.fmt.fmtSliceHexLower(&gamma_prime.z)});

    // Handle gamma_s transition
    const gamma_s = &gamma_prime.s;
    gamma_s.deinit(allocator);
    _ = gamma_s.clearAndTakeOwnership();

    // Update gamma_s based on conditions
    if (stx.time.prior_slot_in_epoch >= params.ticket_submission_end_epoch_slot and
        current_gamma.a.len == params.epoch_length and
        stx.time.current_epoch == stx.time.prior_epoch + 1)
    {
        span.debug("Operating in ticket mode for gamma_s", .{});
        span.trace("Conditions met: prev_slot({d}) >= Y({d}) and gamma_a.len({d}) == epoch_length({d}) and current_epoch({d}) == prior_epoch({d}) + 1)", .{
            stx.time.prior_slot_in_epoch,
            params.ticket_submission_end_epoch_slot,
            current_gamma.a.len,
            params.epoch_length,
            stx.time.current_epoch,
            stx.time.prior_epoch,
        });
        gamma_s.* = .{
            .tickets = try Z_outsideInOrdering(types.TicketBody, allocator, current_gamma.a),
        };
    } else {
        span.warn("Falling back to key mode for gamma_s", .{});

        if (current_gamma.a.len != params.epoch_length) {
            span.warn("  - Gamma accumulator size {d} != epoch length {d}", .{ current_gamma.a.len, params.epoch_length });
        }
        if (stx.time.current_epoch != stx.time.prior_epoch + 1) {
            span.warn("  - Current epoch {d} != prior epoch + 1 ({d})", .{ stx.time.current_epoch, stx.time.prior_epoch + 1 });
        }

        const kappa_prime = try stx.ensure(.kappa_prime);
        gamma_s.* = .{
            .keys = try gammaS_Fallback(allocator, eta_prime[2], params.epoch_length, kappa_prime.*),
        };
    }

    // Reset gamma_a
    span.debug("Resetting gamma_a ticket accumulator at epoch boundary", .{});
    span.trace("Freeing previous gamma_a with {d} tickets", .{current_gamma.a.len});
    allocator.free(gamma_prime.a);
    gamma_prime.a = &[_]types.TicketBody{};
}

// Main transition function using extracted components
pub fn transition(
    comptime params: Params,
    allocator: std.mem.Allocator,
    stx: *StateTransition(params),
    ticket_extrinsic: types.TicketsExtrinsic,
) Error!Result {
    const span = trace.span(.transition);
    defer span.deinit();
    span.debug("Starting state transition", .{});

    // Process ticket extrinsic
    const verified_extrinsic = try processTicketExtrinsic(params, stx, ticket_extrinsic);
    defer allocator.free(verified_extrinsic);

    // Handle epoch transition if needed
    if (stx.time.isNewEpoch()) {
        try transitionEpoch(
            params,
            allocator,
            stx,
        );
    }

    // Process tickets within submission window
    const gamma = try stx.ensure(.gamma);
    const gamma_prime = try stx.ensure(.gamma_prime);
    if (stx.time.is_in_ticket_submission_period) {
        span.debug("Processing ticket submissions", .{});
        const merged_gamma_a = try mergeTicketsIntoTicketAccumulatorGammaA(
            allocator,
            gamma.a,
            verified_extrinsic,
            params.epoch_length,
        );
        allocator.free(gamma_prime.a);
        gamma_prime.a = merged_gamma_a;
    }

    // Generate markers
    span.debug("Determining output markers", .{});
    var epoch_marker: ?types.EpochMark = null;
    var winning_ticket_marker: ?types.TicketsMark = null;

    if (stx.time.isNewEpoch()) {
        span.debug("Creating epoch marker", .{});
        epoch_marker = .{
            .entropy = (try stx.ensure(.eta_prime))[1],
            .tickets_entropy = (try stx.ensure(.eta_prime))[2],
            .validators = try extractBandersnatchKeys(allocator, gamma_prime.k),
        };
    }

    if (stx.time.current_epoch == stx.time.prior_epoch and
        stx.time.prior_slot_in_epoch < params.ticket_submission_end_epoch_slot and
        params.ticket_submission_end_epoch_slot <= stx.time.current_slot_in_epoch and
        gamma.a.len == params.epoch_length) // TODO: check if this should not be gamma_prime.a
    {
        winning_ticket_marker = .{
            .tickets = try Z_outsideInOrdering(
                types.TicketBody,
                allocator,
                gamma.a,
            ),
        };
    }

    return .{
        .epoch_marker = epoch_marker,
        .ticket_marker = winning_ticket_marker,
    };
}

fn verifyTicketEnvelope(
    allocator: std.mem.Allocator,
    ring_size: usize,
    gamma_z: *const types.BandersnatchVrfRoot,
    n2: types.Entropy,
    extrinsic: []const types.TicketEnvelope,
) ![]types.TicketBody {
    const span = trace.span(.verify_ticket_envelope);
    defer span.deinit();
    span.debug("Verifying {d} ticket envelopes", .{extrinsic.len});
    span.trace("Ring size: {d}, gamma_z: {any}, n2: {any}", .{
        ring_size,
        std.fmt.fmtSliceHexLower(gamma_z),
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
        span.trace("Verifying ticket envelope [{d}]:", .{i});
        span.trace("  Attempt: {d}", .{extr.attempt});
        span.trace("  Signature: {s}", .{std.fmt.fmtSliceHexLower(&extr.signature)});

        // TODO: rewrite
        const vrf_input = "jam_ticket_seal" ++ n2 ++ [_]u8{extr.attempt};

        const output = try ring_vrf.verifyRingSignatureAgainstCommitment(
            gamma_z,
            ring_size,
            vrf_input,
            &empty_aux_data,
            &extr.signature,
        );
        span.trace("  VRF output (ticket ID): {s}", .{std.fmt.fmtSliceHexLower(&output)});

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
