const std = @import("std");
const testing = std.testing;
const authorization_queue = @import("../authorizer_queue.zig");
const Phi = authorization_queue.Phi;

const H = 32; // Hash size (32)

const trace = @import("../tracing.zig").scoped(.state_decoding);

pub fn decode(
    comptime core_count: u16,
    comptime authorization_queue_length: u8,
    allocator: std.mem.Allocator,
    reader: anytype,
) !Phi(core_count, authorization_queue_length) {
    const span = trace.span(.decode);
    defer span.deinit();

    span.debug("starting phi state decoding for {d} cores with queue length {d}", .{ core_count, authorization_queue_length });

    var phi = try Phi(core_count, authorization_queue_length).init(allocator);
    errdefer phi.deinit();

    span.debug("initialized phi state with {d} total slots", .{phi.queue_data.len});

    // Read all authorization data directly into queue_data
    for (phi.queue_data) |*slot| {
        try reader.readNoEof(slot);
    }

    span.info("completed decoding phi state", .{});

    return phi;
}

test "decode phi - empty queues" {
    const allocator = testing.allocator;
    const core_count: u16 = 2;
    const Q = 80;

    // Create buffer with all zero hashes
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    // Write zero hashes for both cores
    const zero_hash = [_]u8{0} ** H;
    var i: usize = 0;
    while (i < core_count * Q) : (i += 1) {
        try buffer.appendSlice(&zero_hash);
    }

    var fbs = std.io.fixedBufferStream(buffer.items);
    var phi = try decode(core_count, Q, allocator, fbs.reader());
    defer phi.deinit();

    // Verify all slots are empty (zero)
    for (0..core_count) |core| {
        for (0..Q) |index| {
            try testing.expect(phi.isEmptySlot(core, index));
        }
    }
}

test "decode phi - with authorizations" {
    const allocator = testing.allocator;
    const core_count: u16 = 2;
    const Q = 80;

    // Create test data
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    // Core 0: First hash non-zero, rest zero
    const auth1 = [_]u8{1} ** H;
    try buffer.appendSlice(&auth1);

    // Fill rest of Core 0's queue with zeros
    var i: usize = 1;
    while (i < Q) : (i += 1) {
        try buffer.appendSlice(&[_]u8{0} ** H);
    }

    // Core 1: First two hashes non-zero, rest zero
    const auth2 = [_]u8{2} ** H;
    const auth3 = [_]u8{3} ** H;
    try buffer.appendSlice(&auth2);
    try buffer.appendSlice(&auth3);

    // Fill rest of Core 1's queue with zeros
    i = 2;
    while (i < Q) : (i += 1) {
        try buffer.appendSlice(&[_]u8{0} ** H);
    }

    var fbs = std.io.fixedBufferStream(buffer.items);
    var phi = try decode(core_count, Q, allocator, fbs.reader());
    defer phi.deinit();

    // Verify Core 0
    try testing.expectEqualSlices(u8, &auth1, &phi.getAuthorization(0, 0));
    for (1..Q) |index| {
        try testing.expect(phi.isEmptySlot(0, index));
    }

    // Verify Core 1
    try testing.expectEqualSlices(u8, &auth2, &phi.getAuthorization(1, 0));
    try testing.expectEqualSlices(u8, &auth3, &phi.getAuthorization(1, 1));
    for (2..Q) |index| {
        try testing.expect(phi.isEmptySlot(1, index));
    }
}

test "decode phi - insufficient data" {
    const allocator = testing.allocator;
    const core_count: u16 = 2;

    const Q = 80;

    // Create buffer with incomplete data
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    // Write less data than required
    try buffer.appendSlice(&[_]u8{1} ** (H * Q + H / 2));

    var fbs = std.io.fixedBufferStream(buffer.items);
    try testing.expectError(error.EndOfStream, decode(core_count, Q, allocator, fbs.reader()));
}

test "decode phi - roundtrip" {
    const allocator = testing.allocator;
    const encoder = @import("../state_encoding/phi.zig");
    const core_count: u16 = 2;
    const Q = 80;

    // Create original phi state
    var original = try Phi(core_count, Q).init(allocator);
    defer original.deinit();

    // Set authorizations at various positions
    const auth1 = [_]u8{1} ** H;
    const auth2 = [_]u8{2} ** H;
    try original.setAuthorization(0, 0, auth1);
    try original.setAuthorization(1, 5, auth2);

    // Encode
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    try encoder.encode(&original, buffer.writer());

    // Decode
    var fbs = std.io.fixedBufferStream(buffer.items);
    var decoded = try decode(core_count, Q, allocator, fbs.reader());
    defer decoded.deinit();

    // Verify all slots match
    for (0..core_count) |core| {
        for (0..Q) |index| {
            const orig_hash = original.getAuthorization(core, index);
            const dec_hash = decoded.getAuthorization(core, index);
            try testing.expectEqualSlices(u8, &orig_hash, &dec_hash);
        }
    }
}
