const std = @import("std");

const types = @import("../types.zig");

const encoder = @import("../codec/encoder.zig");
const codec = @import("../codec.zig");

const authorization_queue = @import("../authorization_queue.zig");
const Phi = authorization_queue.Phi;

const H = 32;

pub fn encode(self: anytype, writer: anytype) !void {
    // The number of cores (C) is a constant no need to encode it
    // Encode each queue
    for (self.queue) |core_queue| {
        // The length of the queue is not encoded as it is a Constants
        // Encode each hash in the queue
        for (core_queue.items) |hash| {
            try writer.writeAll(&hash);
        }
        // Write 0 hashes to fill the queue until 80
        const zero_hashes_to_write = self.max_authorizations_queue_items - core_queue.items.len;
        const zero_hash = [_]u8{0} ** H;
        var i: usize = 0;
        while (i < zero_hashes_to_write) : (i += 1) {
            try writer.writeAll(&zero_hash);
        }
    }
}

//  _____         _   _
// |_   _|__  ___| |_(_)_ __   __ _
//   | |/ _ \/ __| __| | '_ \ / _` |
//   | |  __/\__ \ |_| | | | | (_| |
//   |_|\___||___/\__|_|_| |_|\__, |
//                            |___/

const testing = std.testing;

test "encode" {
    const C = 4;
    const Q = 80;
    var auth_queue = try Phi(C, Q).init(testing.allocator);
    defer auth_queue.deinit();

    const test_hash1 = [_]u8{1} ** H;
    const test_hash2 = [_]u8{2} ** H;

    try auth_queue.addAuthorization(0, test_hash1);
    try auth_queue.addAuthorization(1, test_hash2);

    var buf: [C * Q * H]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try encode(&auth_queue, fbs.writer());

    // Check the first core's hash
    try testing.expectEqualSlices(u8, &test_hash1, buf[0..H]);

    // Check the second core's hash
    try testing.expectEqualSlices(u8, &test_hash2, buf[Q * H .. Q * H + H]);

    // Check that the rest is zeroed
    for (buf[H .. Q * H]) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
    for (buf[Q * H + H ..]) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }

    // Check that all other entries in the map are zero
    for (2..C) |core| {
        const start = core * Q * H;
        const end = start + Q * H;
        for (buf[start..end]) |byte| {
            try testing.expectEqual(@as(u8, 0), byte);
        }
    }

    // Check the total size matches
    try testing.expectEqual(@as(usize, C * Q * H), buf.len);
}
