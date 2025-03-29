const std = @import("std");
const testing = std.testing;
const validator_statistics = @import("../validator_stats.zig");
const codec = @import("../codec.zig");

const Pi = validator_statistics.Pi;

const ValidatorStats = validator_statistics.ValidatorStats;
const CoreActivityRecord = validator_statistics.CoreActivityRecord;
const ServiceActivityRecord = validator_statistics.ServiceActivityRecord;
const ValidatorIndex = @import("../types.zig").ValidatorIndex;
const ServiceId = @import("../types.zig").ServiceId;

const trace = @import("../tracing.zig").scoped(.pi_decoding);

pub fn decode(validators_count: u32, core_count: u32, reader: anytype, allocator: std.mem.Allocator) !Pi {
    const span = trace.span(.decode);
    defer span.deinit();
    span.debug("Starting Pi decoding - validators: {d}, cores: {d}", .{ validators_count, core_count });

    var pi = try Pi.init(allocator, validators_count, core_count);
    errdefer {
        span.debug("Error during decoding, cleaning up Pi structure", .{});
        pi.deinit();
    }

    span.debug("Decoding current epoch stats", .{});
    try decodeEpochStats(validators_count, reader, &pi.current_epoch_stats);

    span.debug("Decoding previous epoch stats", .{});
    try decodeEpochStats(validators_count, reader, &pi.previous_epoch_stats);

    span.debug("Decoding core stats", .{});
    try decodeCoreStats(core_count, reader, &pi.core_stats);

    span.debug("Decoding service stats", .{});
    try decodeServiceStats(reader, &pi.service_stats);

    span.debug("Successfully decoded Pi structure", .{});
    return pi;
}

fn decodeEpochStats(validators_count: u32, reader: anytype, stats: *std.ArrayList(ValidatorStats)) !void {
    const span = trace.span(.decode_epoch_stats);
    defer span.deinit();
    span.debug("Decoding stats for {d} validators", .{validators_count});

    // We are building our core stats from scratch
    stats.clearRetainingCapacity();

    for (0..validators_count) |i| {
        const validator_span = span.child(.validator);
        defer validator_span.deinit();
        validator_span.debug("Decoding validator {d}/{d}", .{ i + 1, validators_count });

        const blocks_produced = try reader.readInt(u32, .little);
        const tickets_introduced = try reader.readInt(u32, .little);
        const preimages_introduced = try reader.readInt(u32, .little);
        const octets_across_preimages = try reader.readInt(u32, .little);
        const reports_guaranteed = try reader.readInt(u32, .little);
        const availability_assurances = try reader.readInt(u32, .little);

        validator_span.trace("Stats: blocks={d}, tickets={d}, preimages={d}, octets={d}, reports={d}, assurances={d}", .{
            blocks_produced,
            tickets_introduced,
            preimages_introduced,
            octets_across_preimages,
            reports_guaranteed,
            availability_assurances,
        });

        try stats.append(ValidatorStats{
            .blocks_produced = blocks_produced,
            .tickets_introduced = tickets_introduced,
            .preimages_introduced = preimages_introduced,
            .octets_across_preimages = octets_across_preimages,
            .reports_guaranteed = reports_guaranteed,
            .availability_assurances = availability_assurances,
        });
    }

    span.debug("Successfully decoded stats for {d} validators", .{validators_count});
}

