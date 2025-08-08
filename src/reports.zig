const std = @import("std");
const types = @import("types.zig");
const state = @import("state.zig");
const crypto = std.crypto;

const recent_blocks = @import("recent_blocks.zig");

const duplicate_check = @import("reports/duplicate_check/duplicate_check.zig");
const guarantor = @import("reports/guarantor/guarantor.zig");
const service = @import("reports/service/service.zig");
const dependency = @import("reports/dependency/dependency.zig");
const anchor = @import("reports/anchor/anchor.zig");
const timing = @import("reports/timing/timing.zig");
const gas = @import("reports/gas/gas.zig");
const authorization = @import("reports/authorization/authorization.zig");
const signature = @import("reports/signature/signature.zig");
const output = @import("reports/output/output.zig");
const banned = @import("reports/banned/banned.zig");

const StateTransition = @import("state_delta.zig").StateTransition;

const tracing = @import("tracing.zig");
const trace = tracing.scoped(.reports);

/// Error types for report validation and processing
pub const Error = error{
    BadCoreIndex,
    FutureReportSlot,
    ReportEpochBeforeLast,
    InsufficientGuarantees,
    OutOfOrderGuarantee,
    NotSortedOrUniqueGuarantors,
    TooManyGuarantees,
    WrongAssignment,
    CoreEngaged,
    AnchorNotRecent,
    BadServiceId,
    BadCodeHash,
    BadAnchor,
    DependencyMissing,
    TooManyDependencies,
    DuplicatePackage,
    BadStateRoot,
    BadBeefyMmrRoot,
    CoreUnauthorized,
    BadValidatorIndex,
    WorkReportGasTooHigh,
    ServiceItemGasTooLow,
    SegmentRootLookupInvalid,
    BadSignature,
    InvalidValidatorPublicKey,
    InvalidRotationPeriod,
    InvalidSlotRange,
    WorkReportTooBig,
    BannedValidators,
};

pub const ValidatedGuaranteeExtrinsic = struct {
    guarantees: []const types.ReportGuarantee,

    // See: https://graypaper.fluffylabs.dev/#/85129da/146302146302?v=0.6.3
    pub fn validate(
        comptime params: @import("jam_params.zig").Params,
        allocator: std.mem.Allocator,
        stx: *StateTransition(params),
        guarantees: types.GuaranteesExtrinsic,
    ) !@This() {
        const span = trace.span(.validate_guarantees);
        defer span.deinit();
        span.debug("Starting guarantee validation for {d} guarantees", .{guarantees.data.len});

        // Check for duplicate packages in the batch
        duplicate_check.checkDuplicatePackageInBatch(params, guarantees) catch |err| switch (err) {
            duplicate_check.Error.DuplicatePackage => return Error.DuplicatePackage,
            duplicate_check.Error.DuplicatePackageInGuarantees => return Error.DuplicatePackage,
            else => |e| return e,
        };

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

            // Validate output size limits
            output.validateOutputSize(params, guarantee) catch |err| switch (err) {
                output.Error.WorkReportTooBig => return Error.WorkReportTooBig,
                else => |e| return e,
            };

            // Validate gas limits
            gas.validateGasLimits(params, guarantee) catch |err| switch (err) {
                gas.Error.WorkReportGasTooHigh => return Error.WorkReportGasTooHigh,
                else => |e| return e,
            };

            // Check total dependencies don't exceed J according to equation 11.3
            dependency.validateDependencyCount(params, guarantee) catch |err| switch (err) {
                dependency.Error.TooManyDependencies => return Error.TooManyDependencies,
                else => |e| return e,
            };

            // Check if we have enough signatures:

            // Validate report slot is not in future
            timing.validateReportSlot(params, stx, guarantee) catch |err| switch (err) {
                timing.Error.FutureReportSlot => return Error.FutureReportSlot,
                else => |e| return e,
            };

            // Check rotation period according to graypaper 11.27
            timing.validateRotationPeriod(params, stx, guarantee) catch |err| switch (err) {
                timing.Error.ReportEpochBeforeLast => return Error.ReportEpochBeforeLast,
                else => |e| return e,
            };

            // Validate anchor is recent
            anchor.validateAnchor(params, stx, guarantee) catch |err| switch (err) {
                anchor.Error.AnchorNotRecent => return Error.AnchorNotRecent,
                anchor.Error.BadBeefyMmrRoot => return Error.BadBeefyMmrRoot,
                anchor.Error.BadStateRoot => return Error.BadStateRoot,
                anchor.Error.BadAnchor => return Error.BadAnchor,
                else => |e| return e,
            };

            // Validate guarantors are sorted and unique
            guarantor.validateSortedAndUnique(guarantee) catch |err| switch (err) {
                guarantor.Error.NotSortedOrUniqueGuarantors => return Error.NotSortedOrUniqueGuarantors,
                else => |e| return e,
            };

            // Check service ID exists
            service.validateServices(params, stx, guarantee) catch |err| switch (err) {
                service.Error.BadServiceId => return Error.BadServiceId,
                service.Error.BadCodeHash => return Error.BadCodeHash,
                service.Error.ServiceItemGasTooLow => return Error.ServiceItemGasTooLow,
                else => |e| return e,
            };

            // TODO: Check core is not engaged
            // if (jam_state.rho.?.isEngaged(guarantee.report.core_index)) {
            //     return Error.CoreEngaged;
            // }

            // Validate report prerequisites exist
            dependency.validatePrerequisites(params, stx, guarantee, guarantees) catch |err| switch (err) {
                dependency.Error.DependencyMissing => return Error.DependencyMissing,
                else => |e| return e,
            };

            // Verify segment root lookup is valid
            dependency.validateSegmentRootLookup(params, stx, guarantee, guarantees) catch |err| switch (err) {
                dependency.Error.SegmentRootLookupInvalid => return Error.SegmentRootLookupInvalid,
                else => |e| return e,
            };

            // Check timeslot is within valid range
            timing.validateSlotRange(params, stx, guarantee) catch |err| switch (err) {
                timing.Error.ReportEpochBeforeLast => return Error.ReportEpochBeforeLast,
                else => |e| return e,
            };

            // 11.27 ---

            // BUILD ASSIGNMENTS ONCE FOR THIS GUARANTEE
            var assignments = try @import("guarantor_assignments.zig").determineGuarantorAssignments(
                params,
                allocator,
                stx,
                guarantee.slot,
            );
            defer assignments.deinit(allocator);

            // Validate signatures
            {
                const sig_span = span.child(.validate_signatures);
                defer sig_span.deinit();

                sig_span.debug("Validating {d} guarantor signatures", .{guarantee.signatures.len});

                // Validate signature count
                guarantor.validateSignatureCount(guarantee) catch |err| switch (err) {
                    guarantor.Error.InsufficientGuarantees => return Error.InsufficientGuarantees,
                    guarantor.Error.TooManyGuarantees => return Error.TooManyGuarantees,
                    else => |e| return e,
                };
                // Validate all validator indices are in range upfront
                try signature.validateValidatorIndices(params, guarantee);

                // Check if any guarantor is banned
                banned.checkBannedValidators(params, guarantee, stx, &assignments) catch |err| switch (err) {
                    banned.Error.BannedValidators => return Error.BannedValidators,
                    else => |e| return e,
                };

                // Validate guarantor assignments using pre-built assignments
                guarantor.validateGuarantorAssignmentsWithPrebuilt(
                    params,
                    guarantee,
                    &assignments,
                ) catch |err| switch (err) {
                    guarantor.Error.InvalidGuarantorAssignment => return Error.WrongAssignment,
                    else => |e| return e,
                };

                // Validate signatures using pre-built assignments
                signature.validateSignaturesWithAssignments(
                    params,
                    allocator,
                    guarantee,
                    &assignments,
                ) catch |err| switch (err) {
                    signature.Error.BadValidatorIndex => return Error.BadValidatorIndex,
                    signature.Error.BadSignature => return Error.BadSignature,
                    signature.Error.InvalidValidatorPublicKey => return Error.InvalidValidatorPublicKey,
                    else => |e| return e,
                };
            }

            // Core must be free or its previous report must have timed out
            timing.validateCoreTimeout(params, stx, guarantee) catch |err| switch (err) {
                timing.Error.CoreEngaged => return Error.CoreEngaged,
                else => |e| return e,
            };

            // Check if the authorizer hash is valid
            authorization.validateCoreAuthorization(params, stx, guarantee) catch |err| switch (err) {
                authorization.Error.CoreUnauthorized => return Error.CoreUnauthorized,
                else => |e| return e,
            };

            // Check for duplicate packages across states
            duplicate_check.checkDuplicatePackageInRecentHistory(params, stx, guarantee, guarantees) catch |err| switch (err) {
                duplicate_check.Error.DuplicatePackage => return Error.DuplicatePackage,
                duplicate_check.Error.DuplicatePackageInGuarantees => return Error.DuplicatePackage,
                else => |e| return e,
            };
            // TODO: should we add this?
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

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.reported);
        allocator.free(self.reporters);
        self.* = undefined;
    }
};

