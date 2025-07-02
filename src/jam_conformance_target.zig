const std = @import("std");
const clap = @import("clap");
const tracing = @import("tracing.zig");

const TargetServer = @import("fuzz_protocol/target.zig").TargetServer;
const trace = @import("tracing.zig").scoped(.jam_conformance_target);

fn showHelp(params: anytype) !void {
    std.debug.print(
        \\JAM Conformance Target: Reference implementation for JAM protocol conformance testing
        \\
        \\This server listens on a Unix domain socket and processes JAM protocol messages
        \\according to the specification. It is used as a reference implementation for
        \\conformance testing of other JAM implementations.
        \\
        \\
    , .{});
    try clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{ .spacing_between_parameters = 0 });
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
        \\ 
        \\--trace <str>          Tracing configuration (e.g., stf=trace,accumulate=debug,pvm=trace,fuzz_protocol=debug)
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

    // Extract configuration
    const socket_path = res.args.socket orelse "/tmp/jam_conformance.sock";
    const verbose = res.args.verbose != 0;

    if (res.args.trace) |trace_config| {
        tracing.runtime.init(allocator);
        try applyTraceConfig(trace_config);
    }

    std.debug.print("JAM Conformance Target Server\n", .{});
    std.debug.print("=============================\n", .{});
    std.debug.print("Socket path: {s}\n", .{socket_path});
    if (verbose) {
        std.debug.print("Verbose mode: enabled\n", .{});
    }
    std.debug.print("\n", .{});

    var server = try TargetServer.init(allocator, socket_path);
    defer server.deinit();

    // Setup signal handler for graceful shutdown
    var sigaction = std.posix.Sigaction{
        .handler = .{ .handler = struct {
            fn handler(_: c_int) callconv(.C) void {
                std.debug.print("\nReceived signal, shutting down...\n", .{});
                std.process.exit(0);
            }
        }.handler },
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

/// Parse and apply trace configuration string
fn applyTraceConfig(config_str: []const u8) !void {
    // Parse config string like "pvm=debug,net=info"
    var iter = std.mem.splitSequence(u8, config_str, ",");
    while (iter.next()) |scope_config| {
        if (scope_config.len == 0) continue;

        if (std.mem.indexOf(u8, scope_config, "=")) |equals_pos| {
            const scope_name = scope_config[0..equals_pos];
            const level_str = scope_config[equals_pos + 1 ..];

            // Parse level
            const level = tracing.LogLevel.fromString(level_str) catch {
                std.debug.print("Warning: Invalid log level '{s}' for scope '{s}'\n", .{ level_str, scope_name });
                continue;
            };

            // Apply configuration
            tracing.runtime.setScope(scope_name, level) catch {
                std.debug.print("Warning: Failed to set tracing for scope '{s}'\n", .{scope_name});
            };
        } else {
            // Just scope name, default to debug
            tracing.runtime.setScope(scope_config, .debug) catch {
                std.debug.print("Warning: Failed to set tracing for scope '{s}'\n", .{scope_config});
            };
        }
    }
}

