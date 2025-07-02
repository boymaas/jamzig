/// A hierarchical tracing and logging system that provides scoped operations with colored output.
/// This module enables structured logging with support for nested operations, configurable scopes,
/// and different log levels.
///
/// Supports three tracing modes:
/// - disabled: No tracing compiled in (dead code elimination)
/// - compile_time: Fixed scopes at compile time (current behavior)
/// - runtime: Dynamic scope control at runtime
///
const std = @import("std");
const build_options = @import("build_options");

// Tracing mode from build options
pub const TracingMode = enum { disabled, compile_time, runtime };
pub const tracing_mode: TracingMode = if (@hasDecl(build_options, "tracing_mode"))
    @enumFromInt(@intFromEnum(build_options.tracing_mode))
else
    .compile_time;

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

    for (scope_strs) |full_str| {
        if (full_str.len == 0) continue;

        // Split on commas
        var scope_iter = std.mem.splitSequence(u8, full_str, ",");
        while (scope_iter.next()) |scope_str| {
            // Skip empty entries
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
    }

    break :blk configs;
} else @as([]const ScopeConfig, &[_]ScopeConfig{});

pub fn findScope(name: []const u8) ?*const ScopeConfig {
    for (boption_scope_configs) |*scope| {
        if (std.mem.startsWith(u8, scope.name, name)) {
            return scope;
        }
    }
    return null;
}

// Runtime tracing configuration (only compiled in runtime mode)
const RuntimeTracingConfig = if (tracing_mode == .runtime) struct {
    config: std.StringHashMap(?LogLevel),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RuntimeTracingConfig {
        return .{
            .config = std.StringHashMap(?LogLevel).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RuntimeTracingConfig) void {
        var iterator = self.config.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.config.deinit();
    }

    pub fn setScope(self: *RuntimeTracingConfig, scope_name: []const u8, level: ?LogLevel) !void {
        // Check if scope already exists and free old key if so
        if (self.config.fetchRemove(scope_name)) |existing| {
            self.allocator.free(existing.key);
        }
        
        const owned_name = try self.allocator.dupe(u8, scope_name);
        try self.config.put(owned_name, level);
    }

    pub fn getScope(self: *const RuntimeTracingConfig, scope_name: []const u8) ?LogLevel {
        return self.config.get(scope_name) orelse null;
    }

    pub fn removeScope(self: *RuntimeTracingConfig, scope_name: []const u8) void {
        if (self.config.fetchRemove(scope_name)) |kv| {
            self.allocator.free(kv.key);
        }
    }
} else void;

// Global runtime configuration (only exists in runtime mode)
var runtime_config: RuntimeTracingConfig = if (tracing_mode == .runtime) 
    undefined // Will be initialized in runtime.init()
else {};

// Runtime tracing API (only available in runtime mode)
pub const runtime = if (tracing_mode == .runtime) struct {
    pub fn init(allocator: std.mem.Allocator) void {
        runtime_config = RuntimeTracingConfig.init(allocator);
    }

    pub fn deinit() void {
        runtime_config.deinit();
    }

    pub fn setScope(scope_name: []const u8, level: LogLevel) !void {
        try runtime_config.setScope(scope_name, level);
    }

    pub fn disableScope(scope_name: []const u8) !void {
        try runtime_config.setScope(scope_name, null);
    }

    pub fn getConfig() std.StringHashMap(?LogLevel) {
        return runtime_config.config;
    }

    pub fn listAvailableScopes() []const ScopeConfig {
        return boption_scope_configs;
    }
} else struct {
    pub fn init(_: std.mem.Allocator) void {}
    pub fn deinit() void {}
    pub fn setScope(_: []const u8, _: LogLevel) void {}
    pub fn disableScope(_: []const u8) void {}
};

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
        // Handle different tracing modes
        return switch (comptime tracing_mode) {
            .disabled => SpanUnion{ .Disabled = DisabledSpan{} },
            .compile_time => self.spanCompileTime(operation),
            .runtime => self.spanRuntime(operation),
        };
    }

    fn spanCompileTime(comptime self: *const Self, operation: @Type(.enum_literal)) SpanUnion {
        // Original compile-time behavior
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

    fn spanRuntime(comptime self: *const Self, operation: @Type(.enum_literal)) SpanUnion {
        // Runtime behavior - check runtime config first, then build config
        if (comptime tracing_mode == .runtime) {
            // Check runtime configuration first
            if (runtime_config.config.get(self.name)) |runtime_level| {
                if (runtime_level == null) {
                    // Explicitly disabled at runtime
                    return SpanUnion{ .Disabled = DisabledSpan{} };
                }
                // Enabled with specific level at runtime
                return SpanUnion{ .Enabled = Span.init(self, operation, current_span, true, runtime_level.?) };
            }
        }

        // Fall back to compile-time configuration
        return self.spanCompileTime(operation);
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

    pub fn deinit(self: *Self) void {
        if (self.depth) |depth| {
            current_depth = depth;
        }
        current_span = self.parent;
        self.* = undefined;
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
            .Enabled => |*span| @constCast(span).deinit(), // TODO
            .Disabled => {},
        }
        @constCast(self).* = undefined; // TODO
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

// TODO: automatically enable nested scopes without requiring additional -Dtracing-scope flags
pub fn scoped(comptime scope: @Type(.enum_literal)) TracingScope {
    return comptime TracingScope.init(scope);
}
