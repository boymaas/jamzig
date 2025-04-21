const std = @import("std");
const uuid = @import("uuid");
const lsquic = @import("lsquic");

const shared = @import("../jamsnp/shared_types.zig");
const ServerConnection = @import("connection.zig").Connection;

const trace = @import("../../tracing.zig").scoped(.network);

pub const StreamId = shared.StreamId;

// -- Nested Stream Struct
pub const Stream = struct {
    id: StreamId, // Added UUID
    lsquic_stream: *lsquic.lsquic_stream_t,
    connection: *ServerConnection,
    read_buffer: []u8,

    // State for echoing "pong" back
    data_to_write: ?[]const u8 = null,
    write_pos: usize = 0,

    pub fn create(alloc: std.mem.Allocator, connection: *ServerConnection, lsquic_stream: *lsquic.lsquic_stream_t) !*Stream {
        const span = trace.span(.stream_create);
        defer span.deinit();
        const stream = try alloc.create(Stream);
        errdefer alloc.destroy(stream);

        const read_buffer = try alloc.alloc(u8, 1024); // Allocate read buffer here
        errdefer alloc.free(read_buffer);

        const new_id = uuid.v4.new();
        span.debug("Creating server stream context with ID: {} on connection ID: {}", .{ new_id, connection.id });

        stream.* = .{
            .id = new_id,
            .lsquic_stream = lsquic_stream,
            .connection = connection,
            .read_buffer = read_buffer,
            .data_to_write = null,
            .write_pos = 0,
        };
        return stream;
    }

    pub fn destroy(self: *Stream, alloc: std.mem.Allocator) void {
        const span = trace.span(.stream_destroy);
        defer span.deinit();
        span.debug("Destroying server stream context for ID: {}", .{self.id});
        // Free associated resources
        alloc.free(self.read_buffer);

        alloc.destroy(self);
    }

    // -- LSQUIC Stream Callbacks
    pub fn onNewStream(
        _: ?*anyopaque, // *JamSnpServer (ea_stream_if_ctx)
        maybe_lsquic_stream: ?*lsquic.lsquic_stream_t,
    ) callconv(.C) ?*lsquic.lsquic_stream_ctx_t {
        const span = trace.span(.on_new_stream);
        defer span.deinit();

        const lsquic_stream_ptr = maybe_lsquic_stream orelse {
            span.err("onNewStream called with null stream pointer!", .{});
            return null;
        };

        const lsquic_connection = lsquic.lsquic_stream_conn(lsquic_stream_ptr);
        const conn_ctx = lsquic.lsquic_conn_get_ctx(lsquic_connection);
        if (conn_ctx == null) {
            span.warn("No connection context found for new stream, maybe connection closing?", .{});
            return null;
        }
        const connection: *ServerConnection = @ptrCast(@alignCast(conn_ctx.?));
        const server = connection.server;
        span.debug("New stream callback triggered on connection ID: {}", .{connection.id});

        const stream = Stream.create(server.allocator, connection, lsquic_stream_ptr) catch |err| {
            span.err("Failed to create stream context: {s}", .{@errorName(err)});
            return null; // Signal error to lsquic
        };
        errdefer stream.destroy(server.allocator);

        // Add to bookkeeping map using UUID
        server.streams.put(stream.id, stream) catch |err| {
            span.err("Failed to add stream {} to map: {s}", .{ stream.id, @errorName(err) });
            return null; // Let errdefer clean up, signal error
        };

        // Invoke user callback
        server.invokeCallback(.StreamCreatedByClient, .{
            .StreamCreatedByClient = .{
                .connection_id = connection.id,
                .stream_id = stream.id,
            },
        });

        // span.debug("Requesting read for new stream ID: {}", .{stream.id});
        // _ = lsquic.lsquic_stream_wantread(lsquic_stream_ptr, 1);

        span.debug("Stream context created successfully for ID: {}", .{stream.id});
        return @ptrCast(stream);
    }

    pub fn onRead(
        _: ?*lsquic.lsquic_stream_t,
        maybe_stream_ctx: ?*lsquic.lsquic_stream_ctx_t,
    ) callconv(.C) void {
        const span = trace.span(.on_stream_read);
        defer span.deinit();

        const stream_ctx = maybe_stream_ctx orelse {
            span.warn("No stream context in read callback for lsquic stream (already closed?)", .{});
            return;
        };
        const stream: *Stream = @ptrCast(@alignCast(stream_ctx));
        const stream_id = stream.id;
        const conn_id = stream.connection.id;
        const server = stream.connection.server;
        // span.trace("Stream read triggered for ID: {}", .{stream_id}); // Noisy

        const read_size = lsquic.lsquic_stream_read(stream.lsquic_stream, stream.read_buffer.ptr, stream.read_buffer.len);

        if (read_size == 0) {
            span.debug("End of stream (FIN) received for stream ID: {}", .{stream_id});
            _ = lsquic.lsquic_stream_wantread(stream.lsquic_stream, 0);
            if (stream.data_to_write == null) {
                span.debug("Closing stream ID {} after FIN (no pending write)", .{stream_id});
                _ = lsquic.lsquic_stream_close(stream.lsquic_stream); // onClose will trigger callback
            } else {
                span.debug("Shutting down read side of stream ID {} after FIN (pending write)", .{stream_id});
                _ = lsquic.lsquic_stream_shutdown(stream.lsquic_stream, 0); // 0 for read
            }
        } else if (read_size < 0) {
            const errno = std.posix.errno(read_size);
            if (errno == std.posix.E.AGAIN) {
                span.trace("Read would block (EAGAIN) for stream ID: {}", .{stream_id});
                server.invokeCallback(.DataReadWouldBlock, .{
                    .DataReadWouldBlock = .{ .connection_id = conn_id, .stream_id = stream_id },
                });
                _ = lsquic.lsquic_stream_wantread(stream.lsquic_stream, 1); // Keep wanting read
            } else {
                span.err("Error reading from stream ID {}: {s}", .{ stream_id, @tagName(errno) });
                server.invokeCallback(.DataReadError, .{
                    .DataReadError = .{ .connection_id = conn_id, .stream_id = stream_id, .error_code = @intFromEnum(errno) },
                });
                _ = lsquic.lsquic_stream_wantread(stream.lsquic_stream, 0);
                _ = lsquic.lsquic_stream_close(stream.lsquic_stream); // onClose will trigger callback
            }
        } else { // read_size > 0
            const bytes_read: usize = @intCast(read_size);
            const received_data = stream.read_buffer[0..bytes_read];
            span.debug("Read {d} bytes from stream ID: {}", .{ bytes_read, stream_id });

            // Invoke DataReceived callback
            server.invokeCallback(.DataReceived, .{
                .DataReceived = .{
                    .connection_id = conn_id,
                    .stream_id = stream_id,
                    .data = received_data,
                },
            });

            // Simple Echo Logic: Prepare to write "pong" if not already writing
            if (stream.data_to_write == null) {
                span.debug("Preparing to write 'pong' to stream ID {}", .{stream_id});
                stream.data_to_write = "pong";
                stream.write_pos = 0;
                _ = lsquic.lsquic_stream_wantwrite(stream.lsquic_stream, 1); // Trigger onWrite
            } else {
                span.trace("Already writing to stream ID {}, ignoring new read data for echo trigger.", .{stream_id});
            }

            // Continue wanting to read
            _ = lsquic.lsquic_stream_wantread(stream.lsquic_stream, 1);
        }
    }

    pub fn onWrite(
        _: ?*lsquic.lsquic_stream_t,
        maybe_stream_ctx: ?*lsquic.lsquic_stream_ctx_t,
    ) callconv(.C) void {
        const span = trace.span(.on_stream_write);
        defer span.deinit();

        const stream_ctx = maybe_stream_ctx orelse {
            span.warn("No stream context in write callback for lsquic stream (already closed?)", .{});
            return;
        };
        const stream: *Stream = @ptrCast(@alignCast(stream_ctx));
        const stream_id = stream.id;
        const conn_id = stream.connection.id;
        const server = stream.connection.server;
        // span.trace("Stream write triggered for ID: {}", .{stream_id}); // Noisy

        if (stream.data_to_write) |data_to_write| {
            const remaining_data = data_to_write[stream.write_pos..];
            if (remaining_data.len == 0) {
                span.warn("onWrite called for stream ID {} but remaining data is zero.", .{stream_id});
                // Should not happen if logic is correct, reset state and shutdown write
                stream.data_to_write = null;
                stream.write_pos = 0;
                _ = lsquic.lsquic_stream_wantwrite(stream.lsquic_stream, 0);
                span.debug("Shutting down write side of stream ID {} after write completion (defensive)", .{stream_id});
                _ = lsquic.lsquic_stream_shutdown(stream.lsquic_stream, 1); // 1 for write
                return;
            }

            const written = lsquic.lsquic_stream_write(stream.lsquic_stream, remaining_data.ptr, remaining_data.len);

            if (written == 0) {
                span.trace("Write blocked for stream ID {}, keeping wantWrite.", .{stream_id});
                server.invokeCallback(.DataWriteWouldBlock, .{ // Added WouldBlock callback
                    .DataWriteWouldBlock = .{ .connection_id = conn_id, .stream_id = stream_id },
                });
                _ = lsquic.lsquic_stream_wantwrite(stream.lsquic_stream, 1); // Keep wanting write
            } else if (written < 0) {
                const errno = std.posix.errno(written);
                // EAGAIN check (unlikely based on lsquic docs, but safe)
                if (errno == std.posix.E.AGAIN) {
                    span.trace("Write would block (EAGAIN) for stream ID {}", .{stream_id});
                    server.invokeCallback(.DataWriteWouldBlock, .{
                        .DataWriteWouldBlock = .{ .connection_id = conn_id, .stream_id = stream_id },
                    });
                    _ = lsquic.lsquic_stream_wantwrite(stream.lsquic_stream, 1);
                    return;
                }
                // Actual error
                span.err("Error writing to stream ID {}: {s}", .{ stream_id, @tagName(errno) });
                server.invokeCallback(.DataWriteError, .{
                    .DataWriteError = .{ .connection_id = conn_id, .stream_id = stream_id, .error_code = @intFromEnum(errno) },
                });
                stream.data_to_write = null; // Stop trying to write
                stream.write_pos = 0;
                _ = lsquic.lsquic_stream_wantwrite(stream.lsquic_stream, 0);
                _ = lsquic.lsquic_stream_close(stream.lsquic_stream); // Close on error
            } else { // written > 0
                const bytes_written: usize = @intCast(written);
                stream.write_pos += bytes_written;
                span.debug("Wrote {d} bytes to stream ID {}. Total written: {d}/{d}", .{ bytes_written, stream_id, stream.write_pos, data_to_write.len });

                if (stream.write_pos >= data_to_write.len) {
                    const total_written = stream.write_pos; // Capture before reset
                    span.debug("Write of 'pong' complete for stream ID: {}", .{stream_id});
                    stream.data_to_write = null;
                    stream.write_pos = 0;
                    _ = lsquic.lsquic_stream_wantwrite(stream.lsquic_stream, 0); // Stop wanting write

                    // Invoke write completed callback
                    server.invokeCallback(.DataWriteCompleted, .{
                        .DataWriteCompleted = .{
                            .connection_id = conn_id,
                            .stream_id = stream_id,
                            .total_bytes_written = total_written,
                        },
                    });

                    span.debug("Shutting down write side of stream ID {} after write completed", .{stream_id});
                    _ = lsquic.lsquic_stream_shutdown(stream.lsquic_stream, 1); // 1 for write
                } else {
                    _ = lsquic.lsquic_stream_wantwrite(stream.lsquic_stream, 1); // Keep wanting write
                }
            }
        } else {
            span.trace("onWrite called for stream ID {} with nothing to write. Disabling wantWrite.", .{stream_id});
            _ = lsquic.lsquic_stream_wantwrite(stream.lsquic_stream, 0);
        }
    }

    pub fn onClose(
        _: ?*lsquic.lsquic_stream_t,
        maybe_stream_ctx: ?*lsquic.lsquic_stream_ctx_t,
    ) callconv(.C) void {
        const span = trace.span(.on_stream_close);
        defer span.deinit();

        const stream_ctx = maybe_stream_ctx orelse {
            span.warn("No stream context in close callback for lsquic stream (double close?)", .{});
            return;
        };
        const stream: *Stream = @ptrCast(@alignCast(stream_ctx));
        const stream_id = stream.id; // Get ID before potential destruction
        const conn_id = stream.connection.id;
        const server = stream.connection.server;
        span.debug("Stream close callback triggered for ID: {}", .{stream_id});

        // Invoke user callback *before* removing/destroying
        server.invokeCallback(.StreamClosedByClient, .{
            .StreamClosedByClient = .{
                .connection_id = conn_id,
                .stream_id = stream_id,
            },
        });

        // Remove from bookkeeping map using UUID
        if (server.streams.fetchRemove(stream_id)) |removed_entry| {
            std.debug.assert(removed_entry.value == stream); // Sanity check
            span.debug("Removed stream ID {} from map.", .{stream_id});
        } else {
            span.warn("Closing stream (ID: {}) was not found in the map, but context existed.", .{stream_id});
        }

        // Destroy our stream context struct using its method
        stream.destroy(server.allocator);

        span.debug("Stream resources cleaned up for formerly ID: {}", .{stream_id});
    }
};
