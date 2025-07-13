const std = @import("std");
const clap = @import("clap");
const tracing = @import("tracing.zig");

const target = @import("fuzz_protocol/target.zig");
const TargetServer = target.TargetServer;
const RestartBehavior = target.RestartBehavior;
const trace = @import("tracing.zig").scoped(.jam_conformance_target);
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
        \\Tracing Examples:
        \\  # Set all scopes to debug level
        \\  jam_conformance_target --trace-all debug
        \\
        \\  # Set all to debug, but keep codec at info level
        \\  jam_conformance_target --trace-all debug --trace-quiet codec
        \\
        \\  # Set all to debug, keep codec quiet, but trace STF
        \\  jam_conformance_target --trace-all debug --trace-quiet codec --trace "stf=trace"
        \\
        \\  # Debug everything including codec (override quiet)
        \\  jam_conformance_target --trace-all debug --trace-quiet codec --trace "codec=debug"
        \\
        \\  # Maximum verbosity for everything
        \\  jam_conformance_target --trace-all trace
        \\
    , .{});
}

pub fn main() !void {
    const span = trace.span(.main);
    defer span.deinit();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const params = comptime clap.parseParamsComptime(
        \\-h, --help             Display this help and exit.
        \\-s, --socket <str>     Unix socket path to listen on (default: /tmp/jam_conformance.sock)
        \\-v, --verbose          Enable verbose output
        \\--trace-all <str>      Set default trace level for all scopes (trace/debug/info/warn/err)
        \\--trace-quiet <str>    Comma-separated scopes to keep at info level (e.g., codec,network)
        \\--trace <str>          Tracing configuration for specific scopes (e.g., stf=trace,accumulate=debug,pvm=trace,fuzz_protocol=debug)
        \\ 
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

    // Configure tracing
    try trace_config.configureTracing(.{
        .verbose = res.args.verbose,
        .trace_all = res.args.@"trace-all",
        .trace = res.args.trace,
        .trace_quiet = res.args.@"trace-quiet",
    });

    std.debug.print("JAM Conformance Target Server\n", .{});
    std.debug.print("=============================\n", .{});
    std.debug.print("Socket path: {s}\n", .{socket_path});
    if (verbose) {
        std.debug.print("Verbose mode: enabled\n", .{});
    }
    std.debug.print("\n", .{});

    var server = try TargetServer.init(allocator, socket_path, .restart_on_disconnect);
    defer server.deinit();

    // Setup signal handler for graceful shutdown
    // Note: Signal handlers must use global state as they can't capture context
    const shutdown_requested = struct {
        var server_ref: ?*TargetServer = null;
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
