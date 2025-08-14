const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const accumulate = @import("../accumulate.zig");
const validator_stats = @import("../validator_stats.zig");

const Params = @import("../jam_params.zig").Params;
const StateTransition = @import("../state_delta.zig").StateTransition;

const trace = @import("../tracing.zig").scoped(.stf);

/// This structure contains all the necessary data for the validator statistics
/// state transition function, decoupled from the Block type.
pub const ValidatorStatsInput = struct {
    /// The validator index who produced the block
    author_index: ?types.ValidatorIndex,
    /// The list of work guarantees
    guarantees: []const types.ReportGuarantee,
    /// The list of availability assurances
    assurances: []const types.AvailAssurance,
    /// The number of tickets introduced in this block
    tickets_count: u32,
    /// The list of preimages
    preimages: []const types.Preimage,
    /// Validators who guaranteed reports (for reports_guaranteed stat)
    guarantor_validators: []const types.ValidatorIndex,
    /// Validators who made assurances (for availability_assurances stat)
    assurance_validators: []const types.ValidatorIndex,

    pub const Empty = ValidatorStatsInput{
        .author_index = null,
        .guarantees = &[_]types.ReportGuarantee{},
        .assurances = &[_]types.AvailAssurance{},
        .tickets_count = 0,
        .preimages = &[_]types.Preimage{},
        .guarantor_validators = &[_]types.ValidatorIndex{},
        .assurance_validators = &[_]types.ValidatorIndex{},
    };

    /// Create a ValidatorStatsInput from a Block (basic version for tests)
    pub fn fromBlock(block: *const types.Block) ValidatorStatsInput {
        return ValidatorStatsInput{
            .author_index = block.header.author_index,
            .guarantees = block.extrinsic.guarantees.data,
            .assurances = block.extrinsic.assurances.data,
            .tickets_count = @intCast(block.extrinsic.tickets.data.len),
            .preimages = block.extrinsic.preimages.data,
            .guarantor_validators = &[_]types.ValidatorIndex{},
            .assurance_validators = &[_]types.ValidatorIndex{},
        };
    }

    /// Create a ValidatorStatsInput from a Block with validator indices
    pub fn fromBlockWithValidators(
        block: *const types.Block,
        guarantor_validators: []const types.ValidatorIndex,
        assurance_validators: []const types.ValidatorIndex,
    ) ValidatorStatsInput {
        return ValidatorStatsInput{
            .author_index = block.header.author_index,
            .guarantees = block.extrinsic.guarantees.data,
            .assurances = block.extrinsic.assurances.data,
            .tickets_count = @intCast(block.extrinsic.tickets.data.len),
            .preimages = block.extrinsic.preimages.data,
            .guarantor_validators = guarantor_validators,
            .assurance_validators = assurance_validators,
        };
    }
};

pub const Error = error{};

