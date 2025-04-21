//! Implementation of the ClientThread and Client. The design is
//! straightforward: the ClientThread is equipped with a mailbox capable of
//! receiving commands asynchronously. Upon execution of a command by the
//! JamSnpClient, an event is generated that associates the invocation with its
//! corresponding result.

const std = @import("std");
const xev = @import("xev");

const jamsnp_client = @import("jamsnp/client.zig");
const shared = @import("jamsnp/shared_types.zig");
const client_stream = @import("client/stream.zig");

const ConnectionId = shared.ConnectionId;
const StreamId = shared.StreamId;
const JamSnpClient = jamsnp_client.JamSnpClient;
const StreamHandle = client_stream.StreamHandle;

const Mailbox = @import("../datastruct/blocking_queue.zig").BlockingQueue;

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
    event_queue: *Mailbox(Client.Event, 64),

    pub const Command = union(enum) {
        pub const Connect = struct {
            const Data = struct {
                address: []const u8,
                port: u16,
            };

            data: Data,
            metadata: CommandMetadata(anyerror!ConnectionId),
        };

        pub const Disconnect = struct {
            const Data = struct {
                connection_id: ConnectionId,
            };

            data: Data,
            metadata: CommandMetadata(void),
        };

        pub const CreateStream = struct {
            const Data = struct {
                connection_id: ConnectionId,
            };

            data: Data,
            metadata: CommandMetadata(void),
        };

        pub const DestroyStream = struct {
            const Data = struct {
                connection_id: ConnectionId,
                stream_id: StreamId,
            };

            data: Data,
            metadata: CommandMetadata(void),
        };

        pub const SendData = struct {
            const Data = struct {
                connection_id: ConnectionId,
                stream_id: StreamId,
                data: []const u8,
            };

            data: Data,
            metadata: CommandMetadata(void),
        };

        pub const StreamWantRead = struct {
            const Data = struct {
                connection_id: ConnectionId,
                stream_id: StreamId,
                want: bool,
            };

            data: Data,
            metadata: CommandMetadata(void),
        };

        pub const StreamWantWrite = struct {
            const Data = struct {
                connection_id: ConnectionId,
                stream_id: StreamId,
                want: bool,
            };

            data: Data,
            metadata: CommandMetadata(void),
        };

        pub const StreamFlush = struct {
            const Data = struct {
                connection_id: ConnectionId,
                stream_id: StreamId,
            };

            data: Data,
            metadata: CommandMetadata(void),
        };

        pub const StreamShutdown = struct {
            const Data = struct {
                connection_id: ConnectionId,
                stream_id: StreamId,
                how: c_int,
            };

            data: Data,
            metadata: CommandMetadata(void),
        };

        pub const Shutdown = struct {
            metadata: CommandMetadata(void),
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
        shutdown: Shutdown,
    };

    pub const CommandResult = struct {
        pub fn Result(T: type) type {
            return struct {
                result: T,
                metadata: *const CommandMetadata(T),
            };
        }

        connect: Result(anyerror!ConnectionId),
        disconnect: Result(void),
        create_stream: Result(void),
        destroy_stream: Result(void),
        send_data: Result(void),
        stream_want_read: Result(void),
        stream_want_write: Result(void),
        stream_flush: Result(void),
        stream_shutdown: Result(void),

        /// Helper method to invoke the appropriate callback based on the result type
        pub fn invokeCallback(self: CommandResult) void {
            switch (self) {
                .connect => |result| result.metadata.callWithResult(result.result),
                .disconnect => |result| result.metadata.callWithResult(result.result),
                .create_stream => |result| result.metadata.callWithResult(result.result),
                .destroy_stream => |result| result.metadata.callWithResult(result.result),
                .send_data => |result| result.metadata.callWithResult(result.result),
                .stream_want_read => |result| result.metadata.callWithResult(result.result),
                .stream_want_write => |result| result.metadata.callWithResult(result.result),
                .stream_flush => |result| result.metadata.callWithResult(result.result),
                .stream_shutdown => |result| result.metadata.callWithResult(result.result),
            }
        }
    };

    pub fn initThread(alloc: std.mem.Allocator, client: *JamSnpClient) !*ClientThread {
        var thread = try alloc.create(ClientThread);
        errdefer alloc.destroy(thread);

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

        thread.alloc = alloc;

        if (client.loop) |_| {
            return error.ClientLoopAlreadyInitialized;
        }

        client.attachToLoop(&thread.loop);
        thread.client = client;

        return thread;
    }

    pub fn deinitThread(self: *ClientThread) void {
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

        try self.wakeup.notify();
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
            return .rearm;
        };

        const thread = self_.?;

        thread.drainMailbox() catch |err| {
            std.log.err("error processing mailbox err={}", .{err});
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

        switch (command) {
            .connect => |cmd| {
                _ = self.client.connect(cmd.data.address, cmd.data.port) catch |err| {
                    // Call the callback with error
                    cmd.metadata.callWithResult(err);
                    // FIXME: add the connection failed event
                };
            },
            .disconnect => |_| {
                // FIXME: add te disconnect call
            },
            .create_stream => |cmd| {
                // Find the connection by ID
                if (self.client.connections.get(cmd.data.connection_id)) |conn| {
                    conn.createStream() catch |err| {
                        // TODO: Handle stream creation failure (e.g., limits)
                        std.log.err("Failed to request stream creation: {}", .{err});
                        cmd.metadata.callWithResult(err); // Signal error?
                    };
                    // Success is signaled by the StreamCreated event later
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
                    };
                    // Success is signaled by StreamClosed event
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
                    // Success is signaled by DataWriteCompleted event
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
                    };
                    // Success is immediate (or error)
                    cmd.metadata.callWithResult({});
                } else {
                    std.log.warn("StreamShutdown command for unknown stream ID: {}", .{cmd.data.stream_id});
                    cmd.metadata.callWithResult(error.StreamNotFound);
                }
            },
            // .shutdown => unreachable, // Handled separately or via Client API
        }
    }

    pub fn startThread(thread: *ClientThread) !std.Thread {
        return try std.Thread.spawn(.{}, ClientThread.threadMain, .{thread});
    }
};

