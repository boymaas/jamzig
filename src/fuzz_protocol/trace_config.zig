const std = @import("std");
const tracing = @import("../tracing.zig");

/// Apply quiet scopes by setting them to info level
pub fn applyQuietScopes(quiet_scopes_str: []const u8) !void {
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
pub fn applyTraceConfig(config_str: []const u8) !void {
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

/// Configure tracing based on command line arguments
pub fn configureTracing(args: struct {
    verbose: u8,
    trace_all: ?[]const u8,
    trace: ?[]const u8,
    trace_quiet: ?[]const u8,
}) !void {
    // Initialize runtime tracing if any trace options are provided
    if (args.trace_all != null or args.trace != null or args.trace_quiet != null) {
        // Apply default level first if specified
        if (args.trace_all) |default_level_str| {
            const default_level = tracing.LogLevel.fromString(default_level_str) catch {
                std.debug.print("Error: Invalid log level '{s}'\n", .{default_level_str});
                std.debug.print("Valid levels: trace, debug, info, warn, err\n", .{});
                return error.InvalidLogLevel;
            };
            tracing.runtime.setDefaultLevel(default_level);
            std.debug.print("Set default trace level to: {s}\n", .{default_level_str});
        }

        // Apply quiet scopes (set them to info level)
        if (args.trace_quiet) |quiet_scopes| {
            try applyQuietScopes(quiet_scopes);
        }

        // Then apply specific overrides if provided (these can override quiet scopes)
        if (args.trace) |trace_config| {
            try applyTraceConfig(trace_config);
        }
    }

    // Apply verbose levels
    try tracing.runtime.setScope("codec", .info); // Keep codec quiet by default
    
    if (args.verbose == 1) {
        try tracing.runtime.setScope("fuzz_protocol", .debug);
        try tracing.runtime.setScope("jam_conformance_fuzzer", .debug);
        try tracing.runtime.setScope("jam_conformance_target", .debug);
        try tracing.runtime.setScope("header_validator", .debug);
    } else if (args.verbose == 2) {
        try tracing.runtime.setScope("fuzz_protocol", .trace);
        try tracing.runtime.setScope("jam_conformance_fuzzer", .trace);
        try tracing.runtime.setScope("jam_conformance_target", .trace);
        try tracing.runtime.setScope("header_validator", .trace);
    } else if (args.verbose == 3) {
        tracing.runtime.setDefaultLevel(.debug);
    } else if (args.verbose == 4) {
        tracing.runtime.setDefaultLevel(.trace);
    } else if (args.verbose == 5) {
        try tracing.runtime.setScope("codec", .debug);
    }
}