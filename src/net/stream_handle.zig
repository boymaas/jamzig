const std = @import("std");
const lsquic = @import("lsquic");

const shared = @import("jamsnp/shared_types.zig");
const trace = @import("../tracing.zig").scoped(.network);

const ConnectionId = shared.ConnectionId;
const StreamId = shared.StreamId;

const common = @import("common.zig");
const CommandCallback = common.CommandCallback;

// StreamHandle provides the user-facing API for interacting with a client stream.
// It sends commands to the ClientThread for actual execution.
pub fn StreamHandle(T: type) type {
    return struct {
        thread: *T,
        stream_id: StreamId,
        connection_id: ConnectionId,
        is_readable: bool = false, // State managed by events, not directly here
        is_writable: bool = false, // State managed by events, not directly here

        // Helper function to push a command to the mailbox and notify the thread
        fn pushCommand(self: *@This(), command: T.Command) !void {
            const span = trace.span(.push_command);
            defer span.deinit();

            _ = self.thread.mailbox.push(command, .{ .instant = {} });
            try self.thread.wakeup.notify();

            span.debug("Command pushed to mailbox and thread notified", .{});
        }

        pub fn sendData(self: *@This(), data: []const u8) !void {
            const span = trace.span(.send_data);
            defer span.deinit();
            span.debug("Sending data to stream", .{});
            span.trace("Connection ID: {d}, Stream ID: {d}, Data length: {d}", .{ self.connection_id, self.stream_id, data.len });
            span.trace("Data first bytes: {any}", .{std.fmt.fmtSliceHexLower(if (data.len > 16) data[0..16] else data)});

            return self.sendDataWithCallback(data, null, null);
        }

        /// Send a message with length prefix to the stream.
        /// The message will be prefixed with a 4-byte little-endian u32 length.
        pub fn sendMessage(self: *@This(), message: []const u8) !void {
            const span = trace.span(.send_message);
            defer span.deinit();
            span.debug("Sending message to stream", .{});
            span.trace("Connection ID: {}, Stream ID: {}, Message length: {d}", .{ self.connection_id, self.stream_id, message.len });

            return self.sendMessageWithCallback(message, null, null);
        }

        /// Send a message with length prefix to the stream with a callback.
        /// The message will be prefixed with a 4-byte little-endian u32 length.
        pub fn sendMessageWithCallback(
            self: *@This(),
            message: []const u8,
            callback: ?CommandCallback(anyerror!void),
            context: ?*anyopaque,
        ) !void {
            const span = trace.span(.send_message_with_callback);
            defer span.deinit();
            span.debug("Sending message with callback to stream", .{});
            span.trace("Connection ID: {}, Stream ID: {}, Message length: {d}", .{ self.connection_id, self.stream_id, message.len });

            const command = T.Command{
                .send_message = .{
                    .data = .{
                        .connection_id = self.connection_id,
                        .stream_id = self.stream_id,
                        .message = message,
                    },
                    .metadata = .{
                        .callback = callback,
                        .context = context,
                    },
                },
            };

            try self.pushCommand(command);
        }

        pub fn sendDataWithCallback(
            self: *@This(),
            data: []const u8,
            callback: ?CommandCallback(anyerror!void),
            context: ?*anyopaque,
        ) !void {
            const span = trace.span(.send_data_with_callback);
            defer span.deinit();
            span.debug("Sending data with callback to stream", .{});
            span.trace("Connection ID: {d}, Stream ID: {d}, Data length: {d}", .{ self.connection_id, self.stream_id, data.len });
            span.trace("Has callback: {}", .{callback != null});

            const command = T.Command{
                .send_data = .{
                    .data = .{
                        .connection_id = self.connection_id,
                        .stream_id = self.stream_id,
                        .data = data,
                    },
                    .metadata = .{
                        .callback = callback,
                        .context = context,
                    },
                },
            };

            try self.pushCommand(command);
        }

        pub fn wantRead(self: *@This(), want: bool) !void {
            const span = trace.span(.want_read);
            defer span.deinit();
            span.debug("Setting want_read={} for stream", .{want});
            span.trace("Connection ID: {d}, Stream ID: {d}", .{ self.connection_id, self.stream_id });

            return self.wantReadWithCallback(want, null, null);
        }

        pub fn wantReadWithCallback(
            self: *@This(),
            want: bool,
            callback: ?CommandCallback(void),
            context: ?*anyopaque,
        ) !void {
            const span = trace.span(.want_read_with_callback);
            defer span.deinit();
            span.debug("Setting want_read={} with callback for stream", .{want});
            span.trace("Connection ID: {d}, Stream ID: {d}, Has callback: {}", .{ self.connection_id, self.stream_id, callback != null });

            const command = T.Command{ .stream_want_read = .{
                .data = .{
                    .connection_id = self.connection_id,
                    .stream_id = self.stream_id,
                    .want = want,
                },
                .metadata = .{
                    .callback = callback,
                    .context = context,
                },
            } };

            try self.pushCommand(command);
        }

        pub fn wantWrite(self: *@This(), want: bool) !void {
            const span = trace.span(.want_write);
            defer span.deinit();
            span.debug("Setting want_write={} for stream", .{want});
            span.trace("Connection ID: {d}, Stream ID: {d}", .{ self.connection_id, self.stream_id });

            return self.wantWriteWithCallback(want, null, null);
        }

        pub fn wantWriteWithCallback(
            self: *@This(),
            want: bool,
            callback: ?CommandCallback(void),
            context: ?*anyopaque,
        ) !void {
            const span = trace.span(.want_write_with_callback);
            defer span.deinit();
            span.debug("Setting want_write={} with callback for stream", .{want});
            span.trace("Connection ID: {d}, Stream ID: {d}, Has callback: {}", .{ self.connection_id, self.stream_id, callback != null });

            const command = T.Command{ .stream_want_write = .{
                .data = .{
                    .connection_id = self.connection_id,
                    .stream_id = self.stream_id,
                    .want = want,
                },
                .metadata = .{
                    .callback = callback,
                    .context = context,
                },
            } };

            try self.pushCommand(command);
        }

        pub fn flush(self: *@This()) !void {
            const span = trace.span(.flush);
            defer span.deinit();
            span.debug("Flushing stream", .{});
            span.trace("Connection ID: {d}, Stream ID: {d}", .{ self.connection_id, self.stream_id });

            return self.flushWithCallback(null, null);
        }

        pub fn flushWithCallback(
            self: *@This(),
            callback: ?CommandCallback(void),
            context: ?*anyopaque,
        ) !void {
            const span = trace.span(.flush_with_callback);
            defer span.deinit();
            span.debug("Flushing stream with callback", .{});
            span.trace("Connection ID: {d}, Stream ID: {d}, Has callback: {}", .{ self.connection_id, self.stream_id, callback != null });

            const command = T.Command{ .stream_flush = .{
                .data = .{
                    .connection_id = self.connection_id,
                    .stream_id = self.stream_id,
                },
                .metadata = .{
                    .callback = callback,
                    .context = context,
                },
            } };

            try self.pushCommand(command);
        }

        pub fn shutdown(self: *@This(), how: c_int) !void {
            const span = trace.span(.shutdown);
            defer span.deinit();
            span.debug("Shutting down stream", .{});
            span.trace("Connection ID: {d}, Stream ID: {d}, How: {d}", .{ self.connection_id, self.stream_id, how });

            return self.shutdownWithCallback(how, null, null);
        }

        pub fn shutdownWithCallback(
            self: *@This(),
            how: c_int,
            callback: ?CommandCallback(void),
            context: ?*anyopaque,
        ) !void {
            const span = trace.span(.shutdown_with_callback);
            defer span.deinit();
            span.debug("Shutting down stream with callback", .{});
            span.trace("Connection ID: {d}, Stream ID: {d}, How: {d}, Has callback: {}", .{ self.connection_id, self.stream_id, how, callback != null });

            const command = T.Command{ .stream_shutdown = .{
                .data = .{
                    .connection_id = self.connection_id,
                    .stream_id = self.stream_id,
                    .how = how,
                },
                .metadata = .{
                    .callback = callback,
                    .context = context,
                },
            } };

            try self.pushCommand(command);
        }

        pub fn close(self: *@This()) !void {
            const span = trace.span(.close);
            defer span.deinit();
            span.debug("Closing stream", .{});
            span.trace("Connection ID: {d}, Stream ID: {d}", .{ self.connection_id, self.stream_id });

            return self.closeWithCallback(null, null);
        }

        pub fn closeWithCallback(
            self: *@This(),
            callback: ?CommandCallback(void),
            context: ?*anyopaque,
        ) !void {
            const span = trace.span(.close_with_callback);
            defer span.deinit();
            span.debug("Closing stream with callback", .{});
            span.trace("Connection ID: {d}, Stream ID: {d}, Has callback: {}", .{ self.connection_id, self.stream_id, callback != null });

            const command = T.Command{ .destroy_stream = .{
                .data = .{
                    .connection_id = self.connection_id,
                    .stream_id = self.stream_id,
                },
                .metadata = .{
                    .callback = callback,
                    .context = context,
                },
            } };

            try self.pushCommand(command);
        }
    };
}
