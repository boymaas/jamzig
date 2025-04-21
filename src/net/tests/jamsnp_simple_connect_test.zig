const std = @import("std");
const ssl = @import("ssl");
const lsquic = @import("lsquic");
const jamsnp_server = @import("../jamsnp/server.zig");
const jamsnp_client = @import("../jamsnp/client.zig");
const common = @import("../jamsnp/common.zig");
const network = @import("network");

const JamSnpServer = jamsnp_server.JamSnpServer;
const JamSnpClient = jamsnp_client.JamSnpClient;

// Add a logging callback function

fn lsquic_log_callback(ctx: ?*anyopaque, buf: [*c]const u8, len: usize) callconv(.C) c_int {
    _ = ctx; // unused
    const stderr = std.io.getStdErr().writer();
    stderr.print("\x1b[33mlsquic: \x1b[0m", .{}) catch return 0;
    stderr.writeAll(buf[0..len]) catch return 0;
    return 0;
}

test "connect" {
    // NOTE:  uncomment for detailed logging
    //
    // const logger_if = lsquic.lsquic_logger_if{
    //     .log_buf = lsquic_log_callback,
    // };
    // lsquic.lsquic_logger_init(&logger_if, null, lsquic.LLTS_HHMMSSMS);
    //
    // const res = lsquic.lsquic_set_log_level("info");
    // if (res != 0) {
    //     @panic("could not set lsquic log level");
    // }
    //
    // NOTE: in common you can uncomment this callback for detailed SSL loggin
    // if necessary
    //
    // ssl.SSL_CTX_set_info_callback(ssl_ctx, ssl_info_callback); // Register the callback

    if (lsquic.lsquic_global_init(lsquic.LSQUIC_GLOBAL_SERVER | lsquic.LSQUIC_GLOBAL_CLIENT) != 0) {
        std.debug.print("Failed to initialize LSQUIC globally\n", .{});
        return error.LsquicInitFailed;
    }
    defer lsquic.lsquic_global_cleanup();

    // Generate keypairs for server and client
    const server_keypair = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic([_]u8{0} ** 32);
    const client_keypair = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic([_]u8{1} ** 32);
    std.debug.print("Generated Ed25519 keypairs\n", .{});

    // Dummy genesis hash
    const genesis_hash = "0123456789abcdef"; // 16 bytes, we'll use first 8 in ALPN

    // Create the server
    var server = try JamSnpServer.initWithLoop(
        std.testing.allocator,
        server_keypair,
        genesis_hash,
        true, // allow builders
    );
    defer server.deinit();
    std.debug.print("JAMSNP server initialized\n", .{});

    // Bind the server to localhost on a specific test port
    const test_port: u16 = 12345;

    const local_endpoint = try server.listen("::1", test_port);
    std.debug.print("Server is listening on: {}\n", .{local_endpoint});

    // Create the client
    var client = try JamSnpClient.initWithLoop(
        std.testing.allocator,
        client_keypair,
        genesis_hash,
        false, // not a builder
    );
    defer client.deinit();
    std.debug.print("JAMSNP client initialized\n", .{});

    // Connect client to server
    _ = try client.connectUsingAddressAndPort("::1", test_port);
    std.debug.print("Client initiated connection to server\n", .{});

    // Client
    std.debug.print("Client running..\n", .{});

    // Now tick both server and client some amount of times
    for (0..20) |_| {
        try client.runTick();
        try server.runTick();
        // Short sleep to avoid busy-waiting
        std.time.sleep(100 * std.time.ns_per_ms);
    }

    std.debug.print("Test passed: QUIC connection established between client and server\n", .{});
}

test "client.events" {
    const server_keypair = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic([_]u8{0} ** 32);
    const client_keypair = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic([_]u8{1} ** 32);
    std.debug.print("Generated Ed25519 keypairs\n", .{});

    // Dummy genesis hash
    const genesis_hash = "0123456789abcdef";

    // Create the server
    var server = try JamSnpServer.initWithLoop(
        std.testing.allocator,
        server_keypair,
        genesis_hash,
        false,
    );
    defer server.deinit();
    std.debug.print("JAMSNP server initialized\n", .{});

    const test_port: u16 = 12346; // Using a different port than the other test
    const local_endpoint = try server.listen("::1", test_port);

    std.debug.print("Server is listening on: {}\n", .{local_endpoint});

    var client = try JamSnpClient.initWithLoop(
        std.testing.allocator,
        client_keypair,
        genesis_hash,
        false, // not a builder
    );
    defer client.deinit();

    _ = try client.connectUsingAddressAndPort("::1", test_port);
    std.debug.print("Client initiated connection to server\n", .{});

    std.debug.print("Running client-server communication...\n", .{});

    var i: usize = 0;
    const max_ticks = 20;

    while (i < max_ticks) : (i += 1) {
        try client.runTick();
        try server.runTick();

        std.time.sleep(100 * std.time.ns_per_ms);
    }
}
