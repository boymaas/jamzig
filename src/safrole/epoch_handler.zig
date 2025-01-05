const std = @import("std");

const types = @import("../types.zig");
const state = @import("../state.zig");
const state_d = @import("../state_delta.zig");
const ordering = @import("ordering.zig");
const entropy = @import("../entropy.zig");

const ring_vrf = @import("../ring_vrf.zig");

const Params = @import("../jam_params.zig").Params;
const StateTransition = state_d.StateTransition;

const trace = @import("../tracing.zig").scoped(.epoch_handler);

/// Transitions the epoch, handling validator rotation and state updates
pub fn handleEpochTransition(
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
    gamma_prime.k = zeroOutOffenders(
        try current_iota.deepClone(allocator),
        current_psi.offendersSlice(),
    );

    // Calculate new gamma_z
    span.debug("Calculating new gamma_z from gamma_k", .{});
    gamma_prime.z = try buildBandersnatchRingRoot(allocator, gamma_prime.k);
    span.trace("New gamma_z value: {any}", .{std.fmt.fmtSliceHexLower(&gamma_prime.z)});

    // Handle gamma_s transition
    const gamma_s = &gamma_prime.s;
    gamma_s.deinit(allocator);
    _ = gamma_s.clearAndTakeOwnership();

    // Update gamma_s based on conditions
    if (stx.time.priorWasInTicketSubmissionTail() and
        current_gamma.a.len == params.epoch_length and
        stx.time.isConsecutiveEpoch())
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
            .tickets = try ordering.outsideInOrdering(types.TicketBody, allocator, current_gamma.a),
        };
    } else {
        span.warn("Falling back to key mode for gamma_s", .{});

        if (current_gamma.a.len != params.epoch_length) {
            span.warn("  - Gamma accumulator size {d} != epoch length {d}", .{ current_gamma.a.len, params.epoch_length });
        }
        if (!stx.time.isConsecutiveEpoch()) {
            span.warn("  - Current epoch {d} != prior epoch + 1 ({d})", .{ stx.time.current_epoch, stx.time.prior_epoch + 1 });
        }

        const kappa_prime = try stx.ensure(.kappa_prime);
        gamma_s.* = .{
            .keys = try entropyBasedKeySelector(allocator, eta_prime[2], params.epoch_length, kappa_prime.*),
        };
    }

    // Reset gamma_a
    span.debug("Resetting gamma_a ticket accumulator at epoch boundary", .{});
    span.trace("Freeing previous gamma_a with {d} tickets", .{current_gamma.a.len});
    allocator.free(gamma_prime.a);
    gamma_prime.a = &[_]types.TicketBody{};
}

// 58. PHI: Zero out any offenders on post_state.iota
fn zeroOutOffenders(data: types.ValidatorSet, offenders: []const types.Ed25519Public) types.ValidatorSet {
    for (data.items()) |*validator_data| {
        // check if in offenders list
        for (offenders) |*offender| {
            if (std.mem.eql(u8, offender, &validator_data.ed25519)) {
                validator_data.* = std.mem.zeroes(types.ValidatorData);
            }
        }
    }
    return data;
}

/// Build the Bandersnatch Ring Root
fn buildBandersnatchRingRoot(
    allocator: std.mem.Allocator,
    gamma_k: types.GammaK,
) !types.GammaZ {
    const span = trace.span(.bandersnatch_ring_root);
    defer span.deinit();
    span.debug("Calculating Bandersnatch ring root from gamma_k", .{});
    span.trace("Number of validator keys in gamma_k: {d}", .{gamma_k.len()});

    // Extract the Bandersnatch public keys
    const keys = try gamma_k.getBandersnatchPublicKeys(allocator);
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

/// Fallback function selects an epoch’s worth of validator Bandersnatch keys
/// from the validator key set k using the entropy collected on chain
pub fn entropyBasedKeySelector(
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

    const keys = try kappa.getBandersnatchPublicKeys(allocator);
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
