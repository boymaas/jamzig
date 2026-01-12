
Removed 22 comments
const std = @import("std");
const clap = @import("clap");
const tracing = @import("tracing");
const build_tuned_allocator = @import("build_tuned_allocator.zig");

const io = @import("io.zig");
const fuzzer_mod = @import("fuzz_protocol/fuzzer.zig");
const socket_target = @import("fuzz_protocol/socket_target.zig");
const report = @import("fuzz_protocol/report.zig");
const block_providers = @import("fuzz_protocol/providers/providers.zig");

const SocketFuzzer = fuzzer_mod.Fuzzer(io.SequentialExecutor, socket_target.SocketTarget, jam_params.TINY_PARAMS);
const jam_params = @import("jam_params.zig");
const jam_params_format = @import("jam_params_format.zig");
const build_options = @import("build_options");
const messages = @import("fuzz_protocol/messages.zig");
const param_formatter = @import("fuzz_protocol/param_formatter.zig");
const trace_config = @import("fuzz_protocol/trace_config.zig");

const trace = @import("tracing").scoped(.jam_conformance_fuzzer);

fn showHelp(params: anytype) !void {
    std.debug.print(
        \\JamZig⚡ Conformance Fuzzer: Protocol conformance testing tool for JAM implementations
        \\
        \\This tool connects to a JAM protocol target server and performs conformance testing according to the JAM fuzz protocol specification by generating deterministic blocks and comparing state transitions.
        \\
        \\
    , .{});
    try clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{ .spacing_between_parameters = 0 });
    std.debug.print(
        \\
        \\Verbose Levels:
        \\  (no -v)    Normal output
        \\  -v         Debug level for key scopes (fuzz_protocol, conformance components)
        \\  -vv        Trace level for key scopes
        \\  -vvv       Debug level for all scopes
        \\  -vvvv      Trace level for all scopes (WARNING: very large output)
        \\  -vvvvv     Trace level with codec debugging (WARNING: extremely large output)
        \\
        \\Examples:
        \\  # Run with debug output for key components
        \\  jam_conformance_fuzzer -v --blocks 100
        \\
        \\  # Run with specific seed and verbose output
        \\  jam_conformance_fuzzer -vv --seed 12345 --blocks 500
        \\
    , .{});
}

