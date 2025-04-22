const std = @import("std");
const uuid = @import("uuid");
const lsquic = @import("lsquic");
const network = @import("network");

const shared = @import("../jamsnp/shared_types.zig");
pub const ConnectionId = shared.ConnectionId;

const trace = @import("../../tracing.zig").scoped(.network);

// -- Nested Connection Struct
pub fn Connection(T: type) type {
    return struct {
        id: ConnectionId, // Added UUID
        lsquic_connection: ?*lsquic.lsquic_conn_t,
        owner: *T, // Either JamSnpClient or JamSnpServer
        endpoint: network.EndPoint,

        // Create function is not typically called directly by user for server
        // It's created internally in onNewConn
        pub fn create(alloc: std.mem.Allocator, server: *T, lsquic_conn: ?*lsquic.lsquic_conn_t, peer_endpoint: network.EndPoint) !*Connection(T) {
            const span = trace.span(.connection_create);
            defer span.deinit();
            const connection = try alloc.create(Connection(T));
            const new_id = uuid.v4.new();
            // TODO: prefix all debug messaeges with the ID
            span.debug("Creating {s} connection context with ID: {} for peer: {}", .{ @typeName(T), new_id, peer_endpoint });
            connection.* = .{
                .id = new_id,
                .lsquic_connection = lsquic_conn,
                .owner = server,
                .endpoint = peer_endpoint,
            };
            return connection;
        }

        // Destroy method for cleanup
        pub fn destroy(self: *Connection(T), alloc: std.mem.Allocator) void {
            const span = trace.span(.connection_destroy);
            defer span.deinit();
            span.debug("Destroying server connection context for ID: {}", .{self.id});
            // Add any connection-specific resource cleanup here if needed
            alloc.destroy(self);
        }

        pub fn createStream(self: *Connection(T)) !void {
            const span = trace.span(.create_stream);
            defer span.deinit();
            span.debug("Requesting new stream on connection ID: {}", .{self.id});

            lsquic.lsquic_conn_make_stream(self.lsquic_connection);

            span.debug("Stream creation request successful for connection ID: {}", .{self.id});
            // Stream object itself is created in the onStreamCreated callback
        }

        // --- LSQUIC Connection Callbacks ---
        pub fn onClientConnectionCreated(
            _: ?*anyopaque, // ea_stream_if_ctx (unused here)
            maybe_lsquic_connection: ?*lsquic.lsquic_conn_t,
        ) callconv(.C) ?*lsquic.lsquic_conn_ctx_t {
            const span = trace.span(.on_connection_created);
            defer span.deinit();

            // Retrieve the connection context we passed to lsquic_engine_connect
            const conn_ctx = lsquic.lsquic_conn_get_ctx(maybe_lsquic_connection).?;
            const connection: *Connection(T) = @alignCast(@ptrCast(conn_ctx));
            span.debug("LSQUIC connection created for endpoint: {}, Assigning ID: {}", .{ connection.endpoint, connection.id });

            // Store the lsquic connection pointer
            connection.lsquic_connection = maybe_lsquic_connection orelse {
                // This shouldn't happen if lsquic calls this, but good practice
                span.err("onConnectionCreated called with null lsquic connection pointer!", .{});
                // TODO: Returning null might signal an error to lsquic? Check docs.
                // Let's assume it's non-null for now.
                return null;
            };

            connection.owner.invokeCallback(.ConnectionEstablished, .{
                .ConnectionEstablished = .{
                    .connection = connection.id,
                    .endpoint = connection.endpoint,
                },
            });

            // Return our connection struct pointer as the context for lsquic
            return @ptrCast(connection);
        }

        pub fn onServerConnectionCreated(
            ctx: ?*anyopaque, // *T
            maybe_lsquic_connection: ?*lsquic.lsquic_conn_t,
        ) callconv(.C) ?*lsquic.lsquic_conn_ctx_t {
            const span = trace.span(.on_new_conn);
            defer span.deinit();

            std.debug.print("onConnectionCreated called with ctx: {?*}\n", .{ctx});

            const owner = @as(*T, @ptrCast(@alignCast(ctx.?)));
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

            const peer_addr = network.EndPoint.fromSocketAddress(@ptrCast(@alignCast(peer_sa)), @sizeOf(@TypeOf(peer_sa))) catch {
                span.err("Failed to convert sockaddr to EndPoint for new connection", .{});
                return null;
            };

            span.debug("New connection callback triggered for peer {}", .{peer_addr});

            // Create connection context using the new create method
            const connection = Connection(T).create(
                owner.allocator,
                owner,
                lsquic_conn_ptr,
                peer_addr,
            ) catch |err| {
                span.err("Failed to create connection context: {s}", .{@errorName(err)});
                return null; // Signal error to lsquic
            };
            errdefer connection.destroy(owner.allocator); // Use destroy method

            // Add to bookkeeping map using UUID
            owner.connections.put(connection.id, connection) catch |err| {
                span.err("Failed to add connection {} to map: {s}", .{ connection.id, @errorName(err) });
                return null; // Let errdefer clean up, signal error
            };

            span.debug("Connection context created successfully for ID: {}", .{connection.id});
            // Return our context struct pointer
            return @ptrCast(connection);
        }

        pub fn onConnectionClosed(maybe_lsquic_connection: ?*lsquic.lsquic_conn_t) callconv(.C) void {
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
            const connection: *Connection(T) = @ptrCast(@alignCast(conn_ctx.?));
            const conn_id = connection.id; // Get ID before potential destruction
            const owner = connection.owner;
            span.debug("Connection closed callback triggered for ID: {}", .{conn_id});

            // Invoke user callback *before* removing/destroying
            owner.invokeCallback(.ConnectionClosed, .{
                .ConnectionClosed = .{ .connection = conn_id },
            });

            // Remove from bookkeeping map using UUID
            if (owner.connections.fetchRemove(conn_id)) |removed_entry| {
                std.debug.assert(removed_entry.value == connection); // Sanity check
                span.debug("Removed connection ID {} from map.", .{conn_id});
            } else {
                span.warn("Closing connection (ID: {}) was not found in the map, but context existed.", .{conn_id});
            }

            // Clear the context in lsquic
            lsquic.lsquic_conn_set_ctx(lsquic_conn_ptr, null);

            // Destroy our connection context struct using its method
            connection.destroy(owner.allocator);

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
}
