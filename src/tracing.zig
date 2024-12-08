/// A hierarchical tracing and logging system that provides scoped operations with colored output.
/// This module enables structured logging with support for nested operations, configurable scopes,
/// and different log levels.
///
const std = @import("std");
const build_options = @import("build_options");

pub const ScopeConfig = struct {
    name: []const u8,
    level: ?LogLevel,
};

// Get default level from build options - LogLevel.info if not specified
pub const boption_default_level: ?LogLevel = if (@hasDecl(build_options, "enable_tracing_level"))
    if (build_options.enable_tracing_level.len == 0)
        null
    else
        LogLevel.fromString(build_options.enable_tracing_level) catch
            @compileError("Invalid log level in enable_tracing_level: '" ++ build_options.enable_tracing_level ++ "'")
else
    null;

// Parse scope configs from build options
pub const boption_scope_configs = if (@hasDecl(build_options, "enable_tracing_scopes"))
blk: {
    const scope_strs = build_options.enable_tracing_scopes;
    var configs: []const ScopeConfig = &[_]ScopeConfig{};

    for (scope_strs) |scope_str| {
        if (scope_str.len == 0) continue;

        // Check if string contains '='
        if (std.mem.indexOf(u8, scope_str, "=")) |equals_pos| {
            // Format is scope=level
            const scope_name = scope_str[0..equals_pos];

            // Skip if scope name is empty
            if (scope_name.len == 0) continue;

            const level_str = scope_str[equals_pos + 1 ..];

            // Skip if invalid level, using comptime catch
            const level = LogLevel.fromString(level_str) catch continue;

            configs = configs ++ &[_]ScopeConfig{.{
                .name = scope_name,
                .level = level,
            }};
        } else {
            // Just a scope name - use default level
            configs = configs ++ &[_]ScopeConfig{.{
                .name = scope_str,
                .level = LogLevel.debug,
            }};
        }
    }

    break :blk configs;
} else @as([]const ScopeConfig, &[_]ScopeConfig{});

threadlocal var current_depth: usize = 0;
threadlocal var current_span: ?*Span = null;

