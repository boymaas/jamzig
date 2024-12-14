const std = @import("std");
const types = @import("types.zig");
const state = @import("state.zig");
const crypto = std.crypto;

/// A wrapper type that guarantees an AssuranceExtrinsic has been validated
pub const ValidatedAssuranceExtrinsic = struct {
    inner: types.AssurancesExtrinsic,

    const Error = error{
        InvalidBitfieldSize,
        DuplicateValidatorIndex,
        NotSortedValidatorIndex,
        InvalidSignature,
        InvalidPublicKey,
        InvalidAnchorHash,
        InvalidValidatorIndex,
    };

    pub inline fn items(self: @This()) []types.AvailAssurance {
        return self.inner.data;
    }

    /// Validates the AssuranceExtrinsic according to protocol rules
    pub fn validate(
        comptime params: @import("jam_params.zig").Params,
        extrinsic: types.AssurancesExtrinsic,
        parent_hash: types.HeaderHash,
        kappa: types.ValidatorSet,
    ) Error!@This() {
        if (extrinsic.data.len == 0) {
            return .{ .inner = extrinsic };
        }

        var prev_validator_idx: isize = -1;
        for (extrinsic.data) |assurance| {
            // Validate bitfield size
            if (assurance.bitfield.len != params.avail_bitfield_bytes) {
                return Error.InvalidBitfieldSize;
            }

            // Ensure strictly increasing validator indices
            if (assurance.validator_index == prev_validator_idx) {
                return Error.DuplicateValidatorIndex;
            } else if (assurance.validator_index < prev_validator_idx) {
                return Error.NotSortedValidatorIndex;
            }
            prev_validator_idx = assurance.validator_index;

            // Validate anchor hash matches parent
            if (!std.mem.eql(u8, &assurance.anchor, &parent_hash)) {
                return Error.InvalidAnchorHash;
            }

            // Validate signature
            // The message is: "$jam_available" ++ H(E(anchor, bitfield))
            const prefix = "jam_available";
            var hasher = std.crypto.hash.blake2.Blake2b256.init(.{});
            hasher.update(prefix);
            hasher.update(&assurance.anchor);
            hasher.update(assurance.bitfield);
            var hash: [32]u8 = undefined;
            hasher.final(&hash);

            if (assurance.validator_index >= kappa.validators.len) {
                return Error.InvalidValidatorIndex;
            }

            const public_key = kappa.validators[assurance.validator_index].ed25519;
            const validator_pub_key = crypto.sign.Ed25519.PublicKey.fromBytes(public_key) catch {
                return Error.InvalidPublicKey;
            };

            const signature = crypto.sign.Ed25519.Signature.fromBytes(assurance.signature);

            signature.verify(&hash, validator_pub_key) catch {
                return Error.InvalidSignature;
            };
        }

        return ValidatedAssuranceExtrinsic{ .inner = extrinsic };
    }
};

/// Process a block's assurance extrinsic to determine which work reports have
/// become available based on validator assurances
pub fn processAssuranceExtrinsic(
    comptime params: @import("jam_params.zig").Params,
    allocator: std.mem.Allocator,
    assurances_extrinsic: ValidatedAssuranceExtrinsic,
    pending_reports: *state.Rho(params.core_count),
) ![]types.AvailabilityAssignment {
    // Track which cores have super-majority assurance
    var assured_reports = std.ArrayList(types.AvailabilityAssignment).init(allocator);
    defer assured_reports.deinit();

    // Just track counts per core instead of individual validator bits
    var core_assurance_counts = [_]usize{0} ** params.core_count;

    // Process each assurance in the extrinsic
    for (assurances_extrinsic.items()) |assurance| {
        const bytes_per_field = (params.core_count + 7) / 8;

        var byte_idx: usize = 0;
        while (byte_idx < bytes_per_field) : (byte_idx += 1) {
            const byte = assurance.bitfield[byte_idx];
            if (byte == 0) continue; // Skip empty bytes

            var bit_pos: u3 = 0;
            while (bit_pos < 8) : (bit_pos += 1) {
                const core_idx = byte_idx * 8 + bit_pos;
                if (core_idx >= params.core_count) break;

                if ((byte & (@as(u8, 1) << bit_pos)) != 0) {
                    core_assurance_counts[core_idx] += 1;
                }
            }
        }
    }

    // Check which cores have super-majority
    const super_majority = params.validators_super_majority;

    for (core_assurance_counts, 0..) |count, core_idx| {
        // If super-majority reached and core has pending report
        if (count > super_majority and
            pending_reports.reports[core_idx] != null)
        {
            try assured_reports.append(try pending_reports.reports[core_idx].?.assignment.deepClone(allocator));
        }
    }

    return assured_reports.toOwnedSlice();
}