pub fn main() !void {
    var alloc = build_tuned_allocator.BuildTunedAllocator.init();
    defer alloc.deinit();
    const allocator = alloc.allocator();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help             Display this help and exit.
        \\-v, --verbose          Enable verbose output (can be repeated up to 5 times)
        \\-s, --socket <str>     Unix socket path to connect to (default: /tmp/jam_conformance.sock)
        \\-S, --seed <u64>       Random seed for deterministic execution (default: timestamp)
        \\-b, --blocks <u32>     Number of blocks to process (default: 100)
        \\-o, --output <str>     Output report file (optional, prints to stdout if not specified)
        \\--dump-params          Dump JAM protocol parameters and exit
        \\--format <str>         Output format for parameter dump: json or text (default: text)
        \\--trace-dir <str>      Directory containing W3F format traces to replay
    );

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        try showHelp(params);
        std.process.exit(1);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try showHelp(params);
        return;
    }

    try trace_config.configureTracing(.{
        .verbose = res.args.verbose,
        .trace_all = null,
        .trace = null,
        .trace_quiet = null,
    });

    const FUZZ_PARAMS = jam_params.TINY_PARAMS;

    if (try param_formatter.handleParamDump(
        FUZZ_PARAMS,
        res.args.@"dump-params" != 0,
        res.args.format,
    )) {
        return;
    }

    const socket_path = res.args.socket orelse "/tmp/jam_conformance.sock";
    const seed = res.args.seed orelse @as(u64, @intCast(std.time.timestamp()));
    const num_blocks = res.args.blocks orelse 100;
    const output_file = res.args.output;
    const trace_dir = res.args.@"trace-dir";

    std.debug.print("JAM Conformance Fuzzer\n", .{});
    std.debug.print("======================\n", .{});
    std.debug.print("Socket path: {s}\n", .{socket_path});
    if (trace_dir) |dir| {
        std.debug.print("Trace directory: {s}\n", .{dir});
        std.debug.print("Trace format: W3F\n", .{});
    } else {
        std.debug.print("Seed: {d}\n", .{seed});
        std.debug.print("Blocks to process: {d}\n", .{num_blocks});
    }
    if (output_file) |f| {
        std.debug.print("Output file: {s}\n", .{f});
    } else {
        std.debug.print("Output: stdout\n", .{});
    }
    std.debug.print("\n", .{});

    const shutdown_requested = struct {
        var atomic: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
    };

    var sigaction = std.posix.Sigaction{
        .handler = .{
            .handler = struct {
                fn handler(_: c_int) callconv(.C) void {
                    shutdown_requested.atomic.store(true, .monotonic);
                }
            }.handler,
        },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };

    std.posix.sigaction(std.posix.SIG.INT, &sigaction, null);
    std.posix.sigaction(std.posix.SIG.TERM, &sigaction, null);

    var executor = try io.SequentialExecutor.init(allocator);
    defer executor.deinit();

    var fuzzer = try fuzzer_mod.createSocketFuzzer(FUZZ_PARAMS, allocator, seed, socket_path);
    defer fuzzer.destroy();

    std.debug.print("Connecting to target at {s}...\n", .{socket_path});

    fuzzer.connectToTarget() catch |err| {
        std.debug.print("Error: Failed to connect to target at {s}: {s}\n", .{ socket_path, @errorName(err) });
        return err;
    };

    try fuzzer.performHandshake();
    std.debug.print("Handshake completed successfully\n\n", .{});

    const check_shutdown = struct {
        fn check() bool {
            return shutdown_requested.atomic.load(.monotonic);
        }
    }.check;

    var result = if (trace_dir) |dir| blk: {
        std.debug.print("Starting trace-based conformance testing from: {s}\n", .{dir});

        var trace_provider = try block_providers.TraceProvider(FUZZ_PARAMS).init(allocator, .{
            .directory = dir,
        });
        defer trace_provider.deinit();

        break :blk try trace_provider.run(SocketFuzzer, fuzzer, check_shutdown);
    } else blk: {
        std.debug.print("Starting conformance testing with {d} blocks...\n", .{num_blocks});

        var sequoia_provider = try block_providers.SequoiaProvider(io.SequentialExecutor, FUZZ_PARAMS).init(&executor, allocator, .{
            .seed = seed,
            .num_blocks = num_blocks,
        });
        defer sequoia_provider.deinit();

        break :blk try sequoia_provider.run(SocketFuzzer, fuzzer, check_shutdown);
    };
    defer result.deinit(allocator);

    if (shutdown_requested.atomic.load(.monotonic)) {
        std.debug.print("\nReceived signal, shutting down gracefully...\n", .{});
    }

    fuzzer.endSession();

    const report_text = try report.generateReport(FUZZ_PARAMS, allocator, result);
    defer allocator.free(report_text);

    if (output_file) |file_path| {
        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        try file.writeAll(report_text);
        std.debug.print("\nReport written to: {s}\n", .{file_path});
    } else {
        std.debug.print("\n{s}\n", .{report_text});
    }

    if (result.isSuccess()) {
        if (trace_dir) |_| {
            std.debug.print("\n✓ Conformance test PASSED - All traces processed successfully\n", .{});
        } else {
            std.debug.print("\n✓ Conformance test PASSED - All {d} blocks processed successfully\n", .{num_blocks});
        }
        std.process.exit(0);
    } else {
        std.debug.print("\n✗ Conformance test FAILED - State mismatch detected\n", .{});
        std.process.exit(1);
    }
}
