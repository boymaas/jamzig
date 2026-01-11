const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const accumulate = @import("../accumulate.zig");
const validator_stats = @import("../validator_stats.zig");

const Params = @import("../jam_params.zig").Params;
const StateTransition = @import("../state_delta.zig").StateTransition;

const trace = @import("tracing").scoped(.validator_stats);

pub const ValidatorStatsInput = struct {
    author_index: ?types.ValidatorIndex,
    guarantees: []const types.ReportGuarantee,
    assurances: []const types.AvailAssurance,
    tickets_count: u32,
    preimages: []const types.Preimage,
    guarantor_reporters: []const types.Ed25519Public,
    assurance_validators: []const types.ValidatorIndex,

    pub const Empty = ValidatorStatsInput{
        .author_index = null,
        .guarantees = &[_]types.ReportGuarantee{},
        .assurances = &[_]types.AvailAssurance{},
        .tickets_count = 0,
        .preimages = &[_]types.Preimage{},
        .guarantor_reporters = &[_]types.Ed25519Public{},
        .assurance_validators = &[_]types.ValidatorIndex{},
    };

    pub fn fromBlock(block: *const types.Block) ValidatorStatsInput {
        return ValidatorStatsInput{
            .author_index = block.header.author_index,
            .guarantees = block.extrinsic.guarantees.data,
            .assurances = block.extrinsic.assurances.data,
            .tickets_count = @intCast(block.extrinsic.tickets.data.len),
            .preimages = block.extrinsic.preimages.data,
            .guarantor_reporters = &[_]types.Ed25519Public{},
            .assurance_validators = &[_]types.ValidatorIndex{},
        };
    }

    pub fn fromBlockWithReporters(
        block: *const types.Block,
        guarantor_reporters: []const types.Ed25519Public,
        assurance_validators: []const types.ValidatorIndex,
    ) ValidatorStatsInput {
        return ValidatorStatsInput{
            .author_index = block.header.author_index,
            .guarantees = block.extrinsic.guarantees.data,
            .assurances = block.extrinsic.assurances.data,
            .tickets_count = @intCast(block.extrinsic.tickets.data.len),
            .preimages = block.extrinsic.preimages.data,
            .guarantor_reporters = guarantor_reporters,
            .assurance_validators = assurance_validators,
        };
    }
};

pub const Error = error{};

pub fn transitionWithInput(
    comptime params: Params,
    stx: *StateTransition(params),
    input: ValidatorStatsInput,
    accumulate_result: *const @import("accumulate.zig").AccumulateResult,
    ready_reports: []types.WorkReport,
) !void {
    const span = trace.span(@src(), .transition_validator_stats);
    defer span.deinit();
    span.debug("Starting validator_stats transition", .{});

    var pi: *state.Pi = try stx.ensure(.pi_prime);

    for (input.guarantees) |guarantee| {
        const core_stats = try pi.getCoreStats(guarantee.report.core_index.value);

        const report = guarantee.report;

        for (report.results) |r| {
            core_stats.gas_used += r.refine_load.gas_used.value;
            core_stats.imports += r.refine_load.imports.value;
            core_stats.extrinsic_count += r.refine_load.extrinsic_count.value;
            core_stats.extrinsic_size += r.refine_load.extrinsic_size.value;
            core_stats.exports += r.refine_load.exports.value;
        }

        core_stats.bundle_size += report.package_spec.length;
    }

    for (0..params.core_count) |core| {
        const core_stats = try pi.getCoreStats(@intCast(core));
        for (input.assurances) |assurance| {
            if (assurance.coreSetInBitfield(@intCast(core))) {
                core_stats.popularity += 1;
            }
        }
    }

    for (ready_reports) |report| {
        const core_stats = try pi.getCoreStats(report.core_index.value);
        core_stats.da_load += report.package_spec.length +
            (params.segment_size *
                try std.math.divCeil(u32, report.package_spec.exports_count * 65, 64));
    }

    if (input.author_index) |author_index| {
        var stats = try pi.getValidatorStats(author_index);
        stats.blocks_produced += 1;
        stats.tickets_introduced += input.tickets_count;

        stats.preimages_introduced += @intCast(input.preimages.len);
        var total_octets: u32 = 0;
        for (input.preimages) |preimage| {
            total_octets += @intCast(preimage.blob.len);
        }
        stats.octets_across_preimages += total_octets;
    }

    // GP statistics.tex: a'[v].guarantees = a[v].guarantees + (κ'[v] ∈ M)
    // Iterate through κ' and check if each validator's Ed25519 key is in reporters set M
    if (input.guarantor_reporters.len > 0) {
        const kappa_prime: *const state.Kappa = try stx.ensure(.kappa_prime);

        for (kappa_prime.validators, 0..) |validator, v| {
            // Check if this validator's Ed25519 key is in the reporters set
            for (input.guarantor_reporters) |reporter_key| {
                if (std.mem.eql(u8, &validator.ed25519, &reporter_key)) {
                    var stats = try pi.getValidatorStats(@intCast(v));
                    stats.reports_guaranteed += 1;
                    break;
                }
            }
        }
    }

    for (input.assurance_validators) |validator_index| {
        var stats = try pi.getValidatorStats(validator_index);
        stats.availability_assurances += 1;
    }

    // GP Eq 13.11
    for (input.preimages) |preimage| {
        const service_stats = try pi.getOrCreateServiceStats(preimage.requester);
        service_stats.provided_count += 1;
        service_stats.provided_size += @intCast(preimage.blob.len);
    }

    // GP Eq 13.12, 13.13, 13.15
    for (input.guarantees) |guarantee| {
        for (guarantee.report.results) |result| {
            const service_stats = try pi.getOrCreateServiceStats(result.service_id);
            service_stats.refinement_count += 1;
            service_stats.refinement_gas_used += result.refine_load.gas_used.value;
            service_stats.imports += result.refine_load.imports.value;
            service_stats.extrinsic_count += result.refine_load.extrinsic_count.value;
            service_stats.extrinsic_size += result.refine_load.extrinsic_size.value;
            service_stats.exports += result.refine_load.exports.value;
        }
    }

    // GP Eq 13.14
    var accum_iter = accumulate_result.accumulation_stats.iterator();
    while (accum_iter.next()) |entry| {
        const service_id = entry.key_ptr.*;
        const stats_I = entry.value_ptr.*;
        const service_stats = try pi.getOrCreateServiceStats(service_id);
        service_stats.accumulate_count += stats_I.accumulated_count;
        service_stats.accumulate_gas_used += stats_I.gas_used;
    }
}

pub fn transition(
    comptime params: Params,
    stx: *StateTransition(params),
    block: *const types.Block,
    reports_result: *const @import("reports.zig").ReportsResult,
    assurance_result: *const @import("assurances.zig").AssuranceResult,
    accumulate_result: *const @import("accumulate.zig").AccumulateResult,
    ready_reports: []types.WorkReport,
) !void {
    const span = trace.span(@src(), .validator_stats);
    defer span.deinit();

    const input = ValidatorStatsInput.fromBlockWithReporters(
        block,
        reports_result.getReporters(),
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
    const span = trace.span(@src(), .transition_epoch);
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
    const span = trace.span(@src(), .clear_per_block_stats);
    defer span.deinit();
    var pi: *state.Pi = try stx.ensure(.pi_prime);

    span.debug("Clearing per block stats", .{});

    pi.clearPerBlockStats();
}
