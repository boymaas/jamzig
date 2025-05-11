//! Implementation of the ClientThread and Client. The design is
//! straightforward: the ClientThread is equipped with a mailbox capable of
//! receiving commands asynchronously. Upon execution of a command by the
//! JamSnpClient, an event is generated that associates the invocation with its
//! corresponding result.

const std = @import("std");
const uuid = @import("uuid");
const network = @import("network");

pub const ClientThread = @import("client_thread.zig").ClientThread;

const shared = @import("jamsnp/shared_types.zig");
pub const ConnectionId = shared.ConnectionId;
pub const StreamId = shared.StreamId;
pub const StreamKind = shared.StreamKind;
pub const StreamHandle = @import("stream_handle.zig").StreamHandle;

const common = @import("common.zig");
const CommandCallback = common.CommandCallback;
const CommandMetadata = common.CommandMetadata;

const Mailbox = @import("../datastruct/blocking_queue.zig").BlockingQueue;

const trace = @import("../tracing.zig").scoped(.network);

/// Client API for the JamSnpClient
pub const Client = struct {
    thread: *ClientThread,

    pub const Event = @import("common.zig").Event;

    pub fn init(thread: *ClientThread) Client {
        return .{
            .thread = thread,
        };
    }

    // Connect to a remote endpoint
    pub fn connect(self: *Client, endpoint: network.EndPoint) !void {
        return self.connectWithCallback(endpoint, null, null);
    }

    // Connect with callback for completion notification
    pub fn connectWithCallback(
        self: *Client,
        endpoint: network.EndPoint,
        callback: ?CommandCallback(anyerror!ConnectionId),
        context: ?*anyopaque,
    ) !void {
        const span = trace.span(.connect_with_callback);
        defer span.deinit();
        span.debug("Connect requested to endpoint: {}", .{endpoint});

        // Generate ConnectionId here
        const connection_id = uuid.v4.new();

        const command = ClientThread.Command{
            .connect = .{
                .data = .{
                    .endpoint = endpoint,
                    .connection_id = connection_id,
                },
                .metadata = .{
                    .callback = callback,
                    .context = context,
                },
            },
        };
        try self.pushCommand(command);
    }

    // Disconnect assumes JamSnpClient/Connection implements it
    pub fn disconnect(self: *Client, connection_id: ConnectionId) !void {
        return self.disconnectWithCallback(connection_id, null, null);
    }

    pub fn disconnectWithCallback(
        self: *Client,
        connection_id: ConnectionId,
        callback: ?CommandCallback(anyerror!void),
        context: ?*anyopaque,
    ) !void {
        const command = ClientThread.Command{ .disconnect = .{
            .data = .{
                .connection_id = connection_id,
            },
            .metadata = .{
                .callback = callback,
                .context = context,
            },
        } };
        self.pushCommand(command);
    }

    // CreateStream assumes JamSnpClient/Connection implements it
    pub fn createStream(self: *Client, connection_id: ConnectionId, kind: StreamKind) !void {
        return self.createStreamWithCallback(connection_id, kind, null, null);
    }

    pub fn createStreamWithCallback(
        self: *Client,
        connection_id: ConnectionId,
        kind: StreamKind,
        callback: ?CommandCallback(anyerror!StreamId), // Callback returns StreamId
        context: ?*anyopaque,
    ) !void {
        const span = trace.span(.create_stream_with_callback);
        defer span.deinit();
        span.debug("Create stream requested on connection: {}", .{connection_id});

        const command = ClientThread.Command{ .create_stream = .{
            .data = .{
                .connection_id = connection_id,
                .kind = kind,
            },
            .metadata = .{
                .callback = callback,
                .context = context,
            },
        } };
        try self.pushCommand(command);
    }

    // DestroyStream uses StreamHandle
    pub fn destroyStream(self: *Client, stream: StreamHandle) !void {
        return self.destroyStreamWithCallback(stream, null, null);
    }

    pub fn destroyStreamWithCallback(
        self: *Client,
        stream: StreamHandle,
        callback: ?CommandCallback(anyerror!void),
        context: ?*anyopaque,
    ) !void {
        const span = trace.span(.destroy_stream_with_callback);
        defer span.deinit();
        span.debug("Destroy stream requested: connection={} stream={}", .{ stream.connection_id, stream.stream_id });

        const command = ClientThread.Command{ .destroy_stream = .{
            .data = .{
                .connection_id = stream.connection_id,
                .stream_id = stream.stream_id,
            },
            .metadata = .{
                .callback = callback,
                .context = context,
            },
        } };
        self.pushCommand(command);
    }

    pub fn pushCommand(self: *Client, command: ClientThread.Command) !void {
        const span = trace.span(.push_command);
        defer span.deinit();
        span.debug("Pushing command: {s}", .{@tagName(command)});

        if (self.thread.mailbox.push(command, .instant) == 0) {
            span.err("Mailbox full, cannot queue command", .{});
            return error.MailboxFull;
        }

        span.debug("Command pushed successfully", .{});
        try self.thread.wakeup.notify();
    }

    // --- Client API Methods ---

    pub fn shutdown(self: *Client) !void {
        const span = trace.span(.client_shutdown);
        defer span.deinit();
        span.debug("Shutting down client", .{});

        // Notify the thread to stop
        try self.thread.stop.notify();
    }

    /// Tries to pop an event from the event queue without blocking.
    /// Returns null if the queue is empty.
    pub fn pollEvent(self: *Client) ?Event {
        return self.thread.event_queue.pop();
    }

    /// Pops an event from the event queue, blocking until one is available.
    pub fn waitEvent(self: *Client) Event {
        return self.thread.event_queue.blockingPop();
    }

    /// Pops an event from the event queue, blocking until one is available
    /// or the timeout (in milliseconds) occurs. Returns null on timeout.
    pub fn timedWaitEvent(self: *Client, timeout_ms: u64) ?Event {
        return self.thread.event_queue.timedBlockingPop(timeout_ms);
    }
};
