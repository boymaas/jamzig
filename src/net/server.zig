//! Implementation of the ServerThread and Server, symmetrical to the client.
//! The ServerThread manages the JamSnpServer and processes commands via a mailbox,
//! generating events for the application.

const std = @import("std");
const xev = @import("xev");
const network = @import("network");

const posix = std.posix;

const shared = @import("jamsnp/shared_types.zig");

const ConnectionId = shared.ConnectionId;
const StreamId = shared.StreamId;
const JamSnpServer = @import("jamsnp/server.zig").JamSnpServer;
const ServerConnection = @import("jamsnp/connection.zig").Connection(JamSnpServer);
const ServerStream = @import("jamsnp/stream.zig").Stream(JamSnpServer);

const Mailbox = @import("../datastruct/blocking_queue.zig").BlockingQueue;

/// Builder for creating a ServerThread instance.
/// Ensures that the underlying JamSnpServer is also initialized.
pub const ServerThreadBuilder = struct {
    _alloc: ?std.mem.Allocator = null,
    _genesis_hash: ?[]const u8 = null,
    _key_pair: ?std.crypto.sign.Ed25519.KeyPair = null,
    _allow_builders: ?bool = false,

    pub fn init() ServerThreadBuilder {
        return .{};
    }

    pub fn allocator(self: *ServerThreadBuilder, alloc: std.mem.Allocator) *ServerThreadBuilder {
        self._alloc = alloc;
        return self;
    }

    pub fn genesisHash(self: *ServerThreadBuilder, genesis_hash: []const u8) *ServerThreadBuilder {
        self._genesis_hash = genesis_hash;
        return self;
    }

    pub fn keypair(self: *ServerThreadBuilder, key_pair: std.crypto.sign.Ed25519.KeyPair) *ServerThreadBuilder {
        self._key_pair = key_pair;
        return self;
    }

    pub fn allowBuilders(self: *ServerThreadBuilder, allow_builders: bool) *ServerThreadBuilder {
        self._allow_builders = allow_builders;
        return self;
    }

    /// Builds the ServerThread.
    pub fn build(self: *const ServerThreadBuilder) !*ServerThread {
        const alloc = self._alloc orelse return error.AllocatorNotSet;
        const genesis_hash = self._genesis_hash orelse return error.GenesisHashNotSet;
        const key_pair = self._key_pair orelse return error.KeyPairNotSet;
        const allow_builders = self._allow_builders orelse return error.AllowBuildersNotSet;

        var jserver = try JamSnpServer.initWithoutLoop(alloc, key_pair, genesis_hash, allow_builders);
        errdefer jserver.deinit();

        return ServerThread.init(alloc, jserver);
    }
};

pub fn CommandCallback(T: type) type {
    return *const fn (result: T, context: ?*anyopaque) void;
}

pub fn CommandMetadata(T: type) type {
    return struct {
        callback: ?CommandCallback(T) = null,
        context: ?*anyopaque = null,

        pub fn callWithResult(self: *const CommandMetadata(T), result: T) void {
            std.debug.print("Command callback invoked with result: {}\n", .{@TypeOf(result)});
            if (self.callback) |callback| {
                callback(result, self.context);
            }
        }
    };
}

