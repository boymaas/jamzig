//! Implementation of the ClientThread and Client. The design is
//! straightforward: the ClientThread is equipped with a mailbox capable of
//! receiving commands asynchronously. Upon execution of a command by the
//! JamSnpClient, an event is generated that associates the invocation with its
//! corresponding result.

const std = @import("std");
const uuid = @import("uuid");
const xev = @import("xev");
const crypto = std.crypto;

const jamsnp_client = @import("jamsnp/client.zig");
const network = @import("network"); // Added for EndPoint

const shared = @import("jamsnp/shared_types.zig");
pub const ConnectionId = shared.ConnectionId;
pub const StreamId = shared.StreamId;
pub const StreamKind = shared.StreamKind;
pub const JamSnpClient = jamsnp_client.JamSnpClient;
pub const Stream = @import("jamsnp/stream.zig").Stream;
pub const StreamHandle = @import("stream_handle.zig").StreamHandle;

pub const Client = @import("client.zig").Client;

const common = @import("common.zig");
const CommandCallback = common.CommandCallback;
const CommandMetadata = common.CommandMetadata;

const Mailbox = @import("../datastruct/blocking_queue.zig").BlockingQueue;

const trace = @import("../tracing.zig").scoped(.network);

/// Builder for creating a ClientThread instance.
/// Ensures that the underlying JamSnpClient is also initialized.
pub const Builder = struct {
    _allocator: ?std.mem.Allocator = null,
    _keypair: ?crypto.sign.Ed25519.KeyPair = null,
    _genesis_hash: ?[]const u8 = null,
    _is_builder: bool = false,

    pub fn init() Builder {
        return .{};
    }

    pub fn allocator(self: *Builder, alloc: std.mem.Allocator) *Builder {
        self._allocator = alloc;
        return self;
    }

    pub fn keypair(self: *Builder, kp: crypto.sign.Ed25519.KeyPair) *Builder {
        self._keypair = kp;
        return self;
    }

    pub fn genesisHash(self: *Builder, hash: []const u8) *Builder {
        self._genesis_hash = hash;
        return self;
    }

    pub fn isBuilder(self: *Builder, is_builder: bool) *Builder {
        self._is_builder = is_builder;
        return self;
    }

    /// Builds the ClientThread.
    /// This involves initializing the JamSnpClient first, then the ClientThread itself.
    pub fn build(self: *const Builder) !*ClientThread {
        const alloc = self._allocator orelse return error.AllocatorNotSet;
        const kp = self._keypair orelse return error.KeypairNotSet;
        const gh = self._genesis_hash orelse return error.GenesisHashNotSet;
        // Note: We create it here, so the ClientThread takes ownership.
        var jclient = try JamSnpClient.initWithoutLoop(
            alloc,
            kp,
            gh,
            self._is_builder,
        );
        errdefer jclient.deinit();

        // 2. Initialize ClientThread
        return ClientThread.init(alloc, jclient);
    }
};

