//! Implementation of the ClientThread and Client. The design is
//! straightforward: the ClientThread is equipped with a mailbox capable of
//! receiving commands asynchronously. Upon execution of a command by the
//! JamSnpClient, an event is generated that associates the invocation with its
//! corresponding result.

const std = @import("std");
const xev = @import("xev");
const crypto = std.crypto;

const jamsnp_client = @import("jamsnp/client.zig");
const network = @import("network"); // Added for EndPoint

const shared = @import("jamsnp/shared_types.zig");
const ConnectionId = shared.ConnectionId;
const StreamId = shared.StreamId;
const JamSnpClient = jamsnp_client.JamSnpClient;
const StreamHandle = @import("stream_handle.zig").StreamHandle;

const Mailbox = @import("../datastruct/blocking_queue.zig").BlockingQueue;

const trace = @import("../tracing.zig").scoped(.network);

/// Builder for creating a ClientThread instance.
/// Ensures that the underlying JamSnpClient is also initialized.
pub const ClientThreadBuilder = struct {
    _allocator: ?std.mem.Allocator = null,
    _keypair: ?crypto.sign.Ed25519.KeyPair = null,
    _genesis_hash: ?[]const u8 = null,
    _is_builder: bool = false,

    pub fn init() ClientThreadBuilder {
        return .{};
    }

    pub fn allocator(self: *ClientThreadBuilder, alloc: std.mem.Allocator) *ClientThreadBuilder {
        self._allocator = alloc;
        return self;
    }

    pub fn keypair(self: *ClientThreadBuilder, kp: crypto.sign.Ed25519.KeyPair) *ClientThreadBuilder {
        self._keypair = kp;
        return self;
    }

    pub fn genesisHash(self: *ClientThreadBuilder, hash: []const u8) *ClientThreadBuilder {
        self._genesis_hash = hash;
        return self;
    }

    pub fn isBuilder(self: *ClientThreadBuilder, is_builder: bool) *ClientThreadBuilder {
        self._is_builder = is_builder;
        return self;
    }

    /// Builds the ClientThread.
    /// This involves initializing the JamSnpClient first, then the ClientThread itself.
    pub fn build(self: *const ClientThreadBuilder) !*ClientThread {
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

/// Callback type for command completion
pub fn CommandCallback(T: type) type {
    return *const fn (result: T, context: ?*anyopaque) void;
}

pub fn CommandMetadata(T: type) type {
    return struct {
        callback: ?CommandCallback(T) = null,
        context: ?*anyopaque = null,

        pub fn callWithResult(self: *const CommandMetadata(T), result: T) void {
            if (self.callback) |callback| {
                callback(result, self.context);
            }
        }
    };
}

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
    pending_connects: std.AutoHashMap(network.EndPoint, CommandMetadata(anyerror!ConnectionId)),
    // TODO: Add maps for other commands needing async callbacks if necessary (e.g., CreateStream)
    // pending_stream_creates: std.AutoHashMap(ConnectionId, CommandMetadata(anyerror!StreamId)), // Example

    pub const Command = union(enum) {
        pub const Connect = struct {
            const Data = network.EndPoint;
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
                data: []const u8, // Caller owns
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
        stream_want_read: StreamWantRead,
        stream_want_write: StreamWantWrite,
        stream_flush: StreamFlush,
        stream_shutdown: StreamShutdown,
    };

    // CommandResult is less relevant now as results come via events/callbacks
    // pub const CommandResult = ...

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

        thread.pending_connects = std.AutoHashMap(network.EndPoint, CommandMetadata(anyerror!ConnectionId)).init(alloc);
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

        // Find the connection or stream based on IDs in the command data
        // This requires the ClientThread to have access to the JamSnpClient's
        // connections and streams maps (or query the JamSnpClient).
        // For simplicity, let's assume direct access or helper functions exist.

        // Execute the command via JamSnpClient
        switch (command) {
            .connect => |cmd| {
                const cmd_span = span.child(.connect);
                defer cmd_span.deinit();
                cmd_span.debug("Connecting to endpoint: {}", .{cmd.data});

                // The actual result (success or failure) comes via ConnectionEstablished/ConnectionFailed events
                _ = self.client.connect(cmd.data) catch |err| {
                    cmd_span.err("Connection attempt failed immediately: {}", .{err});
                    // If connect() itself fails immediately, invoke callback with error
                    try self.pushEvent(.{ .connection_failed = .{ .endpoint = cmd.data, .err = err } });
                };
                cmd_span.debug("Connection attempt initiated", .{});
            },
            .disconnect => |cmd| {
                const cmd_span = span.child(.disconnect);
                defer cmd_span.deinit();
                cmd_span.debug("Disconnect requested for connection {}", .{cmd.data.connection_id});

                // Disconnect is often synchronous in effect (signals intent)
                // Actual closure confirmed by ConnectionClosed event
                // TODO: JamSnpClient needs a `disconnect` method.
                // For now, assume it exists and might return an immediate error.
                // self.client.disconnect(cmd.data.connection_id) catch |err| {
                //     cmd.metadata.callWithResult(err);
                //     return;
                // };
                // Invoke void callback immediately for disconnect command request
                cmd_span.warn("Disconnect operation not implemented", .{});
                cmd.metadata.callWithResult(error.UnsupportedOperation); // Placeholder until disconnect implemented
            },
            .create_stream => |cmd| {
                const cmd_span = span.child(.create_stream);
                defer cmd_span.deinit();
                cmd_span.debug("Creating stream on connection {}", .{cmd.data.connection_id});

                // Find the connection by ID
                if (self.client.connections.get(cmd.data.connection_id)) |conn| {
                    // TODO: ClientConnection needs a createStream method
                    conn.createStream() catch |err| {
                        cmd_span.err("Failed to request stream creation on conn {}: {}", .{ cmd.data.connection_id, err });
                        // If we were storing metadata, invoke callback with error here:
                        // if (self.pending_stream_creates.fetchRemove(cmd.data.connection_id)) |meta| {
                        //     meta.value.callWithResult(err);
                        // }
                        cmd.metadata.callWithResult(err); // Invoke directly for now
                        return;
                    };
                    cmd_span.debug("Stream creation requested successfully", .{});
                    // Success/failure is signaled by the StreamCreated event later
                    // Callback will be invoked in internalStreamCreatedCallback
                } else {
                    cmd_span.warn("CreateStream command for unknown connection ID: {}", .{cmd.data.connection_id});
                    cmd.metadata.callWithResult(error.ConnectionNotFound);
                }
            },
            .destroy_stream => |cmd| {
                const cmd_span = span.child(.destroy_stream);
                defer cmd_span.deinit();
                cmd_span.debug("Destroying stream {} on connection {}", .{ cmd.data.stream_id, cmd.data.connection_id });

                if (self.client.streams.get(cmd.data.stream_id)) |stream| {
                    stream.close() catch |err| {
                        cmd_span.err("Failed to close stream {}: {}", .{ cmd.data.stream_id, err });
                        cmd.metadata.callWithResult(err);
                        return; // Don't invoke success below
                    };
                    cmd_span.debug("Stream close requested successfully", .{});
                    // Success/failure is signaled by the StreamClosed event later.
                    // Invoke void callback immediately for destroy command intent.
                    cmd.metadata.callWithResult({});
                } else {
                    cmd_span.warn("DestroyStream command for unknown stream ID: {}", .{cmd.data.stream_id});
                    cmd.metadata.callWithResult(error.StreamNotFound);
                }
            },
            .send_data => |cmd| {
                const cmd_span = span.child(.send_data);
                defer cmd_span.deinit();
                cmd_span.debug("Sending data on stream {} ({} bytes)", .{ cmd.data.stream_id, cmd.data.data.len });
                cmd_span.trace("Data: {any}", .{std.fmt.fmtSliceHexLower(cmd.data.data)});

                if (self.client.streams.get(cmd.data.stream_id)) |stream| {
                    // This sets the buffer for the next onWrite callback
                    stream.setWriteBuffer(cmd.data.data) catch |err| {
                        cmd_span.err("Failed to set write buffer for stream {}: {}", .{ cmd.data.stream_id, err });
                        cmd.metadata.callWithResult(err);
                        return; // Don't proceed if buffer setting fails
                    };
                    // Trigger the write callback
                    stream.wantWrite(true);
                    cmd_span.debug("Data queued successfully", .{});
                    // Command success means data was buffered. Actual send success
                    // comes via DataWriteCompleted/DataWriteError events.
                    // Invoke void callback immediately for send command intent.
                    cmd.metadata.callWithResult({});
                } else {
                    cmd_span.warn("SendData command for unknown stream ID: {}", .{cmd.data.stream_id});
                    cmd.metadata.callWithResult(error.StreamNotFound);
                }
            },
            .stream_want_read => |cmd| {
                const cmd_span = span.child(.stream_want_read);
                defer cmd_span.deinit();
                cmd_span.debug("Setting wantRead({}) on stream {}", .{ cmd.data.want, cmd.data.stream_id });

                if (self.client.streams.get(cmd.data.stream_id)) |stream| {
                    stream.wantRead(cmd.data.want);
                    cmd_span.debug("wantRead set successfully", .{});
                    cmd.metadata.callWithResult({}); // Immediate success
                } else {
                    cmd_span.warn("StreamWantRead command for unknown stream ID: {}", .{cmd.data.stream_id});
                    cmd.metadata.callWithResult(error.StreamNotFound);
                }
            },
            .stream_want_write => |cmd| {
                const cmd_span = span.child(.stream_want_write);
                defer cmd_span.deinit();
                cmd_span.debug("Setting wantWrite({}) on stream {}", .{ cmd.data.want, cmd.data.stream_id });

                if (self.client.streams.get(cmd.data.stream_id)) |stream| {
                    stream.wantWrite(cmd.data.want);
                    cmd_span.debug("wantWrite set successfully", .{});
                    cmd.metadata.callWithResult({}); // Immediate success
                } else {
                    cmd_span.warn("StreamWantWrite command for unknown stream ID: {}", .{cmd.data.stream_id});
                    cmd.metadata.callWithResult(error.StreamNotFound);
                }
            },
            .stream_flush => |cmd| {
                const cmd_span = span.child(.stream_flush);
                defer cmd_span.deinit();
                cmd_span.debug("Flushing stream {}", .{cmd.data.stream_id});

                if (self.client.streams.get(cmd.data.stream_id)) |stream| {
                    stream.flush() catch |err| {
                        cmd_span.err("Failed to flush stream {}: {}", .{ cmd.data.stream_id, err });
                        cmd.metadata.callWithResult(err);
                        return; // Don't invoke success below
                    };
                    cmd_span.debug("Stream flushed successfully", .{});
                    // Success is immediate (or error)
                    cmd.metadata.callWithResult({});
                } else {
                    cmd_span.warn("StreamFlush command for unknown stream ID: {}", .{cmd.data.stream_id});
                    cmd.metadata.callWithResult(error.StreamNotFound);
                }
            },
            .stream_shutdown => |cmd| {
                const cmd_span = span.child(.stream_shutdown);
                defer cmd_span.deinit();
                cmd_span.debug("Shutting down stream {} with mode {d}", .{ cmd.data.stream_id, cmd.data.how });

                if (self.client.streams.get(cmd.data.stream_id)) |stream| {
                    stream.shutdown(cmd.data.how) catch |err| {
                        cmd_span.err("Failed to shutdown stream {}: {}", .{ cmd.data.stream_id, err });
                        cmd.metadata.callWithResult(err);
                        return; // Don't invoke success below
                    };
                    cmd_span.debug("Stream shutdown successful", .{});
                    // Success is immediate (or error)
                    cmd.metadata.callWithResult({});
                } else {
                    cmd_span.warn("StreamShutdown command for unknown stream ID: {}", .{cmd.data.stream_id});
                    cmd.metadata.callWithResult(error.StreamNotFound);
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
        self.client.setCallback(.ConnectionEstablished, internalConnectionEstablishedCallback, self);
        self.client.setCallback(.ConnectionFailed, internalConnectionFailedCallback, self);
        self.client.setCallback(.ConnectionClosed, internalConnectionClosedCallback, self);
        self.client.setCallback(.StreamCreated, internalStreamCreatedCallback, self);
        self.client.setCallback(.StreamClosed, internalStreamClosedCallback, self);
        self.client.setCallback(.DataReceived, internalDataReceivedCallback, self);
        self.client.setCallback(.DataEndOfStream, internalDataEndOfStreamCallback, self);
        self.client.setCallback(.DataReadError, internalDataReadErrorCallback, self);
        self.client.setCallback(.DataWouldBlock, internalDataReadWouldBlockCallback, self);
        self.client.setCallback(.DataWriteCompleted, internalDataWriteCompletedCallback, self);
        self.client.setCallback(.DataWriteProgress, internalDataWriteProgressCallback, self);
        self.client.setCallback(.DataWriteError, internalDataWriteErrorCallback, self);
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
        if (self.pending_connects.fetchRemove(endpoint)) |metadata| {
            span.debug("Found pending connect command, invoking callback", .{});
            metadata.value.callWithResult(connection_id); // Call command callback with success (ConnectionId)
        } else {
            // This can happen if connection was established without an explicit API call? Or a race?
            span.warn("ConnectionEstablished event for endpoint {} with no pending connect command", .{endpoint});
        }
        try self.pushEvent(.{ .connected = .{ .connection_id = connection_id, .endpoint = endpoint } });
    }

    fn internalConnectionFailedCallback(endpoint: network.EndPoint, err: anyerror, context: ?*anyopaque) !void {
        const span = trace.span(.connection_failed);
        defer span.deinit();
        span.err("Connection failed: endpoint={} error={}", .{ endpoint, err });

        const self: *ClientThread = @ptrCast(@alignCast(context.?));
        // Check if there was a pending connect command for this endpoint
        if (self.pending_connects.fetchRemove(endpoint)) |metadata| {
            span.debug("Found pending connect command, invoking callback with error", .{});
            metadata.value.callWithResult(err); // Call command callback with error
        } else {
            span.warn("ConnectionFailed event for endpoint {} with no pending connect command", .{endpoint});
        }
        try self.pushEvent(.{ .connection_failed = .{ .endpoint = endpoint, .err = err } });
    }

    fn internalConnectionClosedCallback(connection_id: ConnectionId, context: ?*anyopaque) !void {
        const span = trace.span(.connection_closed);
        defer span.deinit();
        span.debug("Connection closed: ID={}", .{connection_id});

        const self: *ClientThread = @ptrCast(@alignCast(context.?));
        try self.pushEvent(.{ .disconnected = .{ .connection_id = connection_id } });
    }

    fn internalStreamCreatedCallback(connection_id: ConnectionId, stream_id: StreamId, context: ?*anyopaque) !void {
        const span = trace.span(.stream_created);
        defer span.deinit();
        span.debug("Stream created: connection={} stream={}", .{ connection_id, stream_id });

        const self: *ClientThread = @ptrCast(@alignCast(context.?));
        try self.pushEvent(.{ .stream_created = .{ .connection_id = connection_id, .stream_id = stream_id } });
    }

    fn internalStreamClosedCallback(connection_id: ConnectionId, stream_id: StreamId, context: ?*anyopaque) !void {
        const span = trace.span(.stream_closed);
        defer span.deinit();
        span.debug("Stream closed: connection={} stream={}", .{ connection_id, stream_id });

        const self: *ClientThread = @ptrCast(@alignCast(context.?));
        try self.pushEvent(.{ .stream_closed = .{ .connection_id = connection_id, .stream_id = stream_id } });
    }

    fn internalDataReceivedCallback(connection_id: ConnectionId, stream_id: StreamId, data: []const u8, context: ?*anyopaque) !void {
        const span = trace.span(.data_received);
        defer span.deinit();
        span.debug("Data received: connection={} stream={} size={d} bytes", .{ connection_id, stream_id, data.len });
        span.trace("Data: {any}", .{std.fmt.fmtSliceHexLower(data)});

        const self: *ClientThread = @ptrCast(@alignCast(context.?));
        try self.pushEvent(.{ .data_received = .{ .connection_id = connection_id, .stream_id = stream_id, .data = data } });
    }

    fn internalDataEndOfStreamCallback(connection_id: ConnectionId, stream_id: StreamId, data_read: []const u8, context: ?*anyopaque) !void {
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
        const err = error.StreamReadError; // Placeholder
        try self.pushEvent(.{ .data_read_error = .{ .connection_id = connection_id, .stream_id = stream_id, .err = err, .raw_error_code = error_code } });
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
        try self.pushEvent(.{ .data_write_completed = .{ .connection_id = connection_id, .stream_id = stream_id, .bytes_written = total_bytes_written } });
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
        const err = error.StreamWriteError; // Placeholder
        try self.pushEvent(.{ .data_write_error = .{ .connection_id = connection_id, .stream_id = stream_id, .err = err, .raw_error_code = error_code } });
    }
};

/// Client API for the JamSnpClient
pub const Client = struct {
    thread: *ClientThread,

    pub const Event = union(enum) {
        connected: struct {
            connection_id: ConnectionId,
            endpoint: network.EndPoint,
        },
        connection_failed: struct {
            endpoint: network.EndPoint,
            err: anyerror,
        },
        disconnected: struct {
            connection_id: ConnectionId,
        },
        stream_created: struct { // Includes streams created by peer? Server only has stream_created_by_client
            connection_id: ConnectionId,
            stream_id: StreamId,
        },
        stream_closed: struct {
            connection_id: ConnectionId,
            stream_id: StreamId,
        },
        data_received: struct {
            connection_id: ConnectionId,
            stream_id: StreamId,
            data: []const u8, // Owned by event, must be freed by consumer
        },
        data_end_of_stream: struct {
            connection_id: ConnectionId,
            stream_id: StreamId,
            final_data: []const u8, // Data read just before EOS, owned by event
        },
        data_write_completed: struct { // Signifies buffer sent by SendData is done
            connection_id: ConnectionId,
            stream_id: StreamId,
            bytes_written: usize,
        },
        // data_write_progress: struct { ... }, // Optional

        // -- Error/Status Events --
        data_read_error: struct {
            connection_id: ConnectionId,
            stream_id: StreamId,
            err: anyerror,
            raw_error_code: i32,
        },
        data_write_error: struct { // Error sending buffer from SendData
            connection_id: ConnectionId,
            stream_id: StreamId,
            err: anyerror,
            raw_error_code: i32,
        },
        data_read_would_block: struct { // Info: reading stopped, call wantRead(true) again
            connection_id: ConnectionId,
            stream_id: StreamId,
        },
        data_write_would_block: struct { // Info: writing stopped, call wantWrite(true) again if more data
            connection_id: ConnectionId,
            stream_id: StreamId,
        },
        @"error": struct { // General error event
            message: []const u8, // Can be literal or allocated (check details)
            details: ?anyerror,
        },

        // --- Helper method to free associated data ---
        pub fn freeData(self: Event, allocator: std.mem.Allocator) void {
            switch (self) {
                .data_received => |ev| allocator.free(ev.data),
                .data_end_of_stream => |ev| allocator.free(ev.final_data),
                // Free message if allocated
                // .@"error" => |ev| if (ev.message_is_allocated) allocator.free(ev.message),
                else => {},
            }
        }
    };

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

        const command = ClientThread.Command{ .connect = .{
            .data = endpoint,
            .metadata = .{
                .callback = callback,
                .context = context,
            },
        } };
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
    pub fn createStream(self: *Client, connection_id: ConnectionId) !void {
        return self.createStreamWithCallback(connection_id, null, null);
    }

    pub fn createStreamWithCallback(
        self: *Client,
        connection_id: ConnectionId,
        callback: ?CommandCallback(anyerror!StreamId), // Callback returns StreamId
        context: ?*anyopaque,
    ) !void {
        const span = trace.span(.create_stream_with_callback);
        defer span.deinit();
        span.debug("Create stream requested on connection: {}", .{connection_id});

        const command = ClientThread.Command{ .create_stream = .{
            .data = .{
                .connection_id = connection_id,
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
