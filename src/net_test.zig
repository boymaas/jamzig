const std = @import("std");
const jamsnp_client = @import("net/jamsnp/client.zig");
const jamsnp_server = @import("net/jamsnp/server.zig");
const jamsnp_common = @import("net/jamsnp/common.zig");
const jamsnp_runner = @import("net/jamsnp/runner.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Sample chain genesis hash
    const chain_genesis_hash = "0123456789abcdef";

    // Generate keypair
    const keypair = try jamsnp_common.Ed25519KeyPair.generate();

    // Example: Run as a server
    if (std.os.argv.len > 1 and std.mem.eql(u8, std.mem.span(std.os.argv[1]), "server")) {
        std.debug.print("Starting JAMSNP server...\n", .{});
        try jamsnp_runner.runServer(allocator, keypair, chain_genesis_hash, "::", // Bind to all interfaces
            4433, // Standard QUIC port
            true // Allow builders
        );
    }
    // Example: Run as a client
    else {
        std.debug.print("Starting JAMSNP client...\n", .{});
        try jamsnp_runner.runClient(allocator, keypair, chain_genesis_hash, "::1", // Connect to localhost
            4433, // Standard QUIC port
            false // Not a builder
        );
    }
}
