const std = @import("std");
const types = @import("types.zig");
const state = @import("state.zig");
const crypto = std.crypto;

const tracing = @import("tracing.zig");
const trace = tracing.scoped(.assurances);

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

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        self.inner.deinit(allocator);
    }

    /// Validates the AssuranceExtrinsic according to protocol rules
    pub fn validate(
        comptime params: @import("jam_params.zig").Params,
        extrinsic: types.AssurancesExtrinsic,
        parent_hash: types.HeaderHash,
        kappa: types.ValidatorSet,
    ) Error!@This() {
        const span = trace.span(.validate);
        defer span.deinit();
        span.debug("Starting validation of AssuranceExtrinsic with {d} assurances", .{extrinsic.data.len});

        if (extrinsic.data.len == 0) {
            span.debug("Empty assurance extrinsic, returning immediately", .{});
            return .{ .inner = extrinsic };
        }

        var prev_validator_idx: isize = -1;
        for (extrinsic.data, 0..) |assurance, i| {
            const assurance_span = span.child(.validate_assurance);
            defer assurance_span.deinit();
            assurance_span.debug("Validating assurance {d} of {d}", .{ i + 1, extrinsic.data.len });

            // Validate bitfield size
            if (assurance.bitfield.len != params.avail_bitfield_bytes) {
                assurance_span.err("Invalid bitfield size {d}, expected {d}", .{ assurance.bitfield.len, params.avail_bitfield_bytes });
                return Error.InvalidBitfieldSize;
            }

            // Ensure strictly increasing validator indices
            assurance_span.trace("Checking validator index ordering - current: {d}, previous: {d}", .{ assurance.validator_index, prev_validator_idx });
            if (assurance.validator_index == prev_validator_idx) {
                assurance_span.err("Duplicate validator index {d}", .{assurance.validator_index});
                return Error.DuplicateValidatorIndex;
            } else if (assurance.validator_index < prev_validator_idx) {
                assurance_span.err("Validator indices not sorted - current: {d}, previous: {d}", .{ assurance.validator_index, prev_validator_idx });
                return Error.NotSortedValidatorIndex;
            }
            prev_validator_idx = assurance.validator_index;

            // Validate anchor hash matches parent
            assurance_span.trace("Validating anchor hash", .{});
            if (!std.mem.eql(u8, &assurance.anchor, &parent_hash)) {
                assurance_span.err("Invalid anchor hash - doesn't match parent", .{});
                return Error.InvalidAnchorHash;
            }

            // Validate signature
            const signature_span = assurance_span.child(.validate_signature);
            defer signature_span.deinit();
            signature_span.debug("Validating signature for validator {d}", .{assurance.validator_index});

            // The message is: "$jam_available" ++ H(E(anchor, bitfield))
            const prefix: []const u8 = "jam_available";
            var hasher = std.crypto.hash.blake2.Blake2b256.init(.{});
            hasher.update(&assurance.anchor);
            hasher.update(assurance.bitfield);
            var hash: [32]u8 = undefined;
            hasher.final(&hash);

            if (assurance.validator_index >= kappa.validators.len) {
                signature_span.err("Invalid validator index {d}, max allowed {d}", .{ assurance.validator_index, kappa.validators.len - 1 });
                return Error.InvalidValidatorIndex;
            }

            signature_span.trace("Retrieving public key for validator {d}", .{assurance.validator_index});
            const public_key = kappa.validators[assurance.validator_index].ed25519;
            const validator_pub_key = crypto.sign.Ed25519.PublicKey.fromBytes(public_key) catch {
                signature_span.err("Invalid public key format for validator {d}", .{assurance.validator_index});
                return Error.InvalidPublicKey;
            };

            const signature = crypto.sign.Ed25519.Signature.fromBytes(assurance.signature);

            signature_span.trace("Verifying signature", .{});
            signature.verify(prefix ++ &hash, validator_pub_key) catch {
                signature_span.err("Signature verification failed for validator {d}", .{assurance.validator_index});
                return Error.InvalidSignature;
            };
            signature_span.debug("Signature verified successfully", .{});
        }

        return ValidatedAssuranceExtrinsic{ .inner = extrinsic };
    }
};

pub const AvailableAssignments = struct {
    inner: []types.AvailabilityAssignment,

    pub fn items(self: @This()) []types.AvailabilityAssignment {
        return self.inner;
    }

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        for (self.items()) |*assignment| {
            assignment.deinit(allocator);
        }
        allocator.free(self.inner);
    }
};

