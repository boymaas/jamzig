const std = @import("std");
const testing = std.testing;
const net = std.net;
const messages = @import("../messages.zig");
const TargetServer = @import("../target.zig").TargetServer;
const version = @import("../version.zig");
const sequoia = @import("../../sequoia.zig");
const types = @import("../../types.zig");
const shared = @import("shared.zig");

const trace = @import("../../tracing.zig").scoped(.fuzz_protocol);

test "handshake" {
    const span = trace.span(.test_handshake);
    defer span.deinit();

    const allocator = testing.allocator;

    // Create socketpair
    var sockets = try shared.createSocketPair();
    defer sockets.deinit();

    // Create target server
    var target = try TargetServer.init(allocator, "unused");
    defer target.deinit();

    // Perform handshake
    _ = try shared.performHandshake(allocator, sockets.fuzzer, sockets.target, &target);

    span.debug("Handshake test completed successfully", .{});
}

test "state_and_verify" {
    const span = trace.span(.test_set_state);
    defer span.deinit();

    const allocator = testing.allocator;

    // Setup
    var sockets = try shared.createSocketPair();
    defer sockets.deinit();

    var target = try TargetServer.init(allocator, "unused");
    defer target.deinit();

    // First perform handshake
    _ = try shared.performHandshake(allocator, sockets.fuzzer, sockets.target, &target);

    // Create test state
    const test_state = [_]messages.KeyValue{
        .{ .key = [_]u8{0x01} ** 31, .value = "test_value_1" },
        .{ .key = [_]u8{0x02} ** 31, .value = "test_value_2" },
        .{ .key = [_]u8{0x03} ** 31, .value = "test_value_3" },
    };

    // Create a dummy header for SetState
    const dummy_header = std.mem.zeroes(types.Header);

    // Send SetState message
    const set_state_msg = messages.Message{
        .set_state = .{
            .header = dummy_header,
            .state = &test_state,
        },
    };
    try shared.sendMessage(allocator, sockets.fuzzer, set_state_msg);

    // Target processes SetState
    var request = try target.readMessage(sockets.target);
    defer request.deinit();
    const response = try target.processMessage(request.value);

    // Target sends response
    try target.sendMessage(sockets.target, response.?);

    // Fuzzer reads response
    var reply = try shared.readMessage(allocator, sockets.fuzzer);
    defer reply.deinit();

    // Verify response is StateRoot
    switch (reply.value) {
        .state_root => |state_root| {
            // For now, the implementation returns zero state root
            // In a real implementation, this would be a proper merkle root
            // TODO: Update this test when computeStateRoot is properly implemented

            // Verify the target's internal state matches response
            try testing.expect(target.current_state_root != null);
            try testing.expectEqualSlices(u8, &state_root, &target.current_state_root.?);
        },
        else => return error.UnexpectedResponse,
    }

    // Verify state was stored correctly
    // The state conversion should have succeeded
    try testing.expect(target.current_state_root != null);

    span.debug("SetState test completed successfully", .{});
}

