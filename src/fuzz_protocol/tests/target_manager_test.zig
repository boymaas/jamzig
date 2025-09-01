const std = @import("std");
const testing = std.testing;
const io = @import("../../io.zig");
const target_manager = @import("../target_manager.zig");
const FuzzTargetServerInThread = target_manager.FuzzTargetInThread(io.SequentialExecutor);
const RestartBehavior = @import("../target.zig").RestartBehavior;

const trace = @import("../../tracing.zig").scoped(.fuzz_protocol);

test "target_manager_initialization" {
    const span = trace.span(.test_target_manager_init);
    defer span.deinit();

    const allocator = testing.allocator;
    const socket_path = "/tmp/test_target_manager_init.sock";

    // Create executor for the target manager
    var executor = io.SequentialExecutor.init(allocator);
    defer executor.deinit();
    var manager = FuzzTargetServerInThread.init(&executor, allocator, socket_path, .exit_on_disconnect);
    defer manager.join();

    // Verify initialization
    try testing.expectEqualStrings(socket_path, manager.socket_path);
    try testing.expectEqual(@as(?std.Thread, null), manager.target_thread);
    try testing.expectEqual(false, manager.isRunning());

    span.debug("Target manager initialization test passed", .{});
}