/// Process a block's assurance extrinsic to determine which work reports have
/// become available based on validator assurances
///
/// Warning: Errors may leave pending_reports partially mutated
pub fn processAssuranceExtrinsic(
    comptime params: @import("jam_params.zig").Params,
    allocator: std.mem.Allocator,
    assurances_extrinsic: ValidatedAssuranceExtrinsic,
    current_slot: types.TimeSlot,
    pending_reports: *state.Rho(params.core_count),
) !AvailableAssignments {
    const span = trace.span(.process_assurance_extrinsic);
    defer span.deinit();
    span.debug("Processing assurance extrinsic with {d} assurances", .{assurances_extrinsic.items().len});
    // Track which cores have super-majority assurance
    var assured_reports = std.ArrayList(types.AvailabilityAssignment).init(allocator);
    errdefer {
        for (assured_reports.items) |r| {
            r.deinit(allocator);
        }
        assured_reports.deinit();
    }

    // First remove any timed out reports
    {
        const timeout_span = span.child(.cleanup_timeouts);
        defer timeout_span.deinit();
        timeout_span.debug("Checking for timed out reports at slot {d}", .{current_slot});
        for (&pending_reports.reports, 0..) |*report, core_idx| {
            if (report.*) |*pending_report| {
                const report_timeout = pending_report.assignment.timeout + params.work_replacement_period;
                if (current_slot >= report_timeout) {
                    timeout_span.debug("core {d}: report.timeout {d} < {d} => remove", .{ core_idx, report_timeout, current_slot });
                    // Report has timed out, remove it
                    pending_report.deinit(allocator);
                    report.* = null;
                }
            }
        }
    }

    // Just track counts per core instead of individual validator bits
    var core_assurance_counts = [_]usize{0} ** params.core_count;

    // Process each assurance in the extrinsic
    {
        const process_span = span.child(.process_assurances);
        defer process_span.deinit();
        process_span.debug("Processing {d} assurances for {d} cores", .{ assurances_extrinsic.items().len, params.core_count });

        for (assurances_extrinsic.items(), 0..) |assurance, assurance_idx| {
            const bitfield_span = process_span.child(.process_bitfield);
            defer bitfield_span.deinit();
            bitfield_span.debug("Processing assurance {d}: bitfield={}", .{ assurance_idx, std.fmt.fmtSliceHexLower(assurance.bitfield) });

            const bytes_per_field = (params.core_count + 7) / 8;
            var byte_idx: usize = 0;
            while (byte_idx < bytes_per_field) : (byte_idx += 1) {
                const byte = assurance.bitfield[byte_idx];
                if (byte == 0) {
                    bitfield_span.trace("Byte {d}: 0x00 (skipping empty byte)", .{byte_idx});
                    continue;
                }

                const byte_span = bitfield_span.child(.process_byte);
                defer byte_span.deinit();
                byte_span.trace("Processing byte {d}: 0x{x:0>2}", .{ byte_idx, byte });

                var bit_pos: u3 = 0;
                while (bit_pos < 8) : (bit_pos += 1) {
                    const core_idx = byte_idx * 8 + bit_pos;
                    if (core_idx >= params.core_count) {
                        byte_span.trace("Stopping at bit {d}: core_idx {d} >= core_count {d}", .{ bit_pos, core_idx, params.core_count });
                        break;
                    }

                    const bit_value = (byte & (@as(u8, 1) << bit_pos)) != 0;
                    if (bit_value) {
                        core_assurance_counts[core_idx] += 1;
                        byte_span.trace("core[{d}] bit {d}: set   (count now {d})", .{ core_idx, bit_pos, core_assurance_counts[core_idx] });
                    } else {
                        byte_span.trace("core[{d}] bit {d}: unset (count now {d})", .{ core_idx, bit_pos, core_assurance_counts[core_idx] });
                    }
                }
            }
            bitfield_span.debug("Finished processing bitfield, current counts: {any}", .{core_assurance_counts});
        }
        process_span.debug("Finished processing all bitfields", .{});
    }

    // Check which cores have super-majority
    {
        const majority_span = span.child(.check_super_majority);
        defer majority_span.deinit();
        majority_span.debug("Checking cores against super majority threshold {d}", .{params.validators_super_majority});

        // Check which cores have super-majority
        const super_majority = params.validators_super_majority;

        for (core_assurance_counts, 0..) |count, core_idx| {
            const core_span = majority_span.child(.check_core);
            defer core_span.deinit();
            core_span.debug("Core {d}: checking assurance count {d} >= super_majority {d}", .{ core_idx, count, super_majority });

            if (count >= super_majority) {
                if (pending_reports.hasReport(core_idx)) {
                    core_span.debug("Core {d}: super-majority reached and report present, taking ownership", .{core_idx});
                    // Deep clone the report - ownership transferred to assured_reports (cleaned up on error)
                    try assured_reports.append(pending_reports.takeReportOwned(core_idx).?.assignment);
                } else {
                    core_span.err("Code {d}: we have assurances for a core which is not engaged", .{core_idx});
                    return error.CoreNotEngaged;
                }
            }
        }
    }

    span.debug("Completed processing with {d} assured reports", .{assured_reports.items.len});
    return .{ .inner = try assured_reports.toOwnedSlice() };
}
