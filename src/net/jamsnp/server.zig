const std = @import("std");
const uuid = @import("uuid"); // Added for UUIDs
const lsquic = @import("lsquic");
const ssl = @import("ssl");
const common = @import("common.zig");
const certificate_verifier = @import("certificate_verifier.zig");
const network = @import("network");
const xev = @import("xev");

const toSocketAddress = @import("../ext.zig").toSocketAddress;
const trace = @import("../../tracing.zig").scoped(.network);

// -- UUID Definitions
pub const ConnectionId = uuid.Uuid;
pub const StreamId = uuid.Uuid;

// -- Callback Definitions (Server-Side)
pub const EventType = enum {
    ClientConnected,
    ClientDisconnected,
    StreamCreatedByClient,
    StreamClosedByClient,
    DataReceived,
    DataWriteCompleted,
    DataReadError,
    DataWriteError,
    DataReadWouldBlock,
    DataWriteWouldBlock,
};

pub const ClientConnectedCallbackFn = *const fn (connection_id: ConnectionId, peer_addr: std.net.Address, context: ?*anyopaque) void;
pub const ClientDisconnectedCallbackFn = *const fn (connection_id: ConnectionId, context: ?*anyopaque) void;
pub const StreamCreatedCallbackFn = *const fn (connection_id: ConnectionId, stream_id: StreamId, context: ?*anyopaque) void;
pub const StreamClosedCallbackFn = *const fn (connection_id: ConnectionId, stream_id: StreamId, context: ?*anyopaque) void;
pub const DataReceivedCallbackFn = *const fn (connection_id: ConnectionId, stream_id: StreamId, data: []const u8, context: ?*anyopaque) void;
pub const DataWriteCompletedCallbackFn = *const fn (connection_id: ConnectionId, stream_id: StreamId, total_bytes_written: usize, context: ?*anyopaque) void;
pub const DataErrorCallbackFn = *const fn (connection_id: ConnectionId, stream_id: StreamId, error_code: i32, context: ?*anyopaque) void;
pub const DataWouldBlockCallbackFn = *const fn (connection_id: ConnectionId, stream_id: StreamId, context: ?*anyopaque) void;

const EventArgs = union(EventType) {
    ClientConnected: struct { connection_id: ConnectionId, peer_addr: std.net.Address },
    ClientDisconnected: struct { connection_id: ConnectionId },
    StreamCreatedByClient: struct { connection_id: ConnectionId, stream_id: StreamId },
    StreamClosedByClient: struct { connection_id: ConnectionId, stream_id: StreamId },
    DataReceived: struct { connection_id: ConnectionId, stream_id: StreamId, data: []const u8 },
    DataWriteCompleted: struct { connection_id: ConnectionId, stream_id: StreamId, total_bytes_written: usize },
    DataReadError: struct { connection_id: ConnectionId, stream_id: StreamId, error_code: i32 },
    DataWriteError: struct { connection_id: ConnectionId, stream_id: StreamId, error_code: i32 },
    DataReadWouldBlock: struct { connection_id: ConnectionId, stream_id: StreamId },
    DataWriteWouldBlock: struct { connection_id: ConnectionId, stream_id: StreamId },
};

// Shared Handler structure
pub const CallbackHandler = struct {
    callback: ?*const anyopaque,
    context: ?*anyopaque,
};

// --- JamSnpServer Struct ---

