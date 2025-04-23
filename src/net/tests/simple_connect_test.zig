const std = @import("std");
const testing = std.testing;
const net_server = @import("../server.zig");
const net_client = @import("../client.zig");
const network = @import("network");
const common = @import("common.zig");
const lsquic = @import("lsquic");

test "server creation and listen" {
    // @import("logging.zig").enableDetailedLsquicLogging();

    const allocator = std.testing.allocator;
    const timeout_ms: u64 = 10_000; // 5 second timeout

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

    // Simple connect test completed
    std.log.info("Server connect test completed successfully.", .{});

    // Defer will shutdown the server and client and free resources
}
