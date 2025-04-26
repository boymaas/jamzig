const std = @import("std");
const network = @import("network");

const shared = @import("jamsnp/shared_types.zig");
pub const ConnectionId = shared.ConnectionId;
pub const StreamId = shared.StreamId;
pub const StreamKind = shared.StreamKind;

pub const ServerThread = @import("server_thread.zig").ServerThread;

const common = @import("common.zig");
const CommandCallback = common.CommandCallback;
const CommandMetadata = common.CommandMetadata;

const trace = @import("../tracing.zig").scoped(.network);

/// Server API for the JamSnpServer
pub const Server = struct {
    thread: *ServerThread,
    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, thread: *ServerThread) !Server {
        return .{
            .thread = thread,
            .allocator = alloc,
        };
    }

    // StreamHandle API
    pub const StreamHandle = struct {
        thread: *ServerThread, // Need access to thread's mailbox
        stream_id: StreamId,
        connection_id: ConnectionId,

        pub fn sendData(self: *StreamHandle, data: []const u8) !void {
            const span = trace.span(.stream_send_data);
            defer span.deinit();

            span.debug("Stream {d}: Sending data ({d} bytes)", .{ self.stream_id, data.len });
            span.trace("Data: {any}", .{std.fmt.fmtSliceHexLower(data)});
            return self.sendDataWithCallback(data, null, null);
        }

        /// Send a message with length prefix to the stream.
        /// The message will be prefixed with a 4-byte little-endian u32 length.
        pub fn sendMessage(self: *StreamHandle, message: []const u8) !void {
            const span = trace.span(.stream_send_message);
            defer span.deinit();

            span.debug("Stream {d}: Sending message ({d} bytes)", .{ self.stream_id, message.len });
            span.trace("Message first bytes: {any}", .{std.fmt.fmtSliceHexLower(if (message.len > 16) message[0..16] else message)});
            return self.sendMessageWithCallback(message, null, null);
        }

        // The data is owned and the responsibility of the caller
        pub fn sendDataWithCallback(
            self: *StreamHandle,
            data: []const u8,
            callback: ?CommandCallback(anyerror!void),
            context: ?*anyopaque,
        ) !void {
            const command = ServerThread.Command{
                .send_data = .{
                    .data = .{
                        .connection_id = self.connection_id,
                        .stream_id = self.stream_id,
                        .data = data,
                    },
                    .metadata = .{ .callback = callback, .context = context },
                },
            };
            _ = self.thread.mailbox.push(command, .{ .instant = {} });
            try self.thread.wakeup.notify();
        }

        /// Send a message with length prefix to the stream with a callback.
        /// The message will be prefixed with a 4-byte little-endian u32 length.
        pub fn sendMessageWithCallback(
            self: *StreamHandle,
            message: []const u8,
            callback: ?CommandCallback(anyerror!void),
            context: ?*anyopaque,
        ) !void {
            const command = ServerThread.Command{
                .send_message = .{
                    .data = .{
                        .connection_id = self.connection_id,
                        .stream_id = self.stream_id,
                        .message = message,
                    },
                    .metadata = .{ .callback = callback, .context = context },
                },
            };
            _ = self.thread.mailbox.push(command, .{ .instant = {} });
            try self.thread.wakeup.notify();
        }

        pub fn wantRead(self: *StreamHandle, want: bool) !void {
            const span = trace.span(.stream_want_read_api);
            defer span.deinit();

            span.debug("Stream {d}: Setting wantRead={}", .{ self.stream_id, want });
            return self.wantReadWithCallback(want, null, null);
        }

        pub fn wantReadWithCallback(
            self: *StreamHandle,
            want: bool,
            callback: ?CommandCallback(anyerror!void),
            context: ?*anyopaque,
        ) !void {
            const command = ServerThread.Command{ .stream_want_read = .{
                .data = .{ .connection_id = self.connection_id, .stream_id = self.stream_id, .want = want },
                .metadata = .{ .callback = callback, .context = context },
            } };
            _ = self.thread.mailbox.push(command, .{ .instant = {} });
            try self.thread.wakeup.notify();
        }

        pub fn wantWrite(self: *StreamHandle, want: bool) !void {
            const span = trace.span(.stream_want_write_api);
            defer span.deinit();

            span.debug("Stream {d}: Setting wantWrite={}", .{ self.stream_id, want });
            return self.wantWriteWithCallback(want, null, null);
        }

        pub fn wantWriteWithCallback(
            self: *StreamHandle,
            want: bool,
            callback: ?CommandCallback(anyerror!void),
            context: ?*anyopaque,
        ) !void {
            const command = ServerThread.Command{ .stream_want_write = .{
                .data = .{ .connection_id = self.connection_id, .stream_id = self.stream_id, .want = want },
                .metadata = .{ .callback = callback, .context = context },
            } };
            _ = self.thread.mailbox.push(command, .{ .instant = {} });
            try self.thread.wakeup.notify();
        }

        pub fn flush(self: *StreamHandle) !void {
            const span = trace.span(.stream_flush_api);
            defer span.deinit();

            span.debug("Stream {d}: Flushing", .{self.stream_id});
            return self.flushWithCallback(null, null);
        }

        pub fn flushWithCallback(
            self: *StreamHandle,
            callback: ?CommandCallback(anyerror!void),
            context: ?*anyopaque,
        ) !void {
            const command = ServerThread.Command{ .stream_flush = .{
                .data = .{ .connection_id = self.connection_id, .stream_id = self.stream_id },
                .metadata = .{ .callback = callback, .context = context },
            } };
            _ = self.thread.mailbox.push(command, .{ .instant = {} });
            try self.thread.wakeup.notify();
        }

        pub fn shutdown(self: *StreamHandle, how: c_int) !void {
            const span = trace.span(.stream_shutdown_api);
            defer span.deinit();

            span.debug("Stream {d}: Shutting down (how={d})", .{ self.stream_id, how });
            return self.shutdownWithCallback(how, null, null);
        }

        pub fn shutdownWithCallback(
            self: *StreamHandle,
            how: c_int,
            callback: ?CommandCallback(anyerror!void),
            context: ?*anyopaque,
        ) !void {
            const command = ServerThread.Command{ .stream_shutdown = .{
                .data = .{ .connection_id = self.connection_id, .stream_id = self.stream_id, .how = how },
                .metadata = .{ .callback = callback, .context = context },
            } };
            _ = self.thread.mailbox.push(command, .{ .instant = {} });
            try self.thread.wakeup.notify();
        }

        pub fn close(self: *StreamHandle) !void {
            const span = trace.span(.stream_close_api);
            defer span.deinit();

            span.debug("Stream {d}: Closing", .{self.stream_id});
            return self.closeWithCallback(null, null);
        }

        pub fn closeWithCallback(
            self: *StreamHandle,
            callback: ?CommandCallback(anyerror!void),
            context: ?*anyopaque,
        ) !void {
            const command = ServerThread.Command{ .destroy_stream = .{
                .data = .{ .connection_id = self.connection_id, .stream_id = self.stream_id },
                .metadata = .{ .callback = callback, .context = context },
            } };
            _ = self.thread.mailbox.push(command, .{ .instant = {} });
            try self.thread.wakeup.notify();
        }
    };

    pub const Event = union(enum) {
        pub fn Result(T: type) type {
            return struct {
                result: T,
                metadata: CommandMetadata(T),

                pub fn invokeCallback(self: *const Result(T)) void {
                    self.metadata.callWithResult(self.result);
                }
            };
        }

        // -- Server events
        listening: struct {
            local_endpoint: network.EndPoint,
            result: Result(anyerror!network.EndPoint),
        },

        // -- Connection events
        client_connected: struct {
            connection_id: ConnectionId,
            peer_endpoint: network.EndPoint,
        },
        client_disconnected: struct {
            connection_id: ConnectionId,
        },

        // -- Streams
        stream_created_by_client: struct {
            connection_id: ConnectionId,
            stream_id: StreamId,
            kind: StreamKind,
        },
        stream_created_by_server: struct {
            connection_id: ConnectionId,
            stream_id: StreamId,
        },
        stream_closed: struct {
            connection_id: ConnectionId,
            stream_id: StreamId,
        },

        // -- Data events
        data_received: struct {
            connection_id: ConnectionId,
            stream_id: StreamId,
            data: []const u8, // owned by original caller
        },
        data_write_completed: struct {
            connection_id: ConnectionId,
            stream_id: StreamId,
            total_bytes_written: usize,
        },
        message_received: struct {
            connection_id: ConnectionId,
            stream_id: StreamId,
            message: []const u8, // Complete message, owned by event
        },
        data_read_error: struct {
            connection_id: ConnectionId,
            stream_id: StreamId,
            error_code: i32,
        },
        data_write_error: struct {
            connection_id: ConnectionId,
            stream_id: StreamId,
            error_code: i32,
        },
        data_read_would_block: struct {
            connection_id: ConnectionId,
            stream_id: StreamId,
        },
        data_write_would_block: struct {
            connection_id: ConnectionId,
            stream_id: StreamId,
        },
        @"error": struct {
            message: []const u8,
            details: ?anyerror,
        },

        pub fn invokeCallback(self: Event) void {
            const span = trace.span(.invoke_event_callback);
            defer span.deinit();

            span.debug("Invoking callback for event: {s}", .{@tagName(self)});
            switch (self) {
                .listening => |e| e.result.invokeCallback(),
                else => {
                    span.err("Event callback not implemented for this event type", .{});
                    @panic("Event callback not implemented for this event type");
                },
            }
        }

        pub fn deinit(self: *Event, alloc: std.mem.Allocator) void {
            const span = trace.span(.deinit_event);
            defer span.deinit();

            switch (self.*) {
                .message_received => |e| {
                    // Free the message buffer if it was allocated
                    if (e.message.len > 0) {
                        alloc.free(e.message);
                    }
                },
                else => {},
            }
            self.* = undefined;
        }
    };

    // --- API Methods ---

    pub fn listen(self: *Server, address: []const u8, port: u16) !void {
        const span = trace.span(.listen);
        defer span.deinit();

        span.debug("Starting server listen on {s}:{d}", .{ address, port });
        return self.listenWithCallback(address, port, null, null);
    }

    pub fn listenWithCallback(
        self: *Server,
        address: []const u8,
        port: u16,
        callback: ?CommandCallback(anyerror!network.EndPoint),
        context: ?*anyopaque,
    ) !void {
        const span = trace.span(.listen_with_callback);
        defer span.deinit();

        span.debug("Starting server listen with callback on {s}:{d}", .{ address, port });
        const command = ServerThread.Command{ .listen = .{
            .data = .{ .address = address, .port = port },
            .metadata = .{ .callback = callback, .context = context },
        } };
        try self.pushCommand(command);
    }

    pub fn disconnectClient(self: *Server, connection_id: ConnectionId) !void {
        const span = trace.span(.disconnect_client_api);
        defer span.deinit();

        span.debug("API: Disconnecting client: {}", .{connection_id});
        return self.disconnectClientWithCallback(connection_id, null, null);
    }

    pub fn disconnectClientWithCallback(
        self: *Server,
        connection_id: ConnectionId,
        callback: ?CommandCallback(anyerror!void),
        context: ?*anyopaque,
    ) !void {
        const span = trace.span(.disconnect_client_with_callback);
        defer span.deinit();

        span.debug("API: Disconnecting client with callback: {}", .{connection_id});
        const command = ServerThread.Command{ .disconnect_client = .{
            .data = .{ .connection_id = connection_id },
            .metadata = .{ .callback = callback, .context = context },
        } };
        try self.pushCommand(command);
    }

    /// Server initiates a stream to a client
    pub fn createStream(self: *Server, connection_id: ConnectionId) !void {
        const span = trace.span(.create_stream_api);
        defer span.deinit();

        span.debug("API: Creating stream for connection: {}", .{connection_id});
        return self.createStreamWithCallback(connection_id, null, null);
    }

    /// Server initiates a stream to a client with callback
    pub fn createStreamWithCallback(
        self: *Server,
        connection_id: ConnectionId,
        // Callback result is StreamId on success, but delivered via event.
        // Command result should likely be anyerror!void here.
        callback: ?CommandCallback(anyerror!StreamId), // Change T to anyerror!void?
        context: ?*anyopaque,
    ) !void {
        const span = trace.span(.create_stream_with_callback);
        defer span.deinit();

        span.debug("API: Creating stream with callback for connection: {}", .{connection_id});
        const command = ServerThread.Command{ .create_stream = .{
            .data = .{ .connection_id = connection_id },
            .metadata = .{ .callback = callback, .context = context },
        } };
        try self.pushCommand(command);
    }

    pub fn shutdown(self: *Server) !void {
        const span = trace.span(.server_shutdown);
        defer span.deinit();

        span.debug("API: Server shutdown requested", .{});
        try self.thread.shutdown();
    }

    pub fn pushCommand(self: *Server, command: ServerThread.Command) !void {
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

    /// Tries to pop an event from the event queue without blocking.
    pub fn pollEvent(self: *Server) ?Event {
        const span = trace.span(.poll_event);
        defer span.deinit();

        const event = self.thread.event_queue.pop();
        if (event) |e| {
            span.debug("Polled event: {s}", .{@tagName(e)});
        } else {
            span.debug("No event available", .{});
        }
        return event;
    }

    /// Pops an event from the event queue, blocking until one is available.
    pub fn waitEvent(self: *Server) Event {
        const span = trace.span(.wait_event);
        defer span.deinit();

        span.debug("Waiting for event", .{});
        const event = self.thread.event_queue.blockingPop();
        span.debug("Received event: {s}", .{@tagName(event)});
        return event;
    }

    /// Pops an event from the event queue, blocking until one is available or timeout occurs.
    pub fn timedWaitEvent(self: *Server, timeout_ms: u64) ?Event {
        const span = trace.span(.timed_wait_event);
        defer span.deinit();

        span.debug("Waiting for event with timeout: {d}ms", .{timeout_ms});
        const event = self.thread.event_queue.timedBlockingPop(timeout_ms);
        if (event) |e| {
            span.debug("Received event: {s}", .{@tagName(e)});
        } else {
            span.debug("Timeout waiting for event", .{});
        }
        return event;
    }
};