/// Transition function that takes ValidatorStatsInput directly
/// This is the core implementation that can be used without a block
pub fn transitionWithInput(
    comptime params: Params,
    stx: *StateTransition(params),
    input: ValidatorStatsInput,
    accumulate_result: *const @import("accumulate.zig").AccumulateResult,
    ready_reports: []types.WorkReport,
) !void {
    const span = trace.span(.transition_validator_stats);
    defer span.deinit();
    span.debug("Starting validator_stats transition", .{});

    var pi: *state.Pi = try stx.ensure(.pi_prime);

    // Since we have validated guarantees here lets run through them
    // and update appropiate core statistics.
    for (input.guarantees) |guarantee| {
        const core_stats = try pi.getCoreStats(guarantee.report.core_index);

        const report = guarantee.report;

        for (report.results) |r| {
            core_stats.gas_used += r.refine_load.gas_used;
            core_stats.imports += r.refine_load.imports;
            core_stats.extrinsic_count += r.refine_load.extrinsic_count;
            core_stats.extrinsic_size += r.refine_load.extrinsic_size;
            core_stats.exports += r.refine_load.exports;
        }

        core_stats.bundle_size += report.package_spec.length;
    }

    // Set the polpularity
    for (0..params.core_count) |core| {
        const core_stats = try pi.getCoreStats(@intCast(core));
        for (input.assurances) |assurance| {
            if (assurance.coreSetInBitfield(@intCast(core))) {
                // This is set when we have an availability assurance
                core_stats.popularity += 1;
            }
        }
    }

    // Process any ready reports to calculate their data availability load
    for (ready_reports) |report| {
        const core_stats = try pi.getCoreStats(report.core_index);
        core_stats.da_load += report.package_spec.length +
            (params.segmentSizeInOctets() *
                try std.math.divCeil(u32, report.package_spec.exports_count * 65, 64));
    }

    // Update validator statistics for the block author
    if (input.author_index) |author_index| {
        var stats = try pi.getValidatorStats(author_index);
        stats.blocks_produced += 1;
        stats.tickets_introduced += input.tickets_count;

        // Preimages statistics (previously in stf/preimages.zig)
        stats.preimages_introduced += @intCast(input.preimages.len);
        var total_octets: u32 = 0;
        for (input.preimages) |preimage| {
            total_octets += @intCast(preimage.blob.len);
        }
        stats.octets_across_preimages += total_octets;
    }

    // Update reports_guaranteed for guarantors (previously in stf/reports.zig)
    for (input.guarantor_validators) |validator_index| {
        var stats = try pi.getValidatorStats(validator_index);
        stats.reports_guaranteed += 1;
    }

    // Update availability_assurances for validators who made assurances (previously in stf/assurances.zig)
    for (input.assurance_validators) |validator_index| {
        var stats = try pi.getValidatorStats(validator_index);
        stats.availability_assurances += 1;
    }

    // Eq 13.11: Preimages Introduced (provided_count, provided_size)
    // Depends on E_P (PreimagesExtrinsic)
    for (input.preimages) |preimage| {
        const service_stats = try pi.getOrCreateServiceStats(preimage.requester);
        service_stats.provided_count += 1;
        service_stats.provided_size += @intCast(preimage.blob.len);
    }

    // Eq 13.12, 13.13, 13.15 (partially): Refinement Stats
    // Depends on E_G (GuaranteesExtrinsic -> WorkReports -> WorkResults)
    for (input.guarantees) |guarantee| {
        for (guarantee.report.results) |result| {
            const service_stats = try pi.getOrCreateServiceStats(result.service_id);
            // Eq 13.12 part 1: refinement_count
            service_stats.refinement_count += 1;
            // Eq 13.12 part 2: refinement_gas_used
            service_stats.refinement_gas_used += result.refine_load.gas_used;
            // Eq 13.13: imports, extrinsic_count, extrinsic_size, exports
            service_stats.imports += result.refine_load.imports;
            service_stats.extrinsic_count += result.refine_load.extrinsic_count;
            service_stats.extrinsic_size += result.refine_load.extrinsic_size;
            service_stats.exports += result.refine_load.exports;
        }
    }

    // Eq 13.14: Accumulation Stats (accumulate_count, accumulate_gas_used)
    // Depends on I (Accumulation Statistics - map ServiceId -> (Gas, Count)) - Eq 12.25
    var accum_iter = accumulate_result.accumulation_stats.iterator();
    while (accum_iter.next()) |entry| {
        const service_id = entry.key_ptr.*;
        const stats_I = entry.value_ptr.*; // {gas_used, accumulated_count}
        const service_stats = try pi.getOrCreateServiceStats(service_id);
        service_stats.accumulate_count += stats_I.accumulated_count;
        service_stats.accumulate_gas_used += stats_I.gas_used;
    }

    // Eq 13.15: Transfer Stats (on_transfers_count, on_transfers_gas_used)
    // Depends on X (Transfer Statistics - map ServiceId -> (Count, Gas)) - Eq 12.30
    var transfer_iter = accumulate_result.transfer_stats.iterator();
    while (transfer_iter.next()) |entry| {
        const service_id = entry.key_ptr.*;
        const stats_X = entry.value_ptr.*; // {transfer_count, gas_used}
        const service_stats = try pi.getOrCreateServiceStats(service_id);
        service_stats.on_transfers_count += stats_X.transfer_count;
        service_stats.on_transfers_gas_used += stats_X.gas_used;
    }
}

/// Transition function that takes a block and delegates to transitionWithInput
/// This maintains backward compatibility with existing code
pub fn transition(
    comptime params: Params,
    stx: *StateTransition(params),
    block: *const types.Block,
    reports_result: *const @import("reports.zig").ReportsResult,
    assurance_result: *const @import("assurances.zig").AssuranceResult,
    accumulate_result: *const @import("accumulate.zig").AccumulateResult,
    ready_reports: []types.WorkReport,
) !void {
    const input = ValidatorStatsInput.fromBlockWithValidators(
        block,
        reports_result.validator_indices,
        assurance_result.validator_indices,
    );

    try transitionWithInput(
        params,
        stx,
        input,
        accumulate_result,
        ready_reports,
    );
}

pub fn transitionEpoch(
    comptime params: Params,
    stx: *StateTransition(params),
) !void {
    const span = trace.span(.transition_validator_stats_epoch);
    defer span.deinit();
    span.debug("Starting validator_stats transition", .{});
    var pi: *state.Pi = try stx.ensure(.pi_prime);

    if (stx.time.isNewEpoch()) {
        span.debug("Transitioning to next epoch", .{});
        try pi.transitionToNextEpoch();
    }
}

pub fn clearPerBlockStats(
    comptime params: Params,
    stx: *StateTransition(params),
) !void {
    const span = trace.span(.transition_validator_stats_epoch);
    defer span.deinit();
    var pi: *state.Pi = try stx.ensure(.pi_prime);

    span.debug("Clearing per block stats", .{});

    // now clear the per block stats
    pi.clearPerBlockStats();
}
