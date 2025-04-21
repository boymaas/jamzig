const std = @import("std");
const lsquic = @import("lsquic");

const client = @import("../client.zig"); // Need ClientThread, Client
const shared = @import("../jamsnp/shared_types.zig");

const ClientThread = client.ClientThread;
const Client = client.Client;
const ConnectionId = shared.ConnectionId;
const StreamId = shared.StreamId;
const CommandCallback = client.CommandCallback;

// StreamHandle provides the user-facing API for interacting with a client stream.
// It sends commands to the ClientThread for actual execution.
pub const StreamHandle = struct {
    thread: *ClientThread,
    stream_id: StreamId,
    connection_id: ConnectionId,
    is_readable: bool = false, // State managed by events, not directly here
    is_writable: bool = false, // State managed by events, not directly here

    pub fn sendData(self: *StreamHandle, data: []const u8) !void {
        return self.sendDataWithCallback(data, null, null);
    }

    pub fn sendDataWithCallback(
        self: *StreamHandle,
        data: []const u8,
        callback: ?CommandCallback(void),
        context: ?*anyopaque,
    ) !void {
        const command = ClientThread.Command{ .send_data = .{
            .data = .{
                .connection_id = self.connection_id,
                .stream_id = self.stream_id,
                .data = data,
            },
            .metadata = .{
                .callback = callback, // Use provided or null
                .context = context,
            },
        } };

        _ = self.thread.mailbox.push(command, .{ .instant = {} });
        try self.thread.wakeup.notify();
    }

    pub fn wantRead(self: *StreamHandle, want: bool) !void {
        return self.wantReadWithCallback(want, null, null);
    }

    pub fn wantReadWithCallback(
        self: *StreamHandle,
        want: bool,
        callback: ?CommandCallback(void),
        context: ?*anyopaque,
    ) !void {
        const command = ClientThread.Command{ .stream_want_read = .{
            .data = .{
                .connection_id = self.connection_id,
                .stream_id = self.stream_id,
                .want = want,
            },
            .metadata = .{
                .callback = callback,
                .context = context,
            },
        } };

        _ = self.thread.mailbox.push(command, .{ .instant = {} });
        try self.thread.wakeup.notify();
    }

    pub fn wantWrite(self: *StreamHandle, want: bool) !void {
        return self.wantWriteWithCallback(want, null, null);
    }

    pub fn wantWriteWithCallback(
        self: *StreamHandle,
        want: bool,
        callback: ?CommandCallback(void),
        context: ?*anyopaque,
    ) !void {
        const command = ClientThread.Command{ .stream_want_write = .{
            .data = .{
                .connection_id = self.connection_id,
                .stream_id = self.stream_id,
                .want = want,
            },
            .metadata = .{
                .callback = callback,
                .context = context,
            },
        } };

        _ = self.thread.mailbox.push(command, .{ .instant = {} });
        try self.thread.wakeup.notify();
    }

    pub fn flush(self: *StreamHandle) !void {
        return self.flushWithCallback(null, null);
    }

    pub fn flushWithCallback(
        self: *StreamHandle,
        callback: ?CommandCallback(void),
        context: ?*anyopaque,
    ) !void {
        const command = ClientThread.Command{ .stream_flush = .{
            .data = .{
                .connection_id = self.connection_id,
                .stream_id = self.stream_id,
            },
            .metadata = .{
                .callback = callback,
                .context = context,
            },
        } };

        _ = self.thread.mailbox.push(command, .{ .instant = {} });
        try self.thread.wakeup.notify();
    }

    pub fn shutdown(self: *StreamHandle, how: c_int) !void {
        return self.shutdownWithCallback(how, null, null);
    }

    pub fn shutdownWithCallback(
        self: *StreamHandle,
        how: c_int,
        callback: ?CommandCallback(void),
        context: ?*anyopaque,
    ) !void {
        const command = ClientThread.Command{ .stream_shutdown = .{
            .data = .{
                .connection_id = self.connection_id,
                .stream_id = self.stream_id,
                .how = how,
            },
            .metadata = .{
                .callback = callback,
                .context = context,
            },
        } };

        _ = self.thread.mailbox.push(command, .{ .instant = {} });
        try self.thread.wakeup.notify();
    }

    pub fn close(self: *StreamHandle) !void {
        return self.closeWithCallback(null, null);
    }

    pub fn closeWithCallback(
        self: *StreamHandle,
        callback: ?CommandCallback(void),
        context: ?*anyopaque,
    ) !void {
        const command = ClientThread.Command{ .destroy_stream = .{
            .data = .{
                .connection_id = self.connection_id,
                .stream_id = self.stream_id,
            },
            .metadata = .{
                .callback = callback,
                .context = context,
            },
        } };

        _ = self.thread.mailbox.push(command, .{ .instant = {} });
        try self.thread.wakeup.notify();
    }
};
