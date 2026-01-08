const std = @import("std");
const types = @import("types.zig");
const state = @import("state.zig");
const ed25519 = @import("crypto/ed25519.zig").Ed25519;

const tracing = @import("tracing");
const trace = tracing.scoped(.assurances);

pub const ValidatedAssuranceExtrinsic = struct {
    inner: types.AssurancesExtrinsic,

    const ValidationError = error{
        InvalidBitfieldSize,
        DuplicateValidatorIndex,
        NotSortedOrUniqueValidatorIndex,
        InvalidSignature,
        InvalidPublicKey,
        InvalidAnchorHash,
        InvalidValidatorIndex,
        BitSetForEmptyCore,
    };

    pub inline fn items(self: @This()) []types.AvailAssurance {
        return self.inner.data;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.inner.deinit(allocator);
        self.* = undefined;
    }

    pub fn validate(
        comptime params: @import("jam_params.zig").Params,
        extrinsic: types.AssurancesExtrinsic,
        parent_hash: types.HeaderHash,
        validators: anytype,
        pending_reports: *const state.Rho(params.core_count),
    ) ValidationError!@This() {
        comptime {
            std.debug.assert(params.core_count > 0);
            std.debug.assert(params.validators_count > 0);
            std.debug.assert(params.avail_bitfield_bytes == (params.core_count + 7) / 8);
        }
        const span = trace.span(@src(), .validate);
        defer span.deinit();
        span.debug("Starting validation of AssuranceExtrinsic with {d} assurances", .{extrinsic.data.len});

        if (extrinsic.data.len == 0) {
            span.debug("Empty assurance extrinsic, returning immediately", .{});
            return .{ .inner = extrinsic };
        }

        var prev_validator_idx: isize = -1;
        for (extrinsic.data, 0..) |assurance, i| {
            const assurance_span = span.child(@src(), .validate_assurance);
            defer assurance_span.deinit();
            assurance_span.debug("Validating assurance {d} of {d}", .{ i + 1, extrinsic.data.len });

            if (assurance.bitfield.len != params.avail_bitfield_bytes) {
                assurance_span.err("Invalid bitfield size {d}, expected {d}", .{ assurance.bitfield.len, params.avail_bitfield_bytes });
                return ValidationError.InvalidBitfieldSize;
            }

            assurance_span.trace("Checking validator index ordering - current: {d}, previous: {d}", .{ assurance.validator_index, prev_validator_idx });
            if (assurance.validator_index == prev_validator_idx) {
                assurance_span.err("Duplicate validator index {d}", .{assurance.validator_index});
                return ValidationError.NotSortedOrUniqueValidatorIndex;
            } else if (assurance.validator_index < prev_validator_idx) {
                assurance_span.err("Validator indices not sorted - current: {d}, previous: {d}", .{ assurance.validator_index, prev_validator_idx });
                return ValidationError.NotSortedOrUniqueValidatorIndex;
            }
            prev_validator_idx = assurance.validator_index;

            // Validate anchor hash matches parent
            assurance_span.trace("Validating anchor hash", .{});
            if (!std.mem.eql(u8, &assurance.anchor, &parent_hash)) {
                assurance_span.err("Invalid anchor hash - doesn't match parent", .{});
                return ValidationError.InvalidAnchorHash;
            }

            // Validate that bits are only set for cores with pending reports
            // This implements the graypaper constraint: ∀a ∈ E_A, c ∈ N_C : a_f[c] ⇒ ρ†[c] ≠ ∅
            const bitfield_validation_span = assurance_span.child(@src(), .validate_bitfield_cores);
            defer bitfield_validation_span.deinit();
            bitfield_validation_span.debug("Validating bitfield against pending reports", .{});

            // Check each bit in the bitfield
            for (0..params.core_count) |core_idx| {
                const byte_idx = core_idx / 8;
                const bit_idx: u3 = @intCast(core_idx % 8);
                const bit_set = (assurance.bitfield[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;

                if (bit_set) {
                    bitfield_validation_span.trace("Core {d}: bit set, checking for pending report", .{core_idx});
                    if (!pending_reports.hasReport(core_idx)) {
                        bitfield_validation_span.err("Core {d}: bit set but no pending report exists", .{core_idx});
                        return ValidationError.BitSetForEmptyCore;
                    }
                    bitfield_validation_span.trace("Core {d}: has pending report, validation passed", .{core_idx});
                }
            }

            // Validate signature
            const signature_span = assurance_span.child(@src(), .validate_signature);
            defer signature_span.deinit();
            signature_span.debug("Validating signature for validator {d}", .{assurance.validator_index});

            // The message is: "jam_available" ++ H(E(anchor, bitfield))
            try validateSignature(
                &signature_span,
                assurance,
                validators,
            );
        }

        return ValidatedAssuranceExtrinsic{ .inner = extrinsic };
    }

    fn validateSignature(
        span: anytype,
        assurance: types.AvailAssurance,
        validators: anytype,
    ) ValidationError!void {
        // Validate validator index bounds
        if (assurance.validator_index >= validators.len) {
            span.err("Invalid validator index {d}, max allowed {d}", .{ assurance.validator_index, validators.len - 1 });
            return ValidationError.InvalidValidatorIndex;
        }

        // Compute message hash: "jam_available" ++ H(E(anchor, bitfield))
        const prefix: []const u8 = "jam_available";
        var hasher = std.crypto.hash.blake2.Blake2b256.init(.{});
        hasher.update(&assurance.anchor);
        hasher.update(assurance.bitfield);
        var hash: [32]u8 = undefined;
        hasher.final(&hash);

        // Get validator public key
        span.trace("Retrieving public key for validator {d}", .{assurance.validator_index});
        const public_key = validators[assurance.validator_index].ed25519;

        // ZIP-215 compliant verification
        const validator_pub_key = ed25519.PublicKey.fromBytes(public_key);
        const signature = ed25519.Signature.fromBytes(assurance.signature);
        span.trace("Verifying signature", .{});
        signature.verify(prefix ++ &hash, validator_pub_key) catch {
            span.err("Signature verification failed for validator {d}", .{assurance.validator_index});
            return ValidationError.InvalidSignature;
        };
        span.debug("Signature verified successfully", .{});
    }
};

pub const AvailableAssignments = struct {
    inner: []types.AvailabilityAssignment,

    pub fn items(self: @This()) []types.AvailabilityAssignment {
        return self.inner;
    }

    /// Returns allocated slice of WorkReport pointers. Caller owns the slice.
    pub fn getWorkReportRefs(self: @This(), allocator: std.mem.Allocator) ![]*const types.WorkReport {
        var reports = try allocator.alloc(*const types.WorkReport, self.inner.len);
        errdefer allocator.free(reports);

        for (self.inner, 0..) |assignment, i| {
            reports[i] = &assignment.report;
        }

        return reports;
    }
    /// Returns allocated slice of deepCloned WorkReports. Caller owns the slice.
    pub fn getWorkReports(self: @This(), allocator: std.mem.Allocator) ![]types.WorkReport {
        var reports = try allocator.alloc(types.WorkReport, self.inner.len);
        errdefer allocator.free(reports);

        for (self.inner, 0..) |assignment, i| {
            reports[i] = try assignment.report.deepClone(allocator);
        }

        return reports;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.items()) |*assignment| {
            assignment.deinit(allocator);
        }
        allocator.free(self.inner);
        self.* = undefined;
    }
};

/// Process a block's assurance extrinsic to determine which work reports have
/// become available based on validator assurances
///
/// Warning: Errors may leave pending_reports partially mutated
pub fn processAssuranceExtrinsic(
    comptime params: @import("jam_params.zig").Params,
    allocator: std.mem.Allocator,
    pending_reports: *state.Rho(params.core_count),
    assurances_extrinsic: ValidatedAssuranceExtrinsic,
    current_slot: types.TimeSlot,
) !AvailableAssignments {
    const span = trace.span(@src(), .process_assurance_extrinsic);
    defer span.deinit();
    span.debug("Processing assurance extrinsic with {d} assurances", .{assurances_extrinsic.items().len});

    // Assert preconditions
    std.debug.assert(params.core_count > 0);
    std.debug.assert(params.validators_super_majority > 0);
    std.debug.assert(params.validators_super_majority <= params.validators_count);

    // Just track counts per core instead of individual validator bits
    var core_assurance_counts = [_]usize{0} ** params.core_count;

    // Process each assurance in the extrinsic
    {
        const process_span = span.child(@src(), .process_assurances);
        defer process_span.deinit();
        process_span.debug("Processing {d} assurances for {d} cores", .{ assurances_extrinsic.items().len, params.core_count });

        for (assurances_extrinsic.items(), 0..) |assurance, assurance_idx| {
            const bitfield_span = process_span.child(@src(), .process_bitfield);
            defer bitfield_span.deinit();
            bitfield_span.debug("Processing assurance {d}: bitfield={}", .{ assurance_idx, std.fmt.fmtSliceHexLower(assurance.bitfield) });

            processBitfield(
                params.core_count,
                assurance.bitfield,
                &core_assurance_counts,
                &bitfield_span,
            );
            bitfield_span.debug("Finished processing bitfield, current counts: {any}", .{core_assurance_counts});
        }
        process_span.debug("Finished processing all bitfields", .{});
    }

    // Track which cores have super-majority assurance
    var assured_reports = std.ArrayList(types.AvailabilityAssignment).init(allocator);
    errdefer {
        for (assured_reports.items) |*r| {
            r.deinit(allocator);
        }
        assured_reports.deinit();
    }

    // Check which cores have super-majority
    {
        const majority_span = span.child(@src(), .check_super_majority);
        defer majority_span.deinit();
        majority_span.debug("Checking cores against super majority threshold {d}", .{params.validators_super_majority});

        // Check which cores have super-majority
        const super_majority = params.validators_super_majority;

        for (core_assurance_counts, 0..) |count, core_idx| {
            const core_span = majority_span.child(@src(), .check_core);
            defer core_span.deinit();
            core_span.debug("Core {d}: checking assurance count {d} >= super_majority {d}", .{ core_idx, count, super_majority });

            if (count >= super_majority) {
                if (pending_reports.hasReport(core_idx)) {
                    core_span.debug("Core {d}: super-majority reached and report present, taking ownership", .{core_idx});
                    // Deep clone the report - ownership transferred to assured_reports (cleaned up on error)
                    try assured_reports.append(pending_reports.takeReport(core_idx).?.assignment);
                } else {
                    core_span.err("Code {d}: we have assurances for a core which is not engaged", .{core_idx});
                    return error.CoreNotEngaged;
                }
            }
        }
    }

    // Now remove any remaining timed out reports
    cleanupTimedOutReports(
        params.work_replacement_period,
        allocator,
        pending_reports,
        current_slot,
        &span,
    );

    span.debug("Completed processing with {d} assured reports", .{assured_reports.items.len});
    return .{ .inner = try assured_reports.toOwnedSlice() };
}

fn processBitfield(
    core_count: u16,
    bitfield: []const u8,
    core_assurance_counts: []usize,
    span: anytype,
) void {
    std.debug.assert(core_count > 0);
    std.debug.assert(bitfield.len == (core_count + 7) / 8);
    std.debug.assert(core_assurance_counts.len == core_count);

    const bytes_per_field = (core_count + 7) / 8;
    var byte_idx: usize = 0;
    while (byte_idx < bytes_per_field) : (byte_idx += 1) {
        const byte = bitfield[byte_idx];
        if (byte == 0) {
            span.trace("Byte {d}: 0x00 (skipping empty byte)", .{byte_idx});
            continue;
        }

        const byte_span = span.child(@src(), .process_byte);
        defer byte_span.deinit();
        byte_span.trace("Processing byte {d}: 0x{x:0>2}", .{ byte_idx, byte });

        var bit_pos: u4 = 0;
        while (bit_pos < 8) : (bit_pos += 1) {
            const core_idx = byte_idx * 8 + bit_pos;
            if (core_idx >= core_count) {
                byte_span.trace("Stopping at bit {d}: core_idx {d} >= core_count {d}", .{ bit_pos, core_idx, core_count });
                break;
            }

            const bit_value = (byte & (@as(u8, 1) << @intCast(bit_pos))) != 0;
            if (bit_value) {
                core_assurance_counts[core_idx] += 1;
                byte_span.trace("core[{d}] bit {d}: set   (count now {d})", .{ core_idx, bit_pos, core_assurance_counts[core_idx] });
            } else {
                byte_span.trace("core[{d}] bit {d}: unset (count now {d})", .{ core_idx, bit_pos, core_assurance_counts[core_idx] });
            }
        }
    }
}

fn cleanupTimedOutReports(
    work_replacement_period: u8,
    allocator: std.mem.Allocator,
    pending_reports: anytype,
    current_slot: types.TimeSlot,
    span: anytype,
) void {
    const timeout_span = span.child(@src(), .cleanup_timeouts);
    defer timeout_span.deinit();
    timeout_span.debug("Checking for timed out reports at slot {d}", .{current_slot});

    for (&pending_reports.reports, 0..) |*report, core_idx| {
        if (report.*) |*pending_report| {
            const report_timeout = pending_report.assignment.timeout + work_replacement_period;
            if (current_slot >= report_timeout) {
                timeout_span.debug("core {d}: report.timeout {d} < {d} => remove", .{ core_idx, report_timeout, current_slot });
                // Report has timed out, remove it
                pending_report.deinit(allocator);
                report.* = null;
            }
        }
    }
}
