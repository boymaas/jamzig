const std = @import("std");
const testing = std.testing;
const xev = @import("xev");

const server = @import("server.zig"); // Import the new server module
const jamsnp_server = @import("jamsnp/server.zig");

const ServerThread = server.ServerThread;
const Server = server.Server;
const JamSnpServer = jamsnp_server.JamSnpServer;

test "initialize and shut down server thread" {
    const allocator = testing.allocator;

    // Create a mock JamSnpServer instance for testing
    var mock_server = try createMockJamSnpServer(allocator);
    errdefer mock_server.deinit();

    // Initialize ServerThread with the mock server
    var thread = try ServerThread.init(
        allocator,
        mock_server,
    );
    defer thread.deinit();

    // Start the server thread
    var handle = try thread.startThread();

    // Initialize the Server API wrapper
    var server_api = try Server.init(allocator, thread);

    // Allow some time for the thread to start up if needed
    std.time.sleep(std.time.ns_per_ms * 500); // 100ms

    // Send shutdown command
    try server_api.shutdown();

    std.time.sleep(std.time.ns_per_ms * 500); // 100ms

    // Wait for the thread to finish
    handle.join();
}

fn createMockJamSnpServer(allocator: std.mem.Allocator) !*JamSnpServer {
    const keypair = try generateDummyKeypair();

    // ASSUMPTION: JamSnpServer needs an initWithoutLoop variant
    return JamSnpServer.initWithoutLoop(
        allocator,
        keypair,
        "dummy_genesis_hash", // Placeholder for actual genesis hash
        false, // allow_builders placeholder
    );
}

fn generateDummyKeypair() !std.crypto.sign.Ed25519.KeyPair {
    return std.crypto.sign.Ed25519.KeyPair.generateDeterministic([_]u8{2} ** 32);
}