/// Client API for the JamSnpClient
pub const Client = struct {
    thread: *ClientThread,

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

        _ = self.thread.mailbox.push(command, .{ .instant = {} });
        try self.thread.wakeup.notify();
    }

    pub fn disconnect(self: *Client, connection_id: ConnectionId) !void {
        return self.disconnectWithCallback(connection_id, null, null);
    }

    pub fn disconnectWithCallback(
        self: *Client,
        connection_id: ConnectionId,
        callback: ?CommandCallback(void),
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

        _ = self.thread.mailbox.push(command, .{ .instant = {} });
        try self.thread.wakeup.notify();
    }

    pub fn createStream(self: *Client, connection_id: ConnectionId) !void {
        return self.createStreamWithCallback(connection_id, null, null);
    }

    pub fn createStreamWithCallback(
        self: *Client,
        connection_id: ConnectionId,
        callback: ?CommandCallback(void),
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

        _ = self.thread.mailbox.push(command, .{ .instant = {} });
        try self.thread.wakeup.notify();
    }

    pub fn destroyStream(self: *Client, stream: StreamHandle) !void {
        return self.destroyStreamWithCallback(stream, null, null);
    }

    pub fn destroyStreamWithCallback(
        self: *Client,
        stream: StreamHandle,
        callback: ?CommandCallback(void),
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

        _ = self.thread.mailbox.push(command, .{ .instant = {} });
        try self.thread.wakeup.notify();
    }

    pub fn shutdown(self: *const Client) !void {
        // Shutdown is now handled by ClientThread stopping its loop
        // No explicit shutdown command needed.
        return self.thread.stop.notify();
    }
};
