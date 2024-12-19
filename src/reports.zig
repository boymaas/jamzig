const std = @import("std");
const types = @import("types.zig");
const state = @import("state.zig");
const crypto = std.crypto;

const tracing = @import("tracing.zig");
const trace = tracing.scoped(.reports);

/// Error types for report validation and processing
pub const Error = error{
    BadCoreIndex,
    FutureReportSlot,
    ReportEpochBeforeLast,
    InsufficientGuarantees,
    TooManyGuarantees,
    OutOfOrderGuarantee,
    NotSortedOrUniqueGuarantors,
    WrongAssignment,
    CoreEngaged,
    AnchorNotRecent,
    BadServiceId,
    BadCodeHash,
    BadAnchor,
    DependencyMissing,
    DuplicatePackage,
    DuplicatePackageInGuarantees,
    BadStateRoot,
    BadBeefyMmrRoot,
    CoreUnauthorized,
    BadValidatorIndex,
    WorkReportGasTooHigh,
    ServiceItemGasTooLow,
    TooManyDependencies,
    SegmentRootLookupInvalid,
    BadSignature,
    InvalidValidatorPublicKey,
};

pub const ValidatedGuaranteeExtrinsic = struct {
    guarantees: []const types.ReportGuarantee,

    pub fn validate(
        comptime params: @import("jam_params.zig").Params,
        allocator: std.mem.Allocator,
        guarantees: types.GuaranteesExtrinsic,
        slot: types.TimeSlot,
        jam_state: *const state.JamState(params),
    ) !@This() {
        const span = trace.span(.validate_guarantees);
        defer span.deinit();
        span.debug("Starting guarantee validation for {d} guarantees", .{guarantees.data.len});

        // Check for duplicate packages using a sorting-based approach.
        // This implementation trades slightly higher memory usage (~11KB for 341 cores)
        // for better runtime complexity (O(n log n) vs O(n²)). The sorted approach
        // provides more predictable performance and better cache locality,
        // to alternatives like hash tables.
        // TODO: benchmark this
        {
            const dup_span = span.child(.check_duplicate_package_in_batch);
            defer dup_span.deinit();

            dup_span.debug("Starting duplicate check for {d} guarantees", .{guarantees.data.len});

            // Create temporary array to store hashes for sorting
            // avoid allocation
            var bounded_buffer = try std.BoundedArray(types.WorkPackageHash, params.core_count).init(0);

            // Copy all package hashes
            for (guarantees.data, 0..) |g, i| {
                try bounded_buffer.append(g.report.package_spec.hash);
                dup_span.trace("Collected hash at index {d}: {s}", .{ i, std.fmt.fmtSliceHexLower(&bounded_buffer.get(i)) });
            }

            // Sort hashes for efficient duplicate checking
            std.mem.sortUnstable(types.WorkPackageHash, bounded_buffer.slice(), {}, @import("utils/sort.zig").ascHashFn);

            // Get access to the sorted hashes
            const sorted_hashes = bounded_buffer.constSlice();

            // Check adjacent hashes for duplicates
            for (sorted_hashes[0 .. sorted_hashes.len - 1], sorted_hashes[1..], 0..) |hash1, hash2, i| {
                dup_span.trace("Comparing sorted hashes at indices {d} and {d}", .{ i, i + 1 });

                if (std.mem.eql(u8, &hash1, &hash2)) {
                    dup_span.err("Found duplicate package hash: {s}", .{std.fmt.fmtSliceHexLower(&hash1)});
                    return Error.DuplicatePackage;
                }
            }

            dup_span.debug("No duplicates found in batch of {d} packages", .{guarantees.data.len});
        }

        // Validate all guarantees
        var prev_guarantee_core: ?u32 = null;
        for (guarantees.data) |guarantee| {
            const core_span = span.child(.validate_core);
            defer core_span.deinit();
            core_span.debug("Validating core index {d} for report hash {s}", .{
                guarantee.report.core_index,
                std.fmt.fmtSliceHexLower(&guarantee.report.package_spec.hash),
            });
            core_span.trace("Report context - anchor: {s}, lookup_anchor: {s}", .{
                std.fmt.fmtSliceHexLower(&guarantee.report.context.anchor),
                std.fmt.fmtSliceHexLower(&guarantee.report.context.lookup_anchor),
            });

            // Check core index
            if (guarantee.report.core_index >= params.core_count) {
                core_span.err("Invalid core index {d} >= {d}", .{ guarantee.report.core_index, params.core_count });
                return Error.BadCoreIndex;
            }

            // Check for out-of-order guarantees
            if (prev_guarantee_core != null and guarantee.report.core_index <= prev_guarantee_core.?) {
                core_span.err("Out-of-order guarantee: {d} <= {d}", .{ guarantee.report.core_index, prev_guarantee_core.? });
                return Error.OutOfOrderGuarantee;
            }
            prev_guarantee_core = guarantee.report.core_index;

            // Check if we have enough signatures:

            const slot_span = span.child(.validate_slot);
            defer slot_span.deinit();
            slot_span.debug("Validating report slot {d} against current slot {d} for core {d}", .{
                guarantee.slot,
                slot,
                guarantee.report.core_index,
            });
            slot_span.trace("Report epoch: {d}, current epoch: {d}", .{
                guarantee.slot / params.epoch_length,
                slot / params.epoch_length,
            });

            // Validate report slot is not in future
            if (guarantee.slot > slot) {
                slot_span.err("Report slot {d} is in the future (current: {d})", .{ guarantee.slot, slot });
                return Error.FutureReportSlot;
            }

            const epoch_span = span.child(.validate_epoch);
            defer epoch_span.deinit();

            // Check epoch is current or last
            const report_epoch = guarantee.slot / params.epoch_length;
            const current_epoch = slot / params.epoch_length;
            epoch_span.debug("Validating report epoch {d} against current epoch {d}", .{ report_epoch, current_epoch });

            if (report_epoch + 1 < current_epoch) {
                epoch_span.err("Report epoch {d} is too old (current: {d})", .{ report_epoch, current_epoch });
                return Error.ReportEpochBeforeLast;
            }

            // Validate anchor is recent
            const anchor_span = span.child(.validate_anchor);
            defer anchor_span.deinit();

            if (jam_state.beta.?.getBlockInfoByHash(guarantee.report.context.anchor)) |binfo| {
                anchor_span.debug("Found anchor block, validating roots", .{});
                anchor_span.trace("Block info - hash: {s}, state root: {s}", .{
                    std.fmt.fmtSliceHexLower(&binfo.header_hash),
                    std.fmt.fmtSliceHexLower(&binfo.state_root),
                });

                if (!std.mem.eql(u8, &guarantee.report.context.beefy_root, &binfo.beefy_mmr_root())) {
                    anchor_span.err("Beefy MMR root mismatch - expected: {s}, got: {s}", .{
                        std.fmt.fmtSliceHexLower(&binfo.beefy_mmr_root()),
                        std.fmt.fmtSliceHexLower(&guarantee.report.context.beefy_root),
                    });
                    return Error.BadBeefyMmrRoot;
                }

                if (!std.mem.eql(u8, &guarantee.report.context.state_root, &binfo.state_root)) {
                    anchor_span.err("State root mismatch - expected: {s}, got: {s}", .{
                        std.fmt.fmtSliceHexLower(&binfo.state_root),
                        std.fmt.fmtSliceHexLower(&guarantee.report.context.state_root),
                    });
                    return Error.BadStateRoot;
                }

                if (!std.mem.eql(u8, &guarantee.report.context.anchor, &binfo.header_hash)) {
                    anchor_span.err("Anchor hash mismatch - expected: {s}, got: {s}", .{
                        std.fmt.fmtSliceHexLower(&binfo.header_hash),
                        std.fmt.fmtSliceHexLower(&guarantee.report.context.anchor),
                    });
                    return Error.BadAnchor;
                }

                anchor_span.debug("Anchor validation successful", .{});
            } else {
                anchor_span.err("Anchor block not found in recent history: {s}", .{
                    std.fmt.fmtSliceHexLower(&guarantee.report.context.anchor),
                });
                return Error.AnchorNotRecent;
            }

            // Validate guarantors are sorted and unique
            {
                const guarantor_span = span.child(.signatures_sorted_unique);
                defer guarantor_span.deinit();

                guarantor_span.debug("Validating {d} guarantor signatures are sorted and unique", .{guarantee.signatures.len});

                var prev_index: ?types.ValidatorIndex = null;
                for (guarantee.signatures, 0..) |sig, i| {
                    guarantor_span.trace("Checking validator index {d} at position {d}", .{ sig.validator_index, i });

                    if (prev_index != null and sig.validator_index <= prev_index.?) {
                        guarantor_span.err("Guarantor validation failed: index {d} <= previous {d}", .{
                            sig.validator_index,
                            prev_index.?,
                        });
                        return Error.NotSortedOrUniqueGuarantors;
                    }
                    prev_index = sig.validator_index;
                }
                guarantor_span.debug("All guarantor indices validated as sorted and unique", .{});
            }

            // Check service ID exists
            for (guarantee.report.results) |result| {
                if (jam_state.delta.?.getAccount(result.service_id)) |service| {
                    // Validate code hash matches
                    if (!std.mem.eql(u8, &service.code_hash, &result.code_hash)) {
                        return Error.BadCodeHash;
                    }

                    // Check gas limits
                    if (result.accumulate_gas < service.min_gas_accumulate) {
                        return Error.ServiceItemGasTooLow;
                    }
                } else {
                    return Error.BadServiceId;
                }
            }

            // Check core is not engaged
            // if (jam_state.rho.?.isEngaged(guarantee.report.core_index)) {
            //     return Error.CoreEngaged;
            // }

            // Validate report prerequisites exist
            // TODO: move this to recent_blocks
            for (guarantee.report.context.prerequisites) |prereq| {
                var found_prereq = false;
                outer: for (jam_state.beta.?.blocks.items) |block| {
                    for (block.work_reports) |report| {
                        if (std.mem.eql(u8, &report.hash, &prereq)) {
                            found_prereq = true;
                            break :outer;
                        }
                    }
                }
                if (!found_prereq) {
                    return Error.DependencyMissing;
                }
            }

            // Verify segment root lookup is valid
            // TODO: move this to recent_blocks
            for (guarantee.report.segment_root_lookup) |segment| {
                var found_package = false;
                outer: for (jam_state.beta.?.blocks.items) |block| {
                    for (block.work_reports) |report| {
                        if (std.mem.eql(u8, &report.hash, &segment.work_package_hash)) {
                            found_package = true;
                            break :outer;
                        }
                    }
                }
                if (!found_package) {
                    return Error.SegmentRootLookupInvalid;
                }
            }

            // Validate signatures
            {
                const sig_span = span.child(.validate_signatures);
                defer sig_span.deinit();

                sig_span.debug("Validating {d} guarantor signatures", .{guarantee.signatures.len});

                sig_span.debug("Checking signature count: {d} must be either 2 or 3", .{guarantee.signatures.len});

                if (guarantee.signatures.len < 2) {
                    sig_span.err("Insufficient guarantees: got {d}, minimum required is 2", .{
                        guarantee.signatures.len,
                    });
                    return Error.InsufficientGuarantees;
                }
                if (guarantee.signatures.len > 3) {
                    sig_span.err("Too many guarantees: got {d}, maximum allowed is 3", .{
                        guarantee.signatures.len,
                    });
                    return Error.TooManyGuarantees;
                }

                for (guarantee.signatures) |sig| {
                    const sig_detail_span = sig_span.child(.validate_signature);
                    defer sig_detail_span.deinit();

                    sig_detail_span.debug("Validating signature for validator index {d}", .{sig.validator_index});
                    sig_detail_span.trace("Signature: {s}", .{std.fmt.fmtSliceHexLower(&sig.signature)});

                    if (sig.validator_index >= jam_state.kappa.?.validators.len) {
                        sig_detail_span.err("Invalid validator index {d} >= {d}", .{
                            sig.validator_index,
                            jam_state.kappa.?.validators.len,
                        });
                        return Error.BadValidatorIndex;
                    }

                    const validator = jam_state.kappa.?.validators[sig.validator_index];
                    const public_key = validator.ed25519;
                    sig_detail_span.trace("Validator public key: {s}", .{std.fmt.fmtSliceHexLower(&public_key)});

                    // Create message to verify using Blake2b
                    // The message is: "jam_guarantee" ++ H(E(anchor, bitfield))
                    const prefix: []const u8 = "jam_guarantee";
                    const w = try @import("./codec.zig").serializeAlloc(types.WorkReport, params, allocator, guarantee.report);
                    defer allocator.free(w);
                    var hasher = std.crypto.hash.blake2.Blake2b256.init(.{});
                    hasher.update(w);
                    var hash: [32]u8 = undefined;
                    hasher.final(&hash);

                    const validator_pub_key = crypto.sign.Ed25519.PublicKey.fromBytes(public_key) catch {
                        return Error.InvalidValidatorPublicKey;
                    };

                    const signature = crypto.sign.Ed25519.Signature.fromBytes(sig.signature);

                    signature.verify(prefix ++ &hash, validator_pub_key) catch {
                        return Error.BadSignature;
                    };
                }
            }

            // Core must be free or its previous report must have timed out
            // (exceeded WorkReplacementPeriod since last report)
            {
                const timeout_span = span.child(.validate_timeout);
                defer timeout_span.deinit();

                if (jam_state.rho.?.getReport(guarantee.report.core_index)) |entry| {
                    timeout_span.debug("Checking core {d} timeout - last: {d}, current: {d}, period: {d}", .{
                        guarantee.report.core_index,
                        entry.assignment.timeout,
                        guarantee.slot,
                        params.work_replacement_period,
                    });

                    if (!entry.assignment.isTimedOut(params.work_replacement_period, guarantee.slot)) {
                        timeout_span.err("Core {d} still engaged - needs {d} more slots", .{
                            guarantee.report.core_index,
                            (entry.assignment.timeout + params.work_replacement_period) - guarantee.slot,
                        });
                        return Error.CoreEngaged;
                    }
                    timeout_span.debug("Core {d} timeout validated", .{guarantee.report.core_index});
                } else {
                    timeout_span.debug("Core {d} is free", .{guarantee.report.core_index});
                }
            }

            // Check if the authorizer hash is valid
            {
                const auth_span = span.child(.validate_authorization);
                defer auth_span.deinit();

                auth_span.debug("Checking authorization for core {d} with hash {s}", .{
                    guarantee.report.core_index,
                    std.fmt.fmtSliceHexLower(&guarantee.report.authorizer_hash),
                });

                if (!jam_state.alpha.?.isAuthorized(guarantee.report.core_index, guarantee.report.authorizer_hash)) {
                    auth_span.err("Core {d} not authorized for hash {s}", .{
                        guarantee.report.core_index,
                        std.fmt.fmtSliceHexLower(&guarantee.report.authorizer_hash),
                    });
                    return Error.CoreUnauthorized;
                }
                auth_span.debug("Authorization validated for core {d}", .{guarantee.report.core_index});
            }

            // Check for duplicate packages across states
            // TODO: move this to recent_blocks
            {
                const dup_span = span.child(.check_duplicate_package_in_recent_history);
                defer dup_span.deinit();

                const package_hash = guarantee.report.package_spec.hash;
                dup_span.debug("Checking for duplicate package hash {s}", .{
                    std.fmt.fmtSliceHexLower(&package_hash),
                });

                const blocks = jam_state.beta.?.blocks;
                dup_span.debug("Comparing against {d} blocks", .{blocks.items.len});
                for (blocks.items, 0..) |block, block_idx| {
                    const block_span = dup_span.child(.check_block);
                    defer block_span.deinit();

                    block_span.debug("Checking block {d} with {d} reports", .{
                        block_idx,
                        block.work_reports.len,
                    });

                    for (block.work_reports, 0..) |report, report_idx| {
                        block_span.trace("Comparing against report {d}: {s}", .{
                            report_idx,
                            std.fmt.fmtSliceHexLower(&report.hash),
                        });
                        if (std.mem.eql(u8, &report.hash, &package_hash)) {
                            block_span.err("Found duplicate package in report {d}", .{
                                report_idx,
                            });
                            return Error.DuplicatePackage;
                        }
                    }
                    block_span.debug("No duplicates found in block {d}", .{block_idx});
                }
                dup_span.debug("No duplicates found for package hash", .{});
            }
            // // Check sufficient guarantors
            // if (guarantee.signatures.len < params.validators_super_majority) {
            //     return Error.InsufficientGuarantees;
            // }
        }

        return @This(){ .guarantees = guarantees.data };
    }
};

