const std = @import("std");
const uuid = @import("uuid");
const lsquic = @import("lsquic");
const network = @import("network");

const shared = @import("../jamsnp/shared_types.zig");
const JamSnpServer = @import("../jamsnp/server.zig").JamSnpServer;

const trace = @import("../../tracing.zig").scoped(.network);

pub const ConnectionId = shared.ConnectionId;

// -- Nested Connection Struct
pub const Connection = struct {
    id: ConnectionId, // Added UUID
    lsquic_connection: *lsquic.lsquic_conn_t,
    server: *JamSnpServer,
    peer_addr: std.net.Address,

    // Create function is not typically called directly by user for server
    // It's created internally in onNewConn
    pub fn create(alloc: std.mem.Allocator, server: *JamSnpServer, lsquic_conn: *lsquic.lsquic_conn_t, peer_addr: std.net.Address) !*Connection {
        const span = trace.span(.connection_create);
        defer span.deinit();
        const connection = try alloc.create(Connection);
        const new_id = uuid.v4.new();
        span.debug("Creating server connection context with ID: {} for peer: {}", .{ new_id, peer_addr });
        connection.* = .{
            .id = new_id,
            .lsquic_connection = lsquic_conn,
            .server = server,
            .peer_addr = peer_addr,
        };
        return connection;
    }

    // Destroy method for cleanup
    pub fn destroy(self: *Connection, alloc: std.mem.Allocator) void {
        const span = trace.span(.connection_destroy);
        defer span.deinit();
        span.debug("Destroying server connection context for ID: {}", .{self.id});
        // Add any connection-specific resource cleanup here if needed
        alloc.destroy(self);
    }

    // --- LSQUIC Connection Callbacks ---
    pub fn onConnectionCreated(
        ctx: ?*anyopaque, // *JamSnpServer
        maybe_lsquic_connection: ?*lsquic.lsquic_conn_t,
    ) callconv(.C) ?*lsquic.lsquic_conn_ctx_t {
        const span = trace.span(.on_new_conn);
        defer span.deinit();

        const server = @as(*JamSnpServer, @ptrCast(@alignCast(ctx.?)));
        const lsquic_conn_ptr = maybe_lsquic_connection orelse {
            span.err("onNewConn called with null lsquic connection!", .{});
            return null;
        };

        var local_sa_ptr: ?*const lsquic.struct_sockaddr = null;
        var peer_sa_ptr: ?*const lsquic.struct_sockaddr = null;
        _ = lsquic.lsquic_conn_get_sockaddr(lsquic_conn_ptr, &local_sa_ptr, &peer_sa_ptr);
        const peer_sa = peer_sa_ptr orelse {
            span.err("Failed to get peer sockaddr for new connection", .{});
            return null;
        };
        const peer_addr = std.net.Address.initPosix(@ptrCast(@alignCast(peer_sa)));
        span.debug("New connection callback triggered for peer {}", .{peer_addr});

        // Create connection context using the new create method
        const connection = Connection.create(
            server.allocator,
            server,
            lsquic_conn_ptr,
            peer_addr,
        ) catch |err| {
            span.err("Failed to create connection context: {s}", .{@errorName(err)});
            return null; // Signal error to lsquic
        };
        errdefer connection.destroy(server.allocator); // Use destroy method

        // Add to bookkeeping map using UUID
        server.connections.put(connection.id, connection) catch |err| {
            span.err("Failed to add connection {} to map: {s}", .{ connection.id, @errorName(err) });
            return null; // Let errdefer clean up, signal error
        };

        span.debug("Connection context created successfully for ID: {}", .{connection.id});
        // Return our context struct pointer
        return @ptrCast(connection);
    }

    pub fn onConnClosed(maybe_lsquic_connection: ?*lsquic.lsquic_conn_t) callconv(.C) void {
        const span = trace.span(.on_conn_closed);
        defer span.deinit();

        const lsquic_conn_ptr = maybe_lsquic_connection orelse {
            span.warn("onConnClosed called with null connection pointer", .{});
            return;
        };

        // Retrieve our connection context
        const conn_ctx = lsquic.lsquic_conn_get_ctx(lsquic_conn_ptr);
        if (conn_ctx == null) {
            span.warn("onConnClosed called for lsquic conn 0x{*} but context was already null (double close?)", .{lsquic_conn_ptr});
            return;
        }
        const connection: *Connection = @ptrCast(@alignCast(conn_ctx.?));
        const conn_id = connection.id; // Get ID before potential destruction
        const server = connection.server;
        span.debug("Connection closed callback triggered for ID: {}", .{conn_id});

        // Invoke user callback *before* removing/destroying
        server.invokeCallback(.ConnectionClosed, .{
            .ConnectionClosed = .{ .connection = conn_id },
        });

        // Remove from bookkeeping map using UUID
        if (server.connections.fetchRemove(conn_id)) |removed_entry| {
            std.debug.assert(removed_entry.value == connection); // Sanity check
            span.debug("Removed connection ID {} from map.", .{conn_id});
        } else {
            span.warn("Closing connection (ID: {}) was not found in the map, but context existed.", .{conn_id});
        }

        // Clear the context in lsquic
        lsquic.lsquic_conn_set_ctx(lsquic_conn_ptr, null);

        // Destroy our connection context struct using its method
        connection.destroy(server.allocator);

        span.debug("Connection resources cleaned up for formerly ID: {}", .{conn_id});
    }

    pub fn onHandshakeDone(conn: ?*lsquic.lsquic_conn_t, status: lsquic.lsquic_hsk_status) callconv(.C) void {
        const span = trace.span(.on_handshake_done);
        defer span.deinit();
        const lsquic_conn_ptr = conn orelse return;

        const conn_ctx = lsquic.lsquic_conn_get_ctx(lsquic_conn_ptr);
        if (conn_ctx == null) {
            span.warn("onHandshakeDone called for lsquic conn 0x{*} but context is null", .{lsquic_conn_ptr});
            return;
        }
        const connection: *Connection = @ptrCast(@alignCast(conn_ctx.?));
        const conn_id = connection.id;
        const server = connection.server;

        span.debug("Handshake completed for connection ID: {} with status: {}", .{ conn_id, status });

        if (status != lsquic.LSQ_HSK_OK and status != lsquic.LSQ_HSK_RESUMED_OK) {
            span.err("Handshake failed with status: {}, closing connection ID: {}", .{ status, conn_id });
            lsquic.lsquic_conn_close(lsquic_conn_ptr); // onConnClosed will handle cleanup
            return;
        }

        // Handshake successful, invoke callback
        span.debug("Handshake successful for connection ID: {}", .{conn_id});
        _ = server;

        // FIXME: handle this

        // server.invokeCallback(.ClientConnected, .{
        //     .ClientConnected = .{
        //         .connection = conn_id,
        //         .peer_addr = connection.peer_addr,
        //     },
        // });
    }
};
