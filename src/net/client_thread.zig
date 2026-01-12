

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

const trace = @import("tracing").scoped(.network);

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
        var jclient = try JamSnpClient.initWithoutLoop(
            alloc,
            kp,
            gh,
            self._is_builder,
        );
        errdefer jclient.deinit();

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

        thread.alloc = alloc;

        try client.attachToLoop(&thread.loop);
        thread.client = client;

        thread.registerClientCallbacks();

        return thread;
    }

    /// Deinitializes the ClientThread and the JamSnpClient it owns.
    pub fn deinit(self: *ClientThread) void {
        const span = trace.span(@src(), .deinit);
        defer span.deinit();
        span.debug("Deinitializing ClientThread", .{});

        self.client.deinit();

        self.pending_streams.deinit();
        self.pending_connects.deinit(); // Deinit pending command maps
        self.event_queue.destroy(self.alloc);
        self.mailbox.destroy(self.alloc);
        self.stop.deinit();
        self.wakeup.deinit();
        self.loop.deinit();

        const alloc = self.alloc;
        self.* = undefined;
        alloc.destroy(self);
    }

    pub fn threadMain(self: *ClientThread) void {
        self.threadMain_() catch |err| {
            const span = trace.span(@src(), .thread_main);
            defer span.deinit();
            span.err("Error in thread: {}", .{err});
        };
    }

    fn threadMain_(self: *ClientThread) !void {
        const span = trace.span(@src(), .thread_main_impl);
        defer span.deinit();
        span.debug("Starting ClientThread main loop", .{});

        try self.threadSetup();
        defer self.threadCleanup();

        span.debug("Registering wakeup and stop callbacks", .{});
        self.wakeup.wait(&self.loop, &self.wakeup_c, ClientThread, self, wakeupCallback);
        self.stop.wait(&self.loop, &self.stop_c, ClientThread, self, stopCallback);

        span.debug("Running event loop", .{});
        _ = try self.loop.run(.until_done);

        span.debug("ClientThread main loop exited", .{});
    }

    fn threadSetup(_: *ClientThread) !void {
    }

    fn threadCleanup(_: *ClientThread) void {
    }

    fn wakeupCallback(
        self_: ?*ClientThread,
        _: *xev.Loop,
        _: *xev.Completion,
        r: xev.Async.WaitError!void,
    ) xev.CallbackAction {
        const span = trace.span(@src(), .wakeup_callback);
        defer span.deinit();
        span.debug("Wakeup callback triggered", .{});

        _ = r catch |err| {
            span.err("Error in wakeup callback: {}", .{err});
            return .rearm;
        };

        const thread = self_.?;

        thread.drainMailbox() catch |err| {
            span.err("Error processing mailbox: {}", .{err});
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
        const span = trace.span(@src(), .stop_callback);
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
        const span = trace.span(@src(), .drain_mailbox);
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
        const span = trace.span(@src(), .process_command);
        defer span.deinit();
        span.debug("Processing command: {s}", .{@tagName(command)});

        switch (command) {
            .connect => |cmd| {
                const cmd_span = span.child(@src(), .connect);
                defer cmd_span.deinit();
                cmd_span.debug("Connecting to endpoint: {}", .{cmd.data});

                try self.pending_connects.put(cmd.data.connection_id, cmd.metadata);

                self.client.connect(cmd.data.endpoint, cmd.data.connection_id) catch |err| {
                    cmd_span.err("Connection attempt failed immediately: {}", .{err});
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
                const cmd_span = span.child(@src(), .disconnect);
                defer cmd_span.deinit();
                cmd_span.debug("Disconnect requested for connection {}", .{cmd.data.connection_id});

                cmd_span.warn("Disconnect operation not implemented", .{});
                // FIXME: generate an event here
            },
            .create_stream => |cmd| {
                const cmd_span = span.child(@src(), .create_stream);
                defer cmd_span.deinit();
                cmd_span.debug("Creating stream on connection {}", .{cmd.data.connection_id});

                if (self.client.connections.get(cmd.data.connection_id)) |conn| {

                    try self.pending_streams.writeItem(cmd);

                    conn.createStream();
                    cmd_span.debug("Stream creation requested to LSQUIC", .{});
                } else {
                    cmd_span.warn("CreateStream command for unknown connection ID: {}", .{cmd.data.connection_id});
                    // FIXME: need to send an event here
                }
            },
            .destroy_stream => |cmd| {
                const cmd_span = span.child(@src(), .destroy_stream);
                defer cmd_span.deinit();
                cmd_span.debug("Destroying stream {} on connection {}", .{ cmd.data.stream_id, cmd.data.connection_id });

                if (self.client.streams.get(cmd.data.stream_id)) |stream| {
                    stream.close() catch |err| {
                        cmd_span.err("Failed to close stream {}: {}", .{ cmd.data.stream_id, err });
                        // FIXME: generate an event here
                        return; // Don't invoke success below
                    };
                    cmd_span.debug("Stream close requested successfully", .{});
                    // FIXME: generate an event here
                } else {
                    cmd_span.warn("DestroyStream command for unknown stream ID: {}", .{cmd.data.stream_id});
                    // FIXME: generate an event here
                }
            },
            .send_data => |cmd| {
                const cmd_span = span.child(@src(), .send_data);
                defer cmd_span.deinit();
                cmd_span.debug("Sending data on stream {} ({} bytes)", .{ cmd.data.stream_id, cmd.data.data.len });
                cmd_span.trace("Data: {any}", .{std.fmt.fmtSliceHexLower(cmd.data.data)});

                if (self.client.streams.get(cmd.data.stream_id)) |stream| {
                    stream.setWriteBuffer(cmd.data.data, .owned, .datawritecompleted) catch |err| {
                        cmd_span.err("Failed to set write buffer for stream {}: {}", .{ cmd.data.stream_id, err });
                        // FIXME: generate an event here
                        return; // Don't proceed if buffer setting fails
                    };
                    stream.wantWrite(true);
                    cmd_span.debug("Data queued successfully", .{});
                    // FIXME: generate an event here
                } else {
                    cmd_span.warn("SendData command for unknown stream ID: {}", .{cmd.data.stream_id});
                }
            },
            .send_message => |cmd| {
                const cmd_span = span.child(@src(), .send_message);
                defer cmd_span.deinit();
                cmd_span.debug("Sending message on stream {} ({} bytes)", .{ cmd.data.stream_id, cmd.data.message.len });
                cmd_span.trace("Message first bytes: {any}", .{std.fmt.fmtSliceHexLower(if (cmd.data.message.len > 16) cmd.data.message[0..16] else cmd.data.message)});

                if (self.client.streams.get(cmd.data.stream_id)) |stream| {
                    stream.setMessageBuffer(cmd.data.message) catch |err| {
                        cmd_span.err("Failed to set message buffer for stream {}: {}", .{ cmd.data.stream_id, err });
                        // FIXME: generate an event here
                        return; // Don't proceed if buffer setting fails
                    };
                    stream.wantWrite(true);
                    cmd_span.debug("Message queued successfully", .{});
                } else {
                    cmd_span.warn("SendMessage command for unknown stream ID: {}", .{cmd.data.stream_id});
                }
            },
            .stream_want_read => |cmd| {
                const cmd_span = span.child(@src(), .stream_want_read);
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
                const cmd_span = span.child(@src(), .stream_want_write);
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
                const cmd_span = span.child(@src(), .stream_flush);
                defer cmd_span.deinit();
                cmd_span.debug("Flushing stream {}", .{cmd.data.stream_id});

                if (self.client.streams.get(cmd.data.stream_id)) |stream| {
                    stream.flush() catch |err| {
                        cmd_span.err("Failed to flush stream {}: {}", .{ cmd.data.stream_id, err });
                        // FIXME: generate an event here
                        return; // Don't invoke success below
                    };
                    cmd_span.debug("Stream flushed successfully", .{});
                    // FIXME: generate an event here
                } else {
                    cmd_span.warn("StreamFlush command for unknown stream ID: {}", .{cmd.data.stream_id});
                    // FIXME: generate an event here
                }
            },
            .stream_shutdown => |cmd| {
                const cmd_span = span.child(@src(), .stream_shutdown);
                defer cmd_span.deinit();
                cmd_span.debug("Shutting down stream {} with mode {d}", .{ cmd.data.stream_id, cmd.data.how });

                if (self.client.streams.get(cmd.data.stream_id)) |stream| {
                    stream.shutdown(cmd.data.how) catch |err| {
                        cmd_span.err("Failed to shutdown stream {}: {}", .{ cmd.data.stream_id, err });
                        // FIXME: generate an event here
                        return; // Don't invoke success below
                    };
                    cmd_span.debug("Stream shutdown successful", .{});
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


    fn registerClientCallbacks(self: *ClientThread) void {
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
        const span = trace.span(@src(), .push_event);
        defer span.deinit();
        span.debug("Pushing event: {s}", .{@tagName(event)});

        if (self.event_queue.push(event, .instant) == 0) {
            span.err("Client event queue full, dropping event: {s}", .{@tagName(event)});
            return error.QueueFull;
        }
        span.debug("Event pushed successfully", .{});
    }

    fn internalConnectionEstablishedCallback(connection_id: ConnectionId, endpoint: network.EndPoint, context: ?*anyopaque) !void {
        const span = trace.span(@src(), .connection_established);
        defer span.deinit();
        span.debug("Connection established: ID={} endpoint={}", .{ connection_id, endpoint });

        const self: *ClientThread = @ptrCast(@alignCast(context.?));
        if (self.pending_connects.fetchRemove(connection_id)) |metadata| {
            try self.pushEvent(.{ .connected = .{ .connection_id = connection_id, .endpoint = endpoint, .metadata = metadata.value } });
            span.debug("Found pending connect command, invoking callback", .{});
        } else {
            std.debug.panic("No pending connect on: {}", .{connection_id});
        }
    }

    fn internalConnectionFailedCallback(connection_id: ConnectionId, endpoint: network.EndPoint, err: anyerror, context: ?*anyopaque) !void {
        const span = trace.span(@src(), .connection_failed);
        defer span.deinit();
        span.err("Connection failed: endpoint={} error={}", .{ endpoint, err });


        const self: *ClientThread = @ptrCast(@alignCast(context.?));
        if (self.pending_connects.fetchRemove(connection_id)) |metadata| {
            try self.pushEvent(.{ .connection_failed = .{ .endpoint = endpoint, .connection_id = connection_id, .err = err, .metadata = metadata.value } });
        } else {
            std.debug.panic("No pending connect on: {}", .{connection_id});
        }
    }

    fn internalConnectionClosedCallback(connection_id: ConnectionId, context: ?*anyopaque) !void {
        const span = trace.span(@src(), .connection_closed);
        defer span.deinit();
        span.debug("Connection closed: ID={}", .{connection_id});

        const self: *ClientThread = @ptrCast(@alignCast(context.?));

        if (self.pending_connects.fetchRemove(connection_id)) |metadata| {
            span.debug("Found pending connect command, invoking callback", .{});
            metadata.value.callWithResult(connection_id); // Call command callback with success (ConnectionId)
        }

        try self.pushEvent(.{ .disconnected = .{ .connection_id = connection_id } });
    }

    fn internalStreamCreatedCallback(stream: *Stream(JamSnpClient), context: ?*anyopaque) !void {
        const span = trace.span(@src(), .stream_created);
        defer span.deinit();
        span.debug("Stream created: connection={} stream={}", .{ stream.connection.id, stream.id });

        const client_thread: *ClientThread = @ptrCast(@alignCast(context.?));

        switch (stream.origin()) {
            .local_initiated => {
                span.debug("Local initiated stream", .{});
                if (client_thread.pending_streams.readItem()) |cmd| {
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
                    span.warn("StreamCreated event for connection {} with no pending stream command", .{stream.connection.id});
                    std.debug.panic("StreamCreated event for connection {} with no pending stream command", .{stream.connection.id});
                }
            },
            .remote_initiated => {
                span.debug("Remote initiated stream", .{});
                span.debug("Reading StreamKind from peer", .{});
                const stream_kind_buffer = try client_thread.alloc.alloc(u8, 1);
                try stream.setReadBuffer(stream_kind_buffer, .owned, .none);
                stream.wantRead(true);
            },
        }
    }

    fn internalStreamClosedCallback(connection_id: ConnectionId, stream_id: StreamId, context: ?*anyopaque) !void {
        const span = trace.span(@src(), .stream_closed);
        defer span.deinit();
        span.debug("Stream closed: connection={} stream={}", .{ connection_id, stream_id });

        const self: *ClientThread = @ptrCast(@alignCast(context.?));
        try self.pushEvent(.{ .stream_closed = .{ .connection_id = connection_id, .stream_id = stream_id } });
    }

    fn internalDataReadCompletedCallback(connection_id: ConnectionId, stream_id: StreamId, data: []const u8, context: ?*anyopaque) !void {
        const span = trace.span(@src(), .data_received);
        defer span.deinit();
        span.debug("Data received: connection={} stream={} size={d} bytes", .{ connection_id, stream_id, data.len });
        span.trace("Data: {any}", .{std.fmt.fmtSliceHexLower(data)});

        const self: *ClientThread = @ptrCast(@alignCast(context.?));
        try self.pushEvent(.{ .data_received = .{ .connection_id = connection_id, .stream_id = stream_id, .data = data } });
    }

    fn internalDataReadEndOfStreamCallback(connection_id: ConnectionId, stream_id: StreamId, data_read: []const u8, context: ?*anyopaque) !void {
        const span = trace.span(@src(), .data_end_of_stream);
        defer span.deinit();
        span.debug("End of stream: connection={} stream={} final_data_size={d} bytes", .{ connection_id, stream_id, data_read.len });
        if (data_read.len > 0) {
            span.trace("Final data: {any}", .{std.fmt.fmtSliceHexLower(data_read)});
        }

        const self: *ClientThread = @ptrCast(@alignCast(context.?));
        try self.pushEvent(.{ .data_end_of_stream = .{ .connection_id = connection_id, .stream_id = stream_id, .final_data = data_read } });
    }

    fn internalDataReadErrorCallback(connection_id: ConnectionId, stream_id: StreamId, error_code: i32, context: ?*anyopaque) !void {
        const span = trace.span(@src(), .data_read_error);
        defer span.deinit();
        span.err("Stream read error: connection={} stream={} error_code={d}", .{ connection_id, stream_id, error_code });

        const self: *ClientThread = @ptrCast(@alignCast(context.?));
        try self.pushEvent(.{ .data_read_error = .{ .connection_id = connection_id, .stream_id = stream_id, .error_code = error_code } });
    }

    fn internalDataReadWouldBlockCallback(connection_id: ConnectionId, stream_id: StreamId, context: ?*anyopaque) !void {
        const span = trace.span(@src(), .data_read_would_block);
        defer span.deinit();
        span.debug("Read would block: connection={} stream={}", .{ connection_id, stream_id });

        const self: *ClientThread = @ptrCast(@alignCast(context.?));
        try self.pushEvent(.{ .data_read_would_block = .{ .connection_id = connection_id, .stream_id = stream_id } });
    }

    fn internalDataWriteCompletedCallback(connection_id: ConnectionId, stream_id: StreamId, total_bytes_written: usize, context: ?*anyopaque) !void {
        const span = trace.span(@src(), .data_write_completed);
        defer span.deinit();
        span.debug("Write completed: connection={} stream={} bytes={d}", .{ connection_id, stream_id, total_bytes_written });

        const self: *ClientThread = @ptrCast(@alignCast(context.?));
        try self.pushEvent(.{ .data_write_completed = .{ .connection_id = connection_id, .stream_id = stream_id, .total_bytes_written = total_bytes_written } });
    }

    fn internalDataWriteProgressCallback(connection_id: ConnectionId, stream_id: StreamId, bytes_written: usize, total_size: usize, context: ?*anyopaque) void {
        const span = trace.span(@src(), .data_write_progress);
        defer span.deinit();
        span.debug("Write progress: connection={} stream={} bytes={d}/{d} ({d}%)", .{ connection_id, stream_id, bytes_written, total_size, if (total_size > 0) (bytes_written * 100) / total_size else 0 });

        const self: *ClientThread = @ptrCast(@alignCast(context.?));
        _ = self;
    }

    fn internalDataWriteErrorCallback(connection_id: ConnectionId, stream_id: StreamId, error_code: i32, context: ?*anyopaque) !void {
        const span = trace.span(@src(), .data_write_error);
        defer span.deinit();
        span.err("Stream write error: connection={} stream={} error_code={d}", .{ connection_id, stream_id, error_code });

        const self: *ClientThread = @ptrCast(@alignCast(context.?));
        try self.pushEvent(.{ .data_write_error = .{ .connection_id = connection_id, .stream_id = stream_id, .error_code = error_code } });
    }

    fn internalMessageSendCallback(connection_id: ConnectionId, stream_id: StreamId, context: ?*anyopaque) !void {
        const span = trace.span(@src(), .message_send);
        defer span.deinit();
        span.debug("Message send: connection={} stream={}", .{ connection_id, stream_id });

        const self: *ClientThread = @ptrCast(@alignCast(context.?));
        try self.pushEvent(.{ .message_send = .{ .connection_id = connection_id, .stream_id = stream_id } });
    }

    fn internalMessageReceivedCallback(connection_id: ConnectionId, stream_id: StreamId, message: []const u8, context: ?*anyopaque) !void {
        const span = trace.span(@src(), .message_received);
        defer span.deinit();
        span.debug("Message received: connection={} stream={} size={d} bytes", .{ connection_id, stream_id, message.len });
        span.trace("Message first bytes: {any}", .{std.fmt.fmtSliceHexLower(if (message.len > 16) message[0..16] else message)});

        const self: *ClientThread = @ptrCast(@alignCast(context.?));
        try self.pushEvent(.{ .message_received = .{ .connection_id = connection_id, .stream_id = stream_id, .message = message } });
    }
};
