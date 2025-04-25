const std = @import("std");
const testing = std.testing;
const net_server = @import("../server.zig");
const net_client = @import("../client.zig");
const network = @import("network");
const common = @import("common.zig");
const lsquic = @import("lsquic");

const StreamHandle = @import("../stream_handle.zig").StreamHandle;
const StreamKind = @import("../jamsnp/shared_types.zig").StreamKind;

test "create stream and send data" {
    // @import("logging.zig").enableDetailedLsquicLogging();

    const allocator = std.testing.allocator;
    const timeout_ms: u64 = 5_000;

    // -- Build our server

    // Create and start server
    var test_server = try common.createTestServer(allocator);
    // test_server.enableDetailedLogging();
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

    // Create and start client
    var test_client = try common.createTestClient(allocator);
    // test_client.enableDetailedLogging();
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
    const client_stream_event = try test_client.expectEvent(timeout_ms, .stream_created);
    const stream_id = client_stream_event.stream_created.stream_id;
    std.log.info("Client created stream with ID: {}", .{stream_id});

    // QUIC server will create the stream on the first STREAM FRAME with Offset 0 received
    // Since the client will send 1 byte indicating the stream kind this will trigger a stream_created_by client
    const server_stream_event = try test_server.expectEvent(timeout_ms, .stream_created_by_client);
    std.log.info("Server observed stream creation with ID: {}", .{server_stream_event.stream_created_by_client.stream_id});

    // --- Send data over the stream ---
    var stream_handle = try test_client.buildStreamHandle(
        connected_event.connected.connection_id,
        stream_id,
    );

    const payload = "Hello, JamSnp!";
    try stream_handle.sendData(payload);

    // Wait for the server to receive the data
    const data_event = try test_server.expectEvent(timeout_ms, .data_received);
    try testing.expectEqual(@as(usize, payload.len), data_event.data_received.data.len);
    try testing.expect(std.mem.eql(u8, payload, data_event.data_received.data));

    std.log.info("Data transfer verified successfully.", .{});

    // Defer will shutdown the server and client and free resources
}
