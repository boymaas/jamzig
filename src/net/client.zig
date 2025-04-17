//! Implementation of the ClientThread and Client. The design is
//! straightforward: the ClientThread is equipped with a mailbox capable of
//! receiving commands asynchronously. Upon execution of a command by the
//! JamSnpClient, an event is generated that associates the invocation with its
//! corresponding result.

const std = @import("std");
const xev = @import("xev");

const JamSnpClient = @import("jamsnp/client.zig").JamSnpClient;
const types = @import("types.zig");
const ConnectionId = types.ConnectionId;
const StreamId = types.StreamId;

const Mailbox = @import("../datastruct/blocking_queue.zig").BlockingQueue;

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
        const Connect = struct {
            address: []const u8,
            port: u16,
        };

        const Disconnect = struct {
            connection_id: ConnectionId,
        };

        const CreateStream = struct {
            connection_id: ConnectionId,
        };

        const DestroyStream = struct {
            connection_id: ConnectionId,
            stream_id: StreamId,
        };

        const SendData = struct {
            connection_id: ConnectionId,
            stream_id: StreamId,
            data: []const u8,
        };

        const StreamWantRead = struct {
            connection_id: ConnectionId,
            stream_id: StreamId,
            want: bool,
        };

        const StreamWantWrite = struct {
            connection_id: ConnectionId,
            stream_id: StreamId,
            want: bool,
        };

        const StreamFlush = struct {
            connection_id: ConnectionId,
            stream_id: StreamId,
        };

        const StreamShutdown = struct {
            connection_id: ConnectionId,
            stream_id: StreamId,
            how: c_int,
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
        shutdown: void,
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
            switch (command) {
                .shutdown => try self.stop.notify(),
                .connect, .disconnect, .create_stream, .destroy_stream, .send_data => {
                    try self.processCommand(command);
                },
            }
        }
    }

    fn processCommand(self: *ClientThread, command: Command) !void {
        switch (command) {
            .connect => |connect_data| {
                try self.client.connect(connect_data.address, connect_data.port);

                // TODO: Get actual connection ID from JamSnpClient
                _ = self.event_queue.push(.{
                    .type = .connected,
                }, .{ .instant = {} });
            },
            .disconnect => |disconnect_data| {
                // TODO: Implement using JamSnpClient
                _ = self.event_queue.push(.{
                    .type = .disconnected,
                    .connection_id = disconnect_data.connection_id,
                }, .{ .instant = {} });
            },
            .create_stream => |create_stream_data| {
                // Find the connection by ID
                // For now, assuming we have a connection map
                // TODO: Implement actual connection lookup

                // Create the stream using JamSnpClient
                // TODO: Replace with actual implementation
                const stream_id: StreamId = StreamId.fromRaw(1); // Placeholder

                // Generate stream_created event
                _ = self.event_queue.push(.{
                    .type = .stream_created,
                    .connection_id = create_stream_data.connection_id,
                    .stream_id = stream_id,
                }, .{ .instant = {} });
            },
            .destroy_stream => |destroy_stream_data| {
                // Find the stream by ID
                // TODO: Implement actual stream lookup

                // Close the stream
                // TODO: Implement actual stream closing

                // Generate stream_destroyed event
                _ = self.event_queue.push(.{
                    .type = .stream_destroyed,
                    .connection_id = destroy_stream_data.connection_id,
                    .stream_id = destroy_stream_data.stream_id,
                }, .{ .instant = {} });
            },
            .send_data => |send_data| {
                // Find the stream by ID
                // TODO: Implement actual stream lookup

                // Write data to the stream
                // TODO: Implement actual data writing

                // For now, just acknowledge the data was sent
                _ = send_data;
            },
            .stream_want_read => |want_read| {
                // Find the stream by ID
                // TODO: Implement actual stream lookup

                // Set want-read on the stream
                // TODO: Implement actual want-read setting
                _ = want_read;
            },
            .stream_want_write => |want_write| {
                // Find the stream by ID
                // TODO: Implement actual stream lookup

                // Set want-write on the stream
                // TODO: Implement actual want-write setting
                _ = want_write;
            },
            .stream_flush => |flush| {
                // Find the stream by ID
                // TODO: Implement actual stream lookup

                // Flush the stream
                // TODO: Implement actual stream flushing
                _ = flush;
            },
            .stream_shutdown => |shutdown| {
                // Find the stream by ID
                // TODO: Implement actual stream lookup

                // Shutdown the stream
                // TODO: Implement actual stream shutdown
                _ = shutdown;
            },
            .shutdown => {},
        }
    }

    pub fn wakeupThread(thread: *ClientThread) !void {
        _ = thread.mailbox.push(.{ .work_item = .{} }, .{ .instant = {} });
        try thread.wakeup.notify();
    }

    pub fn startThread(thread: *ClientThread) !std.Thread {
        return try std.Thread.spawn(.{}, ClientThread.threadMain, .{thread});
    }
};

