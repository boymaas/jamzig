//! Implementation of the ServerThread and Server, symmetrical to the client.
//! The ServerThread manages the JamSnpServer and processes commands via a mailbox,
//! generating events for the application.

const std = @import("std");
const xev = @import("xev");
const network = @import("network");

const posix = std.posix;

const shared = @import("jamsnp/shared_types.zig");

const Server = @import("server.zig").Server;

pub const ConnectionId = shared.ConnectionId;
pub const Stream = @import("jamsnp/stream.zig").Stream;
pub const StreamId = shared.StreamId;
pub const StreamKind = shared.StreamKind;
pub const JamSnpServer = @import("jamsnp/server.zig").JamSnpServer;
pub const ServerConnection = @import("jamsnp/connection.zig").Connection(JamSnpServer);
pub const ServerStream = @import("jamsnp/stream.zig").Stream(JamSnpServer);

const common = @import("common.zig");
const CommandCallback = common.CommandCallback;
const CommandMetadata = common.CommandMetadata;

const Mailbox = @import("../datastruct/blocking_queue.zig").BlockingQueue;

const trace = @import("../tracing.zig").scoped(.network);

/// Builder for creating a ServerThread instance.
/// Ensures that the underlying JamSnpServer is also initialized.
pub const Builder = struct {
    _alloc: ?std.mem.Allocator = null,
    _genesis_hash: ?[]const u8 = null,
    _key_pair: ?std.crypto.sign.Ed25519.KeyPair = null,
    _allow_builders: ?bool = false,

    pub fn init() Builder {
        return .{};
    }

    pub fn allocator(self: *Builder, alloc: std.mem.Allocator) *Builder {
        self._alloc = alloc;
        return self;
    }

    pub fn genesisHash(self: *Builder, genesis_hash: []const u8) *Builder {
        self._genesis_hash = genesis_hash;
        return self;
    }

    pub fn keypair(self: *Builder, key_pair: std.crypto.sign.Ed25519.KeyPair) *Builder {
        self._key_pair = key_pair;
        return self;
    }

    pub fn allowBuilders(self: *Builder, allow_builders: bool) *Builder {
        self._allow_builders = allow_builders;
        return self;
    }

    /// Builds the ServerThread.
    pub fn build(self: *const Builder) !*ServerThread {
        const alloc = self._alloc orelse return error.AllocatorNotSet;
        const genesis_hash = self._genesis_hash orelse return error.GenesisHashNotSet;
        const key_pair = self._key_pair orelse return error.KeyPairNotSet;
        const allow_builders = self._allow_builders orelse return error.AllowBuildersNotSet;

        var jserver = try JamSnpServer.initWithoutLoop(alloc, key_pair, genesis_hash, allow_builders);
        errdefer jserver.deinit();

        return ServerThread.init(alloc, jserver);
    }
};

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
        pub const SendMessage = struct {
            const Data = struct {
                connection_id: ConnectionId,
                stream_id: StreamId,
                message: []const u8, // Caller owns
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
        send_message: SendMessage,
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
        self.server.setCallback(.connection_established, internalClientConnectedCallback, self);
        self.server.setCallback(.connection_closed, internalClientDisconnectedCallback, self);
        self.server.setCallback(.stream_created, internalStreamCreatedCallback, self);
        self.server.setCallback(.stream_closed, internalStreamClosedByClientCallback, self);
        self.server.setCallback(.data_read_completed, internalDataReadCompletedCallback, self);
        self.server.setCallback(.data_write_completed, internalDataWriteCompletedCallback, self); // Server might need this?
        self.server.setCallback(.data_read_error, internalDataReadErrorCallback, self);
        self.server.setCallback(.data_write_error, internalDataWriteErrorCallback, self);
        self.server.setCallback(.data_would_block, internalDataReadWouldBlockCallback, self);
        self.server.setCallback(.message_received, internalMessageReceivedCallback, self);
        self.server.setCallback(.message_send, internalMessageSendCallback, self);
    }

    pub fn shutdown(self: *ServerThread) !void {
        const span = trace.span(.thread_shutdown);
        defer span.deinit();
        span.debug("ServerThread shutdown requested", .{});
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
        const span = trace.span(.thread_main);
        defer span.deinit();
        span.debug("Server thread starting", .{});

        self.threadMain_() catch |err| {
            span.err("Server thread error: {any}", .{err});
            const event = Server.Event{ .@"error" = .{ .message = "server thread failed", .details = err } };
            // Try pushing error event, ignore if queue is full/closed
            _ = self.event_queue.push(event, .instant);
        };
    }

    fn threadMain_(self: *ServerThread) !void {
        const span = trace.span(.thread_main_impl);
        defer span.deinit();

        span.debug("Registering wakeup and stop handlers", .{});
        self.wakeup.wait(&self.loop, &self.wakeup_c, ServerThread, self, wakeupCallback);
        self.stop.wait(&self.loop, &self.stop_c, ServerThread, self, stopCallback);

        // Initial notify might not be needed unless startup commands are expected
        // try self.wakeup.notify();
        span.debug("Starting event loop", .{});
        _ = try self.loop.run(.until_done);
        span.debug("Server thread loop finished", .{});
    }

    fn wakeupCallback(
        self_: ?*ServerThread,
        _: *xev.Loop,
        _: *xev.Completion,
        r: xev.Async.WaitError!void,
    ) xev.CallbackAction {
        const span = trace.span(.wakeup_callback);
        defer span.deinit();

        _ = r catch |err| {
            span.err("Error in server wakeup: {}", .{err});
            // Potentially fatal? Or try to rearm?
            return .rearm;
        };

        span.debug("Processing mailbox", .{});
        const thread = self_.?;
        thread.drainMailbox() catch |err| {
            span.err("Error processing server mailbox: {}", .{err});
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
        const span = trace.span(.stop_callback);
        defer span.deinit();

        _ = r catch unreachable; // Should not fail
        span.debug("Server stop requested", .{});
        self_.?.loop.stop();
        return .disarm;
    }

    fn drainMailbox(self: *ServerThread) !void {
        const span = trace.span(.drain_mailbox);
        defer span.deinit();

        var command_count: usize = 0;
        while (self.mailbox.pop()) |command| {
            command_count += 1;
            // Process command results immediately and invoke callbacks if needed
            // This mirrors the client's immediate command execution.
            // Asynchronous results (like stream creation) come via events.
            try self.processCommand(command);
        }
        span.debug("Processed {d} commands from mailbox", .{command_count});
    }

    // Processes a command and returns a CommandResult
    fn processCommand(self: *ServerThread, command: Command) !void {
        const span = trace.span(.process_command);
        defer span.deinit();

        span.debug("Processing command: {s}", .{@tagName(command)});
        switch (command) {
            .listen => |cmd| {
                const cmd_span = span.child(.listen_command);
                defer cmd_span.deinit();
                cmd_span.debug("Processing listen command for {s}:{d}", .{ cmd.data.address, cmd.data.port });

                const maybe_local_endpoint = self.server.listen(cmd.data.address, cmd.data.port);
                // Push 'Listening' event on success? JamSnpServer might do this.
                if (maybe_local_endpoint) |local_end_point| {
                    // Assuming listen returns the bound endpoint on success eventually via event/callback
                    // For now, just signal command success.
                    // A dedicated 'Listening' event pushed by internalListenCallback would be better.
                    cmd_span.debug("Server listening on endpoint: {}", .{local_end_point});
                    try self.pushEvent(.{
                        .listening = .{ .local_endpoint = local_end_point, .result = .{ .metadata = cmd.metadata, .result = local_end_point } },
                    });
                } else |err| {
                    // Handle error (log, notify, etc.)
                    cmd_span.err("Error listening: {any}", .{err});
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
            .send_message => |cmd| {
                _ = try self.sendMessageImpl(cmd.data.stream_id, cmd.data.message);
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
        const span = trace.span(.push_event);
        defer span.deinit();

        span.debug("Pushing event: {s}", .{@tagName(event)});
        _ = try self.event_queue.pushInstantNotFull(event);
    }

    // --- Command Implementation Helpers ---
    // These interact with JamSnpServer and its components

    fn findConnection(self: *ServerThread, id: ConnectionId) !*ServerConnection {
        const span = trace.span(.find_connection);
        defer span.deinit();

        span.debug("Looking for connection: {}", .{id});
        const conn = self.server.connections.get(id) orelse {
            span.err("Connection not found: {}", .{id});
            return error.ConnectionNotFound;
        };
        return conn;
    }

    fn findStream(self: *ServerThread, id: StreamId) !*ServerStream {
        const span = trace.span(.find_stream);
        defer span.deinit();

        span.debug("Looking for stream: {}", .{id});
        const stream = self.server.streams.get(id) orelse {
            span.err("Stream not found: {}", .{id});
            return error.StreamNotFound;
        };
        return stream;
    }

    fn disconnectClientImpl(self: *ServerThread, conn_id: ConnectionId) anyerror!void {
        const span = trace.span(.disconnect_client);
        defer span.deinit();

        span.debug("Disconnecting client: {}", .{conn_id});
        const conn = try self.findConnection(conn_id);
        // Use lsquic function directly, assuming connection holds the lsquic ptr
        @import("lsquic").lsquic_conn_close(conn.lsquic_connection);
        span.debug("Client disconnection initiated", .{});
    }

    fn createStreamImpl(self: *ServerThread, conn_id: ConnectionId) anyerror!void {
        const span = trace.span(.create_stream);
        defer span.deinit();

        span.debug("Creating stream for connection: {}", .{conn_id});
        const conn = try self.findConnection(conn_id);
        // Server initiating a stream
        @import("lsquic").lsquic_conn_make_stream(conn.lsquic_connection);
        span.debug("Stream creation initiated", .{});
    }

    fn destroyStreamImpl(self: *ServerThread, stream_id: StreamId) anyerror!void {
        const span = trace.span(.destroy_stream);
        defer span.deinit();

        span.debug("Destroying stream: {}", .{stream_id});
        const stream = try self.findStream(stream_id);
        // Assuming ServerStream has a close method or similar
        // For now, call lsquic directly. Needs ServerStream wrapper method ideally.
        if (@import("lsquic").lsquic_stream_close(stream.lsquic_stream) != 0) {
            span.err("Failed to close stream: {}", .{stream_id});
            return error.StreamCloseFailed;
        }
        span.debug("Stream destroyed successfully", .{});
    }

    fn sendDataImpl(self: *ServerThread, stream_id: StreamId, data: []const u8) anyerror!void {
        const span = trace.span(.send_data);
        defer span.deinit();

        span.debug("Sending data on stream: {}", .{stream_id});
        span.trace("Data length: {d} bytes", .{data.len});
        span.trace("Data: {any}", .{std.fmt.fmtSliceHexLower(data)});

        const stream = try self.findStream(stream_id);
        try stream.setWriteBuffer(data, .owned, .datawritecompleted);
        stream.wantWrite(true);
        span.debug("Data queued for writing", .{});
    }

    fn sendMessageImpl(self: *ServerThread, stream_id: StreamId, message: []const u8) anyerror!void {
        const span = trace.span(.send_message);
        defer span.deinit();

        span.debug("Sending message on stream: {}", .{stream_id});
        span.trace("Message length: {d} bytes", .{message.len});
        span.trace("Message first bytes: {any}", .{std.fmt.fmtSliceHexLower(if (message.len > 16) message[0..16] else message)});

        const stream = try self.findStream(stream_id);
        try stream.setMessageBuffer(message);
        stream.wantWrite(true);
        span.debug("Message queued for writing", .{});
    }

    fn streamWantReadImpl(self: *ServerThread, stream_id: StreamId, want: bool) anyerror!void {
        const span = trace.span(.stream_want_read);
        defer span.deinit();

        span.debug("Setting stream {d} wantRead={}", .{ stream_id, want });
        const stream = try self.findStream(stream_id);
        stream.wantRead(want);
        span.debug("Stream wantRead set successfully", .{});
    }

    fn streamWantWriteImpl(self: *ServerThread, stream_id: StreamId, want: bool) anyerror!void {
        const span = trace.span(.stream_want_write);
        defer span.deinit();

        span.debug("Setting stream {d} wantWrite={}", .{ stream_id, want });
        const stream = try self.findStream(stream_id);
        stream.wantWrite(want);
        span.debug("Stream wantWrite set successfully", .{});
    }

    fn streamFlushImpl(self: *ServerThread, stream_id: StreamId) anyerror!void {
        const span = trace.span(.stream_flush);
        defer span.deinit();

        span.debug("Flushing stream: {}", .{stream_id});
        const stream = try self.findStream(stream_id);
        // ASSUMPTION: ServerStream needs a flush method.
        try stream.flush();
        span.debug("Stream flushed successfully", .{});
    }

    fn streamShutdownImpl(self: *ServerThread, stream_id: StreamId, how: c_int) anyerror!void {
        const span = trace.span(.stream_shutdown);
        defer span.deinit();

        span.debug("Shutting down stream: {d} (how={d})", .{ stream_id, how });
        const stream = try self.findStream(stream_id);
        try stream.shutdown(how);
        span.debug("Stream shutdown successful", .{});
    }

    pub fn startThread(thread: *ServerThread) !std.Thread {
        return try std.Thread.spawn(.{}, ServerThread.threadMain, .{thread});
    }

    // -- Internal Callback Handlers
    // These run in the ServerThread's context and push events
    fn internalListenerCreatedCallback(endpoint: network.EndPoint, context: ?*anyopaque) void {
        const span = trace.span(.listener_created_callback);
        defer span.deinit();

        span.debug("Listener created at {}", .{endpoint});
        const self: *ServerThread = @ptrCast(@alignCast(context.?));
        const event = Server.Event{ .listening = .{ .local_endpoint = endpoint } };
        _ = self.event_queue.push(event, .instant); // Ignore push error (queue full?)
    }

    fn internalClientConnectedCallback(connection_id: ConnectionId, peer_endpoint: network.EndPoint, context: ?*anyopaque) void {
        const span = trace.span(.client_connected_callback);
        defer span.deinit();

        span.debug("Client connected: {d} at {}", .{ connection_id, peer_endpoint });
        const self: *ServerThread = @ptrCast(@alignCast(context.?));
        const event = Server.Event{ .client_connected = .{ .connection_id = connection_id, .endpoint = peer_endpoint } };
        _ = self.event_queue.push(event, .instant); // Ignore push error (queue full?)
    }

    fn internalClientDisconnectedCallback(connection_id: ConnectionId, context: ?*anyopaque) void {
        const span = trace.span(.client_disconnected_callback);
        defer span.deinit();

        span.debug("Client disconnected: {}", .{connection_id});
        const self: *ServerThread = @ptrCast(@alignCast(context.?));
        const event = Server.Event{ .disconnected = .{ .connection_id = connection_id } };
        _ = self.event_queue.push(event, .instant);
    }

    fn internalStreamCreatedCallback(stream: *Stream(JamSnpServer), context: ?*anyopaque) !void {
        const span = trace.span(.stream_created);
        defer span.deinit();
        span.debug("Stream created: connection={} stream={}", .{ stream.connection.id, stream.id });

        const server_thread: *ServerThread = @ptrCast(@alignCast(context.?));

        switch (stream.origin()) {
            .local_initiated => {
                span.debug("Local initiated stream", .{});
                @panic("Local initiated stream not supported yet");
                // if (server_thread.pending_streams.readItem()) |cmd| {
                //     // Set the write buffer and trigger lsquic to send it by setting
                //     // wantWrite to true
                //     try stream.setWriteBuffer(try server_thread.alloc.dupe(u8, std.mem.asBytes(&cmd.data.kind)), .owned, .none);
                //     stream.wantWrite(true);
                //     span.debug("Sending StreamKind to peer", .{});
                //     try server_thread.pushEvent(.{ .stream_created = .{
                //         .connection_id = stream.connection.id,
                //         .stream_id = stream.id,
                //         .kind = cmd.data.kind,
                //         .metadata = cmd.metadata,
                //     } });
                // } else {
                //     // This should never happen.
                //     span.warn("StreamCreated event for connection {} with no pending stream command", .{stream.connection.id});
                //     std.debug.panic("StreamCreated event for connection {} with no pending stream command", .{stream.connection.id});
                // }
            },
            .remote_initiated => {
                span.debug("Remote initiated stream", .{});
                // This is a server-initiated stream, we need to create a new stream
                // object and push it to the event queue
                span.debug("Reading StreamKind from peer", .{});
                const stream_kind_buffer = try server_thread.alloc.alloc(u8, 1);
                try stream.setReadBuffer(
                    stream_kind_buffer,
                    .borrow,
                    .{ .custom = .{
                        .on_success = remoteInitiatedStreamKindReceived,
                        .on_error = remoteInitiatedStreamKindReceivedError,
                        .context = server_thread,
                    } },
                );
                stream.wantRead(true);

                // FIXME: on setReadBuffer, also add the ownership and if we shuold invoke a callback
                // and what callback to invoke. And what about timeouts how are we going to handle that?
            },
        }
    }

    fn remoteInitiatedStreamKindReceived(
        stream: *Stream(JamSnpServer),
        data: []const u8,
        ctx: ?*anyopaque,
    ) anyerror!void {
        const span = trace.span(.remote_initiated_stream_kind_received);
        defer span.deinit();

        // check the inputs close stream when invalid
        const server_thread: *ServerThread = @ptrCast(@alignCast(ctx.?));
        defer server_thread.alloc.free(data);

        const stream_kind: StreamKind = std.meta.intToEnum(StreamKind, data[0]) catch {
            span.err("Invalid stream kind received: {d}. Closing stream", .{data[0]});
            try stream.close();

            return error.InvalidStreamKind;
        };

        span.debug("Remote initiated stream: {}", .{stream_kind});

        stream.wantRead(true);

        // set the kind on the stream
        stream.kind = stream_kind;

        const event = Server.Event{ .stream_created = .{
            .connection_id = stream.connection.id,
            .stream_id = stream.id,
            .kind = stream_kind,
        } };
        _ = try server_thread.event_queue.pushInstantNotFull(event);
    }

    pub fn remoteInitiatedStreamKindReceivedError(
        stream: *Stream(JamSnpServer),
        data: []const u8,
        error_code: i32,
        ctx: ?*anyopaque,
    ) anyerror!void {
        const span = trace.span(.remote_initiated_stream_kind_received_error);
        defer span.deinit();

        const server_thread: *ServerThread = @ptrCast(@alignCast(ctx.?));

        // free the buffer when we are done
        server_thread.alloc.free(data);
        // on an errror we close the stream.
        try stream.close();

        span.err("Remote initiated stream kind received LSQUIC error_code: {}", .{error_code});
    }

    // Need a corresponding event for server-initiated streams too
    // fn internalStreamCreatedByServerCallback(...)

    fn internalStreamClosedByClientCallback(connection_id: ConnectionId, stream_id: StreamId, context: ?*anyopaque) void {
        const span = trace.span(.stream_closed_callback);
        defer span.deinit();

        span.debug("Stream closed by client: {d} on connection {d}", .{ stream_id, connection_id });
        const self: *ServerThread = @ptrCast(@alignCast(context.?));
        const event = Server.Event{ .stream_closed = .{ .connection_id = connection_id, .stream_id = stream_id } };
        _ = self.event_queue.push(event, .instant);
    }

    fn internalDataReadCompletedCallback(connection_id: ConnectionId, stream_id: StreamId, data: []const u8, context: ?*anyopaque) void {
        const span = trace.span(.data_received_callback);
        defer span.deinit();

        span.debug("Data received on stream {d} (connection {d}), length: {d} bytes", .{ stream_id, connection_id, data.len });
        span.trace("Received data: {any}", .{std.fmt.fmtSliceHexLower(data)});

        const self: *ServerThread = @ptrCast(@alignCast(context.?));
        // Data is owned by the caller so no need to copy. Since caller will be
        // the event consumer. The responsibility of freeing the data is on the
        // caller.
        const event = Server.Event{ .data_received = .{ .connection_id = connection_id, .stream_id = stream_id, .data = data } };
        _ = self.event_queue.push(event, .instant);
    }

    fn internalDataWriteCompletedCallback(connection_id: ConnectionId, stream_id: StreamId, total_bytes_written: usize, context: ?*anyopaque) void {
        const span = trace.span(.data_write_completed_callback);
        defer span.deinit();

        span.debug("Data write completed on stream {d} (connection {d}), bytes written: {d}", .{ stream_id, connection_id, total_bytes_written });
        const self: *ServerThread = @ptrCast(@alignCast(context.?));
        const event = Server.Event{ .data_write_completed = .{ .connection_id = connection_id, .stream_id = stream_id, .total_bytes_written = total_bytes_written } };
        _ = self.event_queue.push(event, .instant);
    }

    fn internalDataReadErrorCallback(connection_id: ConnectionId, stream_id: StreamId, error_code: i32, context: ?*anyopaque) void {
        const span = trace.span(.data_read_error_callback);
        defer span.deinit();

        span.err("Data read error on stream {d} (connection {d}), error code: {d}", .{ stream_id, connection_id, error_code });
        const self: *ServerThread = @ptrCast(@alignCast(context.?));
        const event = Server.Event{ .data_read_error = .{ .connection_id = connection_id, .stream_id = stream_id, .error_code = @intCast(error_code) } };
        _ = self.event_queue.push(event, .instant);
    }

    fn internalDataWriteErrorCallback(connection_id: ConnectionId, stream_id: StreamId, error_code: i32, context: ?*anyopaque) void {
        const span = trace.span(.data_write_error_callback);
        defer span.deinit();

        span.err("Data write error on stream {d} (connection {d}), error code: {d}", .{ stream_id, connection_id, error_code });
        const self: *ServerThread = @ptrCast(@alignCast(context.?));
        const event = Server.Event{ .data_write_error = .{ .connection_id = connection_id, .stream_id = stream_id, .error_code = @intCast(error_code) } };
        _ = self.event_queue.push(event, .instant);
    }

    fn internalDataReadWouldBlockCallback(connection_id: ConnectionId, stream_id: StreamId, context: ?*anyopaque) void {
        const span = trace.span(.data_read_would_block_callback);
        defer span.deinit();

        span.debug("Data read would block on stream {d} (connection {d})", .{ stream_id, connection_id });
        const self: *ServerThread = @ptrCast(@alignCast(context.?));
        const event = Server.Event{ .data_read_would_block = .{ .connection_id = connection_id, .stream_id = stream_id } };
        _ = self.event_queue.push(event, .instant);
    }

    fn internalDataWriteWouldBlockCallback(connection_id: ConnectionId, stream_id: StreamId, context: ?*anyopaque) void {
        const span = trace.span(.data_write_would_block_callback);
        defer span.deinit();

        span.debug("Data write would block on stream {d} (connection {d})", .{ stream_id, connection_id });
        const self: *ServerThread = @ptrCast(@alignCast(context.?));
        const event = Server.Event{ .data_write_would_block = .{ .connection_id = connection_id, .stream_id = stream_id } };
        _ = self.event_queue.push(event, .instant);
    }

    fn internalMessageSendCallback(connection_id: ConnectionId, stream_id: StreamId, context: ?*anyopaque) !void {
        const span = trace.span(.message_send);
        defer span.deinit();
        span.debug("Message send: connection={} stream={}", .{ connection_id, stream_id });

        const self: *ServerThread = @ptrCast(@alignCast(context.?));
        try self.pushEvent(.{ .message_send = .{ .connection_id = connection_id, .stream_id = stream_id } });
    }

    fn internalMessageReceivedCallback(connection_id: ConnectionId, stream_id: StreamId, message: []const u8, context: ?*anyopaque) void {
        const span = trace.span(.message_received_callback);
        defer span.deinit();

        span.debug("Message received on stream {d} (connection {d}), length: {d} bytes", .{ stream_id, connection_id, message.len });
        span.trace("Message first bytes: {any}", .{std.fmt.fmtSliceHexLower(if (message.len > 16) message[0..16] else message)});

        const self: *ServerThread = @ptrCast(@alignCast(context.?));

        // Ownership passed to event
        const event = Server.Event{ .message_received = .{ .connection_id = connection_id, .stream_id = stream_id, .message = message } };

        if (self.event_queue.push(event, .instant) == 0) {
            // If push failed, free the allocated memory for message
            // FIXME: this should fail
            span.err("Failed to push message_received event to queue", .{});
            self.alloc.free(message);
        }
    }
};
