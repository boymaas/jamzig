const std = @import("std");

const types = @import("../types.zig");

const encoder = @import("../codec/encoder.zig");
const codec = @import("../codec.zig");

const authorization_queue = @import("../authorizer_queue.zig");
const Phi = authorization_queue.Phi;

const trace = @import("../tracing.zig").scoped(.codec);

const H = 32;

pub fn encode(self: anytype, writer: anytype) !void {
    const span = trace.span(.encode);
    defer span.deinit();
    span.debug("Starting phi encoding", .{});

    // Simply write all queue data in order
    // Data is already in the correct format: C * Q hashes
    span.debug("Encoding {d} authorization slots", .{self.queue_data.len});
    for (self.queue_data) |hash| {
        try writer.writeAll(&hash);
    }
    
    span.debug("Successfully completed phi encoding", .{});
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

    try auth_queue.setAuthorization(0, 0, test_hash1);
    try auth_queue.setAuthorization(1, 0, test_hash2);

    var buf: [C * Q * H]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try encode(&auth_queue, fbs.writer());

    // Check the first core's first hash
    try testing.expectEqualSlices(u8, &test_hash1, buf[0..H]);

    // Check the second core's first hash
    try testing.expectEqualSlices(u8, &test_hash2, buf[Q * H .. Q * H + H]);

    // Check that other slots in first core are zeroed
    for (buf[H .. Q * H]) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
    
    // Check that other slots in second core are zeroed (except first)
    for (buf[Q * H + H .. 2 * Q * H]) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }

    // Check that all other cores are completely zero
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