pub const ClientThread = struct {
    alloc: std.mem.Allocator,
    client: *JamSnpClient,
    loop: xev.Loop,

    wakeup: xev.Async,
    wakeup_c: xev.Completion = .{},

    stop: xev.Async,
    stop_c: xev.Completion = .{},

    mailbox: *Mailbox(Command, 64),
    event_queue: *Mailbox(Client.Event, 64), // Queue for events pushed by internal callbacks

    // Keep track of pending command metadata to invoke callbacks upon completion event
    pending_connects: std.AutoHashMap(ConnectionId, CommandMetadata(anyerror!ConnectionId)),
    pending_streams: std.fifo.LinearFifo(Command.CreateStream, .Dynamic),

    pub const Command = union(enum) {
        pub const Connect = struct {
            const Data = struct {
                endpoint: network.EndPoint,
                connection_id: ConnectionId,
            };
            data: Data,
            metadata: CommandMetadata(anyerror!ConnectionId),
        };

        pub const Disconnect = struct {
            const Data = struct {
                connection_id: ConnectionId,
            };
            data: Data,
            metadata: CommandMetadata(anyerror!void), // Disconnect error?
        };
        pub const CreateStream = struct {
            const Data = struct {
                connection_id: ConnectionId,
                // The initial byte sent to the server specifies the type of
                // stream. This action initiates the stream on the server.
                kind: StreamKind,
            };
            data: Data,
            metadata: CommandMetadata(anyerror!StreamId), // Callback returns StreamId
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
                message: []const u8,
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
                connection_id: ConnectionId, // Needed? StreamHandle has it
                stream_id: StreamId,
                how: c_int,
            };
            data: Data,
            metadata: CommandMetadata(anyerror!void),
        };

        connect: Connect,
        disconnect: Disconnect,
        create_stream: CreateStream,
        destroy_stream: DestroyStream,
        send_data: SendData,
        send_message: SendMessage,
        stream_want_read: StreamWantRead,
        stream_want_write: StreamWantWrite,
        stream_flush: StreamFlush,
        stream_shutdown: StreamShutdown,
    };

    /// Initializes the ClientThread with an existing JamSnpClient instance.
    /// Called by the ClientThreadBuilder.
    pub fn init(alloc: std.mem.Allocator, client: *JamSnpClient) !*ClientThread {
        var thread = try alloc.create(ClientThread);
        errdefer alloc.destroy(thread); // Only destroy thread struct if init fails

        thread.loop = try xev.Loop.init(.{});
        errdefer thread.loop.deinit();

        thread.wakeup = try xev.Async.init();
        errdefer thread.wakeup.deinit();

        thread.stop = try xev.Async.init();
        errdefer thread.stop.deinit();

        thread.mailbox = try Mailbox(Command, 64).create(alloc);
        errdefer thread.mailbox.destroy(alloc);

        thread.event_queue = try Mailbox(Client.Event, 64).create(alloc);
        errdefer thread.event_queue.destroy(alloc);

        thread.pending_connects = std.AutoHashMap(ConnectionId, CommandMetadata(anyerror!ConnectionId)).init(alloc);
        thread.pending_streams = std.fifo.LinearFifo(Command.CreateStream, .Dynamic).init(alloc);
        // Initialize other pending command maps here if needed

        thread.alloc = alloc;

        try client.attachToLoop(&thread.loop);
        thread.client = client;

        // Register internal callbacks
        thread.registerClientCallbacks();

        return thread;
    }

    /// Deinitializes the ClientThread and the JamSnpClient it owns.
    pub fn deinit(self: *ClientThread) void {
        const span = trace.span(.deinit);
        defer span.deinit();
        span.debug("Deinitializing ClientThread", .{});

        // The sequence of operations is critical in this context. Initially,
        // terminate the client, which will consequently dismantle the engine,
        // thereby closing all active connections and streams. Subsequently,
        // deallocate the remaining resources.
        self.client.deinit();

        self.pending_streams.deinit();
        self.pending_connects.deinit(); // Deinit pending command maps
        // Deinit other pending command maps here
        self.event_queue.destroy(self.alloc);
        self.mailbox.destroy(self.alloc);
        self.stop.deinit();
        self.wakeup.deinit();
        self.loop.deinit();
        self.alloc.destroy(self);
    }

    pub fn threadMain(self: *ClientThread) void {
        // Handle errors gracefully
        self.threadMain_() catch |err| {
            const span = trace.span(.thread_main);
            defer span.deinit();
            span.err("Error in thread: {}", .{err});
        };
    }

    fn threadMain_(self: *ClientThread) !void {
        const span = trace.span(.thread_main_impl);
        defer span.deinit();
        span.debug("Starting ClientThread main loop", .{});

        try self.threadSetup();
        defer self.threadCleanup();

        span.debug("Registering wakeup and stop callbacks", .{});
        self.wakeup.wait(&self.loop, &self.wakeup_c, ClientThread, self, wakeupCallback);
        self.stop.wait(&self.loop, &self.stop_c, ClientThread, self, stopCallback);

        // Initial notify might not be needed if setup doesn't queue commands
        // try self.wakeup.notify();
        span.debug("Running event loop", .{});
        _ = try self.loop.run(.until_done);

        span.debug("ClientThread main loop exited", .{});
    }

    fn threadSetup(_: *ClientThread) !void {
        // Perform any thread-specific setup
    }

    fn threadCleanup(_: *ClientThread) void {
        // Perform any thread-specific cleanup
    }

    fn wakeupCallback(
        self_: ?*ClientThread,
        _: *xev.Loop,
        _: *xev.Completion,
        r: xev.Async.WaitError!void,
    ) xev.CallbackAction {
        const span = trace.span(.wakeup_callback);
        defer span.deinit();
        span.debug("Wakeup callback triggered", .{});

        _ = r catch |err| {
            span.err("Error in wakeup callback: {}", .{err});
            // Consider pushing error event?
            return .rearm;
        };

        const thread = self_.?;

        thread.drainMailbox() catch |err| {
            span.err("Error processing mailbox: {}", .{err});
            // Consider pushing error event?
        };

        span.debug("Rearming wakeup callback", .{});
        return .rearm;
    }

    fn stopCallback(
        self: ?*ClientThread,
        _: *xev.Loop,
        _: *xev.Completion,
        r: xev.Async.WaitError!void,
    ) xev.CallbackAction {
        const span = trace.span(.stop_callback);
        defer span.deinit();
        span.debug("ClientThread stopping...", .{});

        if (r) {} else |err| {
            span.err("Error in stop callback: {}", .{err});
        }

        span.debug("Stopping event loop", .{});
        self.?.loop.stop();
        return .disarm;
    }

    fn drainMailbox(self: *ClientThread) !void {
        const span = trace.span(.drain_mailbox);
        defer span.deinit();
        span.debug("Draining mailbox", .{});

        var processed: usize = 0;
        while (self.mailbox.pop()) |command| {
            processed += 1;
            try self.processCommand(command);
        }

        span.debug("Processed {d} commands from mailbox", .{processed});
    }

    fn processCommand(self: *ClientThread, command: Command) !void {
        const span = trace.span(.process_command);
        defer span.deinit();
        span.debug("Processing command: {s}", .{@tagName(command)});

        switch (command) {
            .connect => |cmd| {
                const cmd_span = span.child(.connect);
                defer cmd_span.deinit();
                cmd_span.debug("Connecting to endpoint: {}", .{cmd.data});

                // Store metadata so we forward the metadata back to the client
                try self.pending_connects.put(cmd.data.connection_id, cmd.metadata);

                // The actual result (success or failure) comes via ConnectionEstablished/ConnectionFailed events
                self.client.connect(cmd.data.endpoint, cmd.data.connection_id) catch |err| {
                    cmd_span.err("Connection attempt failed immediately: {}", .{err});
                    // If connect() itself fails immediately, invoke callback with error
                    try self.pushEvent(.{ .connection_failed = .{
                        .endpoint = cmd.data.endpoint,
                        .connection_id = cmd.data.connection_id,
                        .err = err,
                        .metadata = cmd.metadata,
                    } });
                    return error.ConnectFailed;
                };

                cmd_span.debug("Connection attempt initiated", .{});
            },
            .disconnect => |cmd| {
                const cmd_span = span.child(.disconnect);
                defer cmd_span.deinit();
                cmd_span.debug("Disconnect requested for connection {}", .{cmd.data.connection_id});

                cmd_span.warn("Disconnect operation not implemented", .{});
                // FIXME: generate an event here
            },
            .create_stream => |cmd| {
                const cmd_span = span.child(.create_stream);
                defer cmd_span.deinit();
                cmd_span.debug("Creating stream on connection {}", .{cmd.data.connection_id});

                // Find the connection by ID
                if (self.client.connections.get(cmd.data.connection_id)) |conn| {

                    // Push the pending streams to the fifo, this has to be now, as createStream
                    // calls lsquic which if there is enough capacity will call the callback immediately
                    try self.pending_streams.writeItem(cmd);

                    // Create the stream, this will call lsquic to create it, we need to
                    // wait until the StreamCreated event to know the stream ID.
                    conn.createStream();
                    cmd_span.debug("Stream creation requested to LSQUIC", .{});
                    // Success/failure is signaled by the StreamCreated event later
                    // Callback will be invoked in internalStreamCreatedCallback
                } else {
                    cmd_span.warn("CreateStream command for unknown connection ID: {}", .{cmd.data.connection_id});
                    // FIXME: need to send an event here
                }
            },
            .destroy_stream => |cmd| {
                const cmd_span = span.child(.destroy_stream);
                defer cmd_span.deinit();
                cmd_span.debug("Destroying stream {} on connection {}", .{ cmd.data.stream_id, cmd.data.connection_id });

                if (self.client.streams.get(cmd.data.stream_id)) |stream| {
                    stream.close() catch |err| {
                        cmd_span.err("Failed to close stream {}: {}", .{ cmd.data.stream_id, err });
                        // FIXME: generate an event here
                        return; // Don't invoke success below
                    };
                    cmd_span.debug("Stream close requested successfully", .{});
                    // Success/failure is signaled by the StreamClosed event later.
                    // Invoke void callback immediately for destroy command intent.
                    // FIXME: generate an event here
                } else {
                    cmd_span.warn("DestroyStream command for unknown stream ID: {}", .{cmd.data.stream_id});
                    // FIXME: generate an event here
                }
            },
            .send_data => |cmd| {
                const cmd_span = span.child(.send_data);
                defer cmd_span.deinit();
                cmd_span.debug("Sending data on stream {} ({} bytes)", .{ cmd.data.stream_id, cmd.data.data.len });
                cmd_span.trace("Data: {any}", .{std.fmt.fmtSliceHexLower(cmd.data.data)});

                if (self.client.streams.get(cmd.data.stream_id)) |stream| {
                    // This sets the buffer for the next onWrite callback
                    stream.setWriteBuffer(cmd.data.data, .owned, .datawritecompleted) catch |err| {
                        cmd_span.err("Failed to set write buffer for stream {}: {}", .{ cmd.data.stream_id, err });
                        // FIXME: generate an event here
                        return; // Don't proceed if buffer setting fails
                    };
                    // Trigger the write callback
                    stream.wantWrite(true);
                    cmd_span.debug("Data queued successfully", .{});
                    // Command success means data was buffered. Actual send success
                    // comes via DataWriteCompleted/DataWriteError events.
                    // Invoke void callback immediately for send command intent.
                    // FIXME: generate an event here
                } else {
                    cmd_span.warn("SendData command for unknown stream ID: {}", .{cmd.data.stream_id});
                    // FIXME generate and event here
                }
            },
            .send_message => |cmd| {
                const cmd_span = span.child(.send_message);
                defer cmd_span.deinit();
                cmd_span.debug("Sending message on stream {} ({} bytes)", .{ cmd.data.stream_id, cmd.data.message.len });
                cmd_span.trace("Message first bytes: {any}", .{std.fmt.fmtSliceHexLower(if (cmd.data.message.len > 16) cmd.data.message[0..16] else cmd.data.message)});

                if (self.client.streams.get(cmd.data.stream_id)) |stream| {
                    // This creates a new buffer with length prefix and message data
                    stream.setMessageBuffer(cmd.data.message) catch |err| {
                        cmd_span.err("Failed to set message buffer for stream {}: {}", .{ cmd.data.stream_id, err });
                        // FIXME: generate an event here
                        return; // Don't proceed if buffer setting fails
                    };
                    // Trigger the write callback
                    stream.wantWrite(true);
                    cmd_span.debug("Message queued successfully", .{});
                    // Command success means message was buffered. Actual send success
                    // comes via DataWriteCompleted/DataWriteError events.
                } else {
                    cmd_span.warn("SendMessage command for unknown stream ID: {}", .{cmd.data.stream_id});
                }
            },
            .stream_want_read => |cmd| {
                const cmd_span = span.child(.stream_want_read);
                defer cmd_span.deinit();
                cmd_span.debug("Setting wantRead({}) on stream {}", .{ cmd.data.want, cmd.data.stream_id });

                if (self.client.streams.get(cmd.data.stream_id)) |stream| {
                    stream.wantRead(cmd.data.want);
                    cmd_span.debug("wantRead set successfully", .{});
                    // FIXME: generate an event here
                } else {
                    cmd_span.warn("StreamWantRead command for unknown stream ID: {}", .{cmd.data.stream_id});
                    // FIXME: generate an event here
                }
            },
            .stream_want_write => |cmd| {
                const cmd_span = span.child(.stream_want_write);
                defer cmd_span.deinit();
                cmd_span.debug("Setting wantWrite({}) on stream {}", .{ cmd.data.want, cmd.data.stream_id });

                if (self.client.streams.get(cmd.data.stream_id)) |stream| {
                    stream.wantWrite(cmd.data.want);
                    cmd_span.debug("wantWrite set successfully", .{});
                    // FIXME: generate an event here
                } else {
                    cmd_span.warn("StreamWantWrite command for unknown stream ID: {}", .{cmd.data.stream_id});
                    // FIXME: generate an event here
                }
            },
            .stream_flush => |cmd| {
                const cmd_span = span.child(.stream_flush);
                defer cmd_span.deinit();
                cmd_span.debug("Flushing stream {}", .{cmd.data.stream_id});

                if (self.client.streams.get(cmd.data.stream_id)) |stream| {
                    stream.flush() catch |err| {
                        cmd_span.err("Failed to flush stream {}: {}", .{ cmd.data.stream_id, err });
                        // FIXME: generate an event here
                        return; // Don't invoke success below
                    };
                    cmd_span.debug("Stream flushed successfully", .{});
                    // Success is immediate (or error)
                    // FIXME: generate an event here
                } else {
                    cmd_span.warn("StreamFlush command for unknown stream ID: {}", .{cmd.data.stream_id});
                    // FIXME: generate an event here
                }
            },
            .stream_shutdown => |cmd| {
                const cmd_span = span.child(.stream_shutdown);
                defer cmd_span.deinit();
                cmd_span.debug("Shutting down stream {} with mode {d}", .{ cmd.data.stream_id, cmd.data.how });

                if (self.client.streams.get(cmd.data.stream_id)) |stream| {
                    stream.shutdown(cmd.data.how) catch |err| {
                        cmd_span.err("Failed to shutdown stream {}: {}", .{ cmd.data.stream_id, err });
                        // FIXME: generate an event here
                        return; // Don't invoke success below
                    };
                    cmd_span.debug("Stream shutdown successful", .{});
                    // Success is immediate (or error)
                    // FIXME: generate an event here
                } else {
                    cmd_span.warn("StreamShutdown command for unknown stream ID: {}", .{cmd.data.stream_id});
                    // FIXME: generate an event here
                }
            },
        }
    }

    pub fn startThread(thread: *ClientThread) !std.Thread {
        return try std.Thread.spawn(.{}, ClientThread.threadMain, .{thread});
    }

    // -- Internal Callback Handlers
    // These run in the ClientThread's context and push events

    fn registerClientCallbacks(self: *ClientThread) void {
        // Pass 'self' as context so callbacks can access the thread state (event_queue, pending_connects)
        self.client.setCallback(.connection_established, internalConnectionEstablishedCallback, self);
        self.client.setCallback(.connection_failed, internalConnectionFailedCallback, self);
        self.client.setCallback(.connection_closed, internalConnectionClosedCallback, self);
        self.client.setCallback(.stream_created, internalStreamCreatedCallback, self);
        self.client.setCallback(.stream_closed, internalStreamClosedCallback, self);
        self.client.setCallback(.data_read_completed, internalDataReadCompletedCallback, self);
        self.client.setCallback(.data_read_end_of_stream, internalDataReadEndOfStreamCallback, self);
        self.client.setCallback(.data_read_error, internalDataReadErrorCallback, self);
        self.client.setCallback(.data_would_block, internalDataReadWouldBlockCallback, self);
        self.client.setCallback(.data_write_completed, internalDataWriteCompletedCallback, self);
        self.client.setCallback(.data_write_progress, internalDataWriteProgressCallback, self);
        self.client.setCallback(.data_write_error, internalDataWriteErrorCallback, self);
        self.client.setCallback(.message_send, internalMessageSendCallback, self);
        self.client.setCallback(.message_received, internalMessageReceivedCallback, self);
    }

    fn pushEvent(self: *ClientThread, event: Client.Event) !void {
        const span = trace.span(.push_event);
        defer span.deinit();
        span.debug("Pushing event: {s}", .{@tagName(event)});

        // Helper to push event, logs if queue is full
        if (self.event_queue.push(event, .instant) == 0) {
            span.err("Client event queue full, dropping event: {s}", .{@tagName(event)});
            return error.QueueFull;
        }
        span.debug("Event pushed successfully", .{});
    }

    fn internalConnectionEstablishedCallback(connection_id: ConnectionId, endpoint: network.EndPoint, context: ?*anyopaque) !void {
        const span = trace.span(.connection_established);
        defer span.deinit();
        span.debug("Connection established: ID={} endpoint={}", .{ connection_id, endpoint });

        const self: *ClientThread = @ptrCast(@alignCast(context.?));
        // Check if there was a pending connect command for this endpoint
        if (self.pending_connects.fetchRemove(connection_id)) |metadata| {
            try self.pushEvent(.{ .connected = .{ .connection_id = connection_id, .endpoint = endpoint, .metadata = metadata.value } });
            span.debug("Found pending connect command, invoking callback", .{});
        } else {
            // This can happen if connection was established without an explicit API call? Or a race?
            std.debug.panic("No pending connect on: {}", .{connection_id});
        }
    }

    fn internalConnectionFailedCallback(connection_id: ConnectionId, endpoint: network.EndPoint, err: anyerror, context: ?*anyopaque) !void {
        const span = trace.span(.connection_failed);
        defer span.deinit();
        span.err("Connection failed: endpoint={} error={}", .{ endpoint, err });

        // Connection Failed event is triggered immediatly before adding to pending_connects

        const self: *ClientThread = @ptrCast(@alignCast(context.?));
        // The connection_id is not available in this callback, so we cannot use it for the event.
        if (self.pending_connects.fetchRemove(connection_id)) |metadata| {
            try self.pushEvent(.{ .connection_failed = .{ .endpoint = endpoint, .connection_id = connection_id, .err = err, .metadata = metadata.value } });
        } else {
            std.debug.panic("No pending connect on: {}", .{connection_id});
        }
        // We should probably add the connection_id to this callback
        // so we can use it here.
    }

    fn internalConnectionClosedCallback(connection_id: ConnectionId, context: ?*anyopaque) !void {
        const span = trace.span(.connection_closed);
        defer span.deinit();
        span.debug("Connection closed: ID={}", .{connection_id});

        const self: *ClientThread = @ptrCast(@alignCast(context.?));

        // If we where trying to establish a connection but it closed we need to remove
        // the pending connection
        if (self.pending_connects.fetchRemove(connection_id)) |metadata| {
            span.debug("Found pending connect command, invoking callback", .{});
            metadata.value.callWithResult(connection_id); // Call command callback with success (ConnectionId)
        }

        try self.pushEvent(.{ .disconnected = .{ .connection_id = connection_id } });
    }

    fn internalStreamCreatedCallback(stream: *Stream(JamSnpClient), context: ?*anyopaque) !void {
        const span = trace.span(.stream_created);
        defer span.deinit();
        span.debug("Stream created: connection={} stream={}", .{ stream.connection.id, stream.id });

        const client_thread: *ClientThread = @ptrCast(@alignCast(context.?));

        switch (stream.origin()) {
            .local_initiated => {
                span.debug("Local initiated stream", .{});
                if (client_thread.pending_streams.readItem()) |cmd| {
                    // Set the write buffer and trigger lsquic to send it by setting
                    // wantWrite to true
                    try stream.setWriteBuffer(try client_thread.alloc.dupe(u8, std.mem.asBytes(&cmd.data.kind)), .owned, .none);
                    stream.wantWrite(true);
                    span.debug("Sending StreamKind to peer", .{});
                    try client_thread.pushEvent(.{ .stream_created = .{
                        .connection_id = stream.connection.id,
                        .stream_id = stream.id,
                        .kind = cmd.data.kind,
                        .metadata = cmd.metadata,
                    } });
                } else {
                    // This should never happen.
                    span.warn("StreamCreated event for connection {} with no pending stream command", .{stream.connection.id});
                    std.debug.panic("StreamCreated event for connection {} with no pending stream command", .{stream.connection.id});
                }
            },
            .remote_initiated => {
                span.debug("Remote initiated stream", .{});
                // This is a server-initiated stream, we need to create a new stream
                // object and push it to the event queue
                span.debug("Reading StreamKind from peer", .{});
                const stream_kind_buffer = try client_thread.alloc.alloc(u8, 1);
                try stream.setReadBuffer(stream_kind_buffer, .owned, .none);
                stream.wantRead(true);
            },
        }
    }

    fn internalStreamClosedCallback(connection_id: ConnectionId, stream_id: StreamId, context: ?*anyopaque) !void {
        const span = trace.span(.stream_closed);
        defer span.deinit();
        span.debug("Stream closed: connection={} stream={}", .{ connection_id, stream_id });

        const self: *ClientThread = @ptrCast(@alignCast(context.?));
        try self.pushEvent(.{ .stream_closed = .{ .connection_id = connection_id, .stream_id = stream_id } });
    }

    fn internalDataReadCompletedCallback(connection_id: ConnectionId, stream_id: StreamId, data: []const u8, context: ?*anyopaque) !void {
        const span = trace.span(.data_received);
        defer span.deinit();
        span.debug("Data received: connection={} stream={} size={d} bytes", .{ connection_id, stream_id, data.len });
        span.trace("Data: {any}", .{std.fmt.fmtSliceHexLower(data)});

        const self: *ClientThread = @ptrCast(@alignCast(context.?));
        try self.pushEvent(.{ .data_received = .{ .connection_id = connection_id, .stream_id = stream_id, .data = data } });
    }

    fn internalDataReadEndOfStreamCallback(connection_id: ConnectionId, stream_id: StreamId, data_read: []const u8, context: ?*anyopaque) !void {
        const span = trace.span(.data_end_of_stream);
        defer span.deinit();
        span.debug("End of stream: connection={} stream={} final_data_size={d} bytes", .{ connection_id, stream_id, data_read.len });
        if (data_read.len > 0) {
            span.trace("Final data: {any}", .{std.fmt.fmtSliceHexLower(data_read)});
        }

        const self: *ClientThread = @ptrCast(@alignCast(context.?));
        // Data might be partial from last read attempt. Copy it if needed.
        try self.pushEvent(.{ .data_end_of_stream = .{ .connection_id = connection_id, .stream_id = stream_id, .final_data = data_read } });
    }

    fn internalDataReadErrorCallback(connection_id: ConnectionId, stream_id: StreamId, error_code: i32, context: ?*anyopaque) !void {
        const span = trace.span(.data_read_error);
        defer span.deinit();
        span.err("Stream read error: connection={} stream={} error_code={d}", .{ connection_id, stream_id, error_code });

        const self: *ClientThread = @ptrCast(@alignCast(context.?));
        // Convert i32 error code to a Zig error if possible/meaningful
        try self.pushEvent(.{ .data_read_error = .{ .connection_id = connection_id, .stream_id = stream_id, .error_code = error_code } });
    }

    fn internalDataReadWouldBlockCallback(connection_id: ConnectionId, stream_id: StreamId, context: ?*anyopaque) !void {
        const span = trace.span(.data_read_would_block);
        defer span.deinit();
        span.debug("Read would block: connection={} stream={}", .{ connection_id, stream_id });

        const self: *ClientThread = @ptrCast(@alignCast(context.?));
        try self.pushEvent(.{ .data_read_would_block = .{ .connection_id = connection_id, .stream_id = stream_id } });
    }

    fn internalDataWriteCompletedCallback(connection_id: ConnectionId, stream_id: StreamId, total_bytes_written: usize, context: ?*anyopaque) !void {
        const span = trace.span(.data_write_completed);
        defer span.deinit();
        span.debug("Write completed: connection={} stream={} bytes={d}", .{ connection_id, stream_id, total_bytes_written });

        const self: *ClientThread = @ptrCast(@alignCast(context.?));
        try self.pushEvent(.{ .data_write_completed = .{ .connection_id = connection_id, .stream_id = stream_id, .total_bytes_written = total_bytes_written } });
    }

    fn internalDataWriteProgressCallback(connection_id: ConnectionId, stream_id: StreamId, bytes_written: usize, total_size: usize, context: ?*anyopaque) void {
        const span = trace.span(.data_write_progress);
        defer span.deinit();
        span.debug("Write progress: connection={} stream={} bytes={d}/{d} ({d}%)", .{ connection_id, stream_id, bytes_written, total_size, if (total_size > 0) (bytes_written * 100) / total_size else 0 });

        const self: *ClientThread = @ptrCast(@alignCast(context.?));
        // Optional: Push a progress event if desired by the application
        _ = self;
        // self.pushEvent(.{ .data_write_progress = .{ ... } });
    }

    fn internalDataWriteErrorCallback(connection_id: ConnectionId, stream_id: StreamId, error_code: i32, context: ?*anyopaque) !void {
        const span = trace.span(.data_write_error);
        defer span.deinit();
        span.err("Stream write error: connection={} stream={} error_code={d}", .{ connection_id, stream_id, error_code });

        const self: *ClientThread = @ptrCast(@alignCast(context.?));
        try self.pushEvent(.{ .data_write_error = .{ .connection_id = connection_id, .stream_id = stream_id, .error_code = error_code } });
    }

    fn internalMessageSendCallback(connection_id: ConnectionId, stream_id: StreamId, context: ?*anyopaque) !void {
        const span = trace.span(.message_send);
        defer span.deinit();
        span.debug("Message send: connection={} stream={}", .{ connection_id, stream_id });

        const self: *ClientThread = @ptrCast(@alignCast(context.?));
        try self.pushEvent(.{ .message_send = .{ .connection_id = connection_id, .stream_id = stream_id } });
    }

    fn internalMessageReceivedCallback(connection_id: ConnectionId, stream_id: StreamId, message: []const u8, context: ?*anyopaque) !void {
        const span = trace.span(.message_received);
        defer span.deinit();
        span.debug("Message received: connection={} stream={} size={d} bytes", .{ connection_id, stream_id, message.len });
        span.trace("Message first bytes: {any}", .{std.fmt.fmtSliceHexLower(if (message.len > 16) message[0..16] else message)});

        const self: *ClientThread = @ptrCast(@alignCast(context.?));
        try self.pushEvent(.{ .message_received = .{ .connection_id = connection_id, .stream_id = stream_id, .message = message } });
    }
};
