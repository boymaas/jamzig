const std = @import("std");
const net = std.net;
const target = @import("target.zig");
const messages = @import("messages.zig");
const frame = @import("frame.zig");

const trace = @import("../tracing.zig").scoped(.fuzz_protocol);
const RestartBehavior = target.RestartBehavior;

/// Thread context for target server
const ThreadContext = struct {
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    restart_behavior: RestartBehavior,
};

/// Manages the lifecycle of target server instances for fuzzing
pub const FuzzTargetInThread = struct {
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    target_thread: ?std.Thread = null,
    restart_behavior: RestartBehavior = .restart_on_disconnect,

    const Self = @This();

    /// Initialize target manager with socket path
    pub fn init(allocator: std.mem.Allocator, socket_path: []const u8, restart_behavior: RestartBehavior) Self {
        return Self{
            .allocator = allocator,
            .socket_path = socket_path,
            .restart_behavior = restart_behavior,
        };
    }

    /// Clean up target manager resources
    pub fn join(self: *Self) void {
        if (self.target_thread) |thread| {
            const span = trace.span(.target_manager_stop);
            defer span.deinit();
            
            thread.join();
            self.target_thread = null;

            span.debug("Target server stopped", .{});
        }
    }

    /// Start target server in background thread
    pub fn start(self: *Self) !void {
        const span = trace.span(.target_manager_start);
        defer span.deinit();
        span.debug("Starting target server at: {s}", .{self.socket_path});

        if (self.target_thread != null) {
            return error.TargetAlreadyStarted;
        }

        // Create thread context for target
        const context = try self.allocator.create(ThreadContext);
        context.* = .{
            .allocator = self.allocator,
            .socket_path = self.socket_path,
            .restart_behavior = self.restart_behavior,
        };

        // Start target thread
        self.target_thread = try std.Thread.spawn(.{}, targetThreadMain, .{context});
        span.debug("Target server thread started", .{});
    }

    /// Check if target is currently running
    pub fn isRunning(self: *const Self) bool {
        return self.target_thread != null;
    }

    /// Target thread main function
    fn targetThreadMain(context: *const ThreadContext) void {
        defer context.allocator.destroy(context);

        var target_server = target.TargetServer.init(context.allocator, context.socket_path, context.restart_behavior) catch |err| {
            std.log.err("Failed to initialize target server: {s}", .{@errorName(err)});
            return;
        };
        defer target_server.deinit();

        target_server.start() catch |err| {
            std.log.err("Target server error: {s}", .{@errorName(err)});
        };
    }
};
