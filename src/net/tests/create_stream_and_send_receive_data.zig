const std = @import("std");
const testing = std.testing;
const net_server = @import("../server.zig");
const net_client = @import("../client.zig");
const network = @import("network");
const common = @import("common.zig");
const lsquic = @import("lsquic");

const StreamHandle = @import("../stream_handle.zig").StreamHandle;
const StreamKind = @import("../jamsnp/shared_types.zig").StreamKind;
const shared = @import("../jamsnp/shared_types.zig");

test "create stream and send message" {
    // The test allocator is thread safe by default
    const allocator = std.testing.allocator;
    const timeout_ms: u64 = 4_000;

    // -- Build our server
    var test_server = try common.createTestServer(allocator);
    defer test_server.shutdownJoinAndDeinit();

    // Start listening on a port
    const listen_address = "::1"; // Use IPv6 loopback
    const listen_port: u16 = 0; // Use port 0 to get an ephemeral port assigned by the OS
    try test_server.server.listen(listen_address, listen_port);

    // Expect a listening event, indicating the server is ready to accept connections
    const listening_event = test_server.expectEvent(timeout_ms, .listening) catch |err| {
        std.log.err("Failed to receive listen event: {s}", .{@errorName(err)});
        return err;
    };

    // Get the server's bound endpoint from the listening event
    const server_endpoint = listening_event.listening.local_endpoint;
    std.log.info("Server is listening on {}", .{server_endpoint});

    // -- Connect with our client
    var test_client = try common.createTestClient(allocator);
    defer test_client.shutdownJoinAndDeinit();

    // Connect client to server
    try test_client.client.connect(server_endpoint);

    // Wait for connection event on client
    const connected_event = try test_client.expectEvent(timeout_ms, .connected);
    std.log.info("Client connected with connection ID: {}", .{connected_event.connected.connection_id});

    // Wait for the incoming connection event on the server
    const server_connection_event = try test_server.expectEvent(timeout_ms, .client_connected);
    std.log.info("Server received connection with ID: {}", .{server_connection_event.client_connected.connection_id});

    // --- Create a stream from client to server ---
    try test_client.client.createStream(connected_event.connected.connection_id, .block_announcement);

    // Wait for the stream_created event on the client
    const client_stream_created_event = try test_client.expectEvent(timeout_ms, .stream_created);
    const stream_id = client_stream_created_event.stream_created.stream_id;
    // // FIXME: since I am sending the stream kind its generating an event which should be ignored
    // _ = try test_client.expectEvent(timeout_ms, .data_write_completed);
    std.log.info("Client created stream with ID: {}", .{stream_id});

    // Wait for the stream creation event on the server side
    const server_stream_created_event = try test_server.expectEvent(timeout_ms, .stream_created);
    std.log.info("Server stream creation initiated by client with ID: {}", .{server_stream_created_event.stream_created.stream_id});

    // --- Send message over the stream ---
    var client_stream_handle = try test_client.buildStreamHandle(
        connected_event.connected.connection_id,
        stream_id,
    );

    // Create a server stream handle for responses
    var server_stream_handle = try test_server.buildStreamHandle(
        server_stream_created_event.stream_created.connection_id,
        server_stream_created_event.stream_created.stream_id,
    );

    // Create a test message
    const message_content = "JamZig⚡";
    try client_stream_handle.sendMessage(message_content);
    // Wait for the client to complete the sending of the message
    _ = try test_client.expectEvent(timeout_ms, .message_send);

    // Wait for the server to receive the message, ownership of the buffer
    // is with us. So handle freeing it in event or in the callback
    var server_message_rcv_event = try test_server.expectEvent(timeout_ms, .message_received);
    defer server_message_rcv_event.deinit(allocator); // free buffer passed to us
    std.log.info("Server received message with length({}): '{s}'", .{ server_message_rcv_event.message_received.message.len, server_message_rcv_event.message_received.message });

    // Verify message contents
    try testing.expect(std.mem.eql(u8, message_content, server_message_rcv_event.message_received.message));
    std.log.info("Client->Server message verified: '{s}'", .{message_content});

    // --- Send a response message from server to client ---
    std.log.info("Server sending response message", .{});
    const response_content = "Rocks🪨";
    try server_stream_handle.sendMessage(response_content);
    // Wait for the server to complete the sending of the message
    _ = try test_server.expectEvent(timeout_ms, .message_send);
    std.log.info("Server sent message with length({}): '{s}'", .{ response_content.len, response_content });

    // Important, otherwise we are not reading anything
    try client_stream_handle.wantRead(true);
    var client_message_rcv_event = try test_client.expectEvent(timeout_ms, .message_received);
    defer client_message_rcv_event.deinit(allocator); // free buffer passed to us
    std.log.info("Server received message with length({}): '{s}'", .{ client_message_rcv_event.message_received.message.len, client_message_rcv_event.message_received.message });

    try testing.expect(std.mem.eql(u8, response_content, client_message_rcv_event.message_received.message));
    std.log.info("Server->Client message verified: '{s}'", .{response_content});

    // Test complete - success!
    std.log.info("Message-based communication verified successfully", .{});
}