pub fn processGuaranteeExtrinsic(
    comptime params: @import("jam_params.zig").Params,
    allocator: std.mem.Allocator,
    stx: *StateTransition(params),
    validated: ValidatedGuaranteeExtrinsic,
) !Result {
    const span = trace.span(.process_guarantees);
    defer span.deinit();
    span.debug("Processing guarantees - count: {d}, slot: {d}", .{ validated.guarantees.len, stx.time.current_slot });
    // span.trace("Current state root: {s}", .{
    //     std.fmt.fmtSliceHexLower(&jam_state.beta.?.blocks.items[0].state_root),
    // });

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
        process_span.debug("Creating availability assignment with timeout {d}", .{stx.time.current_slot});
        const assignment = types.AvailabilityAssignment{
            .report = try guarantee.report.deepClone(allocator),
            .timeout = stx.time.current_slot,
        };

        var rho: *state.Rho(params.core_count) = try stx.ensure(.rho_prime);
        rho.setReport(
            core_index,
            assignment,
        );

        // Track reported packages
        try reported.append(.{
            .hash = assignment.report.package_spec.hash,
            .exports_root = guarantee.report.package_spec.exports_root,
        });

        // BUILD ASSIGNMENTS ONCE FOR REPORTER EXTRACTION
        var assignments = try @import("guarantor_assignments.zig").determineGuarantorAssignments(
            params,
            allocator,
            stx,
            guarantee.slot,
        );
        defer assignments.deinit(allocator);

        // Track reporters using the correct validator set from assignments
        add_reporters: for (guarantee.signatures) |sig| {
            const validator = assignments.validators.validators[sig.validator_index];

            for (reporters.items) |reporter| {
                if (std.mem.eql(u8, &reporter, &validator.ed25519)) {
                    // Already added this reporter
                    continue :add_reporters;
                }
            }

            try reporters.append(validator.ed25519);
        }
    }

    return .{
        .reported = try reported.toOwnedSlice(),
        .reporters = try reporters.toOwnedSlice(),
    };
}
