const std = @import("std");
const testing = std.testing;
const validator_statistics = @import("../validator_stats.zig");
const Pi = validator_statistics.Pi;
const ValidatorStats = validator_statistics.ValidatorStats;
const ValidatorIndex = @import("../types.zig").ValidatorIndex;

pub fn decode(reader: anytype, allocator: std.mem.Allocator) !Pi {
    // Initialize Pi with validator count which we'll determine from the data
    var current_epoch_stats = std.ArrayList(ValidatorStats).init(allocator);
    errdefer current_epoch_stats.deinit();

    var previous_epoch_stats = std.ArrayList(ValidatorStats).init(allocator);
    errdefer previous_epoch_stats.deinit();

    // Read current epoch stats
    try decodeEpochStats(reader, &current_epoch_stats);

    // Read previous epoch stats
    try decodeEpochStats(reader, &previous_epoch_stats);

    // Ensure both arrays have same length
    if (current_epoch_stats.items.len != previous_epoch_stats.items.len) {
        return error.InvalidData;
    }

    return Pi{
        .current_epoch_stats = current_epoch_stats,
        .previous_epoch_stats = previous_epoch_stats,
        .allocator = allocator,
        .validator_count = current_epoch_stats.items.len,
    };
}

fn decodeEpochStats(reader: anytype, stats: *std.ArrayList(ValidatorStats)) !void {
    while (true) {
        // Try to read all stats fields
        const blocks_produced = reader.readInt(u32, .little) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        const tickets_introduced = try reader.readInt(u32, .little);
        const preimages_introduced = try reader.readInt(u32, .little);
        const octets_across_preimages = try reader.readInt(u32, .little);
        const reports_guaranteed = try reader.readInt(u32, .little);
        const availability_assurances = try reader.readInt(u32, .little);

        try stats.append(ValidatorStats{
            .blocks_produced = blocks_produced,
            .tickets_introduced = tickets_introduced,
            .preimages_introduced = preimages_introduced,
            .octets_across_preimages = octets_across_preimages,
            .reports_guaranteed = reports_guaranteed,
            .availability_assurances = availability_assurances,
        });
    }
}

test "decode pi - empty state" {
    const allocator = testing.allocator;

    // Create buffer with no stats
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    var fbs = std.io.fixedBufferStream(buffer.items);
    var pi = try decode(fbs.reader(), allocator);
    defer pi.deinit();

    try testing.expectEqual(@as(usize, 0), pi.current_epoch_stats.items.len);
    try testing.expectEqual(@as(usize, 0), pi.previous_epoch_stats.items.len);
}

test "decode pi - with validator stats" {
    const allocator = testing.allocator;

    // Create test data buffer
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    // Write current epoch stats for two validators
    inline for ([_]u32{ 10, 5, 3, 1000, 2, 1 }) |val| {
        try buffer.writer().writeInt(u32, val, .little);
    }
    inline for ([_]u32{ 8, 4, 2, 800, 1, 0 }) |val| {
        try buffer.writer().writeInt(u32, val, .little);
    }

    // Write previous epoch stats for two validators
    inline for ([_]u32{ 9, 4, 2, 900, 1, 0 }) |val| {
        try buffer.writer().writeInt(u32, val, .little);
    }
    inline for ([_]u32{ 7, 3, 1, 700, 0, 0 }) |val| {
        try buffer.writer().writeInt(u32, val, .little);
    }

    var fbs = std.io.fixedBufferStream(buffer.items);
    var pi = try decode(fbs.reader(), allocator);
    defer pi.deinit();

    // Verify stats count
    try testing.expectEqual(@as(usize, 2), pi.current_epoch_stats.items.len);
    try testing.expectEqual(@as(usize, 2), pi.previous_epoch_stats.items.len);

    // Verify current epoch stats for first validator
    const current_stats1 = pi.current_epoch_stats.items[0];
    try testing.expectEqual(@as(u32, 10), current_stats1.blocks_produced);
    try testing.expectEqual(@as(u32, 5), current_stats1.tickets_introduced);
    try testing.expectEqual(@as(u32, 3), current_stats1.preimages_introduced);
    try testing.expectEqual(@as(u32, 1000), current_stats1.octets_across_preimages);
    try testing.expectEqual(@as(u32, 2), current_stats1.reports_guaranteed);
    try testing.expectEqual(@as(u32, 1), current_stats1.availability_assurances);

    // Verify previous epoch stats for second validator
    const previous_stats2 = pi.previous_epoch_stats.items[1];
    try testing.expectEqual(@as(u32, 7), previous_stats2.blocks_produced);
    try testing.expectEqual(@as(u32, 3), previous_stats2.tickets_introduced);
    try testing.expectEqual(@as(u32, 1), previous_stats2.preimages_introduced);
    try testing.expectEqual(@as(u32, 700), previous_stats2.octets_across_preimages);
    try testing.expectEqual(@as(u32, 0), previous_stats2.reports_guaranteed);
    try testing.expectEqual(@as(u32, 0), previous_stats2.availability_assurances);
}

