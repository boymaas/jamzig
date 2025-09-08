/// No-op tracing implementation - zero runtime overhead when tracing is disabled
const std = @import("std");

// Define LogLevel inline to avoid module conflicts
pub const LogLevel = enum {
    trace,
    debug,
    info,
    warn,
    err,

    pub fn symbol(self: LogLevel) []const u8 {
        return switch (self) {
            .trace => "•",
            .debug => "○",
            .info => "→",
            .warn => "⚠",
            .err => "✖",
        };
    }

    pub fn fromString(str: []const u8) !LogLevel {
        inline for (@typeInfo(LogLevel).@"enum".fields) |field| {
            if (std.mem.eql(u8, str, field.name)) {
                return @enumFromInt(field.value);
            }
        }
        return error.InvalidLogLevel;
    }
};

pub const TracingScope = struct {
    name: []const u8,

    const Self = @This();

    pub fn init(comptime scope: @Type(.enum_literal)) Self {
        return comptime Self{
            .name = @tagName(scope),
        };
    }

    pub inline fn span(comptime self: *const Self, src: std.builtin.SourceLocation, operation: @Type(.enum_literal)) Span {
        _ = self;
        _ = src;
        _ = operation;
        return Span{};
    }
};

pub const Span = struct {
    scope: []const u8 = "",
    operation: []const u8 = "",

    const Self = @This();

    pub fn init(scope: []const u8, operation: []const u8) Self {
        _ = scope;
        _ = operation;
        return Self{};
    }

    pub inline fn child(self: *const Self, src: std.builtin.SourceLocation, operation: @Type(.enum_literal)) Span {
        _ = self;
        _ = src;
        _ = operation;
        return Span{};
    }

    pub fn deinit(self: *const Self) void {
        _ = self;
    }

    pub inline fn trace(self: *const Self, comptime fmt: []const u8, args: anytype) void {
        _ = self;
        _ = fmt;
        _ = args;
    }

    pub inline fn debug(self: *const Self, comptime fmt: []const u8, args: anytype) void {
        _ = self;
        _ = fmt;
        _ = args;
    }

    pub inline fn info(self: *const Self, comptime fmt: []const u8, args: anytype) void {
        _ = self;
        _ = fmt;
        _ = args;
    }

    pub inline fn warn(self: *const Self, comptime fmt: []const u8, args: anytype) void {
        _ = self;
        _ = fmt;
        _ = args;
    }

    pub inline fn err(self: *const Self, comptime fmt: []const u8, args: anytype) void {
        _ = self;
        _ = fmt;
        _ = args;
    }
};

// Module initialization (no-ops)
pub fn init(_: std.mem.Allocator) void {}
pub fn deinit() void {}

// Configuration API (all no-ops)
pub fn setScope(_: []const u8, _: LogLevel) !void {}
pub fn disableScope(_: []const u8) void {}
pub fn setDefaultLevel(_: LogLevel) void {}
pub fn reset() void {}
pub fn findScope(_: []const u8) ?LogLevel {
    return null;
}

pub fn scoped(comptime scope: @Type(.enum_literal)) TracingScope {
    return comptime TracingScope.init(scope);
}

