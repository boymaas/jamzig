const std = @import("std");
const types = @import("../types.zig");
const encoder = @import("../codec/encoder.zig");
const codec = @import("../codec.zig");

const validator_statistics = @import("../validator_stats.zig");
const Pi = validator_statistics.Pi;
const ValidatorIndex = types.ValidatorIndex;
const ValidatorStats = validator_statistics.ValidatorStats;

pub fn encode(self: *const Pi, writer: anytype) !void {
    // Encode current epoch stats
    try encodeEpochStats(self.current_epoch_stats.items, writer);
    // Encode previous epoch stats
    try encodeEpochStats(self.previous_epoch_stats.items, writer);
}

fn encodeEpochStats(stats: []ValidatorStats, writer: anytype) !void {
    for (stats) |entry| {
        try writer.writeInt(u32, entry.blocks_produced, .little); // b: Number of blocks produced
        try writer.writeInt(u32, entry.tickets_introduced, .little); // t: Number of validator tickets introduced
        try writer.writeInt(u32, entry.preimages_introduced, .little); // p: Number of preimages introduced
        try writer.writeInt(u32, entry.octets_across_preimages, .little); // d: Total number of octets across preimages
        try writer.writeInt(u32, entry.reports_guaranteed, .little); // g: Number of reports guaranteed
        try writer.writeInt(u32, entry.availability_assurances, .little); // a: Number of availability assurances
    }
}

//  _____         _   _
// |_   _|__  ___| |_(_)_ __   __ _
//   | |/ _ \/ __| __| | '_ \ / _` |
//   | |  __/\__ \ |_| | | | | (_| |
//   |_|\___||___/\__|_|_| |_|\__, |
//                            |___/

const testing = std.testing;
const mem = std.mem;

test "encode" {
    const allocator = std.testing.allocator;
    var pi = try Pi.init(allocator, 6);
    defer pi.deinit();

    pi.current_epoch_stats.items[0].blocks_produced = 10;
    pi.current_epoch_stats.items[0].tickets_introduced = 5;
    pi.current_epoch_stats.items[0].preimages_introduced = 3;
    pi.current_epoch_stats.items[0].octets_across_preimages = 1000;
    pi.current_epoch_stats.items[0].reports_guaranteed = 2;
    pi.current_epoch_stats.items[0].availability_assurances = 1;

    pi.current_epoch_stats.items[1].blocks_produced = 8;
    pi.current_epoch_stats.items[1].tickets_introduced = 4;
    pi.current_epoch_stats.items[1].preimages_introduced = 2;
    pi.current_epoch_stats.items[1].octets_across_preimages = 800;
    pi.current_epoch_stats.items[1].reports_guaranteed = 1;
    pi.current_epoch_stats.items[1].availability_assurances = 0;

    // Previous epoch stats (empty for this test)

    var buffer: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try encode(&pi, fbs.writer());

    const expected = [_]u8{
        10, 0, 0, 0, // blocks (validator 0)
        5, 0, 0, 0, // tickets
        3, 0, 0, 0, // preimages
        232, 3, 0, 0, // data (1000 in little endian)
        2, 0, 0, 0, // guarantees
        1, 0, 0, 0, // assurances
        8, 0, 0, 0, // blocks (validator 1)
        4, 0, 0, 0, // tickets
        2, 0, 0, 0, // preimages
        32, 3, 0, 0, // data (800 in little endian)
        1, 0, 0, 0, // guarantees
        0, 0, 0, 0, // assurances
    };

    const written = fbs.getWritten();
    try testing.expectEqualSlices(u8, &expected, written[0..expected.len]);

    // Check that the rest of the written memory is all zeros
    for (written[expected.len..]) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
}
