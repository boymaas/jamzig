/// A hierarchical tracing and logging system that provides scoped operations with colored output.
/// This module enables structured logging with support for nested operations, configurable scopes,
/// and different log levels.
///
/// Features:
/// - Four log levels (debug, info, warn, err) with distinct ANSI colors
/// - Hierarchical operation tracking within named scopes
/// - Automatic indentation based on operation nesting depth
/// - Thread-local indent tracking
///
/// Example usage:
/// ```zig
/// const scope = scoped(.networking);
/// const span = scope.span(.connect);
/// defer span.deinit();
///
/// span.info("Connecting to {s}...", .{host});
///
/// const auth_span = span.child(.authenticate);
/// defer auth_span.deinit();
/// auth_span.debug("Starting authentication...", .{});
/// ```
///
/// The system consists of three main types:
///
/// LogLevel: An enum defining log levels and their associated ANSI color codes
/// - debug (cyan)
/// - info (green)
/// - warn (yellow)
/// - err (red)
///
/// TracingScope: Represents a high-level logging category
/// - Acts as a factory for creating Span instances
///
/// Span: Represents a specific operation within a scope
/// - Supports hierarchical parent-child relationships
/// - Automatically logs entry/exit
/// - Provides leveled logging methods (debug, info, warn, err)
/// - Maintains operation path for context in log messages
///
/// Log output format:
/// [indent][color][scope.operation.suboperation] message[reset]\n
///
/// Note: Spans should typically be created with defer for automatic cleanup:
/// ```zig
/// const span = scope.span(.operation);
/// defer span.deinit();
/// // ... operation code ...
/// ```
const std = @import("std");

pub const LogLevel = enum {
    trace,
    debug,
    info,
    warn,
    err,

    pub fn color(self: LogLevel) []const u8 {
        return switch (self) {
            .trace => "\x1b[90m", // bright black/gray
            .debug => "\x1b[36m",
            .info => "\x1b[32m",
            .warn => "\x1b[33m",
            .err => "\x1b[31m",
        };
    }
};

// Thread-local indent tracking
threadlocal var indent_level: usize = 0;

pub const TracingScope = struct {
    name: []const u8,

    const Self = @This();

    pub fn init(comptime scope: @Type(.enum_literal)) Self {
        return Self{
            .name = @tagName(scope),
        };
    }

    pub fn span(self: *const Self, operation: @Type(.enum_literal)) Span {
        return Span.init(self, operation, null);
    }
};

pub const Span = struct {
    scope: *const TracingScope,
    operation: []const u8,
    parent: ?*const Span,
    start_indent: usize, // Store the indent level when span starts

    const Self = @This();

    pub fn init(scope: *const TracingScope, operation: @Type(.enum_literal), parent: ?*const Span) Self {
        const span = Self{
            .scope = scope,
            .operation = @tagName(operation),
            .parent = parent,
            .start_indent = indent_level,
        };

        span.log(.trace, "\x1b[1m[ENTER]\x1b[22m", .{});
        indent_level += 1; // Increment indent level on span creation
        return span;
    }

    pub fn child(self: *const Self, operation: @Type(.enum_literal)) Span {
        return Span.init(self.scope, operation, self);
    }

    pub fn deinit(self: *const Self) void {
        indent_level = self.start_indent; // Restore indent level on span cleanup
        self.log(.trace, "\x1b[1m[EXIT]\x1b[22m", .{});
    }

    pub inline fn trace(self: *const Self, comptime fmt: []const u8, args: anytype) void {
        self.log(.trace, fmt, args);
    }

    pub inline fn debug(self: *const Self, comptime fmt: []const u8, args: anytype) void {
        self.log(.debug, fmt, args);
    }

    pub inline fn info(self: *const Self, comptime fmt: []const u8, args: anytype) void {
        self.log(.info, fmt, args);
    }

    pub inline fn warn(self: *const Self, comptime fmt: []const u8, args: anytype) void {
        self.log(.warn, fmt, args);
    }

    pub inline fn err(self: *const Self, comptime fmt: []const u8, args: anytype) void {
        self.log(.err, fmt, args);
    }

    fn getFullPath(self: *const Self, buf: []u8) []const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        var writer = fbs.writer();

        // Build path from root to leaf
        var spans: [32]*const Span = undefined;
        var count: usize = 0;

        var current: ?*const Span = self;
        while (current) |span| : (current = span.parent) {
            spans[count] = span;
            count += 1;
        }

        // Write scope name first
        writer.print("{s}", .{self.scope.name}) catch return "";

        // Then write spans in order from root to leaf
        var i: usize = count;
        while (i > 0) : (i -= 1) {
            const span = spans[i - 1];
            writer.print(".{s}", .{span.operation}) catch return "";
        }

        return fbs.getWritten();
    }

    inline fn log(self: *const Self, level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        const color = level.color();
        const reset = "\x1b[0m";
        var path_buf: [1024]u8 = undefined;
        const path = self.getFullPath(&path_buf);

        var indent_buf: [128]u8 = undefined;
        const indent = indent_buf[0 .. indent_level * 2];
        @memset(indent, ' ');

        std.debug.print("{s}{s}[{s}] " ++ fmt ++ reset ++ "\n", .{ indent, color, path } ++ args);
    }
};

pub fn scoped(comptime scope: @Type(.enum_literal)) TracingScope {
    return TracingScope.init(scope);
}

test "TracingScope initialization" {
    const testing = std.testing;
    const scope = scoped(.test_scope);
    try testing.expectEqualStrings("test_scope", scope.name);
}

test "Span path construction" {
    const testing = std.testing;
    const scope = scoped(.networking);

    var path_buf: [1024]u8 = undefined;

    // Test single span
    {
        const span = scope.span(.connect);
        defer span.deinit();
        const path = span.getFullPath(&path_buf);
        try testing.expectEqualStrings("networking.connect", path);
    }

    // Test nested spans
    {
        const parent_span = scope.span(.connect);
        defer parent_span.deinit();

        const child_span = parent_span.child(.authenticate);
        defer child_span.deinit();

        const path = child_span.getFullPath(&path_buf);
        try testing.expectEqualStrings("networking.connect.authenticate", path);
    }
}

test "Span parent relationships" {
    const testing = std.testing;
    const scope = scoped(.test_scope);

    const parent = scope.span(.parent);
    defer parent.deinit();
    try testing.expect(parent.parent == null);

    const child = parent.child(.child);
    defer child.deinit();
    try testing.expect(child.parent != null);
    try testing.expectEqual(parent.operation, child.parent.?.operation);
}