fn decodeCoreStats(core_count: u32, reader: anytype, stats: *std.ArrayList(CoreActivityRecord)) !void {
    const span = trace.span(.decode_core_stats);
    defer span.deinit();
    span.debug("Decoding stats for {d} cores", .{core_count});

    // We are building our core stats from scratch
    stats.clearRetainingCapacity();

    for (0..core_count) |i| {
        const core_span = span.child(.core);
        defer core_span.deinit();
        core_span.debug("Decoding core {d}/{d}", .{ i + 1, core_count });

        const gas_used = try codec.readInteger(reader);
        const imports = @as(u16, @truncate(try codec.readInteger(reader)));
        const extrinsic_count = @as(u16, @truncate(try codec.readInteger(reader)));
        const extrinsic_size = @as(u32, @truncate(try codec.readInteger(reader)));
        const exports = @as(u16, @truncate(try codec.readInteger(reader)));
        const bundle_size = @as(u32, @truncate(try codec.readInteger(reader)));
        const da_load = @as(u32, @truncate(try codec.readInteger(reader)));
        const popularity = @as(u16, @truncate(try codec.readInteger(reader)));

        core_span.trace("Core activity: gas_used={d}, imports={d}, extrinsics={d}({d} bytes), exports={d}, bundle={d}, da_load={d}, popularity={d}", .{
            gas_used,
            imports,
            extrinsic_count,
            extrinsic_size,
            exports,
            bundle_size,
            da_load,
            popularity,
        });

        try stats.append(CoreActivityRecord{
            .gas_used = gas_used,
            .imports = imports,
            .extrinsic_count = extrinsic_count,
            .extrinsic_size = extrinsic_size,
            .exports = exports,
            .bundle_size = bundle_size,
            .da_load = da_load,
            .popularity = popularity,
        });
    }

    span.debug("Successfully decoded stats for {d} cores", .{core_count});
}

fn decodeServiceStats(reader: anytype, stats: *std.AutoHashMap(ServiceId, ServiceActivityRecord)) !void {
    const span = trace.span(.decode_service_stats);
    defer span.deinit();

    const service_count = @as(u32, @truncate(try codec.readInteger(reader)));
    span.debug("Decoding stats for {d} services", .{service_count});

    for (0..service_count) |i| {
        const service_span = span.child(.service);
        defer service_span.deinit();

        // TODO: check this against the graypaper
        // const service_id = @as(u32, @truncate(try codec.readInteger(reader)));
        const service_id = try reader.readInt(u32, .little);
        service_span.debug("Decoding service {d}/{d} (ID: {d})", .{ i + 1, service_count, service_id });

        const provided_count = @as(u16, @truncate(try codec.readInteger(reader)));
        const provided_size = @as(u32, @truncate(try codec.readInteger(reader)));

        const refinement_count = @as(u32, @truncate(try codec.readInteger(reader)));
        const refinement_gas_used = try codec.readInteger(reader);

        const imports = @as(u32, @truncate(try codec.readInteger(reader)));
        const extrinsic_count = @as(u32, @truncate(try codec.readInteger(reader)));
        const extrinsic_size = @as(u32, @truncate(try codec.readInteger(reader)));
        const exports = @as(u32, @truncate(try codec.readInteger(reader)));

        const accumulate_count = @as(u32, @truncate(try codec.readInteger(reader)));
        const accumulate_gas_used = try codec.readInteger(reader);

        const on_transfers_count = @as(u32, @truncate(try codec.readInteger(reader)));
        const on_transfers_gas_used = try codec.readInteger(reader);

        service_span.trace("Service data: provided={d} items ({d} bytes), refinements={d} (gas={d})", .{ provided_count, provided_size, refinement_count, refinement_gas_used });

        service_span.trace("Service activity: imports={d}, extrinsics={d} ({d} bytes), exports={d}", .{ imports, extrinsic_count, extrinsic_size, exports });

        service_span.trace("Service operations: accumulate={d} (gas={d}), transfers={d} (gas={d})", .{ accumulate_count, accumulate_gas_used, on_transfers_count, on_transfers_gas_used });

        const record = ServiceActivityRecord{
            .provided_count = provided_count,
            .provided_size = provided_size,
            .refinement_count = refinement_count,
            .refinement_gas_used = refinement_gas_used,
            .imports = imports,
            .extrinsic_count = extrinsic_count,
            .extrinsic_size = extrinsic_size,
            .exports = exports,
            .accumulate_count = accumulate_count,
            .accumulate_gas_used = accumulate_gas_used,
            .on_transfers_count = on_transfers_count,
            .on_transfers_gas_used = on_transfers_gas_used,
        };

        try stats.put(service_id, record);
    }

    span.debug("Successfully decoded stats for {d} services", .{service_count});
}
