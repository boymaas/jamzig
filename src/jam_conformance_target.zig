const std = @import("std");
const clap = @import("clap");
const tracing = @import("tracing.zig");

const TargetServer = @import("fuzz_protocol/target.zig").TargetServer;
const trace = @import("tracing.zig").scoped(.jam_conformance_target);
const jam_params = @import("jam_params.zig");
const jam_params_format = @import("jam_params_format.zig");
const build_options = @import("build_options");
const messages = @import("fuzz_protocol/messages.zig");

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
    if (res.args.@"dump-params" != 0) {
        const format = res.args.format orelse "text";
        const params_type = if (@hasDecl(build_options, "conformance_params") and build_options.conformance_params == .tiny) "TINY" else "FULL";

        const stdout = std.io.getStdOut().writer();

        if (std.mem.eql(u8, format, "json")) {
            jam_params_format.formatParamsJson(messages.FUZZ_PARAMS, params_type, stdout) catch |err| {
                // Handle BrokenPipe error gracefully (e.g., when piping to head)
                if (err == error.BrokenPipe) {
                    std.process.exit(0);
                }
                return err;
            };
        } else if (std.mem.eql(u8, format, "text")) {
            jam_params_format.formatParamsText(messages.FUZZ_PARAMS, params_type, stdout) catch |err| {
                // Handle BrokenPipe error gracefully (e.g., when piping to head)
                if (err == error.BrokenPipe) {
                    std.process.exit(0);
                }
                return err;
            };
        } else {
            std.debug.print("Error: Invalid format '{s}'. Use 'json' or 'text'.\n", .{format});
            std.process.exit(1);
        }
        return;
    }

    // Extract configuration
    const socket_path = res.args.socket orelse "/tmp/jam_conformance.sock";
    const verbose = res.args.verbose != 0;

    // Initialize runtime tracing if any trace options are provided
    if (res.args.@"trace-all" != null or res.args.trace != null or res.args.@"trace-quiet" != null) {

        // Apply default level first if specified
        if (res.args.@"trace-all") |default_level_str| {
            const default_level = tracing.LogLevel.fromString(default_level_str) catch {
                std.debug.print("Error: Invalid log level '{s}'\n", .{default_level_str});
                std.debug.print("Valid levels: trace, debug, info, warn, err\n", .{});
                return error.InvalidLogLevel;
            };
            tracing.runtime.setDefaultLevel(default_level);
            std.debug.print("Set default trace level to: {s}\n", .{default_level_str});
        }

        // Apply quiet scopes (set them to info level)
        if (res.args.@"trace-quiet") |quiet_scopes| {
            try applyQuietScopes(quiet_scopes);
        }

        // Then apply specific overrides if provided (these can override quiet scopes)
        if (res.args.trace) |trace_config| {
            try applyTraceConfig(trace_config);
        }
    }

    try tracing.runtime.setScope("codec", .info); // Keep codec quiet by default
    if (res.args.verbose == 1) {
        try tracing.runtime.setScope("fuzz_protocol", .debug);
        try tracing.runtime.setScope("jam_conformance_target", .debug);
        try tracing.runtime.setScope("header_validator", .debug);
    } else if (res.args.verbose == 2) {
        try tracing.runtime.setScope("fuzz_protocol", .trace);
        try tracing.runtime.setScope("jam_conformance_target", .trace);
        try tracing.runtime.setScope("header_validator", .trace);
    } else if (res.args.verbose == 3) {
        tracing.runtime.setDefaultLevel(.debug);
    } else if (res.args.verbose == 4) {
        tracing.runtime.setDefaultLevel(.trace);
    } else if (res.args.verbose == 5) {
        try tracing.runtime.setScope("codec", .debug);
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

/// Apply quiet scopes by setting them to info level
fn applyQuietScopes(quiet_scopes_str: []const u8) !void {
    var iter = std.mem.splitSequence(u8, quiet_scopes_str, ",");
    var count: usize = 0;

    while (iter.next()) |scope_name| {
        const trimmed = std.mem.trim(u8, scope_name, " \t");
        if (trimmed.len == 0) continue;

        tracing.runtime.setScope(trimmed, .info) catch {
            std.debug.print("Warning: Failed to set quiet scope '{s}' to info level\n", .{trimmed});
        };
        count += 1;
    }

    if (count > 0) {
        std.debug.print("Set {d} scope(s) to info level: {s}\n", .{ count, quiet_scopes_str });
    }
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
