const std = @import("std");
const uuid = @import("uuid");
const lsquic = @import("lsquic");

const shared = @import("../jamsnp/shared_types.zig");
const Connection = @import("connection.zig").Connection;

const trace = @import("../../tracing.zig").scoped(.network);

pub const StreamId = shared.StreamId;

pub const CallbackMethod = enum {
    none,
    datawritecompleted,
    messagecompleted,
};

pub const Ownership = enum {
    borrow,
    owned,
};

// --- Internal Stream Struct (for lsquic context)
// This struct holds the state needed *within* the lsquic callbacks.
pub fn Stream(T: type) type {
    return struct {
        id: StreamId,
        lsquic_stream_id: u64 = 0, // Set in onStreamCreated
        connection: *Connection(T),
        lsquic_stream: *lsquic.lsquic_stream_t, // Set in onStreamCreated

        kind: ?shared.StreamKind = null, // Set in onStreamCreated

        // Internal state for reading/writing (managed by lsquic callbacks)
        want_write: bool = false,
        write_buffer: ?[]const u8 = null, // Buffer provided by user via command
        write_buffer_pos: usize = 0,
        write_buffer_owned: Ownership = .borrow, // Flag to indicate if we own the write buffer memory
        write_call_callback_method: CallbackMethod = .none, // Flag to indicate if we should send a write completed event

        want_read: bool = false,
        read_buffer: ?[]u8 = null, // Buffer provided by user via command
        read_buffer_pos: usize = 0,

        // Message reading state
        message_reading_state: enum {
            idle, // Not currently reading a message
            reading_length, // Reading the 4-byte length prefix
            reading_body, // Reading the message body
        } = .idle,
        message_length_buffer: [4]u8 = undefined, // Buffer to store length prefix
        message_length_read: usize = 0, // Bytes read into length buffer
        message_length: ?u32 = null, // Parsed message length
        message_buffer: ?[]u8 = null, // Allocated buffer for message
        message_read: usize = 0, // Bytes read into message buffer

        fn create(alloc: std.mem.Allocator, connection: *Connection(T), lsquic_stream: *lsquic.lsquic_stream_t, lsquic_stream_id: u64) !*Stream(T) {
            const span = trace.span(.stream_create_internal);
            defer span.deinit();
            span.debug("Creating internal Stream context for connection ID: {}", .{connection.id});
            const stream = try alloc.create(Stream(T));
            errdefer alloc.destroy(stream);

            stream.* = .{
                .id = uuid.v4.new(),
                .lsquic_stream = lsquic_stream,
                .lsquic_stream_id = lsquic_stream_id,
                .connection = connection,
                .want_write = false,
                .write_buffer = null,
                .write_buffer_pos = 0,
                .want_read = false,
                .read_buffer = null,
                .read_buffer_pos = 0,
            };
            span.debug("Internal Stream context created with ID: {}", .{stream.id});
            return stream;
        }

        // The brilliance of the QUIC Stream ID design lies in its encoding of crucial stream properties directly within the ID itself, specifically using the two least significant bits (LSBs). This allows any endpoint to determine the stream's initiator and directionality simply by examining the ID value.  
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

        // This function is used to determine the stream perspective (client/server)
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
            // Just free the memory, lsquic handles its stream resources.
            const span = trace.span(.stream_destroy_internal);
            defer span.deinit();
            span.debug("Destroying internal Stream struct for ID: {}", .{self.id});

            // Free owned write buffer if it exists
            if (self.write_buffer_owned == .owned and self.write_buffer != null) {
                const buffer_to_free = self.write_buffer.?;
                self.connection.owner.allocator.free(buffer_to_free);
                span.debug("Freed owned write buffer during stream destruction for ID: {}", .{self.id});
            }

            // Free message buffer if allocated
            if (self.message_buffer) |buffer| {
                self.connection.owner.allocator.free(buffer);
                span.debug("Freed message buffer during stream destruction for ID: {}", .{self.id});
            }

            // Other buffers are managed by the caller

            self.* = undefined;
            alloc.destroy(self);
        }

        pub fn wantRead(self: *Stream(T), want: bool) void {
            const span = trace.span(.stream_want_read_internal);
            defer span.deinit();
            const want_val: c_int = if (want) 1 else 0;
            span.debug("Setting internal stream want-read to {} for ID: {}", .{ want, self.id });
            _ = lsquic.lsquic_stream_wantread(self.lsquic_stream, want_val);
            // FIXME: handle potential error from lsquic_stream_wantread
            self.want_read = want; // Update internal state
        }

        pub fn wantWrite(self: *Stream(T), want: bool) void {
            const span = trace.span(.stream_want_write_internal);
            defer span.deinit();
            const want_val: c_int = if (want) 1 else 0;
            span.debug("Setting internal stream want-write to {} for ID: {}", .{ want, self.id });
            _ = lsquic.lsquic_stream_wantwrite(self.lsquic_stream, want_val);
            // FIXME: handle potential error from lsquic_stream_wantwrite
            self.want_write = want; // Update internal state
        }

        /// Prepare the stream to read into the provided buffer. We take ownership of the buffer
        pub fn setReadBuffer(self: *Stream(T), buffer: []u8) !void {
            const span = trace.span(.stream_set_read_buffer);
            defer span.deinit();
            span.debug("Setting read buffer (len={d}) for internal stream ID: {}", .{ buffer.len, self.id });

            if (buffer.len == 0) {
                span.warn("Read buffer set with zero-length for stream ID: {}", .{self.id});
                return error.InvalidArgument;
            }
            // Overwrite previous buffer if any? Let's overwrite for simplicity.
            if (self.read_buffer != null) {
                span.warn("Overwriting existing read buffer for stream ID: {}", .{self.id});
            }

            self.read_buffer = buffer;
            self.read_buffer_pos = 0;
            // wantRead should be set by the command handler based on user request
        }

        /// Prepare the stream to write the provided data.
        pub fn setWriteBuffer(self: *Stream(T), data: []const u8, owned: Ownership, callback_method: CallbackMethod) !void {
            const span = trace.span(.stream_set_write_buffer);
            defer span.deinit();
            span.debug("Setting write buffer ({d} bytes) for internal stream ID: {}", .{ data.len, self.id });

            if (data.len == 0) {
                span.warn("Write buffer set with zero-length data for stream ID: {}. Ignoring.", .{self.id});
                return error.ZeroDataLen;
            }
            // Let's overwrite for simplicity.
            if (self.write_buffer != null) {
                span.err("Stream ID {} is already writing, cannot issue new write.", .{self.id});
                return error.StreamAlreadyWriting;
            }

            self.write_buffer = data;
            self.write_buffer_pos = 0;
            self.write_buffer_owned = owned;
            self.write_call_callback_method = callback_method; // Set to true if we want to send a write completed event
            // wantWrite should be set by the command handler
        }

        /// Prepare the stream to write a message with a length prefix.
        /// Will allocate a new buffer containing the length prefix + message data.
        pub fn setMessageBuffer(self: *Stream(T), message: []const u8) !void {
            const span = trace.span(.stream_set_message_buffer);
            defer span.deinit();
            span.debug("Setting message buffer ({d} bytes) for internal stream ID: {}", .{ message.len, self.id });

            if (self.write_buffer != null) {
                span.err("Stream ID {} is already writing, cannot issue new write.", .{self.id});
                return error.StreamAlreadyWriting;
            }

            // Allocate buffer for length prefix (4 bytes) + message
            const total_size = 4 + message.len;
            var buffer = try self.connection.owner.allocator.alloc(u8, total_size);
            errdefer self.connection.owner.allocator.free(buffer);

            // Write length prefix as little-endian u32
            std.mem.writeInt(u32, buffer[0..4], @intCast(message.len), .little);

            // Copy message data
            @memcpy(buffer[4..], message);

            // Set the buffer
            self.write_buffer = buffer;
            self.write_buffer_pos = 0;
            self.write_buffer_owned = .owned; // We own this buffer and need to free it
            self.write_call_callback_method = .messagecompleted; // Set to true if we want to send a write completed event

            span.debug("Message buffer set: {d} bytes length prefix + {d} bytes data", .{ 4, message.len });
        }

        pub fn flush(self: *Stream(T)) !void {
            const span = trace.span(.stream_flush_internal);
            defer span.deinit();
            span.debug("Flushing internal stream ID: {}", .{self.id});
            if (lsquic.lsquic_stream_flush(self.lsquic_stream) != 0) {
                span.err("Failed to flush internal stream ID: {}", .{self.id});
                return error.StreamFlushFailed;
            }
        }

        pub fn shutdown(self: *Stream(T), how: c_int) !void {
            const span = trace.span(.stream_shutdown_internal);
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
            const span = trace.span(.stream_close_internal);
            defer span.deinit();
            span.debug("Closing internal stream ID: {}", .{self.id});
            // This signals intent to close; onStreamClosed callback handles final cleanup.
            if (lsquic.lsquic_stream_close(self.lsquic_stream) != 0) {
                span.err("Failed to close internal stream ID: {}", .{self.id});
                return error.StreamCloseFailed;
            }
        }

        pub fn onStreamCreated(
            _: ?*anyopaque, // ea_stream_if_ctx (unused)
            maybe_lsquic_stream: ?*lsquic.lsquic_stream_t,
        ) callconv(.C) [*c]lsquic.lsquic_stream_ctx_t {
            const span = trace.span(.on_stream_created);
            defer span.deinit();

            span.debug("onStreamCreated triggered", .{});

            // Check if this connection is still valid, when we have null means connection
            // is going away
            const lsquic_stream = maybe_lsquic_stream orelse {
                span.err("Stream created callback received null stream, doing nothing", .{});
                return null;
            };

            // This was pretty hard to find as it was not in the documentation, this
            // seems to be the only way to determine if the stream was created locally
            // or remote
            const lsquic_stream_id = lsquic.lsquic_stream_id(lsquic_stream);
            span.debug("LSQUIC Stream ID: {}", .{lsquic_stream_id});

            // Get the parent Connection context
            const lsquic_connection = lsquic.lsquic_stream_conn(maybe_lsquic_stream);
            const conn_ctx = lsquic.lsquic_conn_get_ctx(lsquic_connection).?; // Assume parent conn context is valid
            const connection: *Connection(T) = @alignCast(@ptrCast(conn_ctx));

            // Use the internal Stream.create
            const stream = Stream(T).create(
                connection.owner.allocator,
                connection,
                lsquic_stream,
                lsquic_stream_id,
            ) catch
                std.debug.panic("OutOfMemory creating internal", .{});

            connection.owner.streams.put(stream.id, stream) catch
                std.debug.panic("OutOfMemory adding stream to map", .{});

            // Invoke the user-facing callback via the client
            shared.invokeCallback(T, &connection.owner.callback_handlers, .StreamCreated, .{
                .StreamCreated = stream,
            });

            return @ptrCast(stream);
        }

        pub fn onStreamReadServer(
            maybe_lsquic_stream: ?*lsquic.lsquic_stream_t,
            maybe_stream_ctx: ?*lsquic.lsquic_stream_ctx_t,
        ) callconv(.C) void {
            const span = trace.span(.on_stream_read_server);
            defer span.deinit();

            const stream_ctx = maybe_stream_ctx orelse {
                span.err("onStreamReadServer called with null context!", .{});
                return;
            };
            const stream: *Stream(T) = @alignCast(@ptrCast(stream_ctx)); // This is the internal Stream
            span.debug("onStreamReadServer triggered for internal stream ID: {}", .{stream.id});

            // Check if a read buffer has been provided via command
            if (stream.kind == null) {
                var kind_buffer: u8 = undefined;
                const read_size = lsquic.lsquic_stream_read(maybe_lsquic_stream, @ptrCast(&kind_buffer), 1);
                if (read_size == 1) {
                    stream.kind = shared.StreamKind.fromRaw(kind_buffer) catch {
                        span.err("Invalid stream kind read for stream ID {}: {d}", .{ stream.id, kind_buffer });
                        stream.close() catch |err| std.debug.panic("Failed to close stream: {s}", .{@errorName(err)});
                        return;
                    };
                    span.debug("Stream kind set to: {}", .{stream.kind.?});
                    // We got our kind, no need to read again, this is the responsibility of the
                    // protocol which will get activated based on the kind
                    stream.wantRead(true); // FIXME: protocol should set this

                    shared.invokeCallback(T, &stream.connection.owner.callback_handlers, .StreamCreated, .{
                        .StreamCreated = stream,
                    });
                    return;
                } else if (read_size == 0) {
                    span.warn("No data read for stream ID {}. Stream kind not set. Try again", .{stream.id});
                    return;
                } else {
                    span.err("Error reading stream kind for stream ID: {}", .{stream.id});
                    stream.close() catch |err| std.debug.panic("Failed to close stream: {s}", .{@errorName(err)});
                    return;
                }
            }

            // When we have already a kind, we can call the onStreamRead
            onStreamRead(maybe_lsquic_stream, maybe_stream_ctx);
        }

        pub fn onStreamRead(
            maybe_lsquic_stream: ?*lsquic.lsquic_stream_t,
            maybe_stream_ctx: ?*lsquic.lsquic_stream_ctx_t,
        ) callconv(.C) void {
            const span = trace.span(.on_stream_read);
            defer span.deinit();

            const stream_ctx = maybe_stream_ctx orelse {
                span.err("onStreamRead called with null context!", .{});
                return;
            };
            const stream: *Stream(T) = @alignCast(@ptrCast(stream_ctx)); // This is the internal Stream
            span.debug("onStreamRead triggered for internal stream ID: {}", .{stream.id});

            // Handle message-based reading if no explicit read buffer was provided
            if (stream.read_buffer == null) {
                processMessageRead(maybe_lsquic_stream, stream) catch |err| {
                    span.err("Error in message read processing for stream ID {}: {s}", .{ stream.id, @errorName(err) });
                    // Handle specific errors and potentially notify via callback
                    switch (err) {
                        error.MessageTooLarge => {
                            span.err("Message too large on stream ID {}, max allowed: {d}", .{ stream.id, shared.MAX_MESSAGE_SIZE });
                            // We could add a specific error callback for this
                            shared.invokeCallback(T, &stream.connection.owner.callback_handlers, .DataReadError, .{
                                .DataReadError = .{
                                    .connection = stream.connection.id,
                                    .stream = stream.id,
                                    .error_code = 9999, // Custom error code for message too large
                                },
                            });
                            // Close the stream - protocol violation
                            stream.close() catch |close_err| {
                                span.err("Failed to close stream after message size violation: {s}", .{@errorName(close_err)});
                            };
                        },
                        error.OutOfMemory => {
                            span.err("Out of memory when allocating for message on stream ID {}", .{stream.id});
                            shared.invokeCallback(T, &stream.connection.owner.callback_handlers, .DataReadError, .{
                                .DataReadError = .{
                                    .connection = stream.connection.id,
                                    .stream = stream.id,
                                    .error_code = 9998, // Custom error code for OOM
                                },
                            });
                        },
                        else => {
                            // Generic error handling
                            shared.invokeCallback(T, &stream.connection.owner.callback_handlers, .DataReadError, .{
                                .DataReadError = .{
                                    .connection = stream.connection.id,
                                    .stream = stream.id,
                                    .error_code = 9997, // Custom error code for other errors
                                },
                            });
                        },
                    }
                    // Reset message state after an error
                    resetMessageState(stream);
                };
                return; // Message processing handled the read
            }

            // Original raw data reading logic when a buffer is explicitly provided
            const buffer_available = stream.read_buffer.?[stream.read_buffer_pos..];
            if (buffer_available.len == 0) {
                span.warn("onStreamRead called for stream ID {} but read buffer is full.", .{stream.id});
                stream.wantRead(false);
                return;
            }

            const read_size = lsquic.lsquic_stream_read(maybe_lsquic_stream, buffer_available.ptr, buffer_available.len);

            if (read_size == 0) {
                span.debug("End of stream reached for stream ID: {}", .{stream.id});
                shared.invokeCallback(T, &stream.connection.owner.callback_handlers, .DataEndOfStream, .{
                    .DataEndOfStream = .{
                        .connection = stream.connection.id,
                        .stream = stream.id,
                        .data_read = stream.read_buffer.?[0..stream.read_buffer_pos],
                    },
                });
                stream.read_buffer = null;
                stream.read_buffer_pos = 0;
                stream.wantRead(false);
            } else if (read_size < 0) {
                switch (std.posix.errno(read_size)) {
                    std.posix.E.AGAIN => {
                        span.debug("Read would block for stream ID: {}", .{stream.id});
                        shared.invokeCallback(T, &stream.connection.owner.callback_handlers, .DataWouldBlock, .{
                            .DataWouldBlock = .{
                                .connection = stream.connection.id,
                                .stream = stream.id,
                            },
                        });
                        // Keep wantRead true
                    },
                    else => |err| {
                        span.err("Error reading from stream ID {}: {s}", .{ stream.id, @tagName(err) });
                        shared.invokeCallback(T, &stream.connection.owner.callback_handlers, .DataReadError, .{
                            .DataReadError = .{
                                .connection = stream.connection.id,
                                .stream = stream.id,
                                .error_code = @intFromEnum(err),
                            },
                        });
                        stream.read_buffer = null;
                        stream.read_buffer_pos = 0;
                        stream.wantRead(false);
                    },
                }
            } else { // read_size > 0
                const bytes_read: usize = @intCast(read_size);
                span.debug("Read {d} bytes from stream ID: {}", .{ bytes_read, stream.id });

                const prev_pos = stream.read_buffer_pos;
                stream.read_buffer_pos += bytes_read;
                const data_just_read = stream.read_buffer.?[prev_pos..stream.read_buffer_pos];

                shared.invokeCallback(T, &stream.connection.owner.callback_handlers, .DataReceived, .{
                    .DataReceived = .{
                        .connection = stream.connection.id,
                        .stream = stream.id,
                        .data = data_just_read,
                    },
                });

                if (stream.read_buffer_pos == stream.read_buffer.?.len) {
                    span.debug("User read buffer full for stream ID: {}. Disabling wantRead.", .{stream.id});
                    stream.read_buffer = null;
                    stream.read_buffer_pos = 0;
                    stream.wantRead(false);
                    // TODO: Signal buffer full? Or rely on DataReceived?
                }
            }
        }

        /// Helper function to reset message reading state
        fn resetMessageState(stream: *Stream(T)) void {
            const span = trace.span(.reset_message_state);
            defer span.deinit();

            // Free any allocated message buffer
            if (stream.message_buffer) |buffer| {
                stream.connection.owner.allocator.free(buffer);
                stream.message_buffer = null;
            }

            // Reset message state
            stream.message_reading_state = .idle;
            stream.message_length_read = 0;
            stream.message_length = null;
            stream.message_read = 0;

            span.debug("Reset message state for stream ID: {}", .{stream.id});
        }

        /// Process reading message-based data
        fn processMessageRead(maybe_lsquic_stream: ?*lsquic.lsquic_stream_t, stream: *Stream(T)) !void {
            const span = trace.span(.process_message_read);
            defer span.deinit();

            const lsquic_stream = maybe_lsquic_stream orelse {
                span.err("processMessageRead called with null lsquic_stream", .{});
                return error.NullLsquicStream;
            };

            // Initialize message reading if idle
            if (stream.message_reading_state == .idle) {
                span.debug("Starting message reading on stream ID: {}", .{stream.id});
                stream.message_reading_state = .reading_length;
                stream.message_length_read = 0;
            }

            // Step 1: Read message length (4 bytes)
            if (stream.message_reading_state == .reading_length) {
                const length_remaining = 4 - stream.message_length_read;
                const read_result = lsquic.lsquic_stream_read(lsquic_stream, &stream.message_length_buffer[stream.message_length_read], length_remaining);

                if (read_result == 0) {
                    // End of stream during length reading
                    span.debug("End of stream reached while reading message length on stream ID: {}", .{stream.id});
                    shared.invokeCallback(T, &stream.connection.owner.callback_handlers, .DataEndOfStream, .{
                        .DataEndOfStream = .{
                            .connection = stream.connection.id,
                            .stream = stream.id,
                            .data_read = &[0]u8{}, // Empty slice
                        },
                    });
                    stream.wantRead(false);
                    return error.EndOfStream;
                } else if (read_result < 0) {
                    const err = std.posix.errno(read_result);
                    if (err == std.posix.E.AGAIN) {
                        // Would block, try again later
                        span.debug("Read would block while reading message length on stream ID: {}", .{stream.id});
                        shared.invokeCallback(T, &stream.connection.owner.callback_handlers, .DataWouldBlock, .{
                            .DataWouldBlock = .{
                                .connection = stream.connection.id,
                                .stream = stream.id,
                            },
                        });
                        return; // Keep wantRead true
                    } else {
                        // Real error
                        span.err("Error reading message length from stream ID {}: {s}", .{ stream.id, @tagName(err) });
                        shared.invokeCallback(T, &stream.connection.owner.callback_handlers, .DataReadError, .{
                            .DataReadError = .{
                                .connection = stream.connection.id,
                                .stream = stream.id,
                                .error_code = @intFromEnum(err),
                            },
                        });
                        stream.wantRead(false);
                        return error.StreamReadError;
                    }
                }

                // Successfully read some bytes of the length prefix
                const bytes_read: usize = @intCast(read_result);
                stream.message_length_read += bytes_read;

                span.debug("Read {d}/{d} bytes of message length on stream ID: {}", .{ stream.message_length_read, 4, stream.id });

                // Check if we've read the complete length prefix
                if (stream.message_length_read == 4) {
                    // Parse the length as little-endian u32
                    const message_length = std.mem.readInt(u32, &stream.message_length_buffer, .little);

                    // Validate message length against maximum allowed size
                    if (message_length > shared.MAX_MESSAGE_SIZE) {
                        span.err("Message length {d} exceeds maximum allowed size {d} on stream ID: {}", .{ message_length, shared.MAX_MESSAGE_SIZE, stream.id });
                        return error.MessageTooLarge;
                    }

                    // If message length is valid, allocate buffer and prepare for body reading
                    span.debug("Message length parsed: {d} bytes for stream ID: {}", .{ message_length, stream.id });

                    // Handle edge case of zero-length message
                    if (message_length == 0) {
                        // Deliver empty message immediately
                        span.warn("Zero-length message received on stream ID: {}", .{stream.id});
                        shared.invokeCallback(T, &stream.connection.owner.callback_handlers, .MessageReceived, .{
                            .MessageReceived = .{
                                .connection = stream.connection.id,
                                .stream = stream.id,
                                .message = &[0]u8{}, // Empty slice
                            },
                        });
                        // Reset message state for next message
                        stream.message_reading_state = .idle;
                        stream.message_length_read = 0;
                        stream.message_length = null;
                        return;
                    }

                    // Allocate buffer for the message body
                    stream.message_buffer = stream.connection.owner.allocator.alloc(u8, message_length) catch {
                        span.err("Failed to allocate {d} bytes for message buffer on stream ID: {}", .{ message_length, stream.id });
                        return error.OutOfMemory;
                    };

                    // Update state to reading body
                    stream.message_length = message_length;
                    stream.message_reading_state = .reading_body;
                    stream.message_read = 0;
                }
            }

            // Step 2: Read message body
            if (stream.message_reading_state == .reading_body) {
                const message_length = stream.message_length orelse {
                    span.err("Invalid state: message_reading_state is reading_body but message_length is null", .{});
                    return error.InvalidState;
                };

                const message_buffer = stream.message_buffer orelse {
                    span.err("Invalid state: message_reading_state is reading_body but message_buffer is null", .{});
                    return error.InvalidState;
                };

                const bytes_remaining = message_length - stream.message_read;
                const read_result = lsquic.lsquic_stream_read(lsquic_stream, message_buffer.ptr + stream.message_read, bytes_remaining);

                if (read_result == 0) {
                    // End of stream during body reading - unexpected termination
                    span.err("End of stream reached while reading message body on stream ID: {}", .{stream.id});
                    shared.invokeCallback(T, &stream.connection.owner.callback_handlers, .DataEndOfStream, .{
                        .DataEndOfStream = .{
                            .connection = stream.connection.id,
                            .stream = stream.id,
                            .data_read = message_buffer[0..stream.message_read], // Partial message data
                        },
                    });
                    // Free allocated buffer since we can't complete the message
                    stream.connection.owner.allocator.free(message_buffer);
                    stream.message_buffer = null;
                    stream.wantRead(false);
                    return error.EndOfStream;
                } else if (read_result < 0) {
                    const err = std.posix.errno(read_result);
                    if (err == std.posix.E.AGAIN) {
                        // Would block, try again later
                        span.debug("Read would block while reading message body on stream ID: {}", .{stream.id});
                        shared.invokeCallback(T, &stream.connection.owner.callback_handlers, .DataWouldBlock, .{
                            .DataWouldBlock = .{
                                .connection = stream.connection.id,
                                .stream = stream.id,
                            },
                        });
                        return; // Keep wantRead true
                    } else {
                        // Real error
                        span.err("Error reading message body from stream ID {}: {s}", .{ stream.id, @tagName(err) });
                        shared.invokeCallback(T, &stream.connection.owner.callback_handlers, .DataReadError, .{
                            .DataReadError = .{
                                .connection = stream.connection.id,
                                .stream = stream.id,
                                .error_code = @intFromEnum(err),
                            },
                        });
                        // Free allocated buffer on error
                        stream.connection.owner.allocator.free(message_buffer);
                        stream.message_buffer = null;
                        stream.wantRead(false);
                        return error.StreamReadError;
                    }
                }

                // Successfully read some bytes of the message body
                const bytes_read: usize = @intCast(read_result);
                stream.message_read += bytes_read;

                span.debug("Read {d}/{d} bytes of message body on stream ID: {}", .{ stream.message_read, message_length, stream.id });

                // Check if message is complete
                if (stream.message_read == message_length) {
                    // Message fully read, deliver it
                    span.debug("Complete message of {d} bytes received on stream ID: {}", .{ message_length, stream.id });

                    // Trigger the message received callback with the full message
                    shared.invokeCallback(T, &stream.connection.owner.callback_handlers, .MessageReceived, .{
                        .MessageReceived = .{
                            .connection = stream.connection.id,
                            .stream = stream.id,
                            .message = message_buffer, // pass ownership to callback
                        },
                    });

                    stream.message_buffer = null;
                    stream.message_length = null;
                    stream.message_reading_state = .idle;
                    stream.message_read = 0;
                    stream.message_length_read = 0;
                }
            }
        }

        pub fn onStreamWrite(
            maybe_lsquic_stream: ?*lsquic.lsquic_stream_t,
            maybe_stream_ctx: ?*lsquic.lsquic_stream_ctx_t,
        ) callconv(.C) void {
            const span = trace.span(.on_stream_write);
            defer span.deinit();

            _ = maybe_lsquic_stream; // Unused in this context

            const stream_ctx = maybe_stream_ctx orelse {
                span.err("onStreamWrite called with null context!", .{});
                return;
            };
            const stream: *Stream(T) = @alignCast(@ptrCast(stream_ctx)); // Internal Stream
            span.debug("onStreamWrite triggered for internal stream ID: {}", .{stream.id});

            if (stream.write_buffer == null) {
                span.warn("onStreamWrite called for stream ID {} but no write buffer set via command. Disabling wantWrite.", .{stream.id});
                stream.wantWrite(false);
                return;
            }

            const data_to_write = stream.write_buffer.?[stream.write_buffer_pos..];
            const total_size = stream.write_buffer.?.len;

            if (data_to_write.len == 0) {
                span.warn("onStreamWrite called for stream ID {} but write buffer position indicates completion.", .{stream.id});
                stream.wantWrite(false);
                return;
            }

            const written = lsquic.lsquic_stream_write(stream.lsquic_stream, data_to_write.ptr, data_to_write.len);

            if (written == 0) {
                span.trace("No data written to stream ID {} (likely blocked)", .{stream.id});
                // Keep wantWrite true
                return;
            } else if (written < 0) {
                if (std.posix.errno(written) == std.posix.E.AGAIN) {
                    span.trace("Stream write would block (EAGAIN) for stream ID {}", .{stream.id});
                    // Keep wantWrite true
                    return;
                } else {
                    const err_code = -written;
                    span.err("Stream write failed for stream ID {} with error code: {d}", .{ stream.id, err_code });
                    if (stream.write_call_callback_method != .none)
                        shared.invokeCallback(T, &stream.connection.owner.callback_handlers, .DataWriteError, .{
                            .DataWriteError = .{
                                .connection = stream.connection.id,
                                .stream = stream.id,
                                .error_code = @intCast(err_code),
                            },
                        });
                    stream.write_buffer = null;
                    stream.write_buffer_pos = 0;
                    stream.write_call_callback_method = .none;
                    stream.wantWrite(false);
                    return;
                }
            }

            // written > 0
            const bytes_written: usize = @intCast(written);
            span.debug("Written {d} bytes to stream ID: {}", .{ bytes_written, stream.id });
            stream.write_buffer_pos += bytes_written;

            if (stream.write_call_callback_method != .none)
                shared.invokeCallback(T, &stream.connection.owner.callback_handlers, .DataWriteProgress, .{
                    .DataWriteProgress = .{
                        .connection = stream.connection.id,
                        .stream = stream.id,
                        .bytes_written = stream.write_buffer_pos,
                        .total_size = total_size,
                    },
                });

            if (stream.write_buffer_pos >= total_size) {
                span.debug("Write complete for user buffer (total {d} bytes) on stream ID: {}", .{ total_size, stream.id });

                switch (stream.write_call_callback_method) {
                    .none => {
                        // No callback to invoke
                    },
                    .datawritecompleted => {
                        shared.invokeCallback(T, &stream.connection.owner.callback_handlers, .DataWriteCompleted, .{
                            .DataWriteCompleted = .{
                                .connection = stream.connection.id,
                                .stream = stream.id,
                                .total_bytes_written = stream.write_buffer_pos,
                            },
                        });
                    },
                    .messagecompleted => {
                        shared.invokeCallback(T, &stream.connection.owner.callback_handlers, .MessageSend, .{
                            .MessageSend = .{
                                .connection = stream.connection.id,
                                .stream = stream.id,
                            },
                        });
                    },
                }

                // Free the buffer if we own it
                if (stream.write_buffer_owned == .owned and stream.write_buffer != null) {
                    const buffer_to_free = stream.write_buffer.?;
                    stream.connection.owner.allocator.free(buffer_to_free);
                    span.debug("Freed owned write buffer for stream ID: {}", .{stream.id});
                }

                stream.write_buffer = null;
                stream.write_buffer_pos = 0;
                stream.write_buffer_owned = .borrow;
                span.trace("Disabling write interest for stream ID {}", .{stream.id});
                stream.wantWrite(false);

                // Flush the stream to ensure all data is sent
                span.debug("Flushing stream ID {} after write completion", .{stream.id});
                if (lsquic.lsquic_stream_flush(stream.lsquic_stream) != 0) {
                    span.err("Failed to flush stream ID {} after write completion", .{stream.id});
                }
            }
            // else: Keep wantWrite true
        }

        pub fn onStreamClosed(
            _: ?*lsquic.lsquic_stream_t,
            maybe_stream_ctx: ?*lsquic.lsquic_stream_ctx_t,
        ) callconv(.C) void {
            const span = trace.span(.on_stream_closed);
            defer span.deinit();
            span.debug("LSQUIC stream closed callback received", .{});

            const stream_ctx = maybe_stream_ctx orelse {
                span.err("onStreamClosed called with null context!", .{});
                return;
            };
            const stream: *Stream(T) = @alignCast(@ptrCast(stream_ctx)); // Internal Stream
            span.debug("Processing internal stream closure for ID: {}", .{stream.id});

            // Invoke the user-facing callback
            shared.invokeCallback(T, &stream.connection.owner.callback_handlers, .StreamClosed, .{
                .StreamClosed = .{
                    .connection = stream.connection.id,
                    .stream = stream.id,
                },
            });

            // Remove the internal stream from the client's map
            if (stream.connection.owner.streams.fetchRemove(stream.id)) |_| {
                span.debug("Removed internal stream ID {} from map.", .{stream.id});
            } else {
                span.warn("Closing an internal stream (ID: {}) that was not found in the map.", .{stream.id});
            }

            // Destroy our internal stream context struct
            const id = stream.id;
            stream.destroy(stream.connection.owner.allocator);

            span.debug("Internal stream cleanup complete for formerly ID: {}", .{id});
        }
    };
}
