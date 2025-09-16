const std = @import("std");
const testing = std.testing;
const net = std.net;

const jam_params = @import("../../jam_params.zig");

const target_manager = @import("../target_manager.zig");
const FuzzTargetInThread = target_manager.FuzzTargetInThread;
const RestartBehavior = @import("../target.zig").RestartBehavior;

const io = @import("../../io.zig");
const fuzzer_mod = @import("../fuzzer.zig");
const socket_target = @import("../socket_target.zig");
const embedded_target = @import("../embedded_target.zig");
const messages = @import("../messages.zig");
const report = @import("../report.zig");

const SocketFuzzer = fuzzer_mod.Fuzzer(io.SequentialExecutor, socket_target.SocketTarget, FUZZ_PARAMS);
const EmbeddedFuzzer = fuzzer_mod.Fuzzer(io.SequentialExecutor, embedded_target.EmbeddedTarget(io.SequentialExecutor, FUZZ_PARAMS), FUZZ_PARAMS);

const trace = @import("tracing").scoped(.fuzz_protocol);

const FUZZ_PARAMS = jam_params.TINY_PARAMS;

test "fuzzer_initialization" {
    const span = trace.span(@src(), .test_fuzzer_init);
    defer span.deinit();

    const allocator = testing.allocator;
    const socket_path = "/tmp/test_fuzzer_init.sock";
    const seed: u64 = 12345;

    var executor = try io.SequentialExecutor.init(allocator);

    var fuzzer_instance = try fuzzer_mod.createSocketFuzzer(FUZZ_PARAMS, &executor, allocator, seed, socket_path);
    defer fuzzer_instance.destroy();

    // Verify initialization
    // try testing.expectEqual(seed, fuzzer.seed);
    // try testing.expectEqualStrings(socket_path, fuzzer.socket_path);
    // try testing.expectEqual(@as(?net.Stream, null), fuzzer.socket);
}

test "fuzzer_socket_target_cycle" {
    const span = trace.span(@src(), .fuzzer_socket_cycle_test);
    defer span.deinit();

    const allocator = testing.allocator;
    const socket_path = "/tmp/test_fuzzer_cycle.sock";
    const seed: u64 = 54321;

    // Start the target server in the background
    // Create executor for the target manager
    var executor = try io.SequentialExecutor.init(allocator);
    defer executor.deinit();

    var target_mgr = FuzzTargetInThread(io.SequentialExecutor, FUZZ_PARAMS).init(&executor, allocator, socket_path, .exit_on_disconnect);
    defer target_mgr.join();

    // Start the fuzz target
    try target_mgr.start();

    var fuzzer_instance = try fuzzer_mod.createSocketFuzzer(FUZZ_PARAMS, &executor, allocator, seed, socket_path);
    defer fuzzer_instance.destroy();

    // std.time.sleep(std.time.ns_per_s * 1); // Give some time for the target to start

    try fuzzer_instance.connectToTarget();
    try fuzzer_instance.performHandshake();

    // Run a short fuzzing cycle (this is an integration test with background target)
    var result = try fuzzer_instance.runFuzzCycle(3);
    defer result.deinit(allocator);

    // This will also stop the target manager
    fuzzer_instance.endSession();

    // Verify results
    // try testing.expectEqual(@as(usize, 3), result.blocks_processed);

    // For now, we expect success since we're testing against our own target
    // In a real conformance test, there might be mismatches
    // span.debug("Fuzz cycle completed. Success: {}", .{result.isSuccess()});
}

test "fuzzer_embedded_target_cycle" {
    const span = trace.span(@src(), .fuzzer_embedded_cycle_test);
    defer span.deinit();

    const allocator = testing.allocator;
    const seed: u64 = 67890;

    // Create executor for embedded target
    var executor = try io.SequentialExecutor.init(allocator);
    defer executor.deinit();

    // Create embedded fuzzer (no socket, no background thread needed)
    var fuzzer_instance = try fuzzer_mod.createEmbeddedFuzzer(FUZZ_PARAMS, &executor, allocator, seed);
    defer fuzzer_instance.destroy();

    // Connect to embedded target (sets state to .connected)
    try fuzzer_instance.connectToTarget();

    // Perform handshake (sets state to .handshake_complete)
    try fuzzer_instance.performHandshake();

    // Run a short fuzzing cycle
    var result = try fuzzer_instance.runFuzzCycle(3);
    defer result.deinit(allocator);

    // Verify results - embedded target should work correctly
    try testing.expectEqual(@as(usize, 3), result.blocks_processed);
    try testing.expect(result.success);

    span.debug("Embedded fuzz cycle completed successfully with {d} blocks", .{result.blocks_processed});
}
