const std = @import("std");

const types = @import("../types.zig");
const state = @import("../state.zig");

const Params = @import("../jam_params.zig").Params;
const StateTransition = @import("../state_delta.zig").StateTransition;

const trace = @import("../tracing.zig").scoped(.stf);

pub const Error = error{};

pub fn transition(
    comptime params: Params,
    stx: *StateTransition(params),
    new_block: *const types.Block,
    ready_reports: []types.WorkReport,
) !void {
    const span = trace.span(.transition_validator_stats);
    defer span.deinit();
    span.debug("Starting validator_stats transition", .{});

    var pi: *state.Pi = try stx.ensureT(state.Pi, .pi_prime);

    // Since we have validated guarantees here lets run through them
    // and update appropiate core statistics.
    // TODO: put this in it own statistics stf
    for (new_block.extrinsic.guarantees.data) |guarantee| {
        const core_stats = try pi.getCoreStats(guarantee.report.core_index);

        const report = guarantee.report;

        for (report.results) |r| {
            core_stats.gas_used += r.refine_load.gas_used;
            core_stats.imports += r.refine_load.imports;
            core_stats.extrinsic_count += r.refine_load.extrinsic_count;
            core_stats.extrinsic_size += r.refine_load.extrinsic_size;
            core_stats.exports += r.refine_load.exports;

            // This is set when we have an availability assurance
            // core_stats.popularity += 0;
        }

        core_stats.bundle_size += report.package_spec.length;
    }

    // Process any ready reports to calculate their data availability load
    for (ready_reports) |report| {
        const core_stats = try pi.getCoreStats(report.core_index);
        core_stats.da_load += report.package_spec.exports_count +
            (params.segmentSizeInOctets() *
                try std.math.divCeil(u32, report.package_spec.exports_count * 65, 64));
    }

    var stats = try pi.getValidatorStats(new_block.header.author_index);
    stats.blocks_produced += 1;
    stats.tickets_introduced += @intCast(new_block.extrinsic.tickets.data.len);

    // Eq 13.11: Preimages Introduced (provided_count, provided_size)
    // Depends on E_P (PreimagesExtrinsic)
    for (new_block.extrinsic.preimages.data) |preimage| {
        const service_stats = try pi.getOrCreateServiceStats(preimage.requester);
        service_stats.provided_count += 1;
        service_stats.provided_size += @intCast(preimage.blob.len);
    }

    // Eq 13.12, 13.13, 13.15 (partially): Refinement Stats
    // Depends on E_G (GuaranteesExtrinsic -> WorkReports -> WorkResults)
    for (new_block.extrinsic.guarantees.data) |guarantee| {
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

    // TODO: add accumulation stats and transfer stats

}

pub fn transition_epoch(
    comptime params: Params,
    stx: *StateTransition(params),
) !void {
    const span = trace.span(.transition_validator_stats_epoch);
    defer span.deinit();
    span.debug("Starting validator_stats transition", .{});
    var pi = try stx.ensureT(state.Pi, .pi_prime);

    if (stx.time.isNewEpoch()) {
        try pi.transitionToNextEpoch();
    }
}
