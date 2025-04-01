const std = @import("std");
const types = @import("../types.zig");
const encoder = @import("../codec/encoder.zig");
const codec = @import("../codec.zig");

const trace = @import("../tracing.zig").scoped(.pi_encoding);

const validator_statistics = @import("../validator_stats.zig");
const Pi = validator_statistics.Pi;
const ValidatorIndex = types.ValidatorIndex;
const ValidatorStats = validator_statistics.ValidatorStats;
const CoreActivityRecord = validator_statistics.CoreActivityRecord;
const ServiceActivityRecord = validator_statistics.ServiceActivityRecord;

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
    service_span.debug("Encoding service stats for {} services", .{self.service_stats.count()});
    try encodeServiceStats(self.service_stats, writer);

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

    // // First encode the number of cores
    // try codec.writeInteger(stats.len, writer);

    for (stats, 0..) |entry, i| {
        const entry_span = span.child(.core_entry);
        defer entry_span.deinit();
        entry_span.debug("Encoding stats for core {}", .{i});

        entry_span.trace("Gas used: {}", .{entry.gas_used});
        try codec.writeInteger(entry.gas_used, writer);

        entry_span.trace("Imports: {}", .{entry.imports});
        try codec.writeInteger(entry.imports, writer);

        entry_span.trace("Extrinsic count: {}", .{entry.extrinsic_count});
        try codec.writeInteger(entry.extrinsic_count, writer);

        entry_span.trace("Extrinsic size: {}", .{entry.extrinsic_size});
        try codec.writeInteger(entry.extrinsic_size, writer);

        entry_span.trace("Exports: {}", .{entry.exports});
        try codec.writeInteger(entry.exports, writer);

        entry_span.trace("Bundle size: {}", .{entry.bundle_size});
        try codec.writeInteger(entry.bundle_size, writer);

        entry_span.trace("DA load: {}", .{entry.da_load});
        try codec.writeInteger(entry.da_load, writer);

        entry_span.trace("Popularity: {}", .{entry.popularity});
        try codec.writeInteger(entry.popularity, writer);
    }

    span.debug("Successfully encoded all core stats", .{});
}

fn encodeServiceStats(stats: std.AutoHashMap(types.ServiceId, ServiceActivityRecord), writer: anytype) !void {
    const span = trace.span(.encode_service_stats);
    defer span.deinit();
    span.debug("Encoding service stats for {} services", .{stats.count()});

    // First encode the number of services
    try codec.writeInteger(stats.count(), writer);

    // Capture all service ids, and reserve capacity to avoid reallocations
    var service_ids = try std.ArrayList(types.ServiceId).initCapacity(stats.allocator, stats.count());
    defer service_ids.deinit();

    var iterator = stats.keyIterator();
    while (iterator.next()) |key_ptr| {
        try service_ids.append(key_ptr.*);
    }
    std.sort.block(types.ServiceId, service_ids.items, {}, comptime std.sort.asc(types.ServiceId));

    for (service_ids.items, 0..) |service_id, entry_index| {
        const record = stats.get(service_id).?;
        const entry_span = span.child(.service_entry);
        defer entry_span.deinit();
        entry_span.debug("Encoding stats for service {} (ID: {})", .{ entry_index, service_id });

        // Encode service ID
        entry_span.trace("Service ID: {}", .{service_id});
        // TODO: check this against the graypaper
        try codec.writeInteger(service_id, writer);
        // try writer.writeInt(u32, service_id, .little);

        // Encode preimage stats
        entry_span.trace("Provided count: {}", .{record.provided_count});
        try codec.writeInteger(record.provided_count, writer);
        entry_span.trace("Provided size: {}", .{record.provided_size});
        try codec.writeInteger(record.provided_size, writer);

        // Encode refinement stats
        entry_span.trace("Refinement count: {}", .{record.refinement_count});
        try codec.writeInteger(record.refinement_count, writer);
        entry_span.trace("Refinement gas used: {}", .{record.refinement_gas_used});
        try codec.writeInteger(record.refinement_gas_used, writer);

        // Encode I/O stats
        // FIXME: fix ordering back to @davxy ordering after merge
        // of: https://github.com/jam-duna/jamtestnet/issues/181
        entry_span.trace("Imports: {}", .{record.imports});
        try codec.writeInteger(record.imports, writer);
        entry_span.trace("Exports: {}", .{record.exports});
        try codec.writeInteger(record.exports, writer);
        entry_span.trace("Extrinsic size: {}", .{record.extrinsic_size});
        try codec.writeInteger(record.extrinsic_size, writer);
        entry_span.trace("Extrinsic count: {}", .{record.extrinsic_count});
        try codec.writeInteger(record.extrinsic_count, writer);

        // Encode accumulation stats
        entry_span.trace("Accumulate count: {}", .{record.accumulate_count});
        try codec.writeInteger(record.accumulate_count, writer);
        entry_span.trace("Accumulate gas used: {}", .{record.accumulate_gas_used});
        try codec.writeInteger(record.accumulate_gas_used, writer);

        // Encode transfer stats
        entry_span.trace("On transfers count: {}", .{record.on_transfers_count});
        try codec.writeInteger(record.on_transfers_count, writer);
        entry_span.trace("On transfers gas used: {}", .{record.on_transfers_gas_used});
        try codec.writeInteger(record.on_transfers_gas_used, writer);
    }

    span.debug("Successfully encoded all service stats in sorted order", .{});
}
