//!
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
        self.pending_connects.deinit(); // Deinit pending command maps
        // Deinit other pending command maps here
        self.event_queue.destroy(self.alloc);
        self.mailbox.destroy(self.alloc);
        self.stop.deinit();
        self.wakeup.deinit();
        self.loop.deinit();
        self.client.deinit();
        self.alloc.destroy(self);
    }

    pub fn threadMain(self: *ClientThread) void {
        // Handle errors gracefully
        self.threadMain_() catch |err| {
            std.log.warn("error in thread err={}", .{err});
        };
    }

    fn threadMain_(self: *ClientThread) !void {
        try self.threadSetup();
        defer self.threadCleanup();
        self.wakeup.wait(&self.loop, &self.wakeup_c, ClientThread, self, wakeupCallback);
        self.stop.wait(&self.loop, &self.stop_c, ClientThread, self, stopCallback);

        // Initial notify might not be needed if setup doesn't queue commands
        // try self.wakeup.notify();
        _ = try self.loop.run(.until_done);
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
        _ = r catch |err| {
            std.log.err("error in wakeup err={}", .{err});
            // Consider pushing error event?
            return .rearm;
        };

        const thread = self_.?;

        thread.drainMailbox() catch |err| {
            std.log.err("error processing mailbox err={}", .{err});
            // Consider pushing error event?
        };

        return .rearm;
    }

    fn stopCallback(
        self_: ?*ClientThread,
        _: *xev.Loop,
        _: *xev.Completion,
        r: xev.Async.WaitError!void,
    ) xev.CallbackAction {
        _ = r catch unreachable;
        self_.?.loop.stop();
        return .disarm;
    }

    fn drainMailbox(self: *ClientThread) !void {
        while (self.mailbox.pop()) |command| {
            try self.processCommand(command);
        }
    }

    fn processCommand(self: *ClientThread, command: Command) !void {
        // Find the connection or stream based on IDs in the command data
        // This requires the ClientThread to have access to the JamSnpClient's
        // connections and streams maps (or query the JamSnpClient).
        // For simplicity, let's assume direct access or helper functions exist.

        // Execute the command via JamSnpClient
        switch (command) {
            .connect => |cmd| {
                // The actual result (success or failure) comes via ConnectionEstablished/ConnectionFailed events
                _ = self.client.connect(cmd.data) catch |err| {
                    // If connect() itself fails immediately, invoke callback with error
                    try self.pushEvent(.{ .connection_failed = .{ .endpoint = cmd.data, .err = err } });
                };
            },
            .disconnect => |cmd| {
                // Disconnect is often synchronous in effect (signals intent)
                // Actual closure confirmed by ConnectionClosed event
                // TODO: JamSnpClient needs a `disconnect` method.
                // For now, assume it exists and might return an immediate error.
                // self.client.disconnect(cmd.data.connection_id) catch |err| {
                //     cmd.metadata.callWithResult(err);
                //     return;
                // };
                // Invoke void callback immediately for disconnect command request
                cmd.metadata.callWithResult(error.UnsupportedOperation); // Placeholder until disconnect implemented
            },
            .create_stream => |cmd| {
                // Find the connection by ID
                if (self.client.connections.get(cmd.data.connection_id)) |conn| {
                    // TODO: ClientConnection needs a createStream method
                    conn.createStream() catch |err| {
                        std.log.err("Failed to request stream creation on conn {}: {}", .{ cmd.data.connection_id, err });
                        // If we were storing metadata, invoke callback with error here:
                        // if (self.pending_stream_creates.fetchRemove(cmd.data.connection_id)) |meta| {
                        //     meta.value.callWithResult(err);
                        // }
                        cmd.metadata.callWithResult(err); // Invoke directly for now
                        return;
                    };
                    // Success/failure is signaled by the StreamCreated event later
                    // Callback will be invoked in internalStreamCreatedCallback
                } else {
                    std.log.warn("CreateStream command for unknown connection ID: {}", .{cmd.data.connection_id});
                    cmd.metadata.callWithResult(error.ConnectionNotFound);
                }
            },
            .destroy_stream => |cmd| {
                if (self.client.streams.get(cmd.data.stream_id)) |stream| {
                    stream.close() catch |err| {
                        std.log.err("Failed to close stream {}: {}", .{ cmd.data.stream_id, err });
                        cmd.metadata.callWithResult(err);
                        return; // Don't invoke success below
                    };
                    // Success/failure is signaled by the StreamClosed event later.
                    // Invoke void callback immediately for destroy command intent.
                    cmd.metadata.callWithResult({});
                } else {
                    std.log.warn("DestroyStream command for unknown stream ID: {}", .{cmd.data.stream_id});
                    cmd.metadata.callWithResult(error.StreamNotFound);
                }
            },
            .send_data => |cmd| {
                if (self.client.streams.get(cmd.data.stream_id)) |stream| {
                    // This sets the buffer for the next onWrite callback
                    stream.setWriteBuffer(cmd.data.data) catch |err| {
                        std.log.err("Failed to set write buffer for stream {}: {}", .{ cmd.data.stream_id, err });
                        cmd.metadata.callWithResult(err);
                        return; // Don't proceed if buffer setting fails
                    };
                    // Trigger the write callback
                    stream.wantWrite(true);
                    // Command success means data was buffered. Actual send success
                    // comes via DataWriteCompleted/DataWriteError events.
                    // Invoke void callback immediately for send command intent.
                    cmd.metadata.callWithResult({});
                } else {
                    std.log.warn("SendData command for unknown stream ID: {}", .{cmd.data.stream_id});
                    cmd.metadata.callWithResult(error.StreamNotFound);
                }
            },
            .stream_want_read => |cmd| {
                if (self.client.streams.get(cmd.data.stream_id)) |stream| {
                    stream.wantRead(cmd.data.want);
                    cmd.metadata.callWithResult({}); // Immediate success
                } else {
                    std.log.warn("StreamWantRead command for unknown stream ID: {}", .{cmd.data.stream_id});
                    cmd.metadata.callWithResult(error.StreamNotFound);
                }
            },
            .stream_want_write => |cmd| {
                if (self.client.streams.get(cmd.data.stream_id)) |stream| {
                    stream.wantWrite(cmd.data.want);
                    cmd.metadata.callWithResult({}); // Immediate success
                } else {
                    std.log.warn("StreamWantWrite command for unknown stream ID: {}", .{cmd.data.stream_id});
                    cmd.metadata.callWithResult(error.StreamNotFound);
                }
            },
            .stream_flush => |cmd| {
                if (self.client.streams.get(cmd.data.stream_id)) |stream| {
                    stream.flush() catch |err| {
                        std.log.err("Failed to flush stream {}: {}", .{ cmd.data.stream_id, err });
                        cmd.metadata.callWithResult(err);
                        return; // Don't invoke success below
                    };
                    // Success is immediate (or error)
                    cmd.metadata.callWithResult({});
                } else {
                    std.log.warn("StreamFlush command for unknown stream ID: {}", .{cmd.data.stream_id});
                    cmd.metadata.callWithResult(error.StreamNotFound);
                }
            },
            .stream_shutdown => |cmd| {
                if (self.client.streams.get(cmd.data.stream_id)) |stream| {
                    stream.shutdown(cmd.data.how) catch |err| {
                        std.log.err("Failed to shutdown stream {}: {}", .{ cmd.data.stream_id, err });
                        cmd.metadata.callWithResult(err);
                        return; // Don't invoke success below
                    };
                    // Success is immediate (or error)
                    cmd.metadata.callWithResult({});
                } else {
                    std.log.warn("StreamShutdown command for unknown stream ID: {}", .{cmd.data.stream_id});
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
        // Helper to push event, logs if queue is full
        if (self.event_queue.push(event, .instant) == 0) {
            std.log.warn("Client event queue full, dropping event: {any}", .{event});
            return error.QueueFull;
        }
    }

    fn internalConnectionEstablishedCallback(connection_id: ConnectionId, endpoint: network.EndPoint, context: ?*anyopaque) !void {
        const self: *ClientThread = @ptrCast(@alignCast(context.?));
        // Check if there was a pending connect command for this endpoint
        if (self.pending_connects.fetchRemove(endpoint)) |metadata| {
            metadata.value.callWithResult(connection_id); // Call command callback with success (ConnectionId)
        } else {
            // This can happen if connection was established without an explicit API call? Or a race?
            std.log.warn("ConnectionEstablished event for endpoint {} with no pending connect command", .{endpoint});
        }
        try self.pushEvent(.{ .connected = .{ .connection_id = connection_id, .endpoint = endpoint } });
    }

    fn internalConnectionFailedCallback(endpoint: network.EndPoint, err: anyerror, context: ?*anyopaque) !void {
        const self: *ClientThread = @ptrCast(@alignCast(context.?));
        // Check if there was a pending connect command for this endpoint
        if (self.pending_connects.fetchRemove(endpoint)) |metadata| {
            metadata.value.callWithResult(err); // Call command callback with error
        } else {
            std.log.warn("ConnectionFailed event for endpoint {} with no pending connect command", .{endpoint});
        }
        try self.pushEvent(.{ .connection_failed = .{ .endpoint = endpoint, .err = err } });
    }

    fn internalConnectionClosedCallback(connection_id: ConnectionId, context: ?*anyopaque) !void {
        const self: *ClientThread = @ptrCast(@alignCast(context.?));
        try self.pushEvent(.{ .disconnected = .{ .connection_id = connection_id } });
    }

    fn internalStreamCreatedCallback(connection_id: ConnectionId, stream_id: StreamId, context: ?*anyopaque) !void {
        const self: *ClientThread = @ptrCast(@alignCast(context.?));
        try self.pushEvent(.{ .stream_created = .{ .connection_id = connection_id, .stream_id = stream_id } });
    }

    fn internalStreamClosedCallback(connection_id: ConnectionId, stream_id: StreamId, context: ?*anyopaque) !void {
        const self: *ClientThread = @ptrCast(@alignCast(context.?));
        try self.pushEvent(.{ .stream_closed = .{ .connection_id = connection_id, .stream_id = stream_id } });
    }

    fn internalDataReceivedCallback(connection_id: ConnectionId, stream_id: StreamId, data: []const u8, context: ?*anyopaque) !void {
        const self: *ClientThread = @ptrCast(@alignCast(context.?));
        try self.pushEvent(.{ .data_received = .{ .connection_id = connection_id, .stream_id = stream_id, .data = data } });
    }

    fn internalDataEndOfStreamCallback(connection_id: ConnectionId, stream_id: StreamId, data_read: []const u8, context: ?*anyopaque) !void {
        const self: *ClientThread = @ptrCast(@alignCast(context.?));
        // Data might be partial from last read attempt. Copy it if needed.
        try self.pushEvent(.{ .data_end_of_stream = .{ .connection_id = connection_id, .stream_id = stream_id, .final_data = data_read } });
    }

    fn internalDataReadErrorCallback(connection_id: ConnectionId, stream_id: StreamId, error_code: i32, context: ?*anyopaque) !void {
        const self: *ClientThread = @ptrCast(@alignCast(context.?));
        // Convert i32 error code to a Zig error if possible/meaningful
        const err = error.StreamReadError; // Placeholder
        try self.pushEvent(.{ .data_read_error = .{ .connection_id = connection_id, .stream_id = stream_id, .err = err, .raw_error_code = error_code } });
    }

    fn internalDataReadWouldBlockCallback(connection_id: ConnectionId, stream_id: StreamId, context: ?*anyopaque) !void {
        const self: *ClientThread = @ptrCast(@alignCast(context.?));
        try self.pushEvent(.{ .data_read_would_block = .{ .connection_id = connection_id, .stream_id = stream_id } });
    }

    fn internalDataWriteCompletedCallback(connection_id: ConnectionId, stream_id: StreamId, total_bytes_written: usize, context: ?*anyopaque) !void {
        const self: *ClientThread = @ptrCast(@alignCast(context.?));
        try self.pushEvent(.{ .data_write_completed = .{ .connection_id = connection_id, .stream_id = stream_id, .bytes_written = total_bytes_written } });
    }

    fn internalDataWriteProgressCallback(connection_id: ConnectionId, stream_id: StreamId, bytes_written: usize, total_size: usize, context: ?*anyopaque) void {
        const self: *ClientThread = @ptrCast(@alignCast(context.?));
        // Optional: Push a progress event if desired by the application
        _ = self;
        _ = connection_id;
        _ = stream_id;
        _ = bytes_written;
        _ = total_size;
        // self.pushEvent(.{ .data_write_progress = .{ ... } });
    }

    fn internalDataWriteErrorCallback(connection_id: ConnectionId, stream_id: StreamId, error_code: i32, context: ?*anyopaque) !void {
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
    pub fn connect(self: *Client, address: []const u8, port: u16) !void {
        return self.connectWithCallback(address, port, null, null);
    }

    // Connect with callback for completion notification
    pub fn connectWithCallback(
        self: *Client,
        address: []const u8,
        port: u16,
        callback: ?CommandCallback(anyerror!ConnectionId),
        context: ?*anyopaque,
    ) !void {
        const command = ClientThread.Command{ .connect = .{
            .data = .{
                .address = address,
                .port = port,
            },
            .metadata = .{
                .callback = callback,
                .context = context,
            },
        } };
        if (!self.thread.mailbox.push(command, .{ .instant = {} })) {
            return error.MailboxFull;
        }
        try self.thread.wakeup.notify();
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
        if (!self.thread.mailbox.push(command, .{ .instant = {} })) {
            return error.MailboxFull;
        }
        try self.thread.wakeup.notify();
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
        const command = ClientThread.Command{ .create_stream = .{
            .data = .{
                .connection_id = connection_id,
            },
            .metadata = .{
                .callback = callback,
                .context = context,
            },
        } };
        if (!self.thread.mailbox.push(command, .{ .instant = {} })) {
            return error.MailboxFull;
        }
        try self.thread.wakeup.notify();
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
        if (!self.thread.mailbox.push(command, .{ .instant = {} })) {
            return error.MailboxFull;
        }
        try self.thread.wakeup.notify();
    }

    // --- Client API Methods ---

    pub fn shutdown(self: *Client) !void {
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