test "decode pi - invalid data" {
    const allocator = testing.allocator;

    // Test truncated stats
    {
        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();

        // Write incomplete stats record
        inline for ([_]u32{ 10, 5, 3 }) |val| {
            try buffer.writer().writeInt(u32, val, .little);
        }

        var fbs = std.io.fixedBufferStream(buffer.items);
        try testing.expectError(error.EndOfStream, decode(fbs.reader(), allocator));
    }

    // Test mismatched epoch stats lengths
    {
        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();

        // Write one current epoch stat
        inline for ([_]u32{ 10, 5, 3, 1000, 2, 1 }) |val| {
            try buffer.writer().writeInt(u32, val, .little);
        }

        // Write two previous epoch stats
        inline for ([_]u32{ 9, 4, 2, 900, 1, 0, 8, 3, 1, 800, 0, 0 }) |val| {
            try buffer.writer().writeInt(u32, val, .little);
        }

        var fbs = std.io.fixedBufferStream(buffer.items);
        try testing.expectError(error.InvalidData, decode(fbs.reader(), allocator));
    }
}

test "decode pi - roundtrip" {
    const allocator = testing.allocator;
    const encoder = @import("../state_encoding/pi.zig");

    // Create original pi state
    var original = try Pi.init(allocator, 2);
    defer original.deinit();

    // Set test stats
    original.current_epoch_stats.items[0] = ValidatorStats{
        .blocks_produced = 10,
        .tickets_introduced = 5,
        .preimages_introduced = 3,
        .octets_across_preimages = 1000,
        .reports_guaranteed = 2,
        .availability_assurances = 1,
    };
    original.previous_epoch_stats.items[1] = ValidatorStats{
        .blocks_produced = 7,
        .tickets_introduced = 3,
        .preimages_introduced = 1,
        .octets_across_preimages = 700,
        .reports_guaranteed = 0,
        .availability_assurances = 0,
    };

    // Encode
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    try encoder.encode(&original, buffer.writer());

    // Decode
    var fbs = std.io.fixedBufferStream(buffer.items);
    var decoded = try decode(fbs.reader(), allocator);
    defer decoded.deinit();

    // Verify stats counts
    try testing.expectEqual(original.validator_count, decoded.validator_count);
    try testing.expectEqual(original.current_epoch_stats.items.len, decoded.current_epoch_stats.items.len);
    try testing.expectEqual(original.previous_epoch_stats.items.len, decoded.previous_epoch_stats.items.len);

    // Verify stats contents
    const orig_curr = original.current_epoch_stats.items[0];
    const dec_curr = decoded.current_epoch_stats.items[0];
    try testing.expectEqual(orig_curr.blocks_produced, dec_curr.blocks_produced);
    try testing.expectEqual(orig_curr.tickets_introduced, dec_curr.tickets_introduced);
    try testing.expectEqual(orig_curr.preimages_introduced, dec_curr.preimages_introduced);
    try testing.expectEqual(orig_curr.octets_across_preimages, dec_curr.octets_across_preimages);
    try testing.expectEqual(orig_curr.reports_guaranteed, dec_curr.reports_guaranteed);
    try testing.expectEqual(orig_curr.availability_assurances, dec_curr.availability_assurances);

    const orig_prev = original.previous_epoch_stats.items[1];
    const dec_prev = decoded.previous_epoch_stats.items[1];
    try testing.expectEqual(orig_prev.blocks_produced, dec_prev.blocks_produced);
    try testing.expectEqual(orig_prev.tickets_introduced, dec_prev.tickets_introduced);
    try testing.expectEqual(orig_prev.preimages_introduced, dec_prev.preimages_introduced);
    try testing.expectEqual(orig_prev.octets_across_preimages, dec_prev.octets_across_preimages);
    try testing.expectEqual(orig_prev.reports_guaranteed, dec_prev.reports_guaranteed);
    try testing.expectEqual(orig_prev.availability_assurances, dec_prev.availability_assurances);
}
