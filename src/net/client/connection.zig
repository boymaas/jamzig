const std = @import("std");
const uuid = @import("uuid");
const lsquic = @import("lsquic");
const network = @import("network");

const shared = @import("../jamsnp/shared_types.zig");
const JamSnpClient = @import("../jamsnp/client.zig").JamSnpClient; // Forward declare or pass as type? Pass for now.
const Stream = @import("../jamsnp/client.zig").Stream; // Assuming Stream is needed here, adjust if moved

const trace = @import("../../tracing.zig").scoped(.network);

pub const ConnectionId = shared.ConnectionId;

// --- Nested Connection Struct ---
pub const Connection = struct {
    id: ConnectionId,
    lsquic_connection: *lsquic.lsquic_conn_t, // Set in onConnectionCreated
    endpoint: network.EndPoint,
    client: *JamSnpClient,

    pub fn create(alloc: std.mem.Allocator, client: *JamSnpClient, endpoint: network.EndPoint) !*Connection {
        const connection = try alloc.create(Connection);
        connection.* = .{
            .id = uuid.v4.new(),
            .lsquic_connection = undefined, // lsquic sets this via callback
            .endpoint = endpoint,
            .client = client,
        };
        return connection;
    }

    pub fn destroy(self: *Connection, alloc: std.mem.Allocator) void {
        const span = trace.span(.connection_destroy);
        defer span.deinit();
        span.debug("Destroying Connection struct for ID: {}", .{self.id});
        alloc.destroy(self);
    }

    // request a new stream on the connection
    pub fn createStream(self: *Connection) !void {
        const span = trace.span(.create_stream);
        defer span.deinit();
        span.debug("Requesting new stream on connection ID: {}", .{self.id});

        // Check if lsquic_connection is valid (has been set by onConnectionCreated)
        if (self.lsquic_connection == undefined) {
            span.err("Cannot create stream, lsquic connection not yet established for ID: {}", .{self.id});
            return error.ConnectionNotReady;
        }

        if (lsquic.lsquic_conn_make_stream(self.lsquic_connection) == null) { // Check for NULL return
            span.err("lsquic_conn_make_stream failed (e.g., stream limit reached?) for connection ID: {}", .{self.id});
            // This usually means stream limit reached or connection closing
            return error.StreamCreationFailed;
        }

        span.debug("Stream creation request successful for connection ID: {}", .{self.id});
        // Stream object itself is created in the onStreamCreated callback
    }

    // -- LSQUIC Connection Callbacks
    pub fn onConnectionCreated(
        _: ?*anyopaque, // ea_stream_if_ctx (unused here)
        maybe_lsquic_connection: ?*lsquic.lsquic_conn_t,
    ) callconv(.C) ?*lsquic.lsquic_conn_ctx_t {
        const span = trace.span(.on_connection_created);
        defer span.deinit();

        // Retrieve the connection context we passed to lsquic_engine_connect
        const conn_ctx = lsquic.lsquic_conn_get_ctx(maybe_lsquic_connection).?;
        const connection: *Connection = @alignCast(@ptrCast(conn_ctx));
        span.debug("LSQUIC connection created for endpoint: {}, Assigning ID: {}", .{ connection.endpoint, connection.id });

        // Store the lsquic connection pointer
        connection.lsquic_connection = maybe_lsquic_connection orelse {
            // This shouldn't happen if lsquic calls this, but good practice
            span.err("onConnectionCreated called with null lsquic connection pointer!", .{});
            // TODO: Returning null might signal an error to lsquic? Check docs.
            // Let's assume it's non-null for now.
            return null;
        };

        connection.client.invokeCallback(.ConnectionEstablished, .{
            .ConnectionEstablished = .{
                .connection = connection.id,
                .endpoint = connection.endpoint,
            },
        });

        // Return our connection struct pointer as the context for lsquic
        return @ptrCast(connection);
    }

    // Note on Connection/Stream Closure Callback Order:
    // lsquic is expected to invoke `Stream.onStreamClosed` for all streams associated
    // with a connection *before* it invokes `Connection.onConnectionClosed` for the
    // connection itself. Therefore, explicit stream cleanup is not performed
    // within `Connection.onConnectionClosed`.
    pub fn onConnectionClosed(maybe_lsquic_connection: ?*lsquic.lsquic_conn_t) callconv(.C) void {
        const span = trace.span(.on_connection_closed);
        defer span.deinit();
        span.debug("LSQUIC connection closed callback received", .{});

        // Retrieve our connection context
        const conn_ctx = lsquic.lsquic_conn_get_ctx(maybe_lsquic_connection);
        // Check if context is null, maybe it was already closed/cleaned up?
        if (conn_ctx == null) {
            span.warn("onConnectionClosed called but context was null, possibly already handled?", .{});
            return;
        }
        const conn: *Connection = @ptrCast(@alignCast(conn_ctx));
        span.debug("Processing connection closure for ID: {}", .{conn.id});

        // Invoke the user's ConnectionClosed callback
        conn.client.invokeCallback(.ConnectionClosed, .{
            .ConnectionClosed = .{ .connection = conn.id },
        });

        // Remove the connection from the client's map *before* destroying it
        if (conn.client.connections.fetchRemove(conn.id)) |_| {
            span.debug("Removed connection ID {} from map.", .{conn.id});
        } else {
            // This might happen if connection failed very early or cleanup race?
            span.warn("Closing a connection (ID: {}) that was not found in the map.", .{conn.id});
        }

        // Clear the context in lsquic *before* destroying our context struct
        // Although lsquic shouldn't use it after this callback returns.

        lsquic.lsquic_conn_set_ctx(maybe_lsquic_connection, null);

        span.debug("Connection cleanup complete for formerly ID: {}", .{conn.id});

        // Destroy our connection context struct
        conn.client.allocator.destroy(conn);
    }
};