pub const LogLevel = enum {
    trace,
    debug,
    info,
    warn,
    err,

    pub fn fromString(str: []const u8) !LogLevel {
        inline for (@typeInfo(LogLevel).@"enum".fields) |field| {
            if (std.mem.eql(u8, str, field.name)) {
                return @enumFromInt(field.value);
            }
        }
        return error.InvalidLogLevel;
    }

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

pub const TracingScope = struct {
    name: []const u8,

    const Self = @This();

    pub fn init(comptime scope: @Type(.enum_literal)) Self {
        return comptime Self{
            .name = @tagName(scope),
        };
    }

    pub fn span(comptime self: *const Self, operation: @Type(.enum_literal)) SpanUnion {
        // First check if scope is enabled and get its configured level
        const scope_config: ScopeConfig = comptime blk: {

            // Look for matching scope config
            for (boption_scope_configs) |config| {
                if (std.mem.eql(u8, config.name, self.name)) {
                    break :blk config;
                }
            }

            break :blk ScopeConfig{
                .name = self.name,
                .level = boption_default_level,
            };
        };

        // Return disabled span if scope is not configured and we have not
        // set a default log level
        if (scope_config.level == null) {
            return SpanUnion{ .Disabled = DisabledSpan{} };
        }

        // Create enabled span with proper level
        return SpanUnion{ .Enabled = Span.init(self, operation, current_span, true, scope_config.level.?) };
    }
};

pub const Span = struct {
    scope: *const TracingScope,
    operation: []const u8,
    parent: ?*Span,
    depth: ?usize = null,
    materialized: bool,
    enabled: bool,
    min_level: LogLevel,

    const Self = @This();

    pub fn init(
        scope: *const TracingScope,
        operation: @Type(.enum_literal),
        parent: ?*Span,
        enabled: bool,
        min_level: LogLevel,
    ) Self {
        return Self{
            .scope = scope,
            .operation = @tagName(operation),
            .parent = parent,
            .materialized = false,
            .enabled = enabled,
            .min_level = min_level,
            .depth = current_depth,
        };
    }

    pub fn child(self: *Self, operation: @Type(.enum_literal)) Span {
        return Span.init(self.scope, operation, self, self.enabled, self.min_level);
    }

    pub fn deinit(self: *const Self) void {
        if (self.depth) |depth| {
            current_depth = depth;
        }
        current_span = self.parent;
    }

    pub inline fn trace(self: *Self, comptime fmt: []const u8, args: anytype) void {
        if (@intFromEnum(LogLevel.trace) >= @intFromEnum(self.min_level)) {
            self.log(.trace, fmt, args);
        }
    }

    pub inline fn debug(self: *Self, comptime fmt: []const u8, args: anytype) void {
        if (@intFromEnum(LogLevel.debug) >= @intFromEnum(self.min_level)) {
            self.log(.debug, fmt, args);
        }
    }

    pub inline fn info(self: *Self, comptime fmt: []const u8, args: anytype) void {
        if (@intFromEnum(LogLevel.info) >= @intFromEnum(self.min_level)) {
            self.log(.info, fmt, args);
        }
    }

    pub inline fn warn(self: *Self, comptime fmt: []const u8, args: anytype) void {
        if (@intFromEnum(LogLevel.warn) >= @intFromEnum(self.min_level)) {
            self.log(.warn, fmt, args);
        }
    }

    pub inline fn err(self: *Self, comptime fmt: []const u8, args: anytype) void {
        if (@intFromEnum(LogLevel.err) >= @intFromEnum(self.min_level)) {
            self.log(.err, fmt, args);
        }
    }

    fn printSpanPath(self: *Self) void {
        if (self.parent) |parent| {
            if (!parent.materialized) {
                parent.printSpanPath();
            }
        }

        if (!self.materialized) {
            // count the materialized spans, this
            // is our new depth
            var cursor = self;
            current_depth = 0;
            while (cursor.parent) |p| {
                if (p.materialized) {
                    current_depth += 1;
                }
                cursor = p;
            }

            var i: usize = 0;
            while (i < current_depth * 2) : (i += 1) {
                std.debug.print(" ", .{});
            }

            std.debug.print("→ ", .{});
            std.debug.print("{s}", .{self.operation});
            @constCast(self).materialized = true;
        }
    }

    inline fn log(self: *Self, level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        if (!self.enabled or @intFromEnum(level) < @intFromEnum(self.min_level)) return;

        // Print full path if this is first materialization at this level
        if (!self.materialized) {
            self.printSpanPath();
            std.debug.print("\n", .{});
        }

        current_span = self;

        // Print indentation
        var i: usize = 0;
        while (i < current_depth * 2) : (i += 1) {
            std.debug.print(" ", .{});
        }

        std.debug.print("  ", .{});

        std.debug.print("{s} ", .{level.format()});
        std.debug.print(fmt ++ "\x1b[0m\n", args);
    }
};

pub const SpanUnion = union(enum) {
    Enabled: Span,
    Disabled: DisabledSpan,

    pub fn logLevel(self: *const SpanUnion) ?LogLevel {
        switch (self.*) {
            .Enabled => |span| span.min_level,
            .Disabled => null,
        }
    }

    pub fn traceLogLevel(self: *const SpanUnion) bool {
        return switch (self.*) {
            .Enabled => |span| @intFromEnum(LogLevel.trace) >= @intFromEnum(span.min_level),
            .Disabled => false,
        };
    }

    pub fn deinit(self: *const SpanUnion) void {
        switch (self.*) {
            .Enabled => |span| span.deinit(),
            .Disabled => {},
        }
    }

    pub fn child(self: *const SpanUnion, operation: @Type(.enum_literal)) SpanUnion {
        return switch (self.*) {
            .Enabled => |*span| SpanUnion{ .Enabled = @constCast(span).child(operation) },
            .Disabled => SpanUnion{ .Disabled = DisabledSpan{} },
        };
    }

    pub inline fn trace(self: *const SpanUnion, comptime fmt: []const u8, args: anytype) void {
        switch (self.*) {
            .Enabled => |*span| @constCast(span).trace(fmt, args),
            .Disabled => {},
        }
    }

    pub inline fn debug(self: *const SpanUnion, comptime fmt: []const u8, args: anytype) void {
        switch (self.*) {
            .Enabled => |*span| @constCast(span).debug(fmt, args),
            .Disabled => {},
        }
    }

    pub inline fn info(self: *const SpanUnion, comptime fmt: []const u8, args: anytype) void {
        switch (self.*) {
            .Enabled => |*span| @constCast(span).info(fmt, args),
            .Disabled => {},
        }
    }

    pub inline fn warn(self: *const SpanUnion, comptime fmt: []const u8, args: anytype) void {
        switch (self.*) {
            .Enabled => |*span| @constCast(span).warn(fmt, args),
            .Disabled => {},
        }
    }

    pub inline fn err(self: *const SpanUnion, comptime fmt: []const u8, args: anytype) void {
        switch (self.*) {
            .Enabled => |*span| @constCast(span).err(fmt, args),
            .Disabled => {},
        }
    }
};

pub const DisabledSpan = struct {
    pub inline fn trace(_: *const DisabledSpan, comptime _: []const u8, _: anytype) void {}
    pub inline fn debug(_: *const DisabledSpan, comptime _: []const u8, _: anytype) void {}
    pub inline fn info(_: *const DisabledSpan, comptime _: []const u8, _: anytype) void {}
    pub inline fn warn(_: *const DisabledSpan, comptime _: []const u8, _: anytype) void {}
    pub inline fn err(_: *const DisabledSpan, comptime _: []const u8, _: anytype) void {}
};

pub fn scoped(comptime scope: @Type(.enum_literal)) TracingScope {
    return comptime TracingScope.init(scope);
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
