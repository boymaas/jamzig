const std = @import("std");
const testing = std.testing;
const authorization_queue = @import("../authorization_queue.zig");
const Phi = authorization_queue.Phi;

const H = 32; // Hash size (32)

const tracing = @import("../tracing.zig");

const trace = tracing.scoped(.phi_decoder);

pub fn decode(
    comptime core_count: u16,
    comptime max_authorizations_queue_items: u8,
    allocator: std.mem.Allocator,
    reader: anytype,
) !Phi(core_count, max_authorizations_queue_items) {
    const span = trace.span(.decode);
    defer span.deinit();

    span.debug("starting phi state decoding for {d} cores", .{core_count});

    var phi = try Phi(core_count, max_authorizations_queue_items).init(allocator);
    errdefer phi.deinit();

    span.debug("initialized empty phi state", .{});

    // For each core
    for (0..core_count) |core| {
        const core_span = span.child(.process_core);
        defer core_span.deinit();
        core_span.debug("processing core {d}", .{core});

        var i: usize = 0;
        while (i < max_authorizations_queue_items) : (i += 1) {
            var hash: [H]u8 = undefined;
            try reader.readNoEof(&hash);

            // Check if hash is non-zero
            var is_zero = true;
            for (hash) |byte| {
                if (byte != 0) {
                    is_zero = false;
                    break;
                }
            }

            if (is_zero) {
                core_span.trace("skipping zero hash at position {d}", .{i});
            } else {
                core_span.debug("found non-zero hash at position {d}", .{i});
                try phi.addAuthorization(@intCast(core), hash);
            }
        }
        core_span.info("processed {d} hashes for core {d}, found {d} non-zero", .{
            max_authorizations_queue_items,
            core,
            phi.queue[core].items.len,
        });
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

    // Verify empty queues
    for (0..core_count) |core| {
        try testing.expectEqual(@as(usize, 0), phi.queue[core].items.len);
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
    try testing.expectEqual(@as(usize, 1), phi.queue[0].items.len);
    try testing.expectEqualSlices(u8, &auth1, &phi.queue[0].items[0]);

    // Verify Core 1
    try testing.expectEqual(@as(usize, 2), phi.queue[1].items.len);
    try testing.expectEqualSlices(u8, &auth2, &phi.queue[1].items[0]);
    try testing.expectEqualSlices(u8, &auth3, &phi.queue[1].items[1]);
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

    // Add authorizations
    const auth1 = [_]u8{1} ** H;
    const auth2 = [_]u8{2} ** H;
    try original.addAuthorization(0, auth1);
    try original.addAuthorization(1, auth2);

    // Encode
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    try encoder.encode(&original, buffer.writer());

    // Decode
    var fbs = std.io.fixedBufferStream(buffer.items);
    var decoded = try decode(core_count, Q, allocator, fbs.reader());
    defer decoded.deinit();

    // Verify queues
    for (0..core_count) |core| {
        try testing.expectEqual(original.queue[core].items.len, decoded.queue[core].items.len);
        for (original.queue[core].items, decoded.queue[core].items) |orig, dec| {
            try testing.expectEqualSlices(u8, &orig, &dec);
        }
    }
}
