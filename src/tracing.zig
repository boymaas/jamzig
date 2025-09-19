const std = @import("std");

pub const LogLevel = @import("tracing/config.zig").LogLevel;
pub const Config = @import("tracing/config.zig").Config;

pub const TracingContext = struct {
    scope: []const u8,
    level: LogLevel,
};

// Static buffer for tracing configuration
var config_buffer: [4096]u8 align(@alignOf(std.StringHashMap(LogLevel).KV)) = undefined;
var config_fba = std.heap.FixedBufferAllocator.init(&config_buffer);

// Global config instance - initialized on first use
var config: ?Config = null;

// Thread-local depth for indentation
threadlocal var depth: usize = 0;

// Thread-local tracing context for auto-detection
threadlocal var current_context: ?TracingContext = null;

// Global mutex for thread-safe trace output
var trace_mutex = std.Thread.Mutex{};

// Global stderr writer type
const StderrWriter = @TypeOf(std.io.getStdErr().writer());

// Generic indented writer for tracing output
fn IndentedWriter(comptime WriterType: type) type {
    return struct {
        inner: WriterType,
        indent_level: usize,
        at_line_start: bool,

        const Self = @This();
        const Error = WriterType.Error;
        const Writer = std.io.Writer(*Self, Error, write);

        pub fn init(inner_writer: WriterType, indent_level: usize) Self {
            return .{
                .inner = inner_writer,
                .indent_level = indent_level,
                .at_line_start = true,
            };
        }

        pub fn writer(self: *Self) Writer {
            return .{ .context = self };
        }

        pub fn write(self: *Self, bytes: []const u8) Error!usize {
            for (bytes) |byte| {
                if (self.at_line_start and byte != '\n') {
                    // Write indentation
                    for (0..self.indent_level * 2) |_| {
                        try self.inner.writeByte(' ');
                    }
                    self.at_line_start = false;
                }
                try self.inner.writeByte(byte);
                if (byte == '\n') {
                    self.at_line_start = true;
                }
            }
            return bytes.len;
        }
    };
}

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
    saved_depth: usize,
    owns_context: bool = false,

    pub fn init(scope: []const u8, operation: []const u8) Span {
        var span = Span{
            .scope = scope,
            .operation = operation,
            .saved_depth = depth,
            .owns_context = false,
        };

        const cfg = getConfig();
        var should_emit = false;

        // Check active context FIRST (fastest path)
        if (current_context != null and !cfg.isDisabledScope(scope)) {
            // Emit using inherited level from active context
            should_emit = true;
        } else if (cfg.findScope(scope)) |level| {
            // Explicitly configured - we set the context
            current_context = TracingContext{ .scope = scope, .level = level };
            span.owns_context = true;
            should_emit = true;
        }

        if (should_emit) {
            trace_mutex.lock();
            defer trace_mutex.unlock();

            const stderr = std.io.getStdErr().writer();
            var indented = IndentedWriter(StderrWriter).init(stderr, depth);
            const writer = indented.writer();

            writer.writeAll("\x1b[1;34m") catch {}; // Bold blue for scope/operation
            writer.print("[{s}] BEGIN {s}", .{ scope, operation }) catch {};
            writer.writeAll("\x1b[0m\n") catch {}; // Reset color and add newline
        }

        depth += 1;
        return span;
    }

    pub fn deinit(self: *const Span) void {
        const cfg = getConfig();
        var should_emit = false;

        // Check if we should emit end message (same logic as init)
        if (current_context != null and !cfg.isDisabledScope(self.scope)) {
            should_emit = true;
        } else if (cfg.findScope(self.scope)) |_| {
            should_emit = true;
        }

        if (should_emit) {
            trace_mutex.lock();
            defer trace_mutex.unlock();

            const stderr = std.io.getStdErr().writer();
            var indented = IndentedWriter(StderrWriter).init(stderr, self.saved_depth);
            const writer = indented.writer();

            writer.writeAll("\x1b[1;34m") catch {}; // Bold blue for scope/operation
            writer.print("[{s}] END {s}", .{ self.scope, self.operation }) catch {};
            writer.writeAll("\x1b[0m\n") catch {}; // Reset color and add newline
        }

        // Clear context if we own it
        if (self.owns_context) {
            current_context = null;
        }

        depth = self.saved_depth;
    }

    pub inline fn child(self: *const Span, src: std.builtin.SourceLocation, operation: @Type(.enum_literal)) Span {
        _ = src; // Not used in regular tracing, only Tracy
        return Span.init(self.scope, @tagName(operation));
    }

    fn log(self: *const Span, level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        const cfg = getConfig();

        // Determine the active level for this scope
        var scope_level: LogLevel = undefined;
        if (current_context != null and !cfg.isDisabledScope(self.scope)) {
            // Use inherited level from active context
            scope_level = current_context.?.level;
        } else if (cfg.findScope(self.scope)) |found_level| {
            // Use explicitly configured level
            scope_level = found_level;
        } else {
            // Not active, don't log
            return;
        }

        if (@intFromEnum(level) < @intFromEnum(scope_level)) {
            return;
        }

        trace_mutex.lock();
        defer trace_mutex.unlock();

        const stderr = std.io.getStdErr().writer();
        var indented = IndentedWriter(StderrWriter).init(stderr, self.saved_depth);
        const writer = indented.writer();

        // Print with color: color code, then message with automatic indentation for multi-line
        writer.writeAll(level.color()) catch return;
        writer.print(fmt, args) catch return;
        writer.writeAll("\x1b[0m\n") catch return; // Reset color and add newline
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