pub const JamSnpServer = struct {
    allocator: std.mem.Allocator,
    keypair: std.crypto.sign.Ed25519.KeyPair,
    socket: network.Socket,
    alpn_id: []const u8,

    // xev state
    loop: xev.Loop = undefined,
    packets_in: xev.UDP,
    packets_in_c: xev.Completion = undefined,
    packets_in_s: xev.UDP.State = undefined,
    packets_in_buffer: []u8 = undefined,
    tick: xev.Timer,
    tick_c: xev.Completion = undefined,

    // lsquic configuration
    lsquic_engine: *lsquic.lsquic_engine_t,
    lsquic_engine_api: lsquic.lsquic_engine_api,
    lsquic_engine_settings: lsquic.lsquic_engine_settings,
    lsquic_stream_interface: lsquic.lsquic_stream_if = .{
        // Mandatory callbacks
        .on_new_conn = Connection.onConnectionCreated,
        .on_conn_closed = Connection.onConnClosed,
        .on_new_stream = Stream.onNewStream,
        .on_read = Stream.onRead,
        .on_write = Stream.onWrite,
        .on_close = Stream.onClose,
        // Optional callbacks
        .on_hsk_done = Connection.onHandshakeDone,
        .on_goaway_received = null,
        .on_new_token = null,
        .on_sess_resume_info = null,
    },

    ssl_ctx: *ssl.SSL_CTX,
    chain_genesis_hash: []const u8,
    allow_builders: bool,

    // Bookkeeping using UUIDs
    connections: std.AutoHashMap(ConnectionId, *Connection),
    streams: std.AutoHashMap(StreamId, *Stream),

    // Callback handlers map (Server-side)
    callback_handlers: [@typeInfo(EventType).@"enum".fields.len]CallbackHandler = [_]CallbackHandler{.{ .callback = null, .context = null }} ** @typeInfo(EventType).@"enum".fields.len,

    pub fn init(
        allocator: std.mem.Allocator,
        keypair: std.crypto.sign.Ed25519.KeyPair,
        genesis_hash: []const u8,
        allow_builders: bool,
    ) !*JamSnpServer {
        const span = trace.span(.init_server);
        defer span.deinit();
        span.debug("Initializing JamSnpServer", .{});

        // Initialize lsquic globally (idempotent check might be needed if used elsewhere)
        if (lsquic.lsquic_global_init(lsquic.LSQUIC_GLOBAL_SERVER) != 0) {
            span.err("Failed to initialize lsquic globally", .{});
            return error.LsquicInitFailed;
        }
        span.debug("lsquic global init successful", .{});

        var socket = try network.Socket.create(.ipv6, .udp);
        errdefer socket.close();

        const alpn_id = try common.buildAlpnIdentifier(allocator, genesis_hash, false);
        errdefer allocator.free(alpn_id);

        const ssl_ctx = try common.configureSSLContext(
            allocator,
            keypair,
            genesis_hash,
            false, // is_client
            false, // is_builder (server doesn't advertise builder role)
            alpn_id,
        );
        errdefer ssl.SSL_CTX_free(ssl_ctx);

        span.debug("Setting up certificate verification", .{});
        ssl.SSL_CTX_set_cert_verify_callback(ssl_ctx, certificate_verifier.verifyCertificate, null);

        span.debug("Allocating server object", .{});
        const server = try allocator.create(JamSnpServer);
        errdefer allocator.destroy(server);

        var engine_settings: lsquic.lsquic_engine_settings = undefined;
        lsquic.lsquic_engine_init_settings(&engine_settings, lsquic.LSENG_SERVER);
        engine_settings.es_versions = 1 << lsquic.LSQVER_ID29; // IETF QUIC v1

        var error_buffer: [128]u8 = undefined;
        if (lsquic.lsquic_engine_check_settings(&engine_settings, 0, @ptrCast(&error_buffer), @sizeOf(@TypeOf(error_buffer))) != 0) {
            span.err("Server engine settings problem: {s}", .{error_buffer});
            return error.LsquicEngineSettingsInvalid;
            // std.debug.panic("Server engine settings problem: {s}", .{error_buffer});
        }

        span.debug("Setting up server structure", .{});
        server.* = JamSnpServer{
            .allocator = allocator,
            .keypair = keypair,
            .socket = socket,
            .lsquic_engine = undefined, // Initialized later
            .lsquic_engine_api = undefined, // Initialized later
            .lsquic_engine_settings = engine_settings,
            .ssl_ctx = ssl_ctx,
            .chain_genesis_hash = try allocator.dupe(u8, genesis_hash),
            .allow_builders = allow_builders,
            .alpn_id = alpn_id,
            .packets_in = xev.UDP.initFd(socket.internal),
            .tick = try xev.Timer.init(),
            // Initialize bookkeeping maps with UUIDs
            .connections = std.AutoHashMap(ConnectionId, *Connection).init(allocator),
            .streams = std.AutoHashMap(StreamId, *Stream).init(allocator),
            // Initialize callback handlers
            .callback_handlers = [_]CallbackHandler{.{ .callback = null, .context = null }} ** @typeInfo(EventType).@"enum".fields.len,
        };
        errdefer server.connections.deinit();
        errdefer server.streams.deinit();
        errdefer allocator.free(server.chain_genesis_hash);

        span.debug("Setting up engine API", .{});
        server.lsquic_engine_api = .{
            .ea_settings = &server.lsquic_engine_settings,
            .ea_stream_if = &server.lsquic_stream_interface,
            .ea_stream_if_ctx = server, // Pass server instance as stream interface context
            .ea_packets_out = &sendPacketsOut,
            .ea_packets_out_ctx = server, // Pass server instance for packet sending
            .ea_get_ssl_ctx = &getSslContext,
            .ea_lookup_cert = &lookupCertificate,
            .ea_cert_lu_ctx = server, // Pass server instance for certificate lookup
            .ea_alpn = null, // Server uses ALPN select callback
        };

        span.debug("Creating lsquic engine", .{});
        server.lsquic_engine = lsquic.lsquic_engine_new(
            lsquic.LSENG_SERVER,
            &server.lsquic_engine_api,
        ) orelse {
            span.err("Failed to create lsquic engine", .{});
            return error.LsquicEngineCreationFailed;
        };

        // Build the xev loop
        try server.buildLoop();

        span.debug("Successfully initialized JamSnpServer", .{});
        return server;
    }

    pub fn deinit(self: *JamSnpServer) void {
        const span = trace.span(.deinit);
        defer span.deinit();
        span.debug("Deinitializing JamSnpServer", .{});

        span.trace("Destroying lsquic engine", .{});
        lsquic.lsquic_engine_destroy(self.lsquic_engine);

        span.trace("Freeing SSL context", .{});
        ssl.SSL_CTX_free(self.ssl_ctx);

        span.trace("Closing socket", .{});
        self.socket.close();

        span.trace("Deinitializing timer", .{});
        self.tick.deinit();

        span.trace("Deinitializing event loop", .{});
        self.loop.deinit();

        span.trace("Freeing buffers", .{});
        self.allocator.free(self.packets_in_buffer);
        self.allocator.free(self.chain_genesis_hash);
        self.allocator.free(self.alpn_id);

        // Cleanup remaining streams (Safety net)
        if (self.streams.count() > 0) {
            span.warn("Streams map not empty during deinit. Count: {d}", .{self.streams.count()});
            var stream_it = self.streams.iterator();
            while (stream_it.next()) |entry| {
                const stream = entry.value_ptr.*;
                span.warn(" Force cleaning stream: {}", .{stream.id});
                stream.destroy(self.allocator); // Use stream's destroy method
            }
        }
        span.trace("Deinitializing streams map", .{});
        self.streams.deinit();

        // Cleanup remaining connections (Safety net)
        if (self.connections.count() > 0) {
            span.warn("Connections map not empty during deinit. Count: {d}", .{self.connections.count()});
            var conn_it = self.connections.iterator();
            while (conn_it.next()) |entry| {
                const conn = entry.value_ptr.*;
                span.warn(" Force cleaning connection: {}", .{conn.id});
                conn.destroy(self.allocator); // Use connection's destroy method
            }
        }
        span.trace("Deinitializing connections map", .{});
        self.connections.deinit();

        // Clear callback handlers
        for (&self.callback_handlers) |*handler| {
            handler.* = .{ .callback = null, .context = null };
        }

        span.trace("Destroying JamSnpServer object", .{});
        self.allocator.destroy(self);

        span.trace("JamSnpServer deinitialization complete", .{});
    }

    pub fn listen(self: *JamSnpServer, addr: []const u8, port: u16) !void {
        const span = trace.span(.listen);
        defer span.deinit();
        span.debug("Starting listen on {s}:{d}", .{ addr, port });
        const address = try network.Address.parse(addr);
        const endpoint = network.EndPoint{
            .address = address,
            .port = port,
        };
        try self.socket.bind(endpoint);
        span.debug("Socket bound successfully to {}", .{endpoint});
    }

    pub fn buildLoop(self: *@This()) !void {
        const span = trace.span(.build_loop);
        defer span.deinit();
        span.debug("Initializing event loop", .{});
        self.loop = try xev.Loop.init(.{});
        errdefer self.loop.deinit();

        self.packets_in_buffer = try self.allocator.alloc(u8, 1500);
        errdefer self.allocator.free(self.packets_in_buffer);

        self.tick.run(
            &self.loop,
            &self.tick_c,
            500, // Initial timeout, will be adjusted
            @This(),
            self,
            onTick,
        );

        self.packets_in.read(
            &self.loop,
            &self.packets_in_c,
            &self.packets_in_s,
            .{ .slice = self.packets_in_buffer },
            @This(),
            self,
            onPacketsIn,
        );
        span.debug("Event loop built successfully", .{});
    }

    pub fn runTick(self: *@This()) !void {
        const span = trace.span(.run_server_tick);
        defer span.deinit();
        span.trace("Running a single tick on JamSnpServer", .{});
        try self.loop.run(.no_wait);
    }

    pub fn runUntilDone(self: *@This()) !void {
        const span = trace.span(.run);
        defer span.deinit();
        span.debug("Starting JamSnpServer event loop", .{});
        try self.loop.run(.until_done);
        span.debug("Event loop completed", .{});
    }

    // -- Callback Registration

    pub fn setCallback(self: *@This(), event_type: EventType, callback_fn_ptr: ?*const anyopaque, context: ?*anyopaque) void {
        const span = trace.span(.set_callback);
        defer span.deinit();
        span.debug("Setting server callback for event {s}", .{@tagName(event_type)});
        self.callback_handlers[@intFromEnum(event_type)] = .{
            .callback = callback_fn_ptr,
            .context = context,
        };
    }

    // -- Callback Invocation

    fn invokeCallback(self: *@This(), event_tag: EventType, args: EventArgs) void {
        const span = trace.span(.invoke_server_callback);
        defer span.deinit();
        std.debug.assert(event_tag == @as(EventType, @enumFromInt(@intFromEnum(args))));

        const handler = &self.callback_handlers[@intFromEnum(event_tag)];
        if (handler.callback) |callback_ptr| {
            span.debug("Invoking server callback for event {s}", .{@tagName(event_tag)});
            switch (args) {
                .ClientConnected => |ev_args| {
                    const callback: ClientConnectedCallbackFn = @ptrCast(@alignCast(callback_ptr));
                    callback(ev_args.connection_id, ev_args.peer_addr, handler.context);
                },
                .ClientDisconnected => |ev_args| {
                    const callback: ClientDisconnectedCallbackFn = @ptrCast(@alignCast(callback_ptr));
                    callback(ev_args.connection_id, handler.context);
                },
                .StreamCreatedByClient => |ev_args| {
                    const callback: StreamCreatedCallbackFn = @ptrCast(@alignCast(callback_ptr));
                    callback(ev_args.connection_id, ev_args.stream_id, handler.context);
                },
                .StreamClosedByClient => |ev_args| {
                    const callback: StreamClosedCallbackFn = @ptrCast(@alignCast(callback_ptr));
                    callback(ev_args.connection_id, ev_args.stream_id, handler.context);
                },
                .DataReceived => |ev_args| {
                    const callback: DataReceivedCallbackFn = @ptrCast(@alignCast(callback_ptr));
                    callback(ev_args.connection_id, ev_args.stream_id, ev_args.data, handler.context);
                },
                .DataWriteCompleted => |ev_args| {
                    const callback: DataWriteCompletedCallbackFn = @ptrCast(@alignCast(callback_ptr));
                    callback(ev_args.connection_id, ev_args.stream_id, ev_args.total_bytes_written, handler.context);
                },
                .DataReadError => |ev_args| {
                    const callback: DataErrorCallbackFn = @ptrCast(@alignCast(callback_ptr));
                    callback(ev_args.connection_id, ev_args.stream_id, ev_args.error_code, handler.context);
                },
                .DataWriteError => |ev_args| {
                    const callback: DataErrorCallbackFn = @ptrCast(@alignCast(callback_ptr));
                    callback(ev_args.connection_id, ev_args.stream_id, ev_args.error_code, handler.context);
                },
                .DataReadWouldBlock => |ev_args| {
                    const callback: DataWouldBlockCallbackFn = @ptrCast(@alignCast(callback_ptr));
                    callback(ev_args.connection_id, ev_args.stream_id, handler.context);
                },
                .DataWriteWouldBlock => |ev_args| {
                    const callback: DataWouldBlockCallbackFn = @ptrCast(@alignCast(callback_ptr));
                    callback(ev_args.connection_id, ev_args.stream_id, handler.context);
                },
            }
        } else {
            span.trace("No server callback registered for event type {s}", .{@tagName(event_tag)});
        }
    }

    // --- xev Callbacks ---

    fn onTick(
        maybe_self: ?*@This(),
        xev_loop: *xev.Loop,
        xev_completion: *xev.Completion,
        xev_timer_result: xev.Timer.RunError!void,
    ) xev.CallbackAction {
        const span = trace.span(.on_server_tick);
        defer span.deinit();

        errdefer |err| {
            span.err("onTick failed with timer error: {s}", .{@errorName(err)});
            std.debug.panic("onTick failed with: {s}", .{@errorName(err)});
        }
        try xev_timer_result;

        const self = maybe_self orelse {
            std.debug.panic("onTick called with null self context!", .{});
            return .disarm; // Cannot proceed
        };

        lsquic.lsquic_engine_process_conns(self.lsquic_engine);

        var delta: c_int = undefined;
        var timeout_in_ms: u64 = 100; // Default timeout
        span.trace("Checking for earliest connection activity", .{});
        if (lsquic.lsquic_engine_earliest_adv_tick(self.lsquic_engine, &delta) != 0) {
            if (delta <= 0) {
                timeout_in_ms = 0;
                span.trace("Next tick scheduled immediately (delta={d})", .{delta});
            } else {
                timeout_in_ms = @intCast(@divTrunc(delta, 1000));
                span.trace("Next tick scheduled in {d}ms (delta={d}us)", .{ timeout_in_ms, delta });
            }
        } else {
            span.trace("No specific next tick advised by lsquic, using default {d}ms", .{timeout_in_ms});
        }

        if (timeout_in_ms == 0 and delta > 0) timeout_in_ms = 1; // Clamp minimum

        span.trace("Scheduling next tick with timeout: {d}ms", .{timeout_in_ms}); // Noisy
        self.tick.run(
            xev_loop,
            xev_completion,
            timeout_in_ms,
            @This(),
            self,
            onTick,
        );

        return .disarm; // Timer was re-armed
    }

    fn onPacketsIn(
        maybe_self: ?*@This(),
        xev_loop: *xev.Loop,
        xev_completion: *xev.Completion,
        xev_state: *xev.UDP.State,
        peer_address: std.net.Address,
        _: xev.UDP,
        xev_read_buffer: xev.ReadBuffer,
        xev_read_result: xev.ReadError!usize,
    ) xev.CallbackAction {
        const span = trace.span(.on_packets_in);
        defer span.deinit();

        errdefer |err| {
            span.err("onPacketsIn failed with error: {s}", .{@errorName(err)});
            std.debug.panic("onPacketsIn failed with: {s}", .{@errorName(err)});
        }

        const bytes = try xev_read_result;
        span.trace("Received {d} bytes from {}", .{ bytes, peer_address });
        span.trace("Packet data: {any}", .{std.fmt.fmtSliceHexLower(xev_read_buffer.slice[0..bytes])});

        // Now change some bytes, to test valid comms TODO: remove
        // xev_read_buffer.slice[6] = 0x66;

        const self = maybe_self.?;

        span.trace("Getting local address", .{});
        const local_address = self.socket.getLocalEndPoint() catch |err| {
            span.err("Failed to get local address: {s}", .{@errorName(err)});
            @panic("Failed to get local address");
        };

        span.trace("Local address: {}", .{local_address});

        span.trace("Passing packet to lsquic engine", .{});
        if (0 > lsquic.lsquic_engine_packet_in(
            self.lsquic_engine,
            xev_read_buffer.slice.ptr,
            bytes,
            @ptrCast(&toSocketAddress(local_address)),
            @ptrCast(&peer_address.any),

            self, // peer_ctx
            0, // ecn
        )) {
            span.err("lsquic_engine_packet_in failed", .{});
            // TODO: is this really unrecoverable?
            @panic("lsquic_engine_packet_in failed");
        }

        span.trace("Processing engine connections", .{});
        lsquic.lsquic_engine_process_conns(self.lsquic_engine);

        span.trace("Successfully processed incoming packet", .{});

        // Rearm to listen for more packets
        self.packets_in.read(
            xev_loop,
            xev_completion,
            xev_state,
            .{ .slice = xev_read_buffer.slice },
            @This(),
            self,
            onPacketsIn,
        );

        return .disarm;
    }

    // --- Nested Connection Struct ---
    pub const Connection = struct {
        id: ConnectionId, // Added UUID
        lsquic_connection: *lsquic.lsquic_conn_t,
        server: *JamSnpServer,
        peer_addr: std.net.Address,

        // Create function is not typically called directly by user for server
        // It's created internally in onNewConn
        fn create(alloc: std.mem.Allocator, server: *JamSnpServer, lsquic_conn: *lsquic.lsquic_conn_t, peer_addr: std.net.Address) !*Connection {
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
        fn destroy(self: *Connection, alloc: std.mem.Allocator) void {
            const span = trace.span(.connection_destroy);
            defer span.deinit();
            span.debug("Destroying server connection context for ID: {}", .{self.id});
            // Add any connection-specific resource cleanup here if needed
            alloc.destroy(self);
        }

        // --- LSQUIC Connection Callbacks ---
        fn onConnectionCreated(
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

        fn onConnClosed(maybe_lsquic_connection: ?*lsquic.lsquic_conn_t) callconv(.C) void {
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
            server.invokeCallback(.ClientDisconnected, .{
                .ClientDisconnected = .{ .connection_id = conn_id },
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

        fn onHandshakeDone(conn: ?*lsquic.lsquic_conn_t, status: lsquic.lsquic_hsk_status) callconv(.C) void {
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
            server.invokeCallback(.ClientConnected, .{
                .ClientConnected = .{
                    .connection_id = conn_id,
                    .peer_addr = connection.peer_addr,
                },
            });
        }
    };

    // --- Nested Stream Struct ---
    pub const Stream = struct {
        id: StreamId, // Added UUID
        lsquic_stream: *lsquic.lsquic_stream_t,
        connection: *Connection,
        read_buffer: []u8, // Buffer for incoming data (allocated in onNewStream)

        // State for echoing "pong" back
        data_to_write: ?[]const u8 = null,
        write_pos: usize = 0,

        // Create function is not typically called directly by user for server
        // It's created internally in onNewStream
        fn create(alloc: std.mem.Allocator, connection: *Connection, lsquic_stream: *lsquic.lsquic_stream_t) !*Stream {
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

        // Destroy method for cleanup
        fn destroy(self: *Stream, alloc: std.mem.Allocator) void {
            const span = trace.span(.stream_destroy);
            defer span.deinit();
            span.debug("Destroying server stream context for ID: {}", .{self.id});
            // Free associated resources
            alloc.free(self.read_buffer);
            // Note: data_to_write points to literal, no free needed.
            alloc.destroy(self);
        }

        // --- LSQUIC Stream Callbacks ---
        fn onNewStream(
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
            const connection: *Connection = @ptrCast(@alignCast(conn_ctx.?));
            const server = connection.server;
            span.debug("New stream callback triggered on connection ID: {}", .{connection.id});

            // Create stream context using new method
            const stream = Stream.create(server.allocator, connection, lsquic_stream_ptr) catch |err| {
                span.err("Failed to create stream context: {s}", .{@errorName(err)});
                return null; // Signal error to lsquic
            };
            errdefer stream.destroy(server.allocator); // Use destroy method

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

            span.debug("Requesting read for new stream ID: {}", .{stream.id});
            _ = lsquic.lsquic_stream_wantread(lsquic_stream_ptr, 1);

            span.debug("Stream context created successfully for ID: {}", .{stream.id});
            return @ptrCast(stream);
        }

        fn onRead(
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

        fn onWrite(
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

        fn onClose(
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
    }; // End Stream Struct

    // --- lsquic Engine API Callbacks ---

    fn getSslContext(ctx: ?*anyopaque, _: ?*const lsquic.struct_sockaddr) callconv(.C) ?*lsquic.struct_ssl_ctx_st {
        const span = trace.span(.get_ssl_context);
        defer span.deinit();
        span.trace("SSL context request", .{});
        const server: *JamSnpServer = @ptrCast(@alignCast(ctx.?));
        return @ptrCast(server.ssl_ctx);
    }

    fn lookupCertificate(
        ctx: ?*anyopaque,
        _: ?*const lsquic.struct_sockaddr,
        sni: ?[*:0]const u8,
    ) callconv(.C) ?*lsquic.struct_ssl_ctx_st {
        const span = trace.span(.lookup_certificate);
        defer span.deinit();
        const server: ?*JamSnpServer = @ptrCast(@alignCast(ctx.?));

        if (sni) |server_name| {
            span.debug("Certificate lookup requested for SNI: {s}. Returning default context.", .{std.mem.sliceTo(server_name, 0)});
        } else {
            span.debug("Certificate lookup requested without SNI. Returning default context.", .{});
        }
        // Return the single SSL_CTX configured for the server.
        return @ptrCast(server.?.ssl_ctx);
    }

    fn sendPacketsOut(
        ctx: ?*anyopaque,
        specs: ?[*]const lsquic.lsquic_out_spec,
        n_specs: c_uint,
    ) callconv(.C) c_int {
        const span = trace.span(.server_send_packets_out);
        defer span.deinit();
        span.trace("Sending {d} packet specs", .{n_specs});

        const server = @as(*JamSnpServer, @ptrCast(@alignCast(ctx)));
        const specs_slice = specs.?[0..n_specs];

        var packets_sent: c_int = 0;
        send_loop: for (specs_slice, 0..) |spec, i| {
            span.trace("Processing packet spec {d} with {d} iovecs", .{ i, spec.iovlen });

            // For each iovec in the spec
            const iov_slice = spec.iov[0..spec.iovlen];
            for (iov_slice) |iov| {
                const packet_buf: [*]const u8 = @ptrCast(iov.iov_base);
                const packet_len: usize = @intCast(iov.iov_len);
                const packet = packet_buf[0..packet_len];

                const dest_addr = std.net.Address.initPosix(@ptrCast(@alignCast(spec.dest_sa)));

                span.trace("Sending packet of {d} bytes to {}", .{ packet_len, dest_addr });

                // Send the packet
                _ = server.socket.sendTo(network.EndPoint.fromSocketAddress(&dest_addr.any, dest_addr.getOsSockLen()) catch |err| {
                    span.err("Failed to convert socket address: {s}", .{@errorName(err)});
                    break :send_loop;
                }, packet) catch |err| {
                    span.err("Failed to send packet: {s}", .{@errorName(err)});
                    break :send_loop;
                };
            }

            packets_sent += 1;
        }

        span.trace("Successfully sent {d}/{d} packets", .{ packets_sent, n_specs });
        return packets_sent;
    }
};
