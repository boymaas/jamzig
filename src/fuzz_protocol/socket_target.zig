const std = @import("std");
const net = std.net;
const messages = @import("messages.zig");
const frame = @import("frame.zig");
const target_interface = @import("target_interface.zig");

const trace = @import("tracing").scoped(.fuzz_protocol);

/// Socket-based target that communicates with external processes via Unix domain sockets
pub const SocketTarget = struct {
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    socket: ?net.Stream = null,

    pub const Config = struct {
        socket_path: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !SocketTarget {
        return SocketTarget{
            .allocator = allocator,
            .socket_path = config.socket_path,
        };
    }

    pub fn deinit(self: *SocketTarget) void {
        self.disconnect();
        self.* = undefined;
    }

    /// Connect to the target socket
    pub fn connectToTarget(self: *SocketTarget) !void {
        const span = trace.span(@src(), .connect_target);
        defer span.deinit();
        span.debug("Connecting to target socket: {s}", .{self.socket_path});

        self.socket = try std.net.connectUnixSocket(self.socket_path);
        span.debug("Connected to target successfully", .{});
    }

    /// Disconnect from target
    pub fn disconnect(self: *SocketTarget) void {
        const span = trace.span(@src(), .disconnect_target);
        defer span.deinit();

        if (self.socket) |socket| {
            socket.close();
            self.socket = null;
            span.debug("Disconnected from target", .{});
        }
    }

    /// Send message to target via socket
    pub fn sendMessage(self: *SocketTarget, comptime params: @import("../jam_params.zig").Params, message: messages.Message) !void {
        const socket = self.socket orelse return error.NotConnected;
        const encoded = try messages.encodeMessage(params, self.allocator, message);
        defer self.allocator.free(encoded);
        try frame.writeFrame(socket, encoded);
    }

    /// Read response message from target via socket
    pub fn readMessage(self: *SocketTarget, comptime params: @import("../jam_params.zig").Params) !messages.Message {
        const socket = self.socket orelse return error.NotConnected;
        const frame_data = try frame.readFrame(self.allocator, socket);
        defer self.allocator.free(frame_data);
        return messages.decodeMessage(params, self.allocator, frame_data);
    }
};

// Compile-time validation that SocketTarget implements the target interface
comptime {
    target_interface.validateTargetInterface(SocketTarget);
}