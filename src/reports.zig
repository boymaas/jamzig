const std = @import("std");
const types = @import("types.zig");
const state = @import("state.zig");
const crypto = std.crypto;

const tracing = @import("tracing.zig");
const trace = tracing.scoped(.reports);

pub const Error = error{
    BadCoreIndex,
    FutureReportSlot,
    ReportEpochBeforeLast,
    InsufficientGuarantees,
    OutOfOrderGuarantee,
    NotSortedOrUniqueGuarantors,
    WrongAssignment,
    CoreEngaged,
    AnchorNotRecent,
    BadServiceId,
    BadCodeHash,
    DependencyMissing,
    DuplicatePackage,
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
        // Validate all guarantees
        for (guarantees.data) |guarantee| {
            // Check core index
            if (guarantee.report.core_index >= params.core_count) {
                return Error.BadCoreIndex;
            }

            // Validate report slot is not in future
            if (guarantee.slot > slot) {
                return Error.FutureReportSlot;
            }

            // Check epoch is current or last
            const report_epoch = guarantee.slot / params.epoch_length;
            const current_epoch = slot / params.epoch_length;
            if (report_epoch + 1 < current_epoch) {
                return Error.ReportEpochBeforeLast;
            }

            // Check sufficient guarantors
            if (guarantee.signatures.len < params.validators_super_majority) {
                return Error.InsufficientGuarantees;
            }

            // Validate guarantors are sorted and unique
            var prev_index: types.ValidatorIndex = 0;
            for (guarantee.signatures) |sig| {
                if (sig.validator_index <= prev_index) {
                    return Error.NotSortedOrUniqueGuarantors;
                }
                prev_index = sig.validator_index;
            }

            // Validate core assignment
            const assignment = jam_state.rho.?.getReport(guarantee.report.core_index);
            if (assignment == null) {
                return Error.WrongAssignment;
            }

            // Check core is not engaged
            // if (jam_state.rho.?.isEngaged(guarantee.report.core_index)) {
            //     return Error.CoreEngaged;
            // }

            // Validate anchor is recent
            if (jam_state.beta.?.getBlockInfoByHash(guarantee.report.context.anchor) == null) {
                return Error.AnchorNotRecent;
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
            for (guarantee.signatures) |sig| {
                if (sig.validator_index >= jam_state.kappa.?.validators.len) {
                    return Error.BadValidatorIndex;
                }

                const validator = jam_state.kappa.?.validators[sig.validator_index];
                const public_key = validator.ed25519;

                // Create message to verify using Blake2b
                // The message is: "jam_guarantee" ++ H(E(anchor, bitfield))
                const prefix: []const u8 = "jam_available";
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
    var reported = std.ArrayList(types.ReportedWorkPackage).init(allocator);
    defer reported.deinit();

    var reporters = std.ArrayList(types.Ed25519Public).init(allocator);
    defer reporters.deinit();

    // Process each validated guarantee
    for (validated.guarantees) |guarantee| {
        const core_index = guarantee.report.core_index;

        // Check if core can be reused
        if (jam_state.rho.?.getReport(core_index)) |existing| {
            const timeout = existing.assignment.timeout;
            if (slot < timeout + params.work_replacement_period) {
                return error.CoreEngaged;
            }
        }

        // Check for duplicate packages across states
        // TODO: move this to recent_blocks
        const package_hash = guarantee.report.package_spec.hash;
        for (jam_state.beta.?.blocks.items) |block| {
            for (block.work_reports) |report| {
                if (std.mem.eql(u8, &report.hash, &package_hash)) {
                    return error.DuplicatePackage;
                }
            }
        }

        // Add report to Rho state
        jam_state.rho.?.setReport(
            core_index,
            types.AvailabilityAssignment{
                .report = try guarantee.report.deepClone(allocator),
                .timeout = guarantee.slot,
            },
        );

        // Track reported packages
        try reported.append(.{
            .hash = package_hash,
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
