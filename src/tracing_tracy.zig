/// Tracy tracing backend - zones and messages integrated with Tracy profiler
const std = @import("std");
const tracy = @import("tracy");
const config_mod = @import("tracing/config.zig");

pub const LogLevel = config_mod.LogLevel;

// Global config instance for Tracy mode
var config: config_mod.Config = undefined;

pub const TracingScope = struct {
    name: []const u8,

    const Self = @This();

    pub fn init(comptime scope: @Type(.enum_literal)) Self {
        return comptime Self{
            .name = @tagName(scope),
        };
    }

    pub fn span(comptime self: *const Self, operation: @Type(.enum_literal)) Span {
        return Span.init(self.name, @tagName(operation));
    }
};

pub const Span = struct {
    scope: []const u8,
    operation: []const u8,
    tracy_zone: tracy.ZoneCtx,
    min_level: LogLevel,
    active: bool,

    pub fn init(scope: []const u8, operation: []const u8) Span {
        const min_level = config.getLevel(scope);
        // Create null-terminated string for Tracy using operation name only
        var operation_buf: [64]u8 = undefined;
        const len = @min(operation.len, operation_buf.len - 1);
        @memcpy(operation_buf[0..len], operation[0..len]);
        operation_buf[len] = 0;

        return Span{
            .scope = scope,
            .operation = operation,
            .tracy_zone = tracy.ZoneN(@src(), @ptrCast(operation_buf[0..len :0])),
            .min_level = min_level,
            .active = true,
        };
    }

    pub fn child(self: *const Span, operation: @Type(.enum_literal)) Span {
        return Span.init(self.scope, @tagName(operation));
    }

    pub fn deinit(self: *const Span) void {
        self.tracy_zone.End();
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

    inline fn log(self: *const Span, level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        if (!self.active or @intFromEnum(level) < @intFromEnum(self.min_level)) return;

        var message_buf: [1024]u8 = undefined;
        const message = std.fmt.bufPrint(&message_buf, fmt, args) catch "formatting error";
        tracy.Message(message);
    }
};

// Module initialization
pub fn init(allocator: std.mem.Allocator) void {
    config = config_mod.Config.init(allocator);
}

pub fn deinit() void {
    config.deinit();
}

// Configuration API (delegate to config)
pub fn setScope(name: []const u8, level: LogLevel) !void {
    try config.setScope(name, level);
}

pub fn disableScope(name: []const u8) !void {
    config.disableScope(name);
}

pub fn setDefaultLevel(level: LogLevel) void {
    config.setDefaultLevel(level);
}

pub fn reset() void {
    config.reset();
}

pub fn findScope(name: []const u8) ?LogLevel {
    return config.findScope(name);
}

pub fn scoped(comptime scope: @Type(.enum_literal)) TracingScope {
    return comptime TracingScope.init(scope);
}

