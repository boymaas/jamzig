const std = @import("std");
const testing = std.testing;
const net = std.net;

const jam_params = @import("../../jam_params.zig");

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

    var fuzzer_instance = try fuzzer_mod.createSocketFuzzer(FUZZ_PARAMS, allocator, seed, socket_path);
    defer fuzzer_instance.destroy();
}

test "fuzzer_embedded_target_cycle" {
    const span = trace.span(@src(), .fuzzer_embedded_cycle_test);
    defer span.deinit();

    const allocator = testing.allocator;
    const seed: u64 = 67890;

    var executor = try io.SequentialExecutor.init(allocator);
    defer executor.deinit();

    var fuzzer_instance = try fuzzer_mod.createEmbeddedFuzzer(FUZZ_PARAMS, &executor, allocator, seed);
    defer fuzzer_instance.destroy();

    try fuzzer_instance.connectToTarget();

    try fuzzer_instance.performHandshake();

    var provider = try @import("../providers/providers.zig").SequoiaProvider(
        io.SequentialExecutor,
        FUZZ_PARAMS,
    ).init(
        &executor,
        allocator,
        .{ .seed = 42, .num_blocks = 3 },
    );
    defer provider.deinit();

    var result = try provider.run(EmbeddedFuzzer, fuzzer_instance, null);
    defer result.deinit(allocator);
}
