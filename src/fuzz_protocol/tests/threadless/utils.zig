const std = @import("std");
const testing = std.testing;
const net = std.net;
const messages = @import("../../messages.zig");
const frame = @import("../../frame.zig");
const version = @import("../../version.zig");

const TargetServer = @import("../../target.zig").TargetServer;

const trace = @import("../../../tracing.zig").scoped(.fuzz_protocol);

/// Represents a pair of connected sockets for fuzzer protocol testing
pub const SocketPair = struct {
    fuzzer: net.Stream,
    target: net.Stream,

    /// Close both sockets in the pair
    pub fn deinit(self: *SocketPair) void {
        self.fuzzer.close();
        self.target.close();
    }
};

/// Helper to create a Unix socketpair for testing
pub fn createSocketPair() !SocketPair {
    var fds: [2]c_int = undefined;
    const result = std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds);
    if (result != 0) return error.SocketPairFailed;

    return SocketPair{
        .fuzzer = net.Stream{ .handle = fds[0] },
        .target = net.Stream{ .handle = fds[1] },
    };
}

/// Helper to send a message from fuzzer side
pub fn sendMessage(allocator: std.mem.Allocator, socket: net.Stream, message: messages.Message) !void {
    const encoded = try messages.encodeMessage(allocator, message);
    defer allocator.free(encoded);
    try frame.writeFrame(socket, encoded);
}

/// Helper to read a message from fuzzer side
pub fn readMessage(allocator: std.mem.Allocator, socket: net.Stream) !messages.codec.Deserialized(messages.Message) {
    const frame_data = try frame.readFrame(allocator, socket);
    defer allocator.free(frame_data);
    return messages.decodeMessage(allocator, frame_data);
}

/// Helper to perform the protocol handshake
pub fn performHandshake(
    allocator: std.mem.Allocator,
    fuzzer_sock: net.Stream,
    target_sock: net.Stream,
    target: *TargetServer,
) !bool {
    const span = trace.span(.perform_handshake);
    defer span.deinit();

    // Fuzzer sends PeerInfo
    const fuzzer_peer_info = messages.PeerInfo{
        .name = "fuzzer",
        .version = .{ .major = 0, .minor = 1, .patch = 23 },
        .protocol_version = .{ .major = 0, .minor = 6, .patch = 6 },
    };
    try sendMessage(allocator, fuzzer_sock, .{ .peer_info = fuzzer_peer_info });

    // Target reads and processes
    var request = try target.readMessage(target_sock);
    defer request.deinit();
    const response = try target.processMessage(request.value);

    // Target sends response
    try target.sendMessage(target_sock, response.?);

    // Fuzzer reads response
    var reply = try readMessage(allocator, fuzzer_sock);
    defer reply.deinit();

    // Verify response is PeerInfo
    switch (reply.value) {
        .peer_info => |peer_info| {
            try testing.expectEqualStrings(version.TARGET_NAME, peer_info.name);
            try testing.expectEqual(version.FUZZ_TARGET_VERSION.major, peer_info.version.major);
            try testing.expectEqual(version.PROTOCOL_VERSION.major, peer_info.protocol_version.major);
        },
        else => return error.UnexpectedResponse,
    }

    try testing.expect(target.server_state == .handshake_complete or target.server_state == .ready);
    return target.server_state != .initial;
}

