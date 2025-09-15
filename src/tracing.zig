const std = @import("std");

pub const LogLevel = @import("tracing/config.zig").LogLevel;
pub const Config = @import("tracing/config.zig").Config;

// Static buffer for tracing configuration
var config_buffer: [4096]u8 align(@alignOf(std.StringHashMap(LogLevel).KV)) = undefined;
var config_fba = std.heap.FixedBufferAllocator.init(&config_buffer);

// Global config instance - initialized on first use
var config: ?Config = null;

// Thread-local depth for indentation
threadlocal var depth: usize = 0;

// Get config, initializing if necessary
fn getConfig() *Config {
    if (config == null) {
        config = Config.init(config_fba.allocator());
    }
    return &config.?;
}

pub const Span = struct {
    scope: []const u8,
    operation: []const u8,
    operation_emitted: bool = false,
    saved_depth: usize,

    pub fn init(scope: []const u8, operation: []const u8) Span {
        const span = Span{
            .scope = scope,
            .operation = operation,
            .saved_depth = depth,
        };

        const cfg = getConfig();
        if (cfg.findScope(scope)) |_| {
            for (0..depth * 2) |_| {
                std.debug.print(" ", .{});
            }
            std.debug.print("\x1b[1;34m", .{}); // Bold blue for scope/operation
            std.debug.print("[{s}] BEGIN {s}", .{ scope, operation });
            std.debug.print("\x1b[0m\n", .{}); // Reset color and add newline
        }

        depth += 1;
        return span;
    }

    pub fn deinit(self: *const Span) void {
        const cfg = getConfig();
        if (cfg.findScope(self.scope)) |_| {
            for (0..self.saved_depth * 2) |_| {
                std.debug.print(" ", .{});
            }
            std.debug.print("\x1b[1;34m", .{}); // Bold blue for scope/operation
            std.debug.print("[{s}] END {s}", .{ self.scope, self.operation });
            std.debug.print("\x1b[0m\n", .{}); // Reset color and add newline
        }

        depth = self.saved_depth;
    }

    pub inline fn child(self: *const Span, src: std.builtin.SourceLocation, operation: @Type(.enum_literal)) Span {
        _ = src; // Not used in regular tracing, only Tracy
        return Span.init(self.scope, @tagName(operation));
    }

    fn log(self: *const Span, level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        const cfg = getConfig();
        const scope_level = cfg.findScope(self.scope) orelse cfg.default_level;

        if (@intFromEnum(level) < @intFromEnum(scope_level)) {
            return;
        }

        // Indent based on depth
        for (0..self.saved_depth * 2) |_| {
            std.debug.print(" ", .{});
        }

        // Print with color: color code, scope, message, then reset color
        std.debug.print("{s} ", .{level.color()});
        std.debug.print(fmt, args);
        std.debug.print("\x1b[0m\n", .{}); // Reset color and add newline
    }

    pub inline fn trace(self: *const Span, comptime fmt: []const u8, args: anytype) void {
        self.log(.trace, fmt, args);
    }

    pub inline fn debug(self: *const Span, comptime fmt: []const u8, args: anytype) void {
        self.log(.debug, fmt, args);
    }

    pub inline fn info(self: *const Span, comptime fmt: []const u8, args: anytype) void {
        self.log(.info, fmt, args);
    }

    pub inline fn warn(self: *const Span, comptime fmt: []const u8, args: anytype) void {
        self.log(.warn, fmt, args);
    }

    pub inline fn err(self: *const Span, comptime fmt: []const u8, args: anytype) void {
        self.log(.err, fmt, args);
    }
};

// Configuration API
pub fn setScope(name: []const u8, level: LogLevel) !void {
    try getConfig().setScope(name, level);
}

pub fn setDefaultLevel(level: LogLevel) void {
    getConfig().setDefaultLevel(level);
}

pub fn reset() void {
    getConfig().reset();
    depth = 0;
}

pub fn disableScope(name: []const u8) void {
    getConfig().disableScope(name);
}

pub fn findScope(name: []const u8) ?LogLevel {
    return getConfig().findScope(name);
}

// API compatibility layer for existing code
pub const TracingScope = struct {
    name: []const u8,

    const Self = @This();

    pub fn init(comptime scope: @Type(.enum_literal)) Self {
        return comptime Self{
            .name = @tagName(scope),
        };
    }

    pub inline fn span(comptime self: *const Self, src: std.builtin.SourceLocation, operation: @Type(.enum_literal)) Span {
        _ = src; // Not used in regular tracing, only Tracy
        return Span.init(self.name, @tagName(operation));
    }
};

pub fn scoped(comptime scope: @Type(.enum_literal)) TracingScope {
    return comptime TracingScope.init(scope);
}
