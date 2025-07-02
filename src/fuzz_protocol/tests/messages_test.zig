const std = @import("std");
const testing = std.testing;
const messages = @import("../messages.zig");

test "message encoding and decoding" {
    const allocator = testing.allocator;

    // Test PeerInfo message
    const peer_info = messages.PeerInfo{
        .name = "test-peer",
        .version = .{ .major = 0, .minor = 1, .patch = 0 },
        .protocol_version = .{ .major = 0, .minor = 6, .patch = 6 },
    };

    const message = messages.Message{ .peer_info = peer_info };

    // Encode message
    const encoded = try messages.encodeMessage(allocator, message);
    defer allocator.free(encoded);

    // Verify length prefix exists
    try testing.expect(encoded.len >= 4);

    // Decode message
    var decoded = try messages.decodeMessage(allocator, encoded);
    defer decoded.deinit();

    // Verify decoded message matches original
    switch (decoded.value) {
        .peer_info => |decoded_peer_info| {
            try testing.expectEqualStrings(peer_info.name, decoded_peer_info.name);
            try testing.expectEqual(peer_info.version.major, decoded_peer_info.version.major);
            try testing.expectEqual(peer_info.version.minor, decoded_peer_info.version.minor);
            try testing.expectEqual(peer_info.version.patch, decoded_peer_info.version.patch);
            try testing.expectEqual(peer_info.protocol_version.major, decoded_peer_info.protocol_version.major);
            try testing.expectEqual(peer_info.protocol_version.minor, decoded_peer_info.protocol_version.minor);
            try testing.expectEqual(peer_info.protocol_version.patch, decoded_peer_info.protocol_version.patch);
        },
        else => try testing.expect(false), // Should be peer_info
    }
}

test "state root message" {
    const allocator = testing.allocator;

    const state_root: messages.StateRootHash = [_]u8{0x12} ** 32;
    const message = messages.Message{ .state_root = state_root };

    // Encode and decode
    const encoded = try messages.encodeMessage(allocator, message);
    defer allocator.free(encoded);

    var decoded = try messages.decodeMessage(allocator, encoded);
    defer decoded.deinit();

    // Verify decoded message
    switch (decoded.value) {
        .state_root => |decoded_root| {
            try testing.expectEqualSlices(u8, &state_root, &decoded_root);
        },
        else => try testing.expect(false),
    }
}

test "key-value state message" {
    const allocator = testing.allocator;

    const kv1 = messages.KeyValue{
        .key = [_]u8{0x01} ** 31,
        .value = "test_value_1",
    };
    const kv2 = messages.KeyValue{
        .key = [_]u8{0x02} ** 31,
        .value = "test_value_2",
    };

    const state = [_]messages.KeyValue{ kv1, kv2 };
    const message = messages.Message{ .state = &state };

    // Encode and decode
    const encoded = try messages.encodeMessage(allocator, message);
    defer allocator.free(encoded);

    var decoded = try messages.decodeMessage(allocator, encoded);
    defer decoded.deinit();

    // Verify decoded message
    switch (decoded.value) {
        .state => |decoded_state| {
            try testing.expectEqual(@as(usize, 2), decoded_state.len);
            try testing.expectEqualSlices(u8, &kv1.key, &decoded_state[0].key);
            try testing.expectEqualStrings(kv1.value, decoded_state[0].value);
            try testing.expectEqualSlices(u8, &kv2.key, &decoded_state[1].key);
            try testing.expectEqualStrings(kv2.value, decoded_state[1].value);
        },
        else => try testing.expect(false),
    }
}

