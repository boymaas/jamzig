const std = @import("std");
const testing = std.testing;
const xev = @import("xev");

const client = @import("../client.zig");
const jamsnp_client = @import("../jamsnp/client.zig"); // Renamed import
const ClientThread = client.ClientThread;
const Client = client.Client;
const JamSnpClient = jamsnp_client.JamSnpClient;

test "initialize and shut down client thread" {
    const allocator = testing.allocator;

    var mock_client = try createMockJamSnpClient(allocator);
    errdefer mock_client.deinit();

    var thread = try ClientThread.init(allocator, mock_client);
    defer thread.deinit();

    var handle = try thread.startThread();

    std.time.sleep(std.time.ns_per_ms * 100); // 100ms

    var client_api = Client.init(thread);
    try client_api.shutdown();

    handle.join();
}

fn createMockJamSnpClient(allocator: std.mem.Allocator) !*JamSnpClient {
    const keypair = try generateDummyKeypair();

    return JamSnpClient.initWithoutLoop(
        allocator,
        keypair,
        "genesis_hash",
        false, // is_builder
    );
}

fn generateDummyKeypair() !std.crypto.sign.Ed25519.KeyPair {
    return std.crypto.sign.Ed25519.KeyPair.generateDeterministic([_]u8{0} ** 32);
}
