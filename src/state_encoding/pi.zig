const std = @import("std");
const types = @import("../types.zig");
const encoder = @import("../codec/encoder.zig");
const codec = @import("../codec.zig");

const trace = @import("../tracing.zig").scoped(.pi_encoding);

const validator_statistics = @import("../validator_stats.zig");
const Pi = validator_statistics.Pi;
const ValidatorIndex = types.ValidatorIndex;
const ValidatorStats = validator_statistics.ValidatorStats;

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
