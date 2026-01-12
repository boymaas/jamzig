const std = @import("std");
const build_options = @import("build_options");

pub const LogLevel = enum(u8) {
    trace = 0,
    debug = 1,
    info = 2,
    warn = 3,
    err = 4,

    pub fn color(self: LogLevel) []const u8 {
        return switch (self) {
            .trace => "\x1b[90m", // Gray
            .debug => "\x1b[36m", // Cyan
            .info => "\x1b[32m", // Green
            .warn => "\x1b[33m", // Yellow
            .err => "\x1b[31m", // Red
        };
    }

    pub fn name(self: LogLevel) []const u8 {
        return switch (self) {
            .trace => "TRACE",
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }

    pub fn fromString(level_str: []const u8) !LogLevel {
        if (std.mem.eql(u8, level_str, "trace")) return .trace;
        if (std.mem.eql(u8, level_str, "debug")) return .debug;
        if (std.mem.eql(u8, level_str, "info")) return .info;
        if (std.mem.eql(u8, level_str, "warn")) return .warn;
        if (std.mem.eql(u8, level_str, "err")) return .err;
        return error.InvalidLogLevel;
    }
};

pub const Scope = []const u8;

pub const Config = struct {
    allocator: std.mem.Allocator,
    scopes: std.StringHashMap(LogLevel),
    default_level: LogLevel,
    disabled_scopes: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator) Config {
        const scopes_str = if (@hasDecl(build_options, "enable_tracing_scopes"))
            build_options.enable_tracing_scopes
        else
            &[_][]const u8{};

        const disabled_scopes = if (@hasDecl(build_options, "disabled_tracing_scopes"))
            build_options.disabled_tracing_scopes
        else
            &[_][]const u8{};

        std.debug.print("Disabled scopes: {any}", .{disabled_scopes});

        const level_str = if (@hasDecl(build_options, "enable_tracing_level") and build_options.enable_tracing_level.len > 0)
            build_options.enable_tracing_level
        else
            "info";

        var config = Config{
            .allocator = allocator,
            .scopes = std.StringHashMap(LogLevel).init(allocator),
            .default_level = parseLogLevel(level_str),
            .disabled_scopes = std.StringHashMap(void).init(allocator),
        };

        for (disabled_scopes) |disabled_scope| {
            config.disabled_scopes.put(disabled_scope, {}) catch |err| {
                std.debug.print("Warning: Failed to add disabled scope '{s}': {}\n", .{ disabled_scope, err });
            };
        }

        for (scopes_str) |scope_config| {
            config.parseAndSetScope(scope_config) catch |err| {
                std.debug.print("Warning: Failed to parse scope config '{s}': {}\n", .{ scope_config, err });
            };
        }

        return config;
    }

    pub fn deinit(self: *Config) void {
        self.scopes.deinit();
        self.disabled_scopes.deinit();
    }

    fn parseAndSetScope(self: *Config, scope_config: []const u8) !void {
        var it = std.mem.tokenizeScalar(u8, scope_config, ',');
        while (it.next()) |single_scope| {
            const trimmed = std.mem.trim(u8, single_scope, " \t");

            if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                const scope_name = trimmed[0..eq_pos];
                const level_name = trimmed[eq_pos + 1 ..];

                const level = parseLogLevel(level_name);
                try self.scopes.put(scope_name, level);
            } else {
                try self.scopes.put(trimmed, .debug);
            }
        }
    }

    fn parseLogLevel(level_str: []const u8) LogLevel {
        return LogLevel.fromString(level_str) catch .info; // Default fallback on error
    }

    pub fn getLevel(self: *const Config, scope: Scope) LogLevel {
        return self.scopes.get(scope) orelse self.default_level;
    }

    pub fn setScope(self: *Config, scope: Scope, level: LogLevel) !void {
        try self.scopes.put(scope, level);
    }

    pub fn setDefaultLevel(self: *Config, level: LogLevel) void {
        self.default_level = level;
    }

    pub fn reset(self: *Config) void {
        self.scopes.clearRetainingCapacity();
        self.disabled_scopes.clearRetainingCapacity();
        self.default_level = .info;
    }

    pub fn disableScope(self: *Config, scope: Scope) void {
        _ = self.scopes.remove(scope);
    }

    pub fn findScope(self: *const Config, scope: Scope) ?LogLevel {
        return self.scopes.get(scope);
    }

    pub fn isActive(self: *const Config, scope: Scope, level: LogLevel) bool {
        const scope_level = self.getLevel(scope);
        return @intFromEnum(level) >= @intFromEnum(scope_level);
    }

    pub fn isDisabledScope(self: *const Config, scope: Scope) bool {
        return self.disabled_scopes.contains(scope);
    }

    pub fn fromBuildOptions(options: []const u8) Config {
        _ = options;
        @panic("fromBuildOptions deprecated - use init() instead");
    }
};