pub const ServerThread = struct {
    alloc: std.mem.Allocator,
    server: *JamSnpServer,
    loop: xev.Loop,

    wakeup: xev.Async,
    wakeup_c: xev.Completion = .{},

    stop: xev.Async,
    stop_c: xev.Completion = .{},

    mailbox: *Mailbox(Command, 64),
    event_queue: *Mailbox(Server.Event, 64),

    pub const Command = union(enum) {
        pub const Listen = struct {
            const Data = struct {
                address: []const u8,
                port: u16,
            };
            data: Data,
            metadata: CommandMetadata(anyerror!network.EndPoint),
        };
        pub const DisconnectClient = struct {
            const Data = struct {
                connection_id: ConnectionId,
            };
            data: Data,
            metadata: CommandMetadata(anyerror!void),
        };
        // Server initiating a stream TO a client
        pub const CreateStream = struct {
            const Data = struct {
                connection_id: ConnectionId,
            };
            data: Data,
            metadata: CommandMetadata(anyerror!void),
        };
        pub const DestroyStream = struct {
            const Data = struct {
                connection_id: ConnectionId,
                stream_id: StreamId,
            };
            data: Data,
            metadata: CommandMetadata(anyerror!void),
        };
        pub const SendData = struct {
            const Data = struct {
                connection_id: ConnectionId,
                stream_id: StreamId,
                data: []const u8,
            };
            data: Data,
            metadata: CommandMetadata(anyerror!void),
        };
        pub const StreamWantRead = struct {
            const Data = struct {
                connection_id: ConnectionId,
                stream_id: StreamId,
                want: bool,
            };
            data: Data,
            metadata: CommandMetadata(anyerror!void),
        };
        pub const StreamWantWrite = struct {
            const Data = struct {
                connection_id: ConnectionId,
                stream_id: StreamId,
                want: bool,
            };
            data: Data,
            metadata: CommandMetadata(anyerror!void),
        };
        pub const StreamFlush = struct {
            const Data = struct {
                connection_id: ConnectionId,
                stream_id: StreamId,
            };
            data: Data,
            metadata: CommandMetadata(anyerror!void),
        };
        pub const StreamShutdown = struct {
            const Data = struct {
                connection_id: ConnectionId,
                stream_id: StreamId,
                how: c_int, // 0=read, 1=write, 2=both
            };
            data: Data,
            metadata: CommandMetadata(anyerror!void),
        };

        listen: Listen,
        disconnect_client: DisconnectClient,
        create_stream: CreateStream,
        destroy_stream: DestroyStream,
        send_data: SendData,
        stream_want_read: StreamWantRead,
        stream_want_write: StreamWantWrite,
        stream_flush: StreamFlush,
        stream_shutdown: StreamShutdown,
    };

    /// Initializes the ServerThread with an existing JamSnpServer instance.
    /// Called by the ServerThreadBuilder.
    pub fn init(alloc: std.mem.Allocator, server_instance: *JamSnpServer) !*ServerThread {
        var thread = try alloc.create(ServerThread);
        errdefer alloc.destroy(thread); // Only destroy thread struct if init fails

        thread.loop = try xev.Loop.init(.{});
        errdefer thread.loop.deinit();

        thread.wakeup = try xev.Async.init();
        errdefer thread.wakeup.deinit();

        thread.stop = try xev.Async.init();
        errdefer thread.stop.deinit();

        thread.mailbox = try Mailbox(Command, 64).create(alloc);
        errdefer thread.mailbox.destroy(alloc);

        thread.event_queue = try Mailbox(Server.Event, 64).create(alloc);
        errdefer thread.event_queue.destroy(alloc);

        thread.alloc = alloc;

        // Attach server to thread's loop
        // Ensure this function exists in JamSnpServer and handles potential errors or state.
        server_instance.attachToLoop(&thread.loop);

        thread.server = server_instance;

        // Register internal callbacks to bridge JamSnpServer events to Server.Event
        thread.registerServerCallbacks();

        return thread;
    }

    fn registerServerCallbacks(self: *ServerThread) void {
        // Pass 'self' as context so callbacks can access the thread state (event_queue)
        self.server.setCallback(.ClientConnected, internalClientConnectedCallback, self);
        self.server.setCallback(.ConnectionEstablished, internalClientDisconnectedCallback, self);
        self.server.setCallback(.StreamCreated, internalStreamCreatedByClientCallback, self);
        self.server.setCallback(.StreamClosed, internalStreamClosedByClientCallback, self);
        self.server.setCallback(.DataReceived, internalDataReceivedCallback, self);
        self.server.setCallback(.DataWriteCompleted, internalDataWriteCompletedCallback, self); // Server might need this?
        self.server.setCallback(.DataReadError, internalDataReadErrorCallback, self);
        self.server.setCallback(.DataWriteError, internalDataWriteErrorCallback, self);
        self.server.setCallback(.DataWouldBlock, internalDataReadWouldBlockCallback, self);
    }

    pub fn shutdown(self: *ServerThread) !void {
        std.debug.print("ServerThread shutdown requested.\n", .{});
        try self.stop.notify();
    }

    pub fn deinit(self: *ServerThread) void {
        // The sequence of operations is critical in this context. Initially,
        // terminate the client, which will consequently dismantle the engine,
        // thereby closing all active connections and streams. Subsequently,
        // deallocate the remaining resources.
        self.server.deinit();

        self.event_queue.destroy(self.alloc);
        self.mailbox.destroy(self.alloc);
        self.stop.deinit();
        self.wakeup.deinit();
        self.loop.deinit();
        self.alloc.destroy(self);
    }

    pub fn threadMain(self: *ServerThread) void {
        self.threadMain_() catch |err| {
            std.log.err("server thread error: {any}", .{err});
            const event = Server.Event{ .@"error" = .{ .message = "server thread failed", .details = err } };
            // Try pushing error event, ignore if queue is full/closed
            _ = self.event_queue.push(event, .instant);
        };
    }

    fn threadMain_(self: *ServerThread) !void {
        self.wakeup.wait(&self.loop, &self.wakeup_c, ServerThread, self, wakeupCallback);
        self.stop.wait(&self.loop, &self.stop_c, ServerThread, self, stopCallback);

        // Initial notify might not be needed unless startup commands are expected
        // try self.wakeup.notify();
        _ = try self.loop.run(.until_done);
        std.log.info("Server thread loop finished.", .{});
    }

    fn wakeupCallback(
        self_: ?*ServerThread,
        _: *xev.Loop,
        _: *xev.Completion,
        r: xev.Async.WaitError!void,
    ) xev.CallbackAction {
        _ = r catch |err| {
            std.log.err("error in server wakeup err={}", .{err});
            // Potentially fatal? Or try to rearm?
            return .rearm;
        };
        const thread = self_.?;
        thread.drainMailbox() catch |err| {
            std.log.err("error processing server mailbox err={}", .{err});
            const event = Server.Event{ .@"error" = .{ .message = "mailbox processing error", .details = err } };
            _ = thread.event_queue.push(event, .instant);
        };
        return .rearm;
    }

    fn stopCallback(
        self_: ?*ServerThread,
        _: *xev.Loop,
        _: *xev.Completion,
        r: xev.Async.WaitError!void,
    ) xev.CallbackAction {
        _ = r catch unreachable; // Should not fail
        std.debug.print("Server stop requested.\n", .{});
        self_.?.loop.stop();
        return .disarm;
    }

    fn drainMailbox(self: *ServerThread) !void {
        while (self.mailbox.pop()) |command| {
            // Process command results immediately and invoke callbacks if needed
            // This mirrors the client's immediate command execution.
            // Asynchronous results (like stream creation) come via events.
            try self.processCommand(command);
        }
    }

    // Processes a command and returns a CommandResult
    fn processCommand(self: *ServerThread, command: Command) !void {
        switch (command) {
            .listen => |cmd| {
                const maybe_local_endpoint = self.server.listen(cmd.data.address, cmd.data.port);
                // Push 'Listening' event on success? JamSnpServer might do this.
                if (maybe_local_endpoint) |local_end_point| {
                    // Assuming listen returns the bound endpoint on success eventually via event/callback
                    // For now, just signal command success.
                    // A dedicated 'Listening' event pushed by internalListenCallback would be better.
                    try self.pushEvent(.{
                        .listening = .{ .local_endpoint = local_end_point, .result = .{ .metadata = cmd.metadata, .result = local_end_point } },
                    });
                } else |err| {
                    // Handle error (log, notify, etc.)
                    std.log.err("Error listening: {any}", .{err});
                }
            },
            .disconnect_client => |cmd| {
                _ = try self.disconnectClientImpl(cmd.data.connection_id);
            },
            .create_stream => |cmd| {
                _ = try self.createStreamImpl(cmd.data.connection_id);
            },
            .destroy_stream => |cmd| {
                _ = try self.destroyStreamImpl(cmd.data.stream_id);
            },
            .send_data => |cmd| {
                _ = try self.sendDataImpl(cmd.data.stream_id, cmd.data.data);
                // Success here just means queued/attempted. Actual completion via event?
            },
            .stream_want_read => |cmd| {
                _ = try self.streamWantReadImpl(cmd.data.stream_id, cmd.data.want);
            },
            .stream_want_write => |cmd| {
                _ = try self.streamWantWriteImpl(cmd.data.stream_id, cmd.data.want);
            },
            .stream_flush => |cmd| {
                _ = try self.streamFlushImpl(cmd.data.stream_id);
            },
            .stream_shutdown => |cmd| {
                _ = try self.streamShutdownImpl(cmd.data.stream_id, cmd.data.how);
            },
        }
    }

    // Pushes an event to the event queue.
    fn pushEvent(self: *ServerThread, event: Server.Event) anyerror!void {
        _ = try self.event_queue.pushInstantNotFull(event);
    }

    // --- Command Implementation Helpers ---
    // These interact with JamSnpServer and its components

    fn findConnection(self: *ServerThread, id: ConnectionId) !*ServerConnection {
        return self.server.connections.get(id) orelse error.ConnectionNotFound;
    }

    fn findStream(self: *ServerThread, id: StreamId) !*ServerStream {
        return self.server.streams.get(id) orelse error.StreamNotFound;
    }

    fn disconnectClientImpl(self: *ServerThread, conn_id: ConnectionId) anyerror!void {
        const conn = try self.findConnection(conn_id);
        // Use lsquic function directly, assuming connection holds the lsquic ptr
        @import("lsquic").lsquic_conn_close(conn.lsquic_connection);
    }

    fn createStreamImpl(self: *ServerThread, conn_id: ConnectionId) anyerror!void {
        const conn = try self.findConnection(conn_id);
        // Server initiating a stream
        @import("lsquic").lsquic_conn_make_stream(conn.lsquic_connection);
    }

    fn destroyStreamImpl(self: *ServerThread, stream_id: StreamId) anyerror!void {
        const stream = try self.findStream(stream_id);
        // Assuming ServerStream has a close method or similar
        // For now, call lsquic directly. Needs ServerStream wrapper method ideally.
        if (@import("lsquic").lsquic_stream_close(stream.lsquic_stream) != 0) {
            return error.StreamCloseFailed;
        }
    }

    fn sendDataImpl(self: *ServerThread, stream_id: StreamId, data: []const u8) anyerror!void {
        const stream = try self.findStream(stream_id);
        try stream.setWriteBuffer(data);
        stream.wantWrite(true);
    }

    fn streamWantReadImpl(self: *ServerThread, stream_id: StreamId, want: bool) anyerror!void {
        const stream = try self.findStream(stream_id);
        stream.wantRead(want);
    }

    fn streamWantWriteImpl(self: *ServerThread, stream_id: StreamId, want: bool) anyerror!void {
        const stream = try self.findStream(stream_id);
        stream.wantWrite(want);
    }

    fn streamFlushImpl(self: *ServerThread, stream_id: StreamId) anyerror!void {
        const stream = try self.findStream(stream_id);
        // ASSUMPTION: ServerStream needs a flush method.
        try stream.flush();
    }

    fn streamShutdownImpl(self: *ServerThread, stream_id: StreamId, how: c_int) anyerror!void {
        const stream = try self.findStream(stream_id);
        try stream.shutdown(how);
    }

    pub fn startThread(thread: *ServerThread) !std.Thread {
        return try std.Thread.spawn(.{}, ServerThread.threadMain, .{thread});
    }

    // -- Internal Callback Handlers
    // These run in the ServerThread's context and push events
    fn internalListenerCreatedCallback(endpoint: network.EndPoint, context: ?*anyopaque) void {
        const self: *ServerThread = @ptrCast(@alignCast(context.?));
        const event = Server.Event{ .listening = .{ .local_endpoint = endpoint } };
        std.debug.print("Listener created at {}", .{endpoint});
        _ = self.event_queue.push(event, .instant); // Ignore push error (queue full?)
    }

    fn internalClientConnectedCallback(connection_id: ConnectionId, peer_endpoint: network.EndPoint, context: ?*anyopaque) void {
        const self: *ServerThread = @ptrCast(@alignCast(context.?));
        const event = Server.Event{ .client_connected = .{ .connection_id = connection_id, .peer_endpoint = peer_endpoint } };
        std.debug.print("Server client connected: {} at {}", .{ connection_id, peer_endpoint });
        _ = self.event_queue.push(event, .instant); // Ignore push error (queue full?)
    }

    fn internalClientDisconnectedCallback(connection_id: ConnectionId, context: ?*anyopaque) void {
        const self: *ServerThread = @ptrCast(@alignCast(context.?));
        const event = Server.Event{ .client_disconnected = .{ .connection_id = connection_id } };
        _ = self.event_queue.push(event, .instant);
    }

    fn internalStreamCreatedByClientCallback(connection_id: ConnectionId, stream_id: StreamId, context: ?*anyopaque) void {
        const self: *ServerThread = @ptrCast(@alignCast(context.?));
        const event = Server.Event{ .stream_created_by_client = .{ .connection_id = connection_id, .stream_id = stream_id } };
        _ = self.event_queue.push(event, .instant);
    }

    // Need a corresponding event for server-initiated streams too
    // fn internalStreamCreatedByServerCallback(...)

    fn internalStreamClosedByClientCallback(connection_id: ConnectionId, stream_id: StreamId, context: ?*anyopaque) void {
        const self: *ServerThread = @ptrCast(@alignCast(context.?));
        const event = Server.Event{ .stream_closed = .{ .connection_id = connection_id, .stream_id = stream_id } };
        _ = self.event_queue.push(event, .instant);
    }

    fn internalDataReceivedCallback(connection_id: ConnectionId, stream_id: StreamId, data: []const u8, context: ?*anyopaque) void {
        const self: *ServerThread = @ptrCast(@alignCast(context.?));
        // Data is owned by the caller so no need to copy. Since caller will be
        // the event consumer. The responsibility of freeing the data is on the
        // caller.
        const event = Server.Event{ .data_received = .{ .connection_id = connection_id, .stream_id = stream_id, .data = data } };
        _ = self.event_queue.push(event, .instant);
    }

    fn internalDataWriteCompletedCallback(connection_id: ConnectionId, stream_id: StreamId, total_bytes_written: usize, context: ?*anyopaque) void {
        const self: *ServerThread = @ptrCast(@alignCast(context.?));
        const event = Server.Event{ .data_write_completed = .{ .connection_id = connection_id, .stream_id = stream_id, .total_bytes_written = total_bytes_written } };
        _ = self.event_queue.push(event, .instant);
    }

    fn internalDataReadErrorCallback(connection_id: ConnectionId, stream_id: StreamId, error_code: i32, context: ?*anyopaque) void {
        const self: *ServerThread = @ptrCast(@alignCast(context.?));
        const event = Server.Event{ .data_read_error = .{ .connection_id = connection_id, .stream_id = stream_id, .error_code = @intCast(error_code) } };
        _ = self.event_queue.push(event, .instant);
    }

    fn internalDataWriteErrorCallback(connection_id: ConnectionId, stream_id: StreamId, error_code: i32, context: ?*anyopaque) void {
        const self: *ServerThread = @ptrCast(@alignCast(context.?));
        const event = Server.Event{ .data_write_error = .{ .connection_id = connection_id, .stream_id = stream_id, .error_code = @intCast(error_code) } };
        _ = self.event_queue.push(event, .instant);
    }

    fn internalDataReadWouldBlockCallback(connection_id: ConnectionId, stream_id: StreamId, context: ?*anyopaque) void {
        const self: *ServerThread = @ptrCast(@alignCast(context.?));
        const event = Server.Event{ .data_read_would_block = .{ .connection_id = connection_id, .stream_id = stream_id } };
        _ = self.event_queue.push(event, .instant);
    }

    fn internalDataWriteWouldBlockCallback(connection_id: ConnectionId, stream_id: StreamId, context: ?*anyopaque) void {
        const self: *ServerThread = @ptrCast(@alignCast(context.?));
        const event = Server.Event{ .data_write_would_block = .{ .connection_id = connection_id, .stream_id = stream_id } };
        _ = self.event_queue.push(event, .instant);
    }
};

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
            return self.sendDataWithCallback(data, null, null);
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

        pub fn wantRead(self: *StreamHandle, want: bool) !void {
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
            switch (self) {
                .listening => |e| e.result.invokeCallback(),
                else => {
                    @panic("Event callback not implemented for this event type");
                },
            }
        }
    };

    // --- API Methods ---

    pub fn listen(self: *Server, address: []const u8, port: u16) !void {
        return self.listenWithCallback(address, port, null, null);
    }

    pub fn listenWithCallback(
        self: *Server,
        address: []const u8,
        port: u16,
        callback: ?CommandCallback(anyerror!network.EndPoint),
        context: ?*anyopaque,
    ) !void {
        const command = ServerThread.Command{ .listen = .{
            .data = .{ .address = address, .port = port },
            .metadata = .{ .callback = callback, .context = context },
        } };
        _ = self.thread.mailbox.push(command, .instant);
        try self.thread.wakeup.notify();
    }

    pub fn disconnectClient(self: *Server, connection_id: ConnectionId) !void {
        return self.disconnectClientWithCallback(connection_id, null, null);
    }

    pub fn disconnectClientWithCallback(
        self: *Server,
        connection_id: ConnectionId,
        callback: ?CommandCallback(anyerror!void),
        context: ?*anyopaque,
    ) !void {
        const command = ServerThread.Command{ .disconnect_client = .{
            .data = .{ .connection_id = connection_id },
            .metadata = .{ .callback = callback, .context = context },
        } };
        _ = self.thread.mailbox.push(command, .{ .instant = {} });
        try self.thread.wakeup.notify();
    }

    /// Server initiates a stream to a client
    pub fn createStream(self: *Server, connection_id: ConnectionId) !void {
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
        const command = ServerThread.Command{ .create_stream = .{
            .data = .{ .connection_id = connection_id },
            .metadata = .{ .callback = callback, .context = context },
        } };
        _ = self.thread.mailbox.push(command, .{ .instant = {} });
        try self.thread.wakeup.notify();
    }

    pub fn shutdown(self: *Server) !void {
        try self.thread.shutdown();
    }

    /// Tries to pop an event from the event queue without blocking.
    pub fn pollEvent(self: *Server) ?Event {
        return self.thread.event_queue.pop();
    }

    /// Pops an event from the event queue, blocking until one is available.
    pub fn waitEvent(self: *Server) Event {
        return self.thread.event_queue.blockingPop();
    }

    /// Pops an event from the event queue, blocking until one is available or timeout occurs.
    pub fn timedWaitEvent(self: *Server, timeout_ms: u64) ?Event {
        return self.thread.event_queue.timedBlockingPop(timeout_ms);
    }
};
