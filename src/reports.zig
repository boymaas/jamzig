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

const tracing = @import("tracing");
const trace = tracing.scoped(.reports);

pub const Error = error{
    BadCoreIndex,
    InsufficientGuarantees,
    OutOfOrderGuarantee,
    CoreEngaged,
    DuplicatePackage,
    LookupAnchorNotRecent,  // v0.7.2
    MissingWorkResults,  // v0.7.2
} || anchor.Error ||
    service.Error ||
    dependency.Error ||
    timing.Error ||
    guarantor.Error ||
    signature.Error ||
    output.Error ||
    gas.Error ||
    authorization.Error ||
    banned.Error ||
    duplicate_check.Error;

pub const ValidatedGuaranteeExtrinsic = struct {
    guarantees: []const types.ReportGuarantee,

    // See: https://graypaper.fluffylabs.dev/#/85129da/146302146302?v=0.6.3
    pub fn validate(
        comptime params: @import("jam_params.zig").Params,
        allocator: std.mem.Allocator,
        stx: *StateTransition(params),
        guarantees: types.GuaranteesExtrinsic,
    ) !@This() {
        const span = trace.span(@src(), .validate_guarantees);
        defer span.deinit();
        span.debug("Starting guarantee validation for {d} guarantees", .{guarantees.data.len});

        duplicate_check.checkDuplicatePackageInBatch(params, guarantees) catch |err| switch (err) {
            duplicate_check.Error.DuplicatePackage => return Error.DuplicatePackage,
            duplicate_check.Error.DuplicatePackageInGuarantees => return Error.DuplicatePackage,
            else => |e| return e,
        };

        var prev_guarantee_core: ?u32 = null;
        for (guarantees.data) |guarantee| {
            const core_span = span.child(@src(), .validate_core);
            defer core_span.deinit();
            core_span.debug("Validating core index {d} for report hash {s}", .{
                guarantee.report.core_index.value,
                std.fmt.fmtSliceHexLower(&guarantee.report.package_spec.hash),
            });
            core_span.trace("Report context - anchor: {s}, lookup_anchor: {s}", .{
                std.fmt.fmtSliceHexLower(&guarantee.report.context.anchor),
                std.fmt.fmtSliceHexLower(&guarantee.report.context.lookup_anchor),
            });

            if (guarantee.report.core_index.value >= params.core_count) {
                core_span.err("Invalid core index {d} >= {d}", .{ guarantee.report.core_index.value, params.core_count });
                return Error.BadCoreIndex;
            }

            if (guarantee.report.results.len == 0) {
                core_span.err("Work report has no results", .{});
                return Error.MissingWorkResults;
            }

            if (prev_guarantee_core != null and guarantee.report.core_index.value <= prev_guarantee_core.?) {
                core_span.err("Out-of-order guarantee: {d} <= {d}", .{ guarantee.report.core_index.value, prev_guarantee_core.? });
                return Error.OutOfOrderGuarantee;
            }
            prev_guarantee_core = guarantee.report.core_index.value;

            try output.validateOutputSize(params, guarantee);
            try gas.validateGasLimits(params, guarantee);
            try dependency.validateDependencyCount(params, guarantee);
            try timing.validateReportSlot(params, stx, guarantee);
            try timing.validateRotationPeriod(params, stx, guarantee);
            try anchor.validateAnchor(params, stx, guarantee);
            try guarantor.validateSortedAndUnique(guarantee);
            try service.validateServices(params, stx, guarantee);

            // TODO: Check core is not engaged
            // if (jam_state.rho.?.isEngaged(guarantee.report.core_index)) {
            //     return Error.CoreEngaged;
            // }

            try dependency.validatePrerequisites(params, stx, guarantee, guarantees);
            try dependency.validateSegmentRootLookup(params, stx, guarantee, guarantees);
            try timing.validateSlotRange(params, stx, guarantee);

            var assignments = try @import("guarantor_assignments.zig").determineGuarantorAssignments(
                params,
                allocator,
                stx,
                guarantee.slot,
            );
            defer assignments.deinit(allocator);

            {
                const sig_span = span.child(@src(), .validate_signatures);
                defer sig_span.deinit();

                sig_span.debug("Validating {d} guarantor signatures", .{guarantee.signatures.len});

                try guarantor.validateSignatureCount(guarantee);
                try signature.validateValidatorIndices(params, guarantee);
                try banned.checkBannedValidators(params, guarantee, stx, &assignments);
                try guarantor.validateGuarantorAssignmentsWithPrebuilt(
                    params,
                    guarantee,
                    &assignments,
                );
                try signature.validateSignaturesWithAssignments(
                    params,
                    allocator,
                    guarantee,
                    &assignments,
                );
            }

            try timing.validateCoreTimeout(params, stx, guarantee);
            try authorization.validateCoreAuthorization(params, stx, guarantee);
            try duplicate_check.checkDuplicatePackageInRecentHistory(params, stx, guarantee, guarantees);
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
    reported: []types.ReportedWorkPackage,
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
    const span = trace.span(@src(), .process_guarantees);
    defer span.deinit();
    span.debug("Processing guarantees - count: {d}, slot: {d}", .{ validated.guarantees.len, stx.time.current_slot });
    // span.trace("Current state root: {s}", .{
    //     std.fmt.fmtSliceHexLower(&jam_state.beta.?.blocks.items[0].state_root),
    // });

    var reported = std.ArrayList(types.ReportedWorkPackage).init(allocator);
    defer reported.deinit();

    var reporters = std.ArrayList(types.Ed25519Public).init(allocator);
    defer reporters.deinit();

    for (validated.guarantees) |guarantee| {
        const process_span = span.child(@src(), .process_guarantee);
        defer process_span.deinit();

        const core_index = guarantee.report.core_index.value;
        process_span.debug("Processing guarantee for core {d}", .{core_index});

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

        try reported.append(.{
            .hash = assignment.report.package_spec.hash,
            .exports_root = guarantee.report.package_spec.exports_root,
        });

        var assignments = try @import("guarantor_assignments.zig").determineGuarantorAssignments(
            params,
            allocator,
            stx,
            guarantee.slot,
        );
        defer assignments.deinit(allocator);

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

    const reported_slice = try reported.toOwnedSlice();
    errdefer allocator.free(reported_slice);

    return .{
        .reported = reported_slice,
        .reporters = try reporters.toOwnedSlice(),
    };
}
