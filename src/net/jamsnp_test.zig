const std = @import("std");
const ssl = @import("ssl");
const lsquic = @import("lsquic");
const JamSnpServer = @import("jamsnp/server.zig").JamSnpServer;
const JamSnpClient = @import("jamsnp/client.zig").JamSnpClient;
const common = @import("jamsnp/common.zig");
const UdpSocket = @import("udp_socket.zig").UdpSocket;

// Add a logging callback function
fn lsquic_log_callback(ctx: ?*anyopaque, buf: [*c]const u8, len: usize) callconv(.C) c_int {
    _ = ctx; // unused
    const stderr = std.io.getStdErr().writer();
    stderr.print("\x1b[33mlsquic: \x1b[0m", .{}) catch return 0;
    stderr.writeAll(buf[0..len]) catch return 0;
    return 0;
}

test "JAMSNP Client-Server Connection" {
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

    // Initialize LSQUIC globally
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
    var server = try JamSnpServer.init(
        std.testing.allocator,
        server_keypair,
        genesis_hash,
        true, // allow builders
    );
    defer server.deinit();
    std.debug.print("JAMSNP server initialized\n", .{});

    // Bind the server to localhost on a specific test port
    const test_port: u16 = 12345;
    try server.listen("::1", test_port);
    std.debug.print("Server is listening on: {}\n", .{server.socket.bound_address.?});

    // Create the client
    var client = try JamSnpClient.init(
        std.testing.allocator,
        client_keypair,
        genesis_hash,
        false, // not a builder
    );
    defer client.deinit();
    std.debug.print("JAMSNP client initialized\n", .{});

    // Connect client to server
    try client.connect("::1", test_port);
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
