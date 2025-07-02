const std = @import("std");
const testing = std.testing;
const FuzzTargetServerInThread = @import("../target_manager.zig").FuzzTargetInThread;

const trace = @import("../../tracing.zig").scoped(.fuzz_protocol);

test "target_manager_initialization" {
    const span = trace.span(.test_target_manager_init);
    defer span.deinit();

    const allocator = testing.allocator;
    const socket_path = "/tmp/test_target_manager_init.sock";

    var manager = FuzzTargetServerInThread.init(allocator, socket_path);
    defer manager.join();

    // Verify initialization
    try testing.expectEqualStrings(socket_path, manager.socket_path);
    try testing.expectEqual(@as(?std.Thread, null), manager.target_thread);
    try testing.expectEqual(false, manager.isRunning());

    span.debug("Target manager initialization test passed", .{});
}
