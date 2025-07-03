const std = @import("std");
const testing = std.testing;
const net = std.net;
const messages = @import("../../messages.zig");
const TargetServer = @import("../../target.zig").TargetServer;
const version = @import("../../version.zig");
const sequoia = @import("../../../sequoia.zig");
const types = @import("../../../types.zig");
const shared = @import("utils.zig");

const trace = @import("../../../tracing.zig").scoped(.fuzz_protocol);

test "handshake" {
    const span = trace.span(.test_handshake);
    defer span.deinit();

    const allocator = testing.allocator;

    // Create socketpair
    var sockets = try shared.createSocketPair();
    defer sockets.deinit();

    // Create target server
    var target = try TargetServer.init(allocator, "unused");
    defer target.deinit();

    // Perform handshake
    _ = try shared.performHandshake(allocator, sockets.fuzzer, sockets.target, &target);

    span.debug("Handshake test completed successfully", .{});
}
