const std = @import("std");
const testing = std.testing;
const messages = @import("../messages.zig");
const version = @import("../version.zig");

test "v1_protocol_features" {
    const allocator = testing.allocator;

    // Test v1 PeerInfo with features
    const peer_info = messages.PeerInfo{
        .fuzz_version = version.FUZZ_PROTOCOL_VERSION,
        .fuzz_features = messages.FEATURE_ANCESTRY | messages.FEATURE_FORK,
        .jam_version = version.PROTOCOL_VERSION,
        .app_version = version.FUZZ_TARGET_VERSION,
        .app_name = "v1-test-peer",
    };

    const peer_message = messages.Message{ .peer_info = peer_info };

    // Encode and decode PeerInfo
    const encoded = try messages.encodeMessage(allocator, peer_message);
    defer allocator.free(encoded);

    var decoded = try messages.decodeMessage(allocator, encoded);
    defer decoded.deinit(allocator);

    // Verify v1 fields
    switch (decoded) {
        .peer_info => |decoded_peer| {
            try testing.expectEqual(@as(u8, 1), decoded_peer.fuzz_version);
            try testing.expectEqual(messages.FEATURE_ANCESTRY | messages.FEATURE_FORK, decoded_peer.fuzz_features);
            try testing.expectEqualStrings("v1-test-peer", decoded_peer.app_name);
        },
        else => try testing.expect(false),
    }
}

test "v1_initialize_message" {
    const allocator = testing.allocator;

    // Create test ancestry
    const ancestry_items = [_]messages.AncestryItem{
        .{ .slot = 100, .header_hash = [_]u8{0x01} ** 32 },
        .{ .slot = 101, .header_hash = [_]u8{0x02} ** 32 },
    };

    // Create Initialize message
    const initialize = messages.Initialize{
        .header = .{
            .parent = [_]u8{0x00} ** 32,
            .parent_state_root = [_]u8{0x11} ** 32,
            .extrinsic_hash = [_]u8{0x22} ** 32,
            .slot = 102,
            .epoch_mark = null,
            .tickets_mark = null,
            .author_index = 0,
            .entropy_source = [_]u8{0x33} ** 96,
            .offenders_mark = &[_][32]u8{},
            .seal = [_]u8{0x44} ** 96,
        },
        .keyvals = messages.State{ .items = &[_]messages.KeyValue{} },
        .ancestry = messages.Ancestry{ .items = &ancestry_items },
    };

    const init_message = messages.Message{ .initialize = initialize };

    // Encode and decode
    const encoded = try messages.encodeMessage(allocator, init_message);
    defer allocator.free(encoded);

    var decoded = try messages.decodeMessage(allocator, encoded);
    defer decoded.deinit(allocator);

    // Verify Initialize message
    switch (decoded) {
        .initialize => |decoded_init| {
            try testing.expectEqual(@as(u32, 102), decoded_init.header.slot);
            try testing.expectEqual(@as(usize, 2), decoded_init.ancestry.items.len);
            try testing.expectEqual(@as(u32, 100), decoded_init.ancestry.items[0].slot);
            try testing.expectEqualSlices(u8, &[_]u8{0x01} ** 32, &decoded_init.ancestry.items[0].header_hash);
        },
        else => try testing.expect(false),
    }
}

test "v1_error_message" {
    const allocator = testing.allocator;

    // Test Error message
    const error_msg = try allocator.dupe(u8, "Test error message");
    var error_message = messages.Message{ .@"error" = error_msg };
    defer error_message.deinit(allocator);

    // Encode and decode
    const encoded = try messages.encodeMessage(allocator, error_message);
    defer allocator.free(encoded);

    var decoded = try messages.decodeMessage(allocator, encoded);
    defer decoded.deinit(allocator);

    // Verify Error message
    switch (decoded) {
        .@"error" => |decoded_error| {
            try testing.expectEqualStrings("Test error message", decoded_error);
        },
        else => try testing.expect(false),
    }
}

test "v1_discriminants" {
    const allocator = testing.allocator;

    // Test peer_info discriminant (should be 0)
    const peer_info = messages.Message{ .peer_info = .{
        .fuzz_version = 1,
        .fuzz_features = 0,
        .jam_version = .{ .major = 0, .minor = 7, .patch = 0 },
        .app_version = .{ .major = 0, .minor = 1, .patch = 0 },
        .app_name = "test",
    } };

    const encoded = try messages.encodeMessage(allocator, peer_info);
    defer allocator.free(encoded);

    // First byte should be the discriminant (0 for peer_info)
    try testing.expectEqual(@as(u8, 0), encoded[0]);

    // Test state_root discriminant (should be 2)
    const state_root = messages.Message{ .state_root = [_]u8{0x00} ** 32 };
    const encoded2 = try messages.encodeMessage(allocator, state_root);
    defer allocator.free(encoded2);

    // First byte should be the discriminant (2 for state_root)
    try testing.expectEqual(@as(u8, 2), encoded2[0]);
}

test "feature_negotiation" {
    // Test feature intersection logic
    const fuzzer_features = messages.FEATURE_ANCESTRY | messages.FEATURE_FORK;
    const target_features = messages.FEATURE_ANCESTRY; // Target only supports ancestry

    const negotiated = fuzzer_features & target_features;

    try testing.expectEqual(messages.FEATURE_ANCESTRY, negotiated);
    try testing.expectEqual(@as(u32, 0), negotiated & messages.FEATURE_FORK);
}