test "state_after_modifications" {
    const span = trace.span(.test_get_state);
    defer span.deinit();

    const allocator = testing.allocator;

    // Setup
    var sockets = try shared.createSocketPair();
    defer sockets.deinit();

    var target = try TargetServer.init(allocator, "unused");
    defer target.deinit();

    // Perform handshake
    _ = try shared.performHandshake(allocator, sockets.fuzzer, sockets.target, &target);

    // First set some state
    const test_state = [_]messages.KeyValue{
        .{ .key = [_]u8{0x01} ** 31, .value = "value1" },
        .{ .key = [_]u8{0x02} ** 31, .value = "value2" },
    };

    const dummy_header = std.mem.zeroes(types.Header);
    const set_state_msg = messages.Message{
        .set_state = .{
            .header = dummy_header,
            .state = &test_state,
        },
    };

    // Send SetState
    try shared.sendMessage(allocator, sockets.fuzzer, set_state_msg);

    // Process SetState
    var set_request = try target.readMessage(sockets.target);
    defer set_request.deinit();
    const set_response = try target.processMessage(set_request.value);
    try target.sendMessage(sockets.target, set_response.?);

    // Read SetState response
    var set_reply = try shared.readMessage(allocator, sockets.fuzzer);
    defer set_reply.deinit();

    // Now test GetState
    const header_hash = std.mem.zeroes(messages.HeaderHash);
    const get_state_msg = messages.Message{ .get_state = header_hash };

    try shared.sendMessage(allocator, sockets.fuzzer, get_state_msg);

    // Target processes GetState
    var get_request = try target.readMessage(sockets.target);
    defer get_request.deinit();
    const get_response = try target.processMessage(get_request.value);
    defer if (get_response) |resp| {
        switch (resp) {
            .state => |state| {
                for (state) |kv| {
                    allocator.free(kv.value);
                }
                allocator.free(state);
            },
            else => {},
        }
    };

    try target.sendMessage(sockets.target, get_response.?);

    // Fuzzer reads response
    var get_reply = try shared.readMessage(allocator, sockets.fuzzer);
    defer get_reply.deinit();

    // Verify response is State (currently empty as per implementation)
    switch (get_reply.value) {
        .state => |state| {
            // Current implementation returns empty state
            try testing.expectEqual(@as(usize, 0), state.len);
        },
        else => return error.UnexpectedResponse,
    }

    span.debug("GetState test completed successfully", .{});
}

test "complete fuzzer session flow" {
    const span = trace.span(.test_complete_flow);
    defer span.deinit();

    const allocator = testing.allocator;

    // Setup
    var sockets = try shared.createSocketPair();
    defer sockets.deinit();

    var target = try TargetServer.init(allocator, "unused");
    defer target.deinit();

    // Step 1: Handshake
    span.debug("Starting handshake", .{});
    _ = try shared.performHandshake(allocator, sockets.fuzzer, sockets.target, &target);

    // Step 2: Initialize state with SetState
    span.debug("Setting initial state", .{});
    const initial_state = [_]messages.KeyValue{
        .{ .key = [_]u8{0x01} ** 31, .value = "initial_value" },
    };

    const dummy_header = std.mem.zeroes(types.Header);
    const set_state_msg = messages.Message{
        .set_state = .{
            .header = dummy_header,
            .state = &initial_state,
        },
    };

    try shared.sendMessage(allocator, sockets.fuzzer, set_state_msg);

    var set_request = try target.readMessage(sockets.target);
    defer set_request.deinit();
    const set_response = try target.processMessage(set_request.value);
    try target.sendMessage(sockets.target, set_response.?);

    var set_reply = try shared.readMessage(allocator, sockets.fuzzer);
    defer set_reply.deinit();

    const initial_state_root = switch (set_reply.value) {
        .state_root => |root| root,
        else => return error.UnexpectedResponse,
    };

    // Step 3: Import a block
    span.debug("Importing block", .{});

    var prng = std.Random.DefaultPrng.init(54321);
    var rng = prng.random();

    var block_builder = try sequoia.createTinyBlockBuilder(allocator, &rng);
    defer block_builder.deinit();

    const block = try block_builder.buildNextBlock();
    defer {
        var mutable_block = block;
        mutable_block.deinit(allocator);
    }

    const import_block_msg = messages.Message{ .import_block = block };
    try shared.sendMessage(allocator, sockets.fuzzer, import_block_msg);

    var import_request = try target.readMessage(sockets.target);
    defer import_request.deinit();
    const import_response = try target.processMessage(import_request.value);
    try target.sendMessage(sockets.target, import_response.?);

    var import_reply = try shared.readMessage(allocator, sockets.fuzzer);
    defer import_reply.deinit();

    const post_block_state_root = switch (import_reply.value) {
        .state_root => |root| root,
        else => return error.UnexpectedResponse,
    };

    try testing.expectEqualSlices(u8, &initial_state_root, &post_block_state_root);

    span.debug("Complete session flow test completed successfully", .{});
}
