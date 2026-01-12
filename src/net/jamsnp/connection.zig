
const std = @import("std");
const uuid = @import("uuid");
const lsquic = @import("lsquic");
const network = @import("network");

const shared = @import("../jamsnp/shared_types.zig");
pub const ConnectionId = shared.ConnectionId;

const trace = @import("tracing").scoped(.network);

pub fn Connection(T: type) type {
    return struct {
        id: ConnectionId, // Added UUID
        lsquic_connection: ?*lsquic.lsquic_conn_t,
        owner: *T, // Either JamSnpClient or JamSnpServer
        endpoint: network.EndPoint,

        pub fn create(alloc: std.mem.Allocator, server: *T, lsquic_conn: ?*lsquic.lsquic_conn_t, peer_endpoint: network.EndPoint, connection_id: ConnectionId) !*Connection(T) {
            const span = trace.span(@src(), .connection_create);
            defer span.deinit();
            const connection = try alloc.create(Connection(T));
            // TODO: prefix all debug messaeges with the ID
            span.debug("Creating {s} connection context with ID: {} for peer: {}", .{ @typeName(T), connection_id, peer_endpoint });
            connection.* = .{
                .id = connection_id,
                .lsquic_connection = lsquic_conn,
                .owner = server,
                .endpoint = peer_endpoint,
            };
            return connection;
        }

        pub fn destroy(self: *Connection(T), alloc: std.mem.Allocator) void {
            const span = trace.span(@src(), .connection_destroy);
            defer span.deinit();
            span.debug("Destroying connection context for ID: {}", .{self.id});
            alloc.destroy(self);
        }

        pub fn createStream(self: *Connection(T)) void {
            const span = trace.span(@src(), .create_stream);
            defer span.deinit();
            span.debug("Requesting new stream on connection ID: {}", .{self.id});

            lsquic.lsquic_conn_make_stream(self.lsquic_connection);

            span.debug("Stream creation request successful for connection ID: {}", .{self.id});
        }

        pub fn onClientConnectionCreated(
            _: ?*anyopaque, // ea_stream_if_ctx (unused here)
            maybe_lsquic_connection: ?*lsquic.lsquic_conn_t,
        ) callconv(.C) ?*lsquic.lsquic_conn_ctx_t {
            const span = trace.span(@src(), .on_connection_created);
            defer span.deinit();
            const lsquic_connection = maybe_lsquic_connection orelse {
                std.debug.panic("onConnectionCreated called with null lsquic connection pointer!", .{});
            };

            const conn_ctx = lsquic.lsquic_conn_get_ctx(lsquic_connection).?;
            const connection: *Connection(T) = @alignCast(@ptrCast(conn_ctx));

            span.debug("onClientConnectionCreated: {}, Assigning ID: {}", .{ connection.endpoint, connection.id });

            connection.lsquic_connection = lsquic_connection;

            shared.invokeCallback(T, &connection.owner.callback_handlers, .{
                .connection_established = connection,
            });

            return @ptrCast(connection);
        }

        pub fn onServerConnectionCreated(
            ctx: ?*anyopaque, // *T
            maybe_lsquic_connection: ?*lsquic.lsquic_conn_t,
        ) callconv(.C) ?*lsquic.lsquic_conn_ctx_t {
            const span = trace.span(@src(), .on_server_connection_created);
            defer span.deinit();

            const owner = @as(*T, @ptrCast(@alignCast(ctx.?)));
            const lsquic_conn_ptr = maybe_lsquic_connection orelse {
                span.err("onServerConnectionCreated called with null lsquic connection!", .{});
                return null;
            };

            var local_sa_ptr: ?*const lsquic.struct_sockaddr = null;
            var peer_sa_ptr: ?*const lsquic.struct_sockaddr = null;
            _ = lsquic.lsquic_conn_get_sockaddr(lsquic_conn_ptr, &local_sa_ptr, &peer_sa_ptr);
            const peer_sa = peer_sa_ptr orelse {
                span.err("Failed to get peer sockaddr for new connection", .{});
                return null;
            };

            const peer_address = std.net.Address.initPosix(@ptrCast(@alignCast(peer_sa)));

            const peer_addr = network.EndPoint.fromSocketAddress(&peer_address.any, peer_address.getOsSockLen()) catch {
                span.err("Failed to convert sockaddr to EndPoint for new connection", .{});
                return null;
            };

            span.debug("New connection callback triggered for peer {}", .{peer_addr});

            const connection_id = uuid.v4.new();

            const connection = Connection(T).create(
                owner.allocator,
                owner,
                lsquic_conn_ptr,
                peer_addr,
                connection_id,
            ) catch |err| {
                span.err("Failed to create connection context: {s}", .{@errorName(err)});
                return null; // Signal error to lsquic
            };
            errdefer connection.destroy(owner.allocator); // Use destroy method

            owner.connections.put(connection.id, connection) catch |err| {
                span.err("Failed to add connection {} to map: {s}", .{ connection.id, @errorName(err) });
                return null; // Let errdefer clean up, signal error
            };

            shared.invokeCallback(T, &owner.callback_handlers, .{
                .connection_established = connection,
            });

            span.debug("Connection context created successfully for ID: {}", .{connection.id});
            return @ptrCast(connection);
        }

        pub fn onConnectionClosed(maybe_lsquic_connection: ?*lsquic.lsquic_conn_t) callconv(.C) void {
            const span = trace.span(@src(), .on_conn_closed);
            defer span.deinit();

            const lsquic_conn_ptr = maybe_lsquic_connection orelse {
                span.warn("onConnClosed called with null connection pointer", .{});
                return;
            };

            const conn_ctx = lsquic.lsquic_conn_get_ctx(lsquic_conn_ptr);
            if (conn_ctx == null) {
                span.warn("onConnClosed called for lsquic conn 0x{*} but context was already null (double close?)", .{lsquic_conn_ptr});
                return;
            }
            const connection: *Connection(T) = @ptrCast(@alignCast(conn_ctx.?));
            const conn_id = connection.id; // Get ID before potential destruction
            const owner = connection.owner;
            span.debug("Connection closed callback triggered for ID: {}", .{conn_id});

            shared.invokeCallback(T, &owner.callback_handlers, .{
                .connection_closed = conn_id,
            });

            if (owner.connections.fetchRemove(conn_id)) |removed_entry| {
                std.debug.assert(removed_entry.value == connection); // Sanity check
                span.debug("Removed connection ID {} from map.", .{conn_id});
            } else {
                span.warn("Closing connection (ID: {}) was not found in the map, but context existed.", .{conn_id});
            }

            lsquic.lsquic_conn_set_ctx(lsquic_conn_ptr, null);

            connection.destroy(owner.allocator);

            span.debug("Connection resources cleaned up for formerly ID: {}", .{conn_id});
        }

        pub fn onHandshakeDone(conn: ?*lsquic.lsquic_conn_t, status: lsquic.lsquic_hsk_status) callconv(.C) void {
            const span = trace.span(@src(), .on_handshake_done);
            defer span.deinit();
            const lsquic_conn_ptr = conn orelse return;

            const conn_ctx = lsquic.lsquic_conn_get_ctx(lsquic_conn_ptr);
            if (conn_ctx == null) {
                span.warn("onHandshakeDone called for lsquic conn 0x{*} but context is null", .{lsquic_conn_ptr});
                return;
            }
            const connection: *Connection(T) = @ptrCast(@alignCast(conn_ctx.?));
            const conn_id = connection.id;
            const server = connection.owner;

            span.debug("Handshake completed for connection ID: {} with status: {}", .{ conn_id, status });

            if (status != lsquic.LSQ_HSK_OK and status != lsquic.LSQ_HSK_RESUMED_OK) {
                span.err("Handshake failed with status: {}, closing connection ID: {}", .{ status, conn_id });
                lsquic.lsquic_conn_close(lsquic_conn_ptr); // onConnClosed will handle cleanup
                return;
            }

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
}
