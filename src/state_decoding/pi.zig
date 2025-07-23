const std = @import("std");
const testing = std.testing;
const validator_statistics = @import("../validator_stats.zig");
const codec = @import("../codec.zig");
const state_decoding = @import("../state_decoding.zig");
const DecodingError = state_decoding.DecodingError;
const DecodingContext = state_decoding.DecodingContext;

const Pi = validator_statistics.Pi;

const ValidatorStats = validator_statistics.ValidatorStats;
const CoreActivityRecord = validator_statistics.CoreActivityRecord;
const ServiceActivityRecord = validator_statistics.ServiceActivityRecord;
const ValidatorIndex = @import("../types.zig").ValidatorIndex;
const ServiceId = @import("../types.zig").ServiceId;

const trace = @import("../tracing.zig").scoped(.pi_decoding);

pub const DecoderParams = struct {
    validators_count: u32,
    core_count: u32,

    pub fn fromJamParams(comptime params: anytype) DecoderParams {
        return .{
            .validators_count = params.validators_count,
            .core_count = params.core_count,
        };
    }
};

pub fn decode(
    comptime params: DecoderParams,
    allocator: std.mem.Allocator,
    context: *DecodingContext,
    reader: anytype,
) !Pi {
    try context.push(.{ .component = "pi" });
    defer context.pop();

    var pi = try Pi.init(allocator, params.validators_count, params.core_count);
    errdefer pi.deinit();

    try context.push(.{ .field = "current_epoch_stats" });
    try decodeEpochStats(params.validators_count, context, reader, &pi.current_epoch_stats);
    context.pop();

    try context.push(.{ .field = "previous_epoch_stats" });
    try decodeEpochStats(params.validators_count, context, reader, &pi.previous_epoch_stats);
    context.pop();

    try context.push(.{ .field = "core_stats" });
    try decodeCoreStats(params.core_count, context, reader, &pi.core_stats);
    context.pop();

    try context.push(.{ .field = "service_stats" });
    try decodeServiceStats(context, reader, &pi.service_stats);
    context.pop();

    return pi;
}

// Runtime version for when parameters aren't known at compile time
pub fn decodeRuntime(
    allocator: std.mem.Allocator,
    context: *DecodingContext,
    validators_count: u32,
    core_count: u32,
    reader: anytype,
) !Pi {
    const params = DecoderParams{
        .validators_count = validators_count,
        .core_count = core_count,
    };
    return decode(params, allocator, context, reader);
}

fn decodeEpochStats(validators_count: u32, context: *DecodingContext, reader: anytype, stats: *std.ArrayList(ValidatorStats)) !void {
    // We are building our core stats from scratch
    stats.clearRetainingCapacity();

    for (0..validators_count) |i| {
        try context.push(.{ .array_index = i });

        const blocks_produced = reader.readInt(u32, .little) catch |err| {
            return context.makeError(error.EndOfStream, "failed to read blocks_produced: {s}", .{@errorName(err)});
        };
        const tickets_introduced = reader.readInt(u32, .little) catch |err| {
            return context.makeError(error.EndOfStream, "failed to read tickets_introduced: {s}", .{@errorName(err)});
        };
        const preimages_introduced = reader.readInt(u32, .little) catch |err| {
            return context.makeError(error.EndOfStream, "failed to read preimages_introduced: {s}", .{@errorName(err)});
        };
        const octets_across_preimages = reader.readInt(u32, .little) catch |err| {
            return context.makeError(error.EndOfStream, "failed to read octets_across_preimages: {s}", .{@errorName(err)});
        };
        const reports_guaranteed = reader.readInt(u32, .little) catch |err| {
            return context.makeError(error.EndOfStream, "failed to read reports_guaranteed: {s}", .{@errorName(err)});
        };
        const availability_assurances = reader.readInt(u32, .little) catch |err| {
            return context.makeError(error.EndOfStream, "failed to read availability_assurances: {s}", .{@errorName(err)});
        };

        stats.append(ValidatorStats{
            .blocks_produced = blocks_produced,
            .tickets_introduced = tickets_introduced,
            .preimages_introduced = preimages_introduced,
            .octets_across_preimages = octets_across_preimages,
            .reports_guaranteed = reports_guaranteed,
            .availability_assurances = availability_assurances,
        }) catch |err| {
            return context.makeError(error.OutOfMemory, "failed to append validator stats: {s}", .{@errorName(err)});
        };

        context.pop();
    }
}

