
const std = @import("std");
const uuid = @import("uuid");
const lsquic = @import("lsquic");

const shared = @import("../jamsnp/shared_types.zig");
const Connection = @import("connection.zig").Connection;

const trace = @import("tracing").scoped(.network);

pub const StreamId = shared.StreamId;

pub const WriteCallbackMethod = enum {
    none,
    datawritecompleted,
    messagecompleted,
};

pub fn ReadCallbackMethod(T: type) type {
    return union(enum) {
        pub const Callback = struct {
            on_success: *const fn (stream: *Stream(T), data: []const u8, ctx: ?*anyopaque) anyerror!void,
            on_error: *const fn (stream: *Stream(T), data: []const u8, error_code: i32, ctx: ?*anyopaque) anyerror!void,
            context: ?*anyopaque = null,
        };

        none,
        events,
        custom: Callback,
    };
}

pub const Ownership = enum {
    borrow,
    owned,
};

pub fn Stream(T: type) type {
    return struct {
        const WriteState = struct {
            want_write: bool = false,
            buffer: ?[]const u8 = null, // Buffer provided by user via command
            position: usize = 0,
            ownership: Ownership = .borrow,
            callback_method: WriteCallbackMethod = .none,

            pub fn freeBufferIfOwned(self: *WriteState, allocator: std.mem.Allocator) void {
                if (self.ownership == .owned and self.buffer != null) {
                    allocator.free(self.buffer.?);
                    self.buffer = null;
                }
                self.ownership = .borrow; // Reset ownership
            }

            pub fn reset(self: *WriteState) void {
                self.want_write = false;
                self.position = 0;
                self.buffer = null;
            }
        };

        const ReadState = struct {
            want_read: bool = false,
            buffer: ?[]u8 = null, // Buffer provided by user via command
            position: usize = 0,
            ownership: Ownership = .borrow,
            callback_method: ReadCallbackMethod(T) = .none,

            pub fn freeBufferIfOwned(self: *ReadState, allocator: std.mem.Allocator) void {
                if (self.ownership == .owned and self.buffer != null) {
                    allocator.free(self.buffer.?);
                    self.buffer = null;
                }
                self.ownership = .borrow; // Reset ownership
            }

            pub fn freeBuffer(self: *ReadState, allocator: std.mem.Allocator) void {
                if (self.buffer) |buffer| {
                    allocator.free(buffer);
                    self.buffer = null;
                }
            }

            pub fn reset(self: *ReadState) void {
                self.want_read = false;
                self.position = 0;
                self.buffer = null;
                self.callback_method = .none;
            }
        };

        const MessageReadState = enum {
            idle, // Not currently reading a message
            reading_length, // Reading the 4-byte length prefix
            reading_body, // Reading the message body
        };

        const MessageState = struct {
            state: MessageReadState = .idle,
            length_buffer: [4]u8 = undefined, // Buffer to store length prefix
            length_read: usize = 0, // Bytes read into length buffer
            length: ?u32 = null, // Parsed message length
            buffer: ?[]u8 = null, // Allocated buffer for message
            bytes_read: usize = 0, // Bytes read into message buffer

            pub fn freeBuffers(self: *MessageState, allocator: std.mem.Allocator) void {
                if (self.buffer) |buffer| {
                    allocator.free(buffer);
                    self.buffer = null;
                }
            }

            pub fn reset(self: *MessageState) void {
                self.state = .idle;
                self.length_read = 0;
                self.length = null;
                self.bytes_read = 0;
                self.buffer = null;
            }
        };

        id: StreamId,
        lsquic_stream_id: u64 = 0, // Set in onStreamCreated
        connection: *Connection(T),
        lsquic_stream: *lsquic.lsquic_stream_t, // Set in onStreamCreated

        kind: ?shared.StreamKind = null, // Set in onStreamCreated

        write_state: WriteState = .{},
        read_state: ReadState = .{},

        message_read_state: MessageState = .{},

        fn create(alloc: std.mem.Allocator, connection: *Connection(T), lsquic_stream: *lsquic.lsquic_stream_t, lsquic_stream_id: u64) !*Stream(T) {
            const span = trace.span(@src(), .stream_create_internal);
            defer span.deinit();
            span.debug("Creating internal Stream context for connection ID: {}", .{connection.id});
            const stream = try alloc.create(Stream(T));
            errdefer alloc.destroy(stream);

            stream.* = .{
                .id = uuid.v4.new(),
                .lsquic_stream = lsquic_stream,
                .lsquic_stream_id = lsquic_stream_id,
                .connection = connection,
            };
            span.debug("Internal Stream context created with ID: {}", .{stream.id});
            return stream;
        }

        // The brilliance of the QUIC Stream ID design lies in its encoding of
        // crucial stream properties directly within the ID itself,
        // specifically using the two least significant bits (LSBs). This
        // allows any endpoint to determine the stream's initiator and
        // directionality simply by examining the ID value.  
        //
        // Initiator (Least Significant Bit - LSB - Bit 0): The very first bit (value 0x01) indicates which endpoint initiated the stream:
        // Bit 0 = 0: The stream was initiated by the Client.
        // Bit 0 = 1: The stream was initiated by the Server.
        // Directionality (Second Least Significant Bit - Bit 1): The second bit (value 0x02) determines whether the stream allows data flow in one or both directions:
        // Bit 1 = 0: The stream is Bidirectional. Both the client and the server can send data on this stream.
        // Bit 1 = 1: The stream is Unidirectional. Data flows only from the initiator of the stream to its peer. The peer can only receive data on this stream.
        //
        // Now to determine from the stream perspectiv if this stream was initiated locally, thus by a a call to
        // lsquic_conn_stream_create, or remotely, we need to take the Stream perspective into account. And the
        // fact if the first bit is set.

        pub const StreamPerspective = enum {
            client,
            server,
        };
        pub fn streamPerspective() StreamPerspective {
            return if (T == @import("client.zig").JamSnpClient) StreamPerspective.client else StreamPerspective.server;
        }

        pub fn origin(self: *Stream(T)) shared.StreamOrigin {
            switch (streamPerspective()) {
                .client => {
                    return if (self.lsquic_stream_id & 0x01 == 0) .local_initiated else .remote_initiated;
                },
                .server => {
                    return if (self.lsquic_stream_id & 0x01 == 0) .remote_initiated else .local_initiated;
                },
            }
        }

        pub fn destroy(self: *Stream(T), alloc: std.mem.Allocator) void {
            const span = trace.span(@src(), .stream_destroy_internal);
            defer span.deinit();
            span.debug("Destroying internal Stream struct for ID: {}", .{self.id});

            if (self.write_state.ownership == .owned and self.write_state.buffer != null) {
                const buffer_to_free = self.write_state.buffer.?;
                self.connection.owner.allocator.free(buffer_to_free);
                span.debug("Freed owned write buffer during stream destruction for ID: {}", .{self.id});
            }

            if (self.message_read_state.buffer) |buffer| {
                self.connection.owner.allocator.free(buffer);
                span.debug("Freed message buffer during stream destruction for ID: {}", .{self.id});
            }


            self.* = undefined;
            alloc.destroy(self);
        }

        pub fn wantRead(self: *Stream(T), want: bool) void {
            const span = trace.span(@src(), .stream_want_read_internal);
            defer span.deinit();
            const want_val: c_int = if (want) 1 else 0;
            span.debug("Setting internal stream want-read to {} for ID: {}", .{ want, self.id });
            _ = lsquic.lsquic_stream_wantread(self.lsquic_stream, want_val);
            // FIXME: handle potential error from lsquic_stream_wantread
            self.read_state.want_read = want; // Update internal state
        }

        pub fn wantWrite(self: *Stream(T), want: bool) void {
            const span = trace.span(@src(), .stream_want_write_internal);
            defer span.deinit();
            const want_val: c_int = if (want) 1 else 0;
            span.debug("Setting internal stream want-write to {} for ID: {}", .{ want, self.id });
            _ = lsquic.lsquic_stream_wantwrite(self.lsquic_stream, want_val);
            // FIXME: handle potential error from lsquic_stream_wantwrite
            self.write_state.want_write = want; // Update internal state
        }

        /// Prepare the stream to read into the provided buffer.
        /// If owned is set to .owned, the stream takes ownership of the buffer and will free it when done.
        pub fn setReadBuffer(self: *Stream(T), buffer: []u8, owned: Ownership, callback_method: ReadCallbackMethod(T)) !void {
            const span = trace.span(@src(), .stream_set_read_buffer);
            defer span.deinit();
            span.debug("Setting read buffer (len={d}, owned={}, callback={}) for internal stream ID: {}", .{ buffer.len, owned, callback_method, self.id });

            if (buffer.len == 0) {
                span.warn("Read buffer set with zero-length for stream ID: {}", .{self.id});
                return error.InvalidArgument;
            }

            if (self.read_state.buffer != null) {
                // FIXME: this should fail
                span.warn("Overwriting existing read buffer for stream ID: {}", .{self.id});
                self.read_state.freeBufferIfOwned(self.connection.owner.allocator);
            }

            self.read_state.buffer = buffer;
            self.read_state.position = 0;
            self.read_state.ownership = owned;
            self.read_state.callback_method = callback_method;
        }

        /// Prepare the stream to write the provided data.
        pub fn setWriteBuffer(self: *Stream(T), data: []const u8, owned: Ownership, callback_method: WriteCallbackMethod) !void {
            const span = trace.span(@src(), .stream_set_write_buffer);
            defer span.deinit();
            span.debug("Setting write buffer ({d} bytes) for internal stream ID: {}", .{ data.len, self.id });

            if (data.len == 0) {
                span.warn("Write buffer set with zero-length data for stream ID: {}. Ignoring.", .{self.id});
                return error.ZeroDataLen;
            }
            if (self.write_state.buffer != null) {
                span.err("Stream ID {} is already writing, cannot issue new write.", .{self.id});
                return error.StreamAlreadyWriting;
            }

            self.write_state.buffer = data;
            self.write_state.position = 0;
            self.write_state.ownership = owned;
            self.write_state.callback_method = callback_method; // Set to true if we want to send a write completed event
        }

        /// Prepare the stream to write a message with a length prefix.
        /// Will allocate a new buffer containing the length prefix + message data.
        pub fn setMessageBuffer(self: *Stream(T), message: []const u8) !void {
            const span = trace.span(@src(), .stream_set_message_buffer);
            defer span.deinit();
            span.debug("Setting message buffer ({d} bytes) for internal stream ID: {}", .{ message.len, self.id });

            if (self.write_state.buffer != null) {
                span.err("Stream ID {} is already writing, cannot issue new write.", .{self.id});
                return error.StreamAlreadyWriting;
            }

            const total_size = 4 + message.len;
            var buffer = try self.connection.owner.allocator.alloc(u8, total_size);
            errdefer self.connection.owner.allocator.free(buffer);

            std.mem.writeInt(u32, buffer[0..4], @intCast(message.len), .little);

            @memcpy(buffer[4..], message);

            self.write_state.buffer = buffer;
            self.write_state.position = 0;
            self.write_state.ownership = .owned; // We own this buffer and need to free it
            self.write_state.callback_method = .messagecompleted; // Set to true if we want to send a write completed event

            span.debug("Message buffer set: {d} bytes length prefix + {d} bytes data", .{ 4, message.len });
        }

        pub fn flush(self: *Stream(T)) !void {
            const span = trace.span(@src(), .stream_flush_internal);
            defer span.deinit();
            span.debug("Flushing internal stream ID: {}", .{self.id});
            if (lsquic.lsquic_stream_flush(self.lsquic_stream) != 0) {
                span.err("Failed to flush internal stream ID: {}", .{self.id});
                return error.StreamFlushFailed;
            }
        }

        pub fn shutdown(self: *Stream(T), how: c_int) !void {
            const span = trace.span(@src(), .stream_shutdown_internal);
            defer span.deinit();
            const direction = switch (how) {
                0 => "read",
                1 => "write",
                2 => "read and write",
                else => "unknown",
            };
            span.debug("Shutting down internal stream ID {} ({s} side)", .{ self.id, direction });
            if (lsquic.lsquic_stream_shutdown(self.lsquic_stream, how) != 0) {
                span.err("Failed to shutdown internal stream ID {}: {s}", .{ self.id, direction });
                return error.StreamShutdownFailed;
            }
        }

        pub fn close(self: *Stream(T)) !void {
            const span = trace.span(@src(), .stream_close_internal);
            defer span.deinit();
            span.debug("Closing internal stream ID: {}", .{self.id});
            if (lsquic.lsquic_stream_close(self.lsquic_stream) != 0) {
                span.err("Failed to close internal stream ID: {}", .{self.id});
                return error.StreamCloseFailed;
            }
        }

        pub fn onStreamCreated(
            _: ?*anyopaque, // ea_stream_if_ctx (unused)
            maybe_lsquic_stream: ?*lsquic.lsquic_stream_t,
        ) callconv(.C) [*c]lsquic.lsquic_stream_ctx_t {
            const span = trace.span(@src(), .on_stream_created);
            defer span.deinit();

            span.debug("onStreamCreated triggered", .{});

            const lsquic_stream = maybe_lsquic_stream orelse {
                span.err("Stream created callback received null stream, doing nothing", .{});
                return null;
            };

            const lsquic_stream_id = lsquic.lsquic_stream_id(lsquic_stream);
            span.debug("LSQUIC Stream ID: {}", .{lsquic_stream_id});

            const lsquic_connection = lsquic.lsquic_stream_conn(maybe_lsquic_stream);
            const conn_ctx = lsquic.lsquic_conn_get_ctx(lsquic_connection).?; // Assume parent conn context is valid
            const connection: *Connection(T) = @alignCast(@ptrCast(conn_ctx));

            const stream = Stream(T).create(
                connection.owner.allocator,
                connection,
                lsquic_stream,
                lsquic_stream_id,
            ) catch
                std.debug.panic("OutOfMemory creating internal", .{});

            connection.owner.streams.put(stream.id, stream) catch
                std.debug.panic("OutOfMemory adding stream to map", .{});

            shared.invokeCallback(T, &connection.owner.callback_handlers, .{
                .stream_created = stream,
            });

            return @ptrCast(stream);
        }

        pub fn onStreamRead(
            maybe_lsquic_stream: ?*lsquic.lsquic_stream_t,
            maybe_stream_ctx: ?*lsquic.lsquic_stream_ctx_t,
        ) callconv(.C) void {
            const span = trace.span(@src(), .on_stream_read);
            defer span.deinit();

            const stream_ctx = maybe_stream_ctx orelse {
                span.err("onStreamRead called with null context!", .{});
                return;
            };

            const stream: *Stream(T) = @alignCast(@ptrCast(stream_ctx)); // This is the internal Stream
            span.debug("onStreamRead triggered for internal stream ID: {}", .{stream.id});

            span.debug("Stream ID: {}", .{@import("../../types.zig").fmt.format(stream.read_state)});

            if (stream.read_state.buffer == null) {
                processMessageRead(stream) catch |err| {
                    span.err("Error in message read processing for stream ID {}: {s}", .{ stream.id, @errorName(err) });
                    switch (err) {
                        error.MessageTooLarge => {
                            span.err("Message too large on stream ID {}, max allowed: {d}", .{ stream.id, shared.MAX_MESSAGE_SIZE });
                            shared.invokeCallback(T, &stream.connection.owner.callback_handlers, .{
                                .data_read_error = .{
                                    .stream = stream,
                                    .error_code = 9999, // TODO: Custom error code for message too large
                                },
                            });
                            stream.close() catch |close_err| {
                                span.err("Failed to close stream after message size violation: {s}", .{@errorName(close_err)});
                            };
                        },
                        error.OutOfMemory => {
                            span.err("Out of memory when allocating for message on stream ID {}", .{stream.id});
                            shared.invokeCallback(T, &stream.connection.owner.callback_handlers, .{
                                .data_read_error = .{
                                    .stream = stream,
                                    .error_code = 9998, // Custom error code for OOM
                                },
                            });
                        },
                        else => {
                            span.err("Generic error in message read processing for stream ID {}", .{stream.id});
                            shared.invokeCallback(T, &stream.connection.owner.callback_handlers, .{
                                .data_read_error = .{
                                    .stream = stream,
                                    .error_code = 9997, // Custom error code for other errors
                                },
                            });
                        },
                    }

                    stream.message_read_state.freeBuffers(stream.connection.owner.allocator);
                    stream.message_read_state.reset();
                };
                return; // Message processing handled the read
            }

            const buffer_available = stream.read_state.buffer.?[stream.read_state.position..];
            if (buffer_available.len == 0) {
                span.warn("onStreamRead called for stream ID {} but read buffer is full.", .{stream.id});
                stream.wantRead(false);
                return;
            }

            const bytes_read_or_error = lsquic.lsquic_stream_read(maybe_lsquic_stream, buffer_available.ptr, buffer_available.len);

            if (bytes_read_or_error == 0) {
                span.debug("End of stream reached for stream ID: {}", .{stream.id});
                shared.invokeCallback(T, &stream.connection.owner.callback_handlers, .{
                    .data_read_end_of_stream = stream,
                });
                stream.read_state.reset();
                stream.read_state.freeBufferIfOwned(stream.connection.owner.allocator);
                stream.wantRead(false);
            } else if (bytes_read_or_error < 0) {
                switch (std.posix.errno(bytes_read_or_error)) {
                    std.posix.E.AGAIN => {
                        span.debug("Read would block for stream ID: {}", .{stream.id});
                        if (stream.read_state.callback_method == .events)
                            shared.invokeCallback(T, &stream.connection.owner.callback_handlers, .{
                                .data_would_block = stream,
                            });
                        return;
                    },
                    else => |err| {
                        span.err("Error reading from stream ID {}: {s}", .{ stream.id, @tagName(err) });
                        switch (stream.read_state.callback_method) {
                            .events => {
                                shared.invokeCallback(T, &stream.connection.owner.callback_handlers, .{
                                    .data_read_error = .{
                                        .stream = stream,
                                        .error_code = @intFromEnum(err),
                                    },
                                });
                            },
                            .custom => |callback| {
                                stream.read_state.ownership = .borrow; // make sure we don't free it
                                callback.on_error(stream, stream.read_state.buffer.?, @intCast(bytes_read_or_error), callback.context) catch {
                                    std.debug.panic("Custom error callback failed for stream ID {}", .{stream.id});
                                };
                            },
                            .none => {
                            },
                        }

                        stream.read_state.freeBufferIfOwned(stream.connection.owner.allocator);
                        stream.read_state.reset();
                        stream.wantRead(false);
                        return;
                    },
                }
            }

            const bytes_read: usize = @intCast(bytes_read_or_error);
            span.debug("Read {d} bytes from stream ID: {}", .{ bytes_read, stream.id });

            stream.read_state.position += bytes_read;

            // FIXME: remove the DtaReadProgress event
            if (stream.read_state.callback_method == .events)
                shared.invokeCallback(T, &stream.connection.owner.callback_handlers, .{
                    .data_read_progress = .{
                        .stream = stream,
                        .bytes_read = stream.read_state.position,
                        .total_size = stream.read_state.buffer.?.len,
                    },
                });

            if (stream.read_state.position == stream.read_state.buffer.?.len) {
                span.debug("Read buffer filled, we completed our read: {}. .", .{stream.id});

                stream.wantRead(false);

                switch (stream.read_state.callback_method) {
                    .events => {
                        span.debug("Generating DataReadCompleted event for stream ID: {}", .{stream.id});
                        stream.read_state.ownership = .borrow; // make sure we don't free it
                        shared.invokeCallback(T, &stream.connection.owner.callback_handlers, .{
                            .data_read_completed = .{
                                .stream = stream,
                                .data = stream.read_state.buffer.?,
                            },
                        });
                    },
                    .custom => {
                        span.debug("Invoking custom callback method for stream ID: {}", .{stream.id});
                        const callback = stream.read_state.callback_method.custom;
                        stream.read_state.ownership = .borrow; // make sure we don't free it
                        callback.on_success(stream, stream.read_state.buffer.?, callback.context) catch {
                            std.debug.panic("Custom success callback failed for stream ID {}", .{stream.id});
                        };
                    },
                    .none => {
                        span.debug("No event or callback called on completion for stream ID: {}", .{stream.id});
                    },
                }

                stream.read_state.reset();
            }
        }

        /// Process reading message-based data
        fn processMessageRead(stream: *Stream(T)) !void {
            const span = trace.span(@src(), .process_message_read);
            defer span.deinit();

            if (stream.message_read_state.state == .idle) {
                span.debug("Starting message reading on stream ID: {}", .{stream.id});
                stream.message_read_state.state = .reading_length;
                stream.message_read_state.length_read = 0;
            }

            if (stream.message_read_state.state == .reading_length) {
                const length_remaining = 4 - stream.message_read_state.length_read;
                // NOTE: using stream.lsquic_stream as set in onStreamCreated
                const read_result = lsquic.lsquic_stream_read(stream.lsquic_stream, &stream.message_read_state.length_buffer[stream.message_read_state.length_read], length_remaining);

                if (read_result == 0) {
                    span.debug("End of stream reached while reading message length on stream ID: {}", .{stream.id});
                    shared.invokeCallback(T, &stream.connection.owner.callback_handlers, .{
                        .data_read_end_of_stream = stream,
                    });
                    stream.wantRead(false);
                    return error.EndOfStream;
                } else if (read_result < 0) {
                    const err = std.posix.errno(read_result);
                    if (err == std.posix.E.AGAIN) {
                        span.debug("Read would block while reading message length on stream ID: {}", .{stream.id});
                        shared.invokeCallback(T, &stream.connection.owner.callback_handlers, .{
                            .data_would_block = stream,
                        });
                        return; // Keep wantRead true
                    } else {
                        span.err("Error reading message length from stream ID {}: {s}", .{ stream.id, @tagName(err) });
                        shared.invokeCallback(T, &stream.connection.owner.callback_handlers, .{
                            .data_read_error = .{
                                .stream = stream,
                                .error_code = @intFromEnum(err),
                            },
                        });
                        stream.wantRead(false);
                        return error.StreamReadError;
                    }
                }

                const bytes_read: usize = @intCast(read_result);
                stream.message_read_state.length_read += bytes_read;

                span.debug("Read {d}/{d} bytes of message length on stream ID: {}", .{ stream.message_read_state.length_read, 4, stream.id });

                if (stream.message_read_state.length_read == 4) {
                    const message_length = std.mem.readInt(u32, &stream.message_read_state.length_buffer, .little);

                    if (message_length > shared.MAX_MESSAGE_SIZE) {
                        span.err("Message length {d} exceeds maximum allowed size {d} on stream ID: {}", .{ message_length, shared.MAX_MESSAGE_SIZE, stream.id });
                        return error.MessageTooLarge;
                    }

                    span.debug("Message length parsed: {d} bytes for stream ID: {}", .{ message_length, stream.id });

                    if (message_length == 0) {
                        span.warn("Zero-length message received on stream ID: {}", .{stream.id});
                        shared.invokeCallback(T, &stream.connection.owner.callback_handlers, .{
                            .message_received = .{
                                .stream = stream,
                                .message = &[0]u8{}, // Empty slice
                            },
                        });
                        stream.message_read_state.reset();
                        return;
                    }

                    stream.message_read_state.buffer = stream.connection.owner.allocator.alloc(u8, message_length) catch {
                        span.err("Failed to allocate {d} bytes for message buffer on stream ID: {}", .{ message_length, stream.id });
                        return error.OutOfMemory;
                    };

                    stream.message_read_state.length = message_length;
                    stream.message_read_state.state = .reading_body;
                    stream.message_read_state.bytes_read = 0;
                }
            }

            if (stream.message_read_state.state == .reading_body) {
                const message_length = stream.message_read_state.length orelse {
                    span.err("Invalid state: message_state.state is reading_body but message_state.length is null", .{});
                    return error.InvalidState;
                };

                const message_buffer = stream.message_read_state.buffer orelse {
                    span.err("Invalid state: message_state.state is reading_body but message_state.buffer is null", .{});
                    return error.InvalidState;
                };

                const bytes_remaining = message_length - stream.message_read_state.bytes_read;
                const read_result = lsquic.lsquic_stream_read(stream.lsquic_stream, message_buffer.ptr + stream.message_read_state.bytes_read, bytes_remaining);

                if (read_result == 0) {
                    span.err("End of stream reached while reading message body on stream ID: {}", .{stream.id});
                    shared.invokeCallback(T, &stream.connection.owner.callback_handlers, .{
                        .data_read_end_of_stream = stream,
                    });

                    stream.message_read_state.reset();
                    stream.wantRead(false);
                    return error.EndOfStream;
                } else if (read_result < 0) {
                    const err = std.posix.errno(read_result);
                    if (err == std.posix.E.AGAIN) {
                        span.debug("Read would block while reading message body on stream ID: {}", .{stream.id});
                        shared.invokeCallback(T, &stream.connection.owner.callback_handlers, .{
                            .data_would_block = stream,
                        });
                        return; // Keep wantRead true, LSQUIC will try again later
                    } else {
                        span.err("Error reading message body from stream ID {}: {s}", .{ stream.id, @tagName(err) });
                        shared.invokeCallback(T, &stream.connection.owner.callback_handlers, .{
                            .data_read_error = .{
                                .stream = stream,
                                .error_code = @intFromEnum(err),
                            },
                        });

                        stream.message_read_state.freeBuffers(stream.connection.owner.allocator);
                        stream.message_read_state.reset();
                        stream.wantRead(false);
                        return error.StreamReadError;
                    }
                }

                const bytes_read: usize = @intCast(read_result);
                stream.message_read_state.bytes_read += bytes_read;

                span.debug("Read {d}/{d} bytes of message body on stream ID: {}", .{
                    stream.message_read_state.bytes_read,
                    message_length,
                    stream.id,
                });

                if (stream.message_read_state.bytes_read == message_length) {
                    span.debug("Complete message of {d} bytes received on stream ID: {}", .{ message_length, stream.id });

                    shared.invokeCallback(T, &stream.connection.owner.callback_handlers, .{
                        .message_received = .{
                            .stream = stream,
                            .message = message_buffer, // pass ownership to callback
                        },
                    });

                    stream.message_read_state.reset();
                }
            }
        }

        pub fn onStreamWrite(
            maybe_lsquic_stream: ?*lsquic.lsquic_stream_t,
            maybe_stream_ctx: ?*lsquic.lsquic_stream_ctx_t,
        ) callconv(.C) void {
            const span = trace.span(@src(), .on_stream_write);
            defer span.deinit();

            _ = maybe_lsquic_stream; // Unused in this context

            const stream_ctx = maybe_stream_ctx orelse {
                span.err("onStreamWrite called with null context!", .{});
                return;
            };
            const stream: *Stream(T) = @alignCast(@ptrCast(stream_ctx)); // Internal Stream
            span.debug("onStreamWrite triggered for internal stream ID: {}", .{stream.id});

            if (stream.write_state.buffer == null) {
                span.warn("onStreamWrite called for stream ID {} but no write buffer set via command. Disabling wantWrite.", .{stream.id});
                stream.wantWrite(false);
                return;
            }

            const data_to_write = stream.write_state.buffer.?[stream.write_state.position..];
            const total_size = stream.write_state.buffer.?.len;

            if (data_to_write.len == 0) {
                span.warn("onStreamWrite called for stream ID {} but write buffer position indicates completion.", .{stream.id});
                stream.wantWrite(false);
                return;
            }

            const written_or_errorcode = lsquic.lsquic_stream_write(stream.lsquic_stream, data_to_write.ptr, data_to_write.len);

            if (written_or_errorcode == 0) {
                span.trace("No data written to stream ID {} (likely blocked)", .{stream.id});
                return;
            } else if (written_or_errorcode < 0) {
                if (std.posix.errno(written_or_errorcode) == std.posix.E.AGAIN) {
                    span.trace("Stream write would block (EAGAIN) for stream ID {}", .{stream.id});
                    return;
                } else {
                    span.err("Stream write failed for stream ID {} with error code: {d}", .{ stream.id, written_or_errorcode });
                    if (stream.write_state.callback_method != .none) {
                        shared.invokeCallback(T, &stream.connection.owner.callback_handlers, .{
                            .data_write_error = .{
                                .stream = stream,
                                .error_code = @intCast(-written_or_errorcode),
                            },
                        });
                        stream.wantWrite(false);
                    }
                    return;
                }
            }

            const bytes_written: usize = @intCast(written_or_errorcode);
            span.debug("Written {d} bytes to stream ID: {}", .{ bytes_written, stream.id });
            stream.write_state.position += bytes_written;

            if (stream.write_state.callback_method != .none)
                shared.invokeCallback(T, &stream.connection.owner.callback_handlers, .{
                    .data_write_progress = .{
                        .stream = stream,
                        .bytes_written = stream.write_state.position,
                        .total_size = total_size,
                    },
                });

            if (stream.write_state.position >= total_size) {
                span.debug("Write complete for user buffer (total {d} bytes) on stream ID: {}", .{ total_size, stream.id });

                switch (stream.write_state.callback_method) {
                    .none => {
                    },
                    .datawritecompleted => {
                        shared.invokeCallback(T, &stream.connection.owner.callback_handlers, .{
                            .data_write_completed = .{
                                .stream = stream,
                                .total_bytes_written = stream.write_state.position,
                            },
                        });
                    },
                    .messagecompleted => {
                        shared.invokeCallback(T, &stream.connection.owner.callback_handlers, .{
                            .message_send = stream,
                        });
                    },
                }

                stream.write_state.freeBufferIfOwned(stream.connection.owner.allocator);
                stream.write_state.reset();

                span.trace("Disabling write interest for stream ID {}", .{stream.id});
                stream.wantWrite(false);

                span.debug("Flushing stream ID {} after write completion", .{stream.id});
                if (lsquic.lsquic_stream_flush(stream.lsquic_stream) != 0) {
                    span.err("Failed to flush stream ID {} after write completion", .{stream.id});
                }
            }
        }

        pub fn onStreamClosed(
            _: ?*lsquic.lsquic_stream_t,
            maybe_stream_ctx: ?*lsquic.lsquic_stream_ctx_t,
        ) callconv(.C) void {
            const span = trace.span(@src(), .on_stream_closed);
            defer span.deinit();
            span.debug("LSQUIC stream closed callback received", .{});

            const stream_ctx = maybe_stream_ctx orelse {
                span.err("onStreamClosed called with null context!", .{});
                return;
            };
            const stream: *Stream(T) = @alignCast(@ptrCast(stream_ctx)); // Internal Stream
            span.debug("Processing internal stream closure for ID: {}", .{stream.id});

            stream.write_state.freeBufferIfOwned(stream.connection.owner.allocator);
            stream.read_state.freeBuffer(stream.connection.owner.allocator);
            stream.message_read_state.freeBuffers(stream.connection.owner.allocator);

            if (stream.connection.owner.streams.fetchRemove(stream.id)) |_| {
                span.debug("Removed internal stream ID {} from map.", .{stream.id});
            } else {
                span.warn("Closing an internal stream (ID: {}) that was not found in the map.", .{stream.id});
            }

            shared.invokeCallback(T, &stream.connection.owner.callback_handlers, .{
                .stream_closed = .{
                    .connection = stream.connection.id,
                    .stream = stream.id,
                },
            });

            const stream_id = stream.id;

            stream.destroy(stream.connection.owner.allocator);

            span.debug("Internal stream cleanup complete for formerly ID: {}", .{stream_id});
        }
    };
}
