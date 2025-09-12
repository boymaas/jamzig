const std = @import("std");
const clap = @import("clap");
const tracing = @import("tracing");
const io = @import("io.zig");
const build_tuned_allocator = @import("build_tuned_allocator.zig");

const target = @import("fuzz_protocol/target.zig");
const TargetServer = target.TargetServer;
const RestartBehavior = target.RestartBehavior;
const trace = @import("tracing").scoped(.jam_conformance_target);
const jam_params = @import("jam_params.zig");
const jam_params_format = @import("jam_params_format.zig");
const build_options = @import("build_options");
const messages = @import("fuzz_protocol/messages.zig");
const param_formatter = @import("fuzz_protocol/param_formatter.zig");
const trace_config = @import("fuzz_protocol/trace_config.zig");

fn showHelp(params: anytype) !void {
    std.debug.print(
        \\JamZig⚡ Conformance Target for JAM Fuzz protocol conformance testing
        \\
        \\This server listens on a Unix domain socket and processes JAM fuzzing protocol messages according to the JAM fuzz protocol specification.
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
        \\  jam_conformance_target -v
        \\
        \\  # Run with maximum verbosity
        \\  jam_conformance_target -vvvv
        \\
    , .{});
}

pub fn main() !void {
    const span = trace.span(@src(), .main);
    defer span.deinit();

    var alloc = build_tuned_allocator.BuildTunedAllocator.init();
    defer alloc.deinit();
    const allocator = alloc.allocator();

    // Parse command line arguments
    const params = comptime clap.parseParamsComptime(
        \\-h, --help             Display this help and exit.
        \\-s, --socket <str>     Unix socket path to listen on (default: /tmp/jam_conformance.sock)
        \\-v, --verbose          Enable verbose output (can be repeated up to 5 times)
        \\--exit-on-disconnect   Exit server when client disconnects (default: keep listening)
        \\--dump-params          Dump JAM protocol parameters and exit
        \\--format <str>         Output format for parameter dump: json or text (default: text)
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

    // Handle parameter dumping
    if (try param_formatter.handleParamDump(res.args.@"dump-params" != 0, res.args.format)) {
        return;
    }

    // Extract configuration
    const socket_path = res.args.socket orelse "/tmp/jam_conformance.sock";
    const verbose = res.args.verbose != 0;
    const exit_on_disconnect = res.args.@"exit-on-disconnect" != 0;

    // Configure tracing
    try trace_config.configureTracing(.{
        .verbose = res.args.verbose,
        .trace_all = null,
        .trace = null,
        .trace_quiet = null,
    });

    std.debug.print("JAM Conformance Target Server\n", .{});
    std.debug.print("=============================\n", .{});
    std.debug.print("Socket path: {s}\n", .{socket_path});
    if (verbose) {
        std.debug.print("Verbose mode: enabled\n", .{});
    }
    if (exit_on_disconnect) {
        std.debug.print("Exit on disconnect: enabled\n", .{});
    }
    std.debug.print("\n", .{});

    const restart_behavior: RestartBehavior = if (exit_on_disconnect) .exit_on_disconnect else .restart_on_disconnect;

    // const ExecutorType = io.SequentialExecutor;
    const ExecutorType = io.ThreadPoolExecutor;

    var executor = try ExecutorType.init(allocator);
    defer executor.deinit();

    var server = try TargetServer(ExecutorType).init(&executor, allocator, socket_path, restart_behavior);
    defer server.deinit();

    // Setup signal handler for graceful shutdown
    // Note: Signal handlers must use global state as they can't capture context
    const shutdown_requested = struct {
        var server_ref: ?*TargetServer(ExecutorType) = null;
    };
    shutdown_requested.server_ref = &server;

    var sigaction = std.posix.Sigaction{
        .handler = .{
            .handler = struct {
                fn handler(_: c_int) callconv(.C) void {
                    // Signal handlers must be async-signal-safe
                    if (shutdown_requested.server_ref) |srv| {
                        srv.shutdown();
                    }
                }
            }.handler,
        },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };

    std.posix.sigaction(std.posix.SIG.INT, &sigaction, null);
    std.posix.sigaction(std.posix.SIG.TERM, &sigaction, null);

    std.debug.print("Starting server...\n", .{});
    std.debug.print("Listening on Unix socket: {s}\n", .{socket_path});
    std.debug.print("Press Ctrl+C to stop\n\n", .{});

    // Start the server (this will block until interrupted)
    try server.start();
}
