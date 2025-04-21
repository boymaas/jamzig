const std = @import("std");
const uuid = @import("uuid");
const lsquic = @import("lsquic");

const shared = @import("../jamsnp/shared_types.zig");
const ServerConnection = @import("server_connection.zig").Connection;

const trace = @import("../../tracing.zig").scoped(.network);

pub const StreamId = shared.StreamId;

// --- Internal Stream Struct (for lsquic context)
// This struct holds the state needed *within* the lsquic callbacks.
pub const Stream = struct {
    id: StreamId,
    connection: *ServerConnection, // Use refactored type
    lsquic_stream: *lsquic.lsquic_stream_t, // Set in onStreamCreated

    // Internal state for reading/writing (managed by lsquic callbacks)
    want_write: bool = false,
    write_buffer: ?[]const u8 = null, // Buffer provided by user via command
    write_buffer_pos: usize = 0,

    want_read: bool = false,
    read_buffer: ?[]u8 = null, // Buffer provided by user via command
    read_buffer_pos: usize = 0,

    fn create(alloc: std.mem.Allocator, connection: *ServerConnection, lsquic_stream: *lsquic.lsquic_stream_t) !*Stream {
        const span = trace.span(.stream_create_internal);
        defer span.deinit();
        span.debug("Creating internal Stream context for connection ID: {}", .{connection.id});
        const stream = try alloc.create(Stream);
        errdefer alloc.destroy(stream);

        stream.* = .{
            .id = uuid.v4.new(),
            .lsquic_stream = lsquic_stream,
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

    pub fn destroy(self: *Stream, alloc: std.mem.Allocator) void {
        // Just free the memory, lsquic handles its stream resources.
        const span = trace.span(.stream_destroy_internal);
        defer span.deinit();
        span.debug("Destroying internal Stream struct for ID: {}", .{self.id});

        // Buffers are managed by the caller

        alloc.destroy(self);
    }

    pub fn wantRead(self: *Stream, want: bool) !void {
        const span = trace.span(.stream_want_read_internal);
        defer span.deinit();
        const want_val: c_int = if (want) 1 else 0;
        span.debug("Setting internal stream want-read to {} for ID: {}", .{ want, self.id });
        _ = lsquic.lsquic_stream_wantread(self.lsquic_stream, want_val);
        // FIXME: handle potential error from lsquic_stream_wantwrite
        self.want_read = want; // Update internal state
    }

    pub fn wantWrite(self: *Stream, want: bool) !void {
        const span = trace.span(.stream_want_write_internal);
        defer span.deinit();
        const want_val: c_int = if (want) 1 else 0;
        span.debug("Setting internal stream want-write to {} for ID: {}", .{ want, self.id });
        _ = lsquic.lsquic_stream_wantwrite(self.lsquic_stream, want_val);
        // FIXME: handle potential error from lsquic_stream_wantwrite
        self.want_write = want; // Update internal state
    }

    /// Prepare the stream to read into the provided buffer.
    /// Called internally when a Stream read command is processed.
    pub fn setReadBuffer(self: *Stream, buffer: []u8) !void {
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
    pub fn setWriteBuffer(self: *Stream, data: []const u8) !void {
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
        // wantWrite should be set by the command handler
    }

    pub fn flush(self: *Stream) !void {
        const span = trace.span(.stream_flush_internal);
        defer span.deinit();
        span.debug("Flushing internal stream ID: {}", .{self.id});
        if (lsquic.lsquic_stream_flush(self.lsquic_stream) != 0) {
            span.err("Failed to flush internal stream ID: {}", .{self.id});
            return error.StreamFlushFailed;
        }
    }

    pub fn shutdown(self: *Stream, how: c_int) !void {
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

    pub fn close(self: *Stream) !void {
        const span = trace.span(.stream_close_internal);
        defer span.deinit();
        span.debug("Closing internal stream ID: {}", .{self.id});
        // This signals intent to close; onStreamClosed callback handles final cleanup.
        if (lsquic.lsquic_stream_close(self.lsquic_stream) != 0) {
            span.err("Failed to close internal stream ID: {}", .{self.id});
            return error.StreamCloseFailed;
        }
    }

    // -- LSQUIC Stream Callbacks
    pub fn onStreamCreated(
        _: ?*anyopaque, // ea_stream_if_ctx (unused)
        maybe_lsquic_stream: ?*lsquic.lsquic_stream_t,
    ) callconv(.C) *lsquic.lsquic_stream_ctx_t {
        const span = trace.span(.on_stream_created);
        defer span.deinit();
        span.debug("LSQUIC stream created callback received", .{});

        // Get the parent Connection context
        const lsquic_connection = lsquic.lsquic_stream_conn(maybe_lsquic_stream);
        const conn_ctx = lsquic.lsquic_conn_get_ctx(lsquic_connection).?; // Assume parent conn context is valid
        const connection: *ServerConnection = @alignCast(@ptrCast(conn_ctx));

        span.debug("Creating internal Stream context for connection ID: {}", .{connection.id});
        // Use the internal Stream.create
        const stream = Stream.create(connection.server.allocator, connection, maybe_lsquic_stream orelse unreachable) catch |err| {
            span.err("Failed to allocate memory for internal Stream context: {s}", .{@errorName(err)});
            std.debug.panic("OutOfMemory creating internal Stream context: {s}", .{@errorName(err)});
        };

        // Add stream to the client's map
        connection.server.streams.put(stream.id, stream) catch |err| {
            span.err("Failed to add internal stream {} to map: {s}", .{ stream.id, @errorName(err) });
            stream.destroy(connection.server.allocator); // Clean up allocated stream
            std.debug.panic("Failed to add internal stream to map: {s}", .{@errorName(err)});
        };

        // Invoke the user-facing callback via the client
        connection.server.invokeCallback(.StreamCreated, .{
            .StreamCreated = .{
                .connection = connection.id,
                .stream = stream.id,
            },
        });

        // Return our internal stream struct pointer as the context for lsquic
        return @ptrCast(stream);
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
        const stream: *Stream = @alignCast(@ptrCast(stream_ctx)); // This is the internal Stream
        span.debug("onStreamRead triggered for internal stream ID: {}", .{stream.id});

        // Check if a read buffer has been provided via command
        if (stream.read_buffer == null) {
            span.warn("onStreamRead called for stream ID {} but no read buffer set via command. Disabling wantRead.", .{stream.id});
            try stream.wantRead(false);
            return;
        }

        const buffer_available = stream.read_buffer.?[stream.read_buffer_pos..];
        if (buffer_available.len == 0) {
            span.warn("onStreamRead called for stream ID {} but read buffer is full.", .{stream.id});
            try stream.wantRead(false);
            return;
        }

        const read_size = lsquic.lsquic_stream_read(maybe_lsquic_stream, buffer_available.ptr, buffer_available.len);

        if (read_size == 0) {
            span.debug("End of stream reached for stream ID: {}", .{stream.id});
            stream.connection.server.invokeCallback(.DataEndOfStream, .{
                .DataEndOfStream = .{
                    .connection = stream.connection.id,
                    .stream = stream.id,
                    .data_read = stream.read_buffer.?[0..stream.read_buffer_pos],
                },
            });
            stream.read_buffer = null;
            stream.read_buffer_pos = 0;
            try stream.wantRead(false);
        } else if (read_size < 0) {
            switch (std.posix.errno(read_size)) {
                std.posix.E.AGAIN => {
                    span.debug("Read would block for stream ID: {}", .{stream.id});
                    stream.connection.server.invokeCallback(.DataWouldBlock, .{
                        .DataWouldBlock = .{
                            .connection = stream.connection.id,
                            .stream = stream.id,
                        },
                    });
                    // Keep wantRead true
                },
                else => |err| {
                    span.err("Error reading from stream ID {}: {s}", .{ stream.id, @tagName(err) });
                    stream.connection.server.invokeCallback(.DataReadError, .{
                        .DataReadError = .{
                            .connection = stream.connection.id,
                            .stream = stream.id,
                            .error_code = @intFromEnum(err),
                        },
                    });
                    stream.read_buffer = null;
                    stream.read_buffer_pos = 0;
                    try stream.wantRead(false);
                },
            }
        } else { // read_size > 0
            const bytes_read: usize = @intCast(read_size);
            span.debug("Read {d} bytes from stream ID: {}", .{ bytes_read, stream.id });

            const prev_pos = stream.read_buffer_pos;
            stream.read_buffer_pos += bytes_read;
            const data_just_read = stream.read_buffer.?[prev_pos..stream.read_buffer_pos];

            stream.connection.server.invokeCallback(.DataReceived, .{
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
                try stream.wantRead(false);
                // TODO: Signal buffer full? Or rely on DataReceived?
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
        const stream: *Stream = @alignCast(@ptrCast(stream_ctx)); // Internal Stream
        span.debug("onStreamWrite triggered for internal stream ID: {}", .{stream.id});

        if (stream.write_buffer == null) {
            span.warn("onStreamWrite called for stream ID {} but no write buffer set via command. Disabling wantWrite.", .{stream.id});
            try stream.wantWrite(false);
            return;
        }

        const data_to_write = stream.write_buffer.?[stream.write_buffer_pos..];
        const total_size = stream.write_buffer.?.len;

        if (data_to_write.len == 0) {
            span.warn("onStreamWrite called for stream ID {} but write buffer position indicates completion.", .{stream.id});
            try stream.wantWrite(false);
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
                stream.connection.server.invokeCallback(.DataWriteError, .{
                    .DataWriteError = .{
                        .connection = stream.connection.id,
                        .stream = stream.id,
                        .error_code = @intCast(err_code),
                    },
                });
                stream.write_buffer = null;
                stream.write_buffer_pos = 0;
                try stream.wantWrite(false);
                return;
            }
        }

        // written > 0
        const bytes_written: usize = @intCast(written);
        span.debug("Written {d} bytes to stream ID: {}", .{ bytes_written, stream.id });
        stream.write_buffer_pos += bytes_written;

        stream.connection.server.invokeCallback(.DataWriteProgress, .{
            .DataWriteProgress = .{
                .connection = stream.connection.id,
                .stream = stream.id,
                .bytes_written = stream.write_buffer_pos,
                .total_size = total_size,
            },
        });

        if (stream.write_buffer_pos >= total_size) {
            span.debug("Write complete for user buffer (total {d} bytes) on stream ID: {}", .{ total_size, stream.id });

            stream.connection.server.invokeCallback(.DataWriteCompleted, .{
                .DataWriteCompleted = .{
                    .connection = stream.connection.id,
                    .stream = stream.id,
                    .total_bytes_written = stream.write_buffer_pos,
                },
            });

            stream.write_buffer = null;
            stream.write_buffer_pos = 0;
            span.trace("Disabling write interest for stream ID {}", .{stream.id});
            try stream.wantWrite(false);
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
        const stream: *Stream = @alignCast(@ptrCast(stream_ctx)); // Internal Stream
        span.debug("Processing internal stream closure for ID: {}", .{stream.id});

        // Invoke the user-facing callback
        stream.connection.server.invokeCallback(.StreamClosed, .{
            .StreamClosed = .{
                .connection = stream.connection.id,
                .stream = stream.id,
            },
        });

        // Remove the internal stream from the client's map
        if (stream.connection.server.streams.fetchRemove(stream.id)) |_| {
            span.debug("Removed internal stream ID {} from map.", .{stream.id});
        } else {
            span.warn("Closing an internal stream (ID: {}) that was not found in the map.", .{stream.id});
        }

        // Destroy our internal stream context struct
        stream.destroy(stream.connection.server.allocator);

        span.debug("Internal stream cleanup complete for formerly ID: {}", .{stream.id});
    }
};
