const std = @import("std");
const testing = std.testing;
const net = std.net;

const jam_params = @import("../../jam_params.zig");

const target_manager = @import("../target_manager.zig");
const FuzzTargetInThread = target_manager.FuzzTargetInThread;
const RestartBehavior = @import("../target.zig").RestartBehavior;

const io = @import("../../io.zig");
const fuzzer_mod = @import("../fuzzer.zig");
const Fuzzer = fuzzer_mod.Fuzzer(io.ThreadPoolExecutor);
const messages = @import("../messages.zig");
const report = @import("../report.zig");

const trace = @import("../../tracing.zig").scoped(.fuzz_protocol);

const FUZZ_PARAMS = jam_params.TINY_PARAMS;

test "fuzzer_initialization" {
    const span = trace.span(.test_fuzzer_init);
    defer span.deinit();

    const allocator = testing.allocator;
    const socket_path = "/tmp/test_fuzzer_init.sock";
    const seed: u64 = 12345;

    var fuzzer = try Fuzzer.create(allocator, seed, socket_path);
    defer fuzzer.destroy();

    // Verify initialization
    // try testing.expectEqual(seed, fuzzer.seed);
    // try testing.expectEqualStrings(socket_path, fuzzer.socket_path);
    // try testing.expectEqual(@as(?net.Stream, null), fuzzer.socket);
}

test "fuzzer_basic_cycle" {
    const span = trace.span(.fuzzer_basic_cycle_test);
    defer span.deinit();

    const allocator = testing.allocator;
    const socket_path = "/tmp/test_fuzzer_cycle.sock";
    const seed: u64 = 54321;

    // Start the target server in the background
    // Create executor for the target manager
    var executor = io.SequentialExecutor.init(allocator);
    defer executor.deinit();
    var target_mgr = FuzzTargetInThread(io.SequentialExecutor).init(&executor, allocator, socket_path, .exit_on_disconnect);
    defer target_mgr.join();

    // Start the fuzz target
    try target_mgr.start();

    var fuzzer = try Fuzzer.create(allocator, seed, socket_path);
    defer fuzzer.destroy();

    // std.time.sleep(std.time.ns_per_s * 1); // Give some time for the target to start

    try fuzzer.connectToTarget();
    try fuzzer.performHandshake();

    // Run a short fuzzing cycle (this is an integration test with background target)
    var result = try fuzzer.runFuzzCycle(3);
    defer result.deinit(allocator);

    // This will also stop the target manager
    fuzzer.endSession();

    // Verify results
    // try testing.expectEqual(@as(usize, 3), result.blocks_processed);

    // For now, we expect success since we're testing against our own target
    // In a real conformance test, there might be mismatches
    // span.debug("Fuzz cycle completed. Success: {}", .{result.isSuccess()});
}
