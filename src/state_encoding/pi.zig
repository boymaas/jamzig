const std = @import("std");
const types = @import("../types.zig");
const encoder = @import("../codec/encoder.zig");
const codec = @import("../codec.zig");

const trace = @import("../tracing.zig").scoped(.codec);

const validator_statistics = @import("../validator_stats.zig");
const Pi = validator_statistics.Pi;
const ValidatorIndex = types.ValidatorIndex;
const ValidatorStats = validator_statistics.ValidatorStats;
const CoreActivityRecord = validator_statistics.CoreActivityRecord;
const ServiceStatsEntry = validator_statistics.ServiceStatsEntry;

pub fn encode(self: *const Pi, writer: anytype) !void {
    const span = trace.span(.encode);
    defer span.deinit();
    span.debug("Starting Pi component encoding", .{});

    // Encode current epoch stats
    const current_span = span.child(.current_epoch);
    defer current_span.deinit();
    current_span.debug("Encoding current epoch stats for {} validators", .{self.current_epoch_stats.items.len});
    try encodeEpochStats(self.current_epoch_stats.items, writer);

    // Encode previous epoch stats
    const previous_span = span.child(.previous_epoch);
    defer previous_span.deinit();
    previous_span.debug("Encoding previous epoch stats for {} validators", .{self.previous_epoch_stats.items.len});
    try encodeEpochStats(self.previous_epoch_stats.items, writer);

    // Encode core statistics
    const core_span = span.child(.core_stats);
    defer core_span.deinit();
    core_span.debug("Encoding core stats for {} cores", .{self.core_stats.items.len});
    try encodeCoreStats(self.core_stats.items, writer);

    // Encode service statistics
    const service_span = span.child(.service_stats);
    defer service_span.deinit();
    service_span.debug("Encoding service stats for {} services", .{self.service_stats.items.len});
    try encodeServiceStats(self.service_stats.items, writer);

    span.debug("Successfully completed Pi encoding", .{});
}

fn encodeEpochStats(stats: []ValidatorStats, writer: anytype) !void {
    const span = trace.span(.encode_epoch_stats);
    defer span.deinit();
    span.debug("Encoding epoch stats for {} validators", .{stats.len});

    for (stats, 0..) |entry, i| {
        const entry_span = span.child(.validator_entry);
        defer entry_span.deinit();
        entry_span.debug("Encoding stats for validator {}", .{i});

        entry_span.trace("Blocks produced: {}", .{entry.blocks_produced});
        try writer.writeInt(u32, entry.blocks_produced, .little);

        entry_span.trace("Tickets introduced: {}", .{entry.tickets_introduced});
        try writer.writeInt(u32, entry.tickets_introduced, .little);

        entry_span.trace("Preimages introduced: {}", .{entry.preimages_introduced});
        try writer.writeInt(u32, entry.preimages_introduced, .little);

        entry_span.trace("Octets across preimages: {}", .{entry.octets_across_preimages});
        try writer.writeInt(u32, entry.octets_across_preimages, .little);

        entry_span.trace("Reports guaranteed: {}", .{entry.reports_guaranteed});
        try writer.writeInt(u32, entry.reports_guaranteed, .little);

        entry_span.trace("Availability assurances: {}", .{entry.availability_assurances});
        try writer.writeInt(u32, entry.availability_assurances, .little);
    }

    span.debug("Successfully encoded all validator stats", .{});
}

fn encodeCoreStats(stats: []CoreActivityRecord, writer: anytype) !void {
    const span = trace.span(.encode_core_stats);
    defer span.deinit();
    span.debug("Encoding core stats for {} cores", .{stats.len});

    for (stats, 0..) |entry, i| {
        const entry_span = span.child(.core_entry);
        defer entry_span.deinit();
        entry_span.debug("Encoding stats for core {}", .{i});

        entry_span.trace("Gas used: {}", .{entry.gas_used});
        try writer.writeInt(u64, entry.gas_used, .little);

        entry_span.trace("Imports: {}", .{entry.imports});
        try writer.writeInt(u16, entry.imports, .little);

        entry_span.trace("Extrinsic count: {}", .{entry.extrinsic_count});
        try writer.writeInt(u16, entry.extrinsic_count, .little);

        entry_span.trace("Extrinsic size: {}", .{entry.extrinsic_size});
        try writer.writeInt(u32, entry.extrinsic_size, .little);

        entry_span.trace("Exports: {}", .{entry.exports});
        try writer.writeInt(u16, entry.exports, .little);

        entry_span.trace("Bundle size: {}", .{entry.bundle_size});
        try writer.writeInt(u32, entry.bundle_size, .little);

        entry_span.trace("DA load: {}", .{entry.da_load});
        try writer.writeInt(u32, entry.da_load, .little);

        entry_span.trace("Popularity: {}", .{entry.popularity});
        try writer.writeInt(u16, entry.popularity, .little);
    }

    span.debug("Successfully encoded all core stats", .{});
}

fn encodeServiceStats(stats: []ServiceStatsEntry, writer: anytype) !void {
    const span = trace.span(.encode_service_stats);
    defer span.deinit();
    span.debug("Encoding service stats for {} services", .{stats.len});

    // First encode the number of services
    const count = @as(u32, @truncate(stats.len));
    try writer.writeInt(u32, count, .little);

    for (stats, 0..) |entry, i| {
        const entry_span = span.child(.service_entry);
        defer entry_span.deinit();
        entry_span.debug("Encoding stats for service {} (ID: {})", .{ i, entry.id });

        // Encode service ID
        entry_span.trace("Service ID: {}", .{entry.id});
        try writer.writeInt(u32, entry.id, .little);

        const record = entry.record;

        // Encode preimage stats
        entry_span.trace("Provided count: {}", .{record.provided_count});
        try writer.writeInt(u16, record.provided_count, .little);

        entry_span.trace("Provided size: {}", .{record.provided_size});
        try writer.writeInt(u32, record.provided_size, .little);

        // Encode refinement stats
        entry_span.trace("Refinement count: {}", .{record.refinement_count});
        try writer.writeInt(u32, record.refinement_count, .little);

        entry_span.trace("Refinement gas used: {}", .{record.refinement_gas_used});
        try writer.writeInt(u64, record.refinement_gas_used, .little);

        // Encode I/O stats
        entry_span.trace("Imports: {}", .{record.imports});
        try writer.writeInt(u32, record.imports, .little);

        entry_span.trace("Extrinsic count: {}", .{record.extrinsic_count});
        try writer.writeInt(u32, record.extrinsic_count, .little);

        entry_span.trace("Extrinsic size: {}", .{record.extrinsic_size});
        try writer.writeInt(u32, record.extrinsic_size, .little);

        entry_span.trace("Exports: {}", .{record.exports});
        try writer.writeInt(u32, record.exports, .little);

        // Encode accumulation stats
        entry_span.trace("Accumulate count: {}", .{record.accumulate_count});
        try writer.writeInt(u32, record.accumulate_count, .little);

        entry_span.trace("Accumulate gas used: {}", .{record.accumulate_gas_used});
        try writer.writeInt(u64, record.accumulate_gas_used, .little);

        // Encode transfer stats
        entry_span.trace("On transfers count: {}", .{record.on_transfers_count});
        try writer.writeInt(u32, record.on_transfers_count, .little);

        entry_span.trace("On transfers gas used: {}", .{record.on_transfers_gas_used});
        try writer.writeInt(u64, record.on_transfers_gas_used, .little);
    }

    span.debug("Successfully encoded all service stats", .{});
}