fn decodeCoreStats(core_count: u32, context: *DecodingContext, reader: anytype, stats: *std.ArrayList(CoreActivityRecord)) !void {
    // We are building our core stats from scratch
    stats.clearRetainingCapacity();

    for (0..core_count) |i| {
        try context.push(.{ .array_index = i });

        const record = CoreActivityRecord.decode(.{}, reader, .{}) catch |err| {
            return context.makeError(error.EndOfStream, "failed to decode core activity record: {s}", .{@errorName(err)});
        };

        stats.append(record) catch |err| {
            return context.makeError(error.OutOfMemory, "failed to append core stats: {s}", .{@errorName(err)});
        };

        context.pop();
    }
}

fn decodeServiceStats(context: *DecodingContext, reader: anytype, stats: *std.AutoHashMap(ServiceId, ServiceActivityRecord)) !void {
    const service_count = @as(u32, @truncate(codec.readInteger(reader) catch |err| {
        return context.makeError(error.EndOfStream, "failed to read service count: {s}", .{@errorName(err)});
    }));

    for (0..service_count) |i| {
        try context.push(.{ .array_index = i });

        // TODO: check this against the graypaper
        // const service_id = @as(u32, @truncate(try codec.readInteger(reader)));
        const service_id = reader.readInt(u32, .little) catch |err| {
            return context.makeError(error.EndOfStream, "failed to read service id: {s}", .{@errorName(err)});
        };

        const provided_count = @as(u16, @truncate(codec.readInteger(reader) catch |err| {
            return context.makeError(error.EndOfStream, "failed to read provided_count: {s}", .{@errorName(err)});
        }));
        const provided_size = @as(u32, @truncate(codec.readInteger(reader) catch |err| {
            return context.makeError(error.EndOfStream, "failed to read provided_size: {s}", .{@errorName(err)});
        }));

        const refinement_count = @as(u32, @truncate(codec.readInteger(reader) catch |err| {
            return context.makeError(error.EndOfStream, "failed to read refinement_count: {s}", .{@errorName(err)});
        }));
        const refinement_gas_used = codec.readInteger(reader) catch |err| {
            return context.makeError(error.EndOfStream, "failed to read refinement_gas_used: {s}", .{@errorName(err)});
        };

        // FIXME: fix ordering back to @davxy ordering after merge
        // of: https://github.com/jam-duna/jamtestnet/issues/181
        const imports = @as(u32, @truncate(codec.readInteger(reader) catch |err| {
            return context.makeError(error.EndOfStream, "failed to read imports: {s}", .{@errorName(err)});
        }));
        const exports = @as(u32, @truncate(codec.readInteger(reader) catch |err| {
            return context.makeError(error.EndOfStream, "failed to read exports: {s}", .{@errorName(err)});
        }));
        const extrinsic_size = @as(u32, @truncate(codec.readInteger(reader) catch |err| {
            return context.makeError(error.EndOfStream, "failed to read extrinsic_size: {s}", .{@errorName(err)});
        }));
        const extrinsic_count = @as(u32, @truncate(codec.readInteger(reader) catch |err| {
            return context.makeError(error.EndOfStream, "failed to read extrinsic_count: {s}", .{@errorName(err)});
        }));

        const accumulate_count = @as(u32, @truncate(codec.readInteger(reader) catch |err| {
            return context.makeError(error.EndOfStream, "failed to read accumulate_count: {s}", .{@errorName(err)});
        }));
        const accumulate_gas_used = codec.readInteger(reader) catch |err| {
            return context.makeError(error.EndOfStream, "failed to read accumulate_gas_used: {s}", .{@errorName(err)});
        };

        const on_transfers_count = @as(u32, @truncate(codec.readInteger(reader) catch |err| {
            return context.makeError(error.EndOfStream, "failed to read on_transfers_count: {s}", .{@errorName(err)});
        }));
        const on_transfers_gas_used = codec.readInteger(reader) catch |err| {
            return context.makeError(error.EndOfStream, "failed to read on_transfers_gas_used: {s}", .{@errorName(err)});
        };

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

        stats.put(service_id, record) catch |err| {
            return context.makeError(error.OutOfMemory, "failed to insert service stats: {s}", .{@errorName(err)});
        };

        context.pop();
    }
}