pub const Result = struct {
    /// Reported packages hash and segment tree root
    reported: []types.ReportedWorkPackage,
    /// Reporters for reported packages
    reporters: []types.Ed25519Public,

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.reported);
        allocator.free(self.reporters);
    }
};

pub fn processGuaranteeExtrinsic(
    comptime params: @import("jam_params.zig").Params,
    allocator: std.mem.Allocator,
    validated: ValidatedGuaranteeExtrinsic,
    slot: types.TimeSlot,
    jam_state: *state.JamState(params),
) !Result {
    const span = trace.span(.process_guarantees);
    defer span.deinit();
    span.debug("Processing guarantees - count: {d}, slot: {d}", .{ validated.guarantees.len, slot });
    span.trace("Current state root: {s}", .{
        std.fmt.fmtSliceHexLower(&jam_state.beta.?.blocks.items[0].state_root),
    });

    var reported = std.ArrayList(types.ReportedWorkPackage).init(allocator);
    defer reported.deinit();

    var reporters = std.ArrayList(types.Ed25519Public).init(allocator);
    defer reporters.deinit();

    // Process each validated guarantee
    for (validated.guarantees) |guarantee| {
        const process_span = span.child(.process_guarantee);
        defer process_span.deinit();

        const core_index = guarantee.report.core_index;
        process_span.debug("Processing guarantee for core {d}", .{core_index});

        // Core can be reused, this is checked when validating the guarantee
        // Add report to Rho state
        process_span.debug("Creating availability assignment with timeout {d}", .{slot});
        const assignment = types.AvailabilityAssignment{
            .report = try guarantee.report.deepClone(allocator),
            .timeout = slot,
        };

        jam_state.rho.?.setReport(
            core_index,
            assignment,
        );

        // remove the authorizer from the pool
        process_span.debug(
            "Removing authorizer from pool {d}",
            .{std.fmt.fmtSliceHexLower(&guarantee.report.authorizer_hash)},
        );
        jam_state.alpha.?.removeAuthorizer(core_index, guarantee.report.authorizer_hash);

        // Track reported packages
        // NOTE:need to entry to use the hash_function to get the work report hash
        const entry = jam_state.rho.?.getReport(core_index).?;
        try reported.append(.{
            .hash = entry.assignment.report.package_spec.hash,
            .exports_root = guarantee.report.package_spec.exports_root,
        });

        // Track reporters and update Pi stats
        for (guarantee.signatures) |sig| {
            const validator = jam_state.kappa.?.validators[sig.validator_index];
            try reporters.append(validator.ed25519);

            // Update guarantee stats in Pi
            if (jam_state.pi) |*pi| {
                (try pi.getValidatorStats(sig.validator_index))
                    .updateReportsGuaranteed(1);
            }
        }
    }

    return .{
        .reported = try reported.toOwnedSlice(),
        .reporters = try reporters.toOwnedSlice(),
    };
}