// On each action here, a command will be pushed to the mailbox of the thread, and it will always result
pub const Client = struct {
    thread: *ClientThread,
    event_handler: ?EventHandler = null,

    const EventHandler = struct {
        callback: *const fn (*Event) void,
        context: ?*anyopaque,
    };

    pub const EventType = enum {
        connected,
        connection_failed,
        disconnected,
        stream_created,
        stream_destroyed,
        stream_readable,
        stream_writable,
        data_received,
        @"error",
    };

    pub const Event = struct {
        type: EventType,
        connection_id: ?ConnectionId = null,
        stream_id: ?StreamId = null,
        data: ?[]const u8 = null,
        error_code: ?u32 = null,
    };

    pub fn init(thread: *ClientThread) Client {
        return .{
            .thread = thread,
        };
    }

    // Connect to a remote endpoint
    pub fn connect(self: *Client, address: []const u8, port: u16) !void {
        const command = ClientThread.Command{ .connect = .{
            .address = address,
            .port = port,
        } };

        _ = self.thread.mailbox.push(command, .{ .instant = {} });
        try self.thread.wakeup.notify();
    }

    pub fn disconnect(self: *Client, connection_id: ConnectionId) !void {
        const command = ClientThread.Command{ .disconnect = .{
            .connection_id = connection_id,
        } };

        _ = self.thread.mailbox.push(command, .{ .instant = {} });
        try self.thread.wakeup.notify();
    }

    pub fn createStream(self: *Client, connection_id: ConnectionId) !StreamHandle {
        const command = ClientThread.Command{ .create_stream = .{
            .connection_id = connection_id,
        } };

        _ = self.thread.mailbox.push(command, .{ .instant = {} });
        try self.thread.wakeup.notify();

        // TODO: Implement proper waiting for stream creation
        // This could be done with a condition variable or by polling the event queue

        // For now, we'll return a placeholder handle
        // In a more complete implementation, we would wait for a stream_created event
        return StreamHandle{
            .thread = self.thread,
            .stream_id = StreamId.fromRaw(1), // Placeholder
            .connection_id = connection_id,
            .is_readable = false,
            .is_writable = false,
        };
    }

    pub fn destroyStream(self: *Client, stream: StreamHandle) !void {
        const command = ClientThread.Command{ .destroy_stream = .{
            .connection_id = stream.connection_id,
            .stream_id = stream.stream_id,
        } };

        _ = self.thread.mailbox.push(command, .{ .instant = {} });
        try self.thread.wakeup.notify();
    }

    pub fn shutdown(self: *const Client) !void {
        const command = ClientThread.Command{ .shutdown = {} };

        _ = self.thread.mailbox.push(command, .{ .instant = {} });
        try self.thread.wakeup.notify();
    }

    pub fn events(_: *Client) ?Event {
        // TODO: Retrieve events from queue
        return null;
    }

    pub fn setOnNewEventsCallback(self: *Client, callback: *const fn (*Event) void, context: ?*anyopaque) void {
        self.event_handler = .{
            .callback = callback,
            .context = context,
        };
    }
};

//
pub const StreamHandle = struct {
    thread: *ClientThread,
    stream_id: StreamId,
    connection_id: ConnectionId,
    is_readable: bool = false,
    is_writable: bool = false,

    pub fn sendData(self: *StreamHandle, data: []u8) !void {
        const command = ClientThread.Command{ .send_data = .{
            .connection_id = self.connection_id,
            .stream_id = self.stream_id,
            .data = data,
        } };

        _ = self.thread.mailbox.push(command, .{ .instant = {} });
        try self.thread.wakeup.notify();
    }

    pub fn wantRead(self: *StreamHandle, want: bool) !void {
        const command = ClientThread.Command{ .stream_want_read = .{
            .connection_id = self.connection_id,
            .stream_id = self.stream_id,
            .want = want,
        } };

        _ = self.thread.mailbox.push(command, .{ .instant = {} });
        try self.thread.wakeup.notify();
    }

    pub fn wantWrite(self: *StreamHandle, want: bool) !void {
        const command = ClientThread.Command{ .stream_want_write = .{
            .connection_id = self.connection_id,
            .stream_id = self.stream_id,
            .want = want,
        } };

        _ = self.thread.mailbox.push(command, .{ .instant = {} });
        try self.thread.wakeup.notify();
    }

    pub fn flush(self: *StreamHandle) !void {
        const command = ClientThread.Command{ .stream_flush = .{
            .connection_id = self.connection_id,
            .stream_id = self.stream_id,
        } };

        _ = self.thread.mailbox.push(command, .{ .instant = {} });
        try self.thread.wakeup.notify();
    }

    pub fn shutdown(self: *StreamHandle, how: c_int) !void {
        const command = ClientThread.Command{ .stream_shutdown = .{
            .connection_id = self.connection_id,
            .stream_id = self.stream_id,
            .how = how,
        } };

        _ = self.thread.mailbox.push(command, .{ .instant = {} });
        try self.thread.wakeup.notify();
    }

    pub fn close(self: *StreamHandle) !void {
        const command = ClientThread.Command{ .destroy_stream = .{
            .connection_id = self.connection_id,
            .stream_id = self.stream_id,
        } };

        _ = self.thread.mailbox.push(command, .{ .instant = {} });
        try self.thread.wakeup.notify();
    }
};
