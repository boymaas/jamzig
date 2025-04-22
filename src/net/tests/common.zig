const std = @import("std");
const testing = std.testing;
const net_server = @import("../server.zig");
const net_client = @import("../client.zig");
const network = @import("network");

pub const TestServer = struct {
    thread: *net_server.ServerThread,
    server: net_server.Server,
    thread_handle: std.Thread,

    /// Wait for a specific event type from the server with a timeout
    pub fn expectEvent(
        self: *TestServer,
        timeout_ms: u64,
        event_type: std.meta.FieldEnum(net_server.Server.Event),
    ) !net_server.Server.Event {
        const maybe_event = self.server.timedWaitEvent(timeout_ms);
        if (maybe_event) |event| {
            if (@as(std.meta.FieldEnum(net_server.Server.Event), event) != event_type) {
                std.debug.print("Expected event type {}, but got {}\n", .{ event_type, event });
                return error.InvalidEventType;
            }
            std.debug.print("Received expected event: {}\n", .{event});
            return event;
        } else {
            return error.Timeout;
        }
    }

    pub fn enableDetailedLogging(self: *TestServer) void {
        self.thread.server.enableSslCtxLogging();
    }

    pub fn join(self: *TestServer) void {
        // Ensure shutdown is called before joining the thread
        self.server.shutdown() catch |err| {
            std.log.err("Error shutting down server: {s}", .{@errorName(err)});
        };
        self.thread_handle.join();
    }

    pub fn deinit(self: *TestServer) void {
        self.thread.deinit();
    }

    pub fn joinAndDeinit(self: *TestServer) void {
        self.join();
        self.deinit();
    }
};

/// Helper function to create and initialize the server
pub fn createTestServer(allocator: std.mem.Allocator) !TestServer {
    const keypair = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic([_]u8{0} ** 32);
    const genesis_hash = "test_genesis_hash";

    // -- Create server using builder
    var server_thread_builder = net_server.ServerThreadBuilder.init();
    var server_thread = server_thread_builder
        .allocator(allocator)
        .keypair(keypair)
        .genesisHash(genesis_hash)
        .allowBuilders(false)
        .build() catch |err| {
        std.log.err("Failed to build server thread: {s}", .{@errorName(err)});
        return err;
    };

    // -- Start the server thread
    const thread_handle = server_thread.startThread() catch |err| {
        std.log.err("Failed to start server thread: {s}", .{@errorName(err)});
        server_thread.deinit();
        return err;
    };

    // -- Create the Server API handle
    const server = try net_server.Server.init(allocator, server_thread);

    return .{
        .thread = server_thread,
        .server = server,
        .thread_handle = thread_handle,
    };
}

pub const TestClient = struct {
    thread: *net_client.ClientThread,
    client: net_client.Client,
    thread_handle: std.Thread,

    /// Wait for a specific event type from the client with a timeout
    pub fn expectEvent(
        self: *TestClient,
        timeout_ms: u64,
        event_type: std.meta.FieldEnum(net_client.Client.Event),
    ) !net_client.Client.Event {
        const maybe_event = self.client.timedWaitEvent(timeout_ms);
        if (maybe_event) |event| {
            if (@as(std.meta.FieldEnum(net_client.Client.Event), event) != event_type) {
                std.debug.print("Expected client event type {}, but got {}\n", .{ event_type, event });
                return error.InvalidEventType;
            }
            std.debug.print("Received expected client event: {}\n", .{event});
            return event;
        } else {
            return error.Timeout;
        }
    }

    pub fn enableDetailedLogging(self: *TestClient) void {
        self.thread.client.enableSslCtxLogging();
    }

    pub fn join(self: *TestClient) void {
        // Ensure shutdown is called before joining the thread
        self.client.shutdown() catch |err| {
            std.log.err("Error shutting down client: {s}", .{@errorName(err)});
        };
        self.thread_handle.join();
    }

    pub fn deinit(self: *TestClient) void {
        self.thread.deinit();
    }

    pub fn joinAndDeinit(self: *TestClient) void {
        self.join();
        self.deinit();
    }
};

/// Helper function to create and initialize the client
pub fn createTestClient(allocator: std.mem.Allocator) !TestClient {
    const keypair = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic([_]u8{1} ** 32);
    const genesis_hash = "test_genesis_hash"; // Same as server for test communication

    // -- Create client using builder
    var client_thread_builder = net_client.ClientThreadBuilder.init();
    var client_thread = client_thread_builder
        .allocator(allocator)
        .keypair(keypair)
        .genesisHash(genesis_hash)
        .isBuilder(false)
        .build() catch |err| {
        std.log.err("Failed to build client thread: {s}", .{@errorName(err)});
        return err;
    };

    // -- Start the client thread
    const thread_handle = client_thread.startThread() catch |err| {
        std.log.err("Failed to start client thread: {s}", .{@errorName(err)});
        client_thread.deinit();
        return err;
    };

    // -- Create the Client API handle
    const client = net_client.Client.init(client_thread);

    return .{
        .thread = client_thread,
        .client = client,
        .thread_handle = thread_handle,
    };
}
