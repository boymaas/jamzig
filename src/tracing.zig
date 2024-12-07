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

    pub fn format(self: LogLevel) []const u8 {
        return switch (self) {
            .trace => "\x1b[90m•", // bright black/gray bullet
            .debug => "\x1b[36m•", // cyan bullet
            .info => "\x1b[32m•", // green bullet
            .warn => "\x1b[33m⚠", // yellow warning
            .err => "\x1b[31m✖", // red x
        };
    }
};

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
    start_indent: usize,

    const Self = @This();

    pub fn init(scope: *const TracingScope, operation: @Type(.enum_literal), parent: ?*const Span) Self {
        const span = Self{
            .scope = scope,
            .operation = @tagName(operation),
            .parent = parent,
            .start_indent = indent_level,
        };

        // Print enter marker with arrow
        if (parent == null) {
            span.printIndent();
            std.debug.print("\x1b[1m{s} →\x1b[22m\n", .{span.operation});
        }

        indent_level += 1;
        return span;
    }

    pub fn child(self: *const Self, operation: @Type(.enum_literal)) Span {
        return Span.init(self.scope, operation, self);
    }

    pub fn deinit(self: *const Self) void {
        indent_level = self.start_indent;
        // Only print exit marker for top-level spans
        if (self.parent == null) {
            self.printIndent();
            std.debug.print("← {s}\n", .{self.operation});
        }
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

    fn printIndent(_: *const Self) void {
        var i: usize = 0;
        while (i < indent_level * 4) : (i += 1) {
            std.debug.print(" ", .{});
        }
    }

    inline fn log(self: *const Self, level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        self.printIndent();

        // For non-trace levels, use bullet points
        std.debug.print("{s} ", .{level.format()});
        std.debug.print(fmt ++ "\x1b[0m\n", args);
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
