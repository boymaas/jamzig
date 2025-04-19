const std = @import("std");
const uuid = @import("uuid");
const lsquic = @import("lsquic");
const ssl = @import("ssl");
const common = @import("common.zig");
const certificate_verifier = @import("certificate_verifier.zig");
const constants = @import("constants.zig");
const network = @import("network");

const xev = @import("xev");

const toSocketAddress = @import("../ext.zig").toSocketAddress;

const trace = @import("../../tracing.zig").scoped(.network);

pub const ConnectionId = uuid.Uuid;
pub const StreamId = uuid.Uuid;

pub const JamSnpClient = struct {

    // Define callback function types
    pub const ConnectionEstablishedCallbackFn = *const fn (connection: ConnectionId, endpoint: network.EndPoint, context: ?*anyopaque) void;
    pub const ConnectionFailedCallbackFn = *const fn (endpoint: network.EndPoint, err: anyerror, context: ?*anyopaque) void;
    pub const ConnectionClosedCallbackFn = *const fn (connection: ConnectionId, context: ?*anyopaque) void;
    pub const StreamCreatedCallbackFn = *const fn (connection: ConnectionId, stream: StreamId, context: ?*anyopaque) void;
    pub const StreamClosedCallbackFn = *const fn (connection: ConnectionId, stream: StreamId, context: ?*anyopaque) void;
    pub const DataReceivedCallbackFn = *const fn (connection: ConnectionId, stream: StreamId, data: []const u8, context: ?*anyopaque) void;
    pub const DataEndOfStreamCallbackFn = *const fn (connection: ConnectionId, stream: StreamId, data_read: []const u8, context: ?*anyopaque) void;
    pub const DataErrorCallbackFn = *const fn (connection: ConnectionId, stream: StreamId, error_code: i32, context: ?*anyopaque) void;
    pub const DataWouldBlockCallbackFn = *const fn (connection: ConnectionId, stream: StreamId, context: ?*anyopaque) void;
    pub const DataWriteProgressCallbackFn = *const fn (connection: ConnectionId, stream: StreamId, bytes_written: usize, total_size: usize, context: ?*anyopaque) void;
    pub const DataWriteCompletedCallbackFn = *const fn (connection: ConnectionId, stream: StreamId, total_bytes_written: usize, context: ?*anyopaque) void;

    // Callback handlers
    pub const CallbackHandler = struct {
        callback: ?*const anyopaque,
        context: ?*anyopaque,
    };

    allocator: std.mem.Allocator,
    keypair: std.crypto.sign.Ed25519.KeyPair,
    socket: network.Socket,

    alpn: []const u8,

    /// Bookkeeping for connections and streams
    connections: std.AutoHashMap(ConnectionId, *Connection),
    streams: std.AutoHashMap(StreamId, *Stream),

    loop: ?*xev.Loop = null,
    loop_owned: bool = false,

    packets_in: xev.UDP,
    packets_in_c: xev.Completion = undefined,
    packets_in_state: xev.UDP.State = undefined,

    packet_in_buffer: []u8 = undefined,

    tick: xev.Timer,
    tick_c: xev.Completion = undefined,

    lsquic_engine: *lsquic.lsquic_engine,
    lsquic_engine_api: lsquic.lsquic_engine_api,
    lsquic_engine_settings: lsquic.lsquic_engine_settings,
    lsquic_stream_iterface: lsquic.lsquic_stream_if = .{
        // Mandatory callbacks
        .on_new_conn = Connection.onNewConn,
        .on_conn_closed = Connection.onConnClosed,
        .on_new_stream = Stream.onNewStream,
        .on_read = Stream.onRead,
        .on_write = Stream.onWrite,
        .on_close = Stream.onClose,
        // Optional callbacks
        // .on_goaway_received = Connection.onGoawayReceived,
        // .on_dg_write = onDbWrite,
        // .on_datagram = onDatagram,
        // .on_hsk_done = Connection.onHskDone,
        // .on_new_token = onNewToken,
        // .on_sess_resume_info = onSessResumeInfo,
        // .on_reset = onReset,
        // .on_conncloseframe_received = Connection.onConnCloseFrameReceived,
    },

    ssl_ctx: *ssl.SSL_CTX,
    chain_genesis_hash: []const u8,
    is_builder: bool,

    // Callback handlers for different events
    connection_established_handler: CallbackHandler = .{ .callback = null, .context = null },
    connection_failed_handler: CallbackHandler = .{ .callback = null, .context = null },
    connection_closed_handler: CallbackHandler = .{ .callback = null, .context = null },
    stream_created_handler: CallbackHandler = .{ .callback = null, .context = null },
    stream_closed_handler: CallbackHandler = .{ .callback = null, .context = null },
    data_received_handler: CallbackHandler = .{ .callback = null, .context = null },
    data_end_of_stream_handler: CallbackHandler = .{ .callback = null, .context = null },
    data_error_handler: CallbackHandler = .{ .callback = null, .context = null },
    data_wouldblock_handler: CallbackHandler = .{ .callback = null, .context = null },
    data_write_started_handler: CallbackHandler = .{ .callback = null, .context = null },
    data_write_progress_handler: CallbackHandler = .{ .callback = null, .context = null },
    data_write_completed_handler: CallbackHandler = .{ .callback = null, .context = null },

    pub fn initWithLoop(
        allocator: std.mem.Allocator,
        keypair: std.crypto.sign.Ed25519.KeyPair,
        chain_genesis_hash: []const u8,
        is_builder: bool,
    ) !*JamSnpClient {
        const client = try initWithoutLoop(allocator, keypair, chain_genesis_hash, is_builder);
        errdefer client.deinit();

        try client.initLoop();

        return client;
    }

    pub fn initAttachLoop(
        allocator: std.mem.Allocator,
        keypair: std.crypto.sign.Ed25519.KeyPair,
        chain_genesis_hash: []const u8,
        is_builder: bool,
        loop: *xev.Loop,
    ) !*JamSnpClient {
        const client = try initWithoutLoop(allocator, keypair, chain_genesis_hash, is_builder);
        errdefer client.deinit();

        try client.attachToLoop(loop);

        return client;
    }

    pub fn initWithoutLoop(
        allocator: std.mem.Allocator,
        keypair: std.crypto.sign.Ed25519.KeyPair,
        chain_genesis_hash: []const u8,
        is_builder: bool,
    ) !*JamSnpClient {
        const span = trace.span(.init_client);
        defer span.deinit();
        span.debug("Initializing JamSnpClient", .{});

        // Initialize lsquic globally (if not already initialized)
        span.debug("Initializing lsquic globally", .{});
        if (lsquic.lsquic_global_init(lsquic.LSQUIC_GLOBAL_CLIENT) != 0) {
            span.err("lsquic global initialization failed", .{});
            return error.LsquicInitFailed;
        }

        // Create UDP socket
        span.debug("Creating UDP socket", .{});
        var socket = try network.Socket.create(.ipv6, .udp);
        errdefer socket.close();

        // Create ALPN identifier
        const alpn_id = try common.buildAlpnIdentifier(allocator, chain_genesis_hash, is_builder);
        errdefer allocator.free(alpn_id);

        // Configure SSL context
        span.debug("Configuring SSL context", .{});
        const ssl_ctx = try common.configureSSLContext(
            allocator,
            keypair,
            chain_genesis_hash,
            true, // is_client
            is_builder,
            alpn_id,
        );
        errdefer ssl.SSL_CTX_free(ssl_ctx);

        // Set up certificate verification
        span.debug("Setting up certificate verification", .{});
        ssl.SSL_CTX_set_cert_verify_callback(ssl_ctx, certificate_verifier.verifyCertificate, null);

        // Initialize lsquic engine settings
        span.debug("Initializing engine settings", .{});
        var engine_settings: lsquic.lsquic_engine_settings = .{};
        lsquic.lsquic_engine_init_settings(&engine_settings, 0);
        engine_settings.es_versions = 1 << lsquic.LSQVER_ID29; // IETF QUIC v1

        // Check settings
        var error_buffer: [128]u8 = undefined;
        if (lsquic.lsquic_engine_check_settings(&engine_settings, 0, @ptrCast(&error_buffer), @sizeOf(@TypeOf(error_buffer))) != 0) {
            std.debug.panic("Client engine settings problem: {s}", .{error_buffer});
        }

        span.debug("Allocating client struct", .{});
        const client = try allocator.create(JamSnpClient);
        errdefer client.deinit();

        client.* = JamSnpClient{
            .allocator = allocator,
            .keypair = keypair,
            .chain_genesis_hash = try allocator.dupe(u8, chain_genesis_hash),
            .is_builder = is_builder,

            .connections = std.AutoHashMap(ConnectionId, *Connection).init(allocator),
            .streams = std.AutoHashMap(StreamId, *Stream).init(allocator),

            .socket = socket,
            .alpn = alpn_id,

            .packets_in = xev.UDP.initFd(socket.internal),

            .packet_in_buffer = try allocator.alloc(u8, 1500),

            .tick = try xev.Timer.init(),

            .lsquic_engine = undefined,
            .lsquic_engine_settings = engine_settings,
            .lsquic_engine_api = .{
                .ea_settings = &engine_settings,
                .ea_stream_if = &client.lsquic_stream_iterface,
                .ea_stream_if_ctx = null,
                .ea_packets_out = &sendPacketsOut,
                .ea_packets_out_ctx = null,
                .ea_get_ssl_ctx = &getSslContext,
                .ea_lookup_cert = null,
                .ea_cert_lu_ctx = null,
                .ea_alpn = @ptrCast(alpn_id.ptr),
            },

            .ssl_ctx = ssl_ctx,
        };

        client.lsquic_engine_api.ea_packets_out_ctx = client;

        // Create lsquic engine
        span.debug("Creating lsquic engine", .{});
        client.*.lsquic_engine = lsquic.lsquic_engine_new(0, &client.*.lsquic_engine_api) orelse {
            span.err("lsquic engine creation failed", .{});
            return error.LsquicEngineCreationFailed;
        };

        span.debug("JamSnpClient initialization successful", .{});
        return client;
    }

    pub fn initLoop(self: *@This()) !void {
        const loop = try self.allocator.create(xev.Loop);
        loop.* = try xev.Loop.init(.{});
        self.loop = loop;
        self.loop_owned = true;
        self.buildLoop();
    }

    pub fn attachToLoop(self: *@This(), loop: *xev.Loop) void {
        self.loop = loop;
        self.loop_owned = false;
        self.buildLoop();
    }

    pub fn buildLoop(self: *@This()) void {
        const span = trace.span(.build_loop);
        defer span.deinit();

        span.debug("Initializing event loop", .{});

        self.tick.run(
            self.loop.?,
            &self.tick_c,
            500,
            @This(),
            self,
            onTick,
        );

        self.packets_in.read(
            self.loop.?,
            &self.packets_in_c,
            &self.packets_in_state,
            .{ .slice = self.packet_in_buffer },
            @This(),
            self,
            onPacketsIn,
        );

        span.debug("Event loop built successfully", .{});
    }

    pub fn runTick(self: *@This()) !void {
        const span = trace.span(.run_client_tick);
        defer span.deinit();
        span.trace("Running a single tick on JamSnpClient", .{});
        try self.loop.?.run(.no_wait);
    }

    pub fn runUntilDone(self: *@This()) !void {
        const span = trace.span(.run);
        defer span.deinit();
        span.debug("Starting JamSnpClient event loop", .{});
        try self.loop.?.run(.until_done);
        span.debug("Event loop completed", .{});
    }

    // Callback registration methods
    pub fn setConnectionEstablishedCallback(self: *@This(), callback: ConnectionEstablishedCallbackFn, context: ?*anyopaque) void {
        const span = trace.span(.set_connection_established_callback);
        defer span.deinit();
        span.debug("Setting connection established callback", .{});

        self.connection_established_handler = .{
            .callback = @ptrCast(callback),
            .context = context,
        };
    }

    pub fn setConnectionFailedCallback(self: *@This(), callback: ConnectionFailedCallbackFn, context: ?*anyopaque) void {
        const span = trace.span(.set_connection_failed_callback);
        defer span.deinit();
        span.debug("Setting connection failed callback", .{});

        self.connection_failed_handler = .{
            .callback = @ptrCast(callback),
            .context = context,
        };
    }

    pub fn setConnectionClosedCallback(self: *@This(), callback: ConnectionClosedCallbackFn, context: ?*anyopaque) void {
        const span = trace.span(.set_connection_closed_callback);
        defer span.deinit();
        span.debug("Setting connection closed callback", .{});

        self.connection_closed_handler = .{
            .callback = @ptrCast(callback),
            .context = context,
        };
    }

    pub fn setStreamCreatedCallback(self: *@This(), callback: StreamCreatedCallbackFn, context: ?*anyopaque) void {
        const span = trace.span(.set_stream_created_callback);
        defer span.deinit();
        span.debug("Setting stream created callback", .{});

        self.stream_created_handler = .{
            .callback = @ptrCast(callback),
            .context = context,
        };
    }

    pub fn setStreamClosedCallback(self: *@This(), callback: StreamClosedCallbackFn, context: ?*anyopaque) void {
        const span = trace.span(.set_stream_closed_callback);
        defer span.deinit();
        span.debug("Setting stream closed callback", .{});

        self.stream_closed_handler = .{
            .callback = @ptrCast(callback),
            .context = context,
        };
    }

    pub fn setDataReceivedCallback(self: *@This(), callback: DataReceivedCallbackFn, context: ?*anyopaque) void {
        const span = trace.span(.set_data_received_callback);
        defer span.deinit();
        span.debug("Setting data received callback", .{});

        self.data_received_handler = .{
            .callback = @ptrCast(callback),
            .context = context,
        };
    }

    pub fn setDataFinishedCallback(self: *@This(), callback: DataEndOfStreamCallbackFn, context: ?*anyopaque) void {
        const span = trace.span(.set_data_finished_callback);
        defer span.deinit();
        span.debug("Setting data finished callback", .{});

        self.data_end_of_stream_handler = .{
            .callback = @ptrCast(callback),
            .context = context,
        };
    }

    pub fn setDataErrorCallback(self: *@This(), callback: DataErrorCallbackFn, context: ?*anyopaque) void {
        const span = trace.span(.set_data_error_callback);
        defer span.deinit();
        span.debug("Setting data error callback", .{});

        self.data_error_handler = .{
            .callback = @ptrCast(callback),
            .context = context,
        };
    }

    pub fn setDataWouldBlockCallback(self: *@This(), callback: DataWouldBlockCallbackFn, context: ?*anyopaque) void {
        const span = trace.span(.set_data_wouldblock_callback);
        defer span.deinit();
        span.debug("Setting data wouldblock callback", .{});

        self.data_wouldblock_handler = .{
            .callback = @ptrCast(callback),
            .context = context,
        };
    }

    pub fn setDataWriteProgressCallback(self: *@This(), callback: DataWriteProgressCallbackFn, context: ?*anyopaque) void {
        const span = trace.span(.set_data_write_progress_callback);
        defer span.deinit();
        span.debug("Setting data write progress callback", .{});

        self.data_write_progress_handler = .{
            .callback = @ptrCast(callback),
            .context = context,
        };
    }

    pub fn setDataWriteCompletedCallback(self: *@This(), callback: DataWriteCompletedCallbackFn, context: ?*anyopaque) void {
        const span = trace.span(.set_data_write_completed_callback);
        defer span.deinit();
        span.debug("Setting data write completed callback", .{});

        self.data_write_completed_handler = .{
            .callback = @ptrCast(callback),
            .context = context,
        };
    }

    // Callback invocation methods
    fn invokeConnectionEstablishedCallback(self: *@This(), connection: ConnectionId, endpoint: network.EndPoint) void {
        const span = trace.span(.invoke_connection_established_callback);
        defer span.deinit();

        if (self.connection_established_handler.callback) |callback_ptr| {
            const callback: ConnectionEstablishedCallbackFn = @ptrCast(@alignCast(callback_ptr));
            span.debug("Invoking connection established callback", .{});
            callback(connection, endpoint, self.connection_established_handler.context);
        } else {
            span.warn("No connection established callback registered", .{});
        }
    }

    fn invokeConnectionFailedCallback(self: *@This(), endpoint: network.EndPoint, err: anyerror) void {
        const span = trace.span(.invoke_connection_failed_callback);
        defer span.deinit();

        if (self.connection_failed_handler.callback) |callback_ptr| {
            const callback: ConnectionFailedCallbackFn = @ptrCast(@alignCast(callback_ptr));
            span.debug("Invoking connection failed callback", .{});
            callback(endpoint, err, self.connection_failed_handler.context);
        } else {
            span.warn("No connection failed callback registered", .{});
        }
    }

    fn invokeConnectionClosedCallback(self: *@This(), connection: ConnectionId) void {
        const span = trace.span(.invoke_connection_closed_callback);
        defer span.deinit();

        if (self.connection_closed_handler.callback) |callback_ptr| {
            const callback: ConnectionClosedCallbackFn = @ptrCast(@alignCast(callback_ptr));
            span.debug("Invoking connection closed callback", .{});
            callback(connection, self.connection_closed_handler.context);
        } else {
            span.warn("No connection closed callback registered", .{});
        }
    }

    fn invokeStreamCreatedCallback(self: *@This(), connection: ConnectionId, stream: StreamId) void {
        const span = trace.span(.invoke_stream_created_callback);
        defer span.deinit();

        if (self.stream_created_handler.callback) |callback_ptr| {
            const callback: StreamCreatedCallbackFn = @ptrCast(@alignCast(callback_ptr));
            span.debug("Invoking stream created callback", .{});
            callback(connection, stream, self.stream_created_handler.context);
        } else {
            span.warn("No stream created callback registered", .{});
        }
    }

    fn invokeStreamClosedCallback(self: *@This(), connection: ConnectionId, stream: StreamId) void {
        const span = trace.span(.invoke_stream_closed_callback);
        defer span.deinit();

        if (self.stream_closed_handler.callback) |callback_ptr| {
            const callback: StreamClosedCallbackFn = @ptrCast(@alignCast(callback_ptr));
            span.debug("Invoking stream closed callback", .{});
            callback(connection, stream, self.stream_closed_handler.context);
        } else {
            span.warn("No stream closed callback registered", .{});
        }
    }

    fn invokeDataReceivedCallback(self: *@This(), connection: ConnectionId, stream: StreamId, data: []const u8) void {
        const span = trace.span(.invoke_data_received_callback);
        defer span.deinit();

        if (self.data_received_handler.callback) |callback_ptr| {
            const callback: DataReceivedCallbackFn = @ptrCast(@alignCast(callback_ptr));
            span.debug("Invoking data received callback", .{});
            callback(connection, stream, data, self.data_received_handler.context);
        } else {
            span.warn("No data received callback registered", .{});
        }
    }

    fn invokeDataEndOfStreamCallback(self: *@This(), connection: ConnectionId, stream: StreamId, data_read: []const u8) void {
        const span = trace.span(.invoke_data_end_of_stream_callback);
        defer span.deinit();

        if (self.data_end_of_stream_handler.callback) |callback_ptr| {
            const callback: DataEndOfStreamCallbackFn = @ptrCast(@alignCast(callback_ptr));
            span.debug("Invoking data finished callback", .{});
            callback(connection, stream, data_read, self.data_end_of_stream_handler.context);
        } else {
            span.warn("No data finished callback registered", .{});
        }
    }

    fn invokeDataErrorCallback(self: *@This(), connection: ConnectionId, stream: StreamId, error_code: i32) void {
        const span = trace.span(.invoke_data_error_callback);
        defer span.deinit();

        if (self.data_error_handler.callback) |callback_ptr| {
            const callback: DataErrorCallbackFn = @ptrCast(@alignCast(callback_ptr));
            span.debug("Invoking data error callback", .{});
            callback(connection, stream, error_code, self.data_error_handler.context);
        } else {
            span.warn("No data error callback registered", .{});
        }
    }

    fn invokeDataWouldBlockCallback(self: *@This(), connection: ConnectionId, stream: StreamId) void {
        const span = trace.span(.invoke_data_wouldblock_callback);
        defer span.deinit();

        if (self.data_wouldblock_handler.callback) |callback_ptr| {
            const callback: DataWouldBlockCallbackFn = @ptrCast(@alignCast(callback_ptr));
            span.debug("Invoking data wouldblock callback", .{});
            callback(connection, stream, self.data_wouldblock_handler.context);
        } else {
            span.warn("No data wouldblock callback registered", .{});
        }
    }

    fn invokeDataWriteProgressCallback(self: *@This(), connection: ConnectionId, stream: StreamId, bytes_written: usize, total_size: usize) void {
        const span = trace.span(.invoke_data_write_progress_callback);
        defer span.deinit();

        if (self.data_write_progress_handler.callback) |callback_ptr| {
            const callback: DataWriteProgressCallbackFn = @ptrCast(@alignCast(callback_ptr));
            span.debug("Invoking data write progress callback", .{});
            callback(connection, stream, bytes_written, total_size, self.data_write_progress_handler.context);
        } else {
            span.trace("No data write progress callback registered", .{});
        }
    }

    fn invokeDataWriteCompletedCallback(self: *@This(), connection: ConnectionId, stream: StreamId, total_bytes_written: usize) void {
        const span = trace.span(.invoke_data_write_completed_callback);
        defer span.deinit();

        if (self.data_write_completed_handler.callback) |callback_ptr| {
            const callback: DataWriteCompletedCallbackFn = @ptrCast(@alignCast(callback_ptr));
            span.debug("Invoking data write completed callback", .{});
            callback(connection, stream, total_bytes_written, self.data_write_completed_handler.context);
        } else {
            span.trace("No data write completed callback registered", .{});
        }
    }

    pub fn deinit(self: *JamSnpClient) void {
        const span = trace.span(.deinit);
        defer span.deinit();

        // Clear all callbacks to prevent use-after-free
        self.connection_established_handler = .{ .callback = null, .context = null };
        self.connection_failed_handler = .{ .callback = null, .context = null };
        self.connection_closed_handler = .{ .callback = null, .context = null };
        self.stream_created_handler = .{ .callback = null, .context = null };
        self.stream_closed_handler = .{ .callback = null, .context = null };
        self.data_received_handler = .{ .callback = null, .context = null };
        self.data_end_of_stream_handler = .{ .callback = null, .context = null };
        self.data_error_handler = .{ .callback = null, .context = null };
        self.data_wouldblock_handler = .{ .callback = null, .context = null };
        self.data_write_started_handler = .{ .callback = null, .context = null };
        self.data_write_progress_handler = .{ .callback = null, .context = null };
        self.data_write_completed_handler = .{ .callback = null, .context = null };

        lsquic.lsquic_engine_destroy(self.lsquic_engine);
        ssl.SSL_CTX_free(self.ssl_ctx);

        self.socket.close();

        self.tick.deinit();
        if (self.loop) |loop| if (self.loop_owned) {
            loop.deinit();
            self.allocator.destroy(loop);
        };

        self.allocator.free(self.packet_in_buffer);
        self.allocator.free(self.chain_genesis_hash);
        self.allocator.free(self.alpn);

        self.connections.deinit();
        self.streams.deinit();

        // Destroy the object itself
        self.allocator.destroy(self);

        span.debug("JamSnpClient deinitialization complete", .{});
    }

    pub fn connect(self: *JamSnpClient, peer_addr: []const u8, peer_port: u16) !ConnectionId {
        const span = trace.span(.connect);
        defer span.deinit();
        span.debug("Connecting to {s}:{d}", .{ peer_addr, peer_port });

        // Bind to a local address (use any address)
        self.socket.bindToPort(0) catch |err| {
            span.err("Failed to bind to local port: {s}", .{@errorName(err)});
            return err;
        };

        // Get the local socket address after binding
        const local_endpoint = self.socket.getLocalEndPoint() catch |err| {
            span.err("Failed to get local endpoint: {s}", .{@errorName(err)});
            return err;
        };

        span.debug("Bound to local endpoint: {}", .{local_endpoint});

        // Parse peer address and create endpoint
        span.debug("Parsing peer address", .{});
        var peer_endpoint: network.EndPoint = undefined;
        const peer_address = network.Address.parse(peer_addr) catch |err| {
            span.err("Failed to parse peer address: {s}", .{@errorName(err)});
            return err;
        };

        peer_endpoint = network.EndPoint{
            .address = peer_address,
            .port = peer_port,
        };

        span.debug("Peer endpoint: {}", .{peer_endpoint});

        // Create a connection
        span.trace("Creating connection context", .{});
        const conn = try Connection.create(self.allocator, self, peer_endpoint);
        errdefer conn.destroy(self.allocator);

        // Create QUIC connection
        span.debug("Creating QUIC connection", .{});
        _ = lsquic.lsquic_engine_connect(
            self.lsquic_engine,
            lsquic.LSQVER_VERNEG, // Negotiate version or lsquic.LSQVER_ID29
            @ptrCast(&toSocketAddress(try self.socket.getLocalEndPoint())), // local_addr
            @ptrCast(&toSocketAddress(peer_endpoint)), // remote_addr
            self.ssl_ctx, // peer_ctx
            @ptrCast(conn), // conn_ctx
            null,
            0, // base_plpmtu - use default
            null,
            0, // session resumption
            null,
            0, // token
        ) orelse {
            span.err("lsquic_engine_connect failed", .{});
            return error.ConnectionFailed;
        };

        // If we where able to create the connection we need to add
        // it to the connections map
        try self.connections.put(conn.id, conn);

        return conn.id;
    }

    pub const Connection = struct {
        id: ConnectionId,
        lsquic_connection: *lsquic.lsquic_conn_t,
        endpoint: network.EndPoint,
        client: *JamSnpClient,

        // Allocates the object and sets the minimal fields still needs to attach the lsquic_connection
        pub fn create(alloc: std.mem.Allocator, client: *JamSnpClient, endpoint: network.EndPoint) !*Connection {
            // Allocate the connection object
            const connection = try alloc.create(Connection);

            connection.* = .{
                .id = uuid.v4.new(),
                .lsquic_connection = undefined,
                .endpoint = endpoint,
                .client = client,
            };

            return connection;
        }

        pub fn destroy(self: *Connection, alloc: std.mem.Allocator) void {
            self.* = undefined;
            alloc.destroy(self);
        }

        // request a new stream on the connection
        pub fn createStream(self: *Connection) !void {
            const span = trace.span(.create_stream);
            defer span.deinit();
            span.debug("Creating new stream on connection", .{});
            // Call lsquic_conn_make_stream to create the stream
            lsquic.lsquic_conn_make_stream(self.lsquic_connection) orelse {
                span.err("Failed to create LSQUIC stream", .{});
                return error.StreamCreationFailed;
            };

            // The stream will be initialized in the onNewStream callback
            span.debug("Stream creation request successful", .{});
        }

        fn onNewConn(
            _: ?*anyopaque,
            maybe_lsquic_connection: ?*lsquic.lsquic_conn_t,
        ) callconv(.C) *lsquic.lsquic_conn_ctx_t {
            const span = trace.span(.on_new_conn);
            defer span.deinit();

            const conn_ctx = lsquic.lsquic_conn_get_ctx(maybe_lsquic_connection).?;
            const connection: *Connection = @alignCast(@ptrCast(conn_ctx));
            span.debug("Connected to {}", .{connection.endpoint});

            connection.lsquic_connection = maybe_lsquic_connection.?;

            // Invoke the connection established callback
            connection.client.invokeConnectionEstablishedCallback(connection.id, connection.endpoint);

            return @ptrCast(connection);
        }

        fn onConnClosed(maybe_lsquic_connection: ?*lsquic.lsquic_conn_t) callconv(.C) void {
            const span = trace.span(.on_conn_closed);
            defer span.deinit();
            span.debug("Connection closed callback", .{});

            const conn_ctx = lsquic.lsquic_conn_get_ctx(maybe_lsquic_connection).?;
            const conn: *Connection = @alignCast(@ptrCast(conn_ctx));

            // Invoke the connection closed callback
            conn.client.invokeConnectionClosedCallback(conn.id);

            // Remove the connection from the map
            if (!conn.client.connections.remove(conn.id)) {
                span.warn("Closing a connection that was not in the map", .{});
            }

            lsquic.lsquic_conn_set_ctx(maybe_lsquic_connection, null);
            conn.client.allocator.destroy(conn);
            span.debug("Connection cleanup complete", .{});
        }
    };

    pub const Stream = struct {
        id: StreamId,
        connection: *Connection,
        lsquic_stream: *lsquic.lsquic_stream_t,

        want_write: bool = false,
        write_buffer: ?[]u8 = null,
        write_buffer_pos: usize = 0,

        want_read: bool = false,
        read_buffer: ?[]u8 = null,
        read_buffer_pos: usize = 0,

        pub fn wantRead(self: *Stream, want: bool) void {
            const span = trace.span(.stream_want_read);
            defer span.deinit();

            const want_val: c_int = if (want) 1 else 0;
            span.debug("Setting stream want-read to {}", .{want});

            _ = lsquic.lsquic_stream_wantread(self.lsquic_stream, want_val);
        }

        pub fn wantWrite(self: *Stream, want: bool) void {
            const span = trace.span(.stream_want_write);
            defer span.deinit();

            const want_val: c_int = if (want) 1 else 0;
            span.debug("Setting stream want-write to {}", .{want});

            _ = lsquic.lsquic_stream_wantwrite(self.lsquic_stream, want_val);
        }

        pub fn read(self: *Stream, buffer: []u8) !void {
            const span = trace.span(.stream_read);
            defer span.deinit();
            span.debug("Reading from stream", .{});

            if (self.read_buffer) |_| {
                span.err("Stream is already reading, cannot read again", .{});
                return error.StreamAlreadyReading;
            }

            self.read_buffer = buffer;
            self.read_buffer_pos = 0;

            self.wantRead(true);
        }

        // Data is owned by the caller
        pub fn write(self: *Stream, data: []const u8) !void {
            const span = trace.span(.stream_write);
            defer span.deinit();
            span.debug("Writing {d} bytes to stream", .{data.len});

            if (self.write_buffer) |_| {
                span.err("Stream is already writing, cannot write again", .{});
                return error.StreamAlreadyWriting;
            }

            self.write_buffer = data;
            self.write_buffer_pos = 0;

            // Invoke the write started callback
            self.connection.client.invokeDataWriteStartedCallback(self.connection.id, self.id, data.len);

            self.wantWrite(true);
        }

        pub fn flush(self: *Stream) !void {
            const span = trace.span(.stream_flush);
            defer span.deinit();
            span.debug("Flushing stream", .{});

            if (lsquic.lsquic_stream_flush(self.lsquic_stream) != 0) {
                span.err("Failed to flush stream", .{});
                return error.StreamFlushFailed;
            }
        }

        pub fn shutdown(self: *Stream, how: c_int) !void {
            const span = trace.span(.stream_shutdown);
            defer span.deinit();

            const direction = switch (how) {
                0 => "read",
                1 => "write",
                2 => "read and write",
                else => "unknown",
            };
            span.debug("Shutting down stream {s} side", .{direction});

            if (lsquic.lsquic_stream_shutdown(self.lsquic_stream, how) != 0) {
                span.err("Failed to shutdown stream", .{});
                return error.StreamShutdownFailed;
            }
        }

        pub fn close(self: *Stream) !void {
            const span = trace.span(.stream_close);
            defer span.deinit();
            span.debug("Closing stream", .{});

            if (lsquic.lsquic_stream_close(self.lsquic_stream) != 0) {
                span.err("Failed to close stream", .{});
                return error.StreamCloseFailed;
            }
        }

        fn onNewStream(
            _: ?*anyopaque,
            maybe_lsquic_stream: ?*lsquic.lsquic_stream_t,
        ) callconv(.C) *lsquic.lsquic_stream_ctx_t {
            const span = trace.span(.on_new_stream);
            defer span.deinit();
            span.debug("New stream callback", .{});

            const lsquic_connection = lsquic.lsquic_stream_conn(maybe_lsquic_stream);
            const conn_ctx = lsquic.lsquic_conn_get_ctx(lsquic_connection).?;
            const connection: *Connection = @alignCast(@ptrCast(conn_ctx));

            span.debug("Creating stream context", .{});
            const stream = connection.client.allocator.create(Stream) catch {
                span.err("Failed to allocate memory for stream", .{});
                @panic("OutOfMemory");
            };

            stream.* = .{
                .id = uuid.v4.new(),
                .lsquic_stream = maybe_lsquic_stream.?,
                .connection = connection,
            };

            // Invoke the stream created callback
            connection.client.invokeStreamCreatedCallback(connection.id, stream.id);

            span.debug("Stream initialization complete", .{});
            return @ptrCast(stream);
        }

        fn onRead(
            maybe_lsquic_stream: ?*lsquic.lsquic_stream_t,
            maybe_stream_ctx: ?*lsquic.lsquic_stream_ctx_t,
        ) callconv(.C) void {
            const span = trace.span(.on_read);
            defer span.deinit();

            const stream: *Stream = @alignCast(@ptrCast(maybe_stream_ctx.?));

            // Read data from the stream
            const data = stream.read_buffer.?[stream.read_buffer_pos..];
            const read_size = lsquic.lsquic_stream_read(maybe_lsquic_stream, data.ptr, data.len);

            if (read_size == 0) {
                // End of stream reached
                stream.connection.client.invokeDataEndOfStreamCallback(stream.connection.id, stream.id, stream.read_buffer.?[0..stream.read_buffer_pos]);
                span.debug("End of stream reached", .{});
            } else if (read_size < 0) {
                switch (std.posix.errno(read_size)) {
                    std.posix.E.AGAIN => {
                        // TODO: check if this AGAIN is correct
                        // FIXME: how to handle many recurring events like this
                        stream.connection.client.invokeDataWouldBlockCallback(stream.connection.id, stream.id);
                        span.debug("Read would block", .{});
                    },
                    else => |err| { // Error occurred
                        stream.connection.client.invokeDataErrorCallback(stream.connection.id, stream.id, @intFromEnum(err));
                        span.err("Error reading from stream: {d}", .{read_size});
                    },
                }
            } else {
                span.debug("Read {d} bytes from stream", .{read_size});

                // We read data successfully, invoke the data received callback
                if (read_size > 0) {
                    // Reset the buffer if we read all requested data
                    if (read_size == data.len) {
                        // Trigger the read callback
                        stream.connection.client.invokeDataReceivedCallback(stream.connection.id, stream.id, stream.read_buffer.?);

                        stream.read_buffer = null;
                        stream.read_buffer_pos = 0;
                        stream.wantRead(false);
                    } else {
                        // Otherwise, update the position for the next read
                        stream.read_buffer_pos += @intCast(read_size);
                    }
                }
            }
        }

        fn onWrite(
            maybe_lsquic_stream: ?*lsquic.lsquic_stream_t,
            maybe_stream: ?*lsquic.lsquic_stream_ctx_t,
        ) callconv(.C) void {
            const span = trace.span(.on_write);
            defer span.deinit();
            span.debug("Stream write callback", .{});

            const stream: *Stream = @alignCast(@ptrCast(maybe_stream.?));

            // A positive value: The number of bytes successfully written to
            // the stream. Zero (0): The write operation could not be performed
            // at the moment, and you should try again later. This typically
            // happens when the congestion window is full or when there are
            // resource constraints. A negative value (-1): An error occurred.
            // You should check errno to determine the specific error.
            const data = stream.write_buffer.?[stream.write_buffer_pos..];
            const total_size = stream.write_buffer.?.len;

            const written = lsquic.lsquic_stream_write(stream.lsquic_stream, data.ptr, data.len);
            if (written == 0) {
                span.trace("No data written to stream", .{});
                return;
            } else if (written == -@as(i32, @intFromEnum(std.posix.E.AGAIN))) {
                span.trace("Stream write would block, returning", .{});
                return;
            } else if (written < 0) {
                span.err("Stream write failed with error: {d}", .{written});
                // FIXME: handle this error, figure out how
                return;
            }

            stream.write_buffer_pos += @intCast(written);

            // Report write progress
            stream.connection.client.invokeDataWriteProgressCallback(stream.connection.id, stream.id, stream.write_buffer_pos, total_size);

            if (stream.write_buffer_pos >= total_size) {
                span.debug("Stream write handling complete. Buffer length: {}", .{total_size});

                // Report write completion
                stream.connection.client.invokeDataWriteCompletedCallback(stream.connection.id, stream.id, stream.write_buffer_pos);

                stream.write_buffer = null;
                stream.write_buffer_pos = 0;

                span.trace("Flushing stream", .{});
                _ = lsquic.lsquic_stream_flush(maybe_lsquic_stream);

                span.trace("Disabling write interest", .{});
                stream.wantWrite(false);
            }
        }

        fn onClose(
            _: ?*lsquic.lsquic_stream_t,
            maybe_stream: ?*lsquic.lsquic_stream_ctx_t,
        ) callconv(.C) void {
            const span = trace.span(.on_stream_close);
            defer span.deinit();
            span.debug("Stream close callback", .{});

            const stream: *Stream = @alignCast(@ptrCast(maybe_stream.?));

            // Invoke the stream closed callback
            stream.connection.client.invokeStreamClosedCallback(stream.connection.id, stream.id);

            // Remove the stream from the map
            if (!stream.connection.client.streams.remove(stream.id)) {
                span.warn("Closing a stream that was not in the map", .{});
            }

            span.debug("Destroying stream", .{});
            stream.connection.client.allocator.destroy(stream);
            span.debug("Stream cleanup complete", .{});
        }
    };

    fn onTick(
        maybe_self: ?*@This(),
        xev_loop: *xev.Loop,
        xev_completion: *xev.Completion,
        xev_timer_result: xev.Timer.RunError!void,
    ) xev.CallbackAction {
        const span = trace.span(.on_client_tick);
        defer span.deinit();

        errdefer |err| {
            span.err("onTick failed with error: {s}", .{@errorName(err)});
            std.debug.panic("onTick failed with: {s}", .{@errorName(err)});
        }
        try xev_timer_result;

        const self = maybe_self.?;
        span.trace("Processing connections", .{});
        lsquic.lsquic_engine_process_conns(self.lsquic_engine);

        // Delta is in 1/1_000_000 so we divide by 100 to get ms
        var delta: c_int = undefined;

        var timeout_in_ms: u64 = 100;
        span.trace("Checking for earliest connection activity", .{});
        if (lsquic.lsquic_engine_earliest_adv_tick(self.lsquic_engine, &delta) != 0) {
            if (delta > 0) {
                timeout_in_ms = @intCast(@divTrunc(delta, 1000));
                span.trace("Next tick scheduled in {d}ms", .{timeout_in_ms});
            }
        }

        span.trace("Scheduling next tick in {d}ms", .{timeout_in_ms});
        self.tick.run(
            xev_loop,
            xev_completion,
            timeout_in_ms,
            @This(),
            self,
            onTick,
        );

        return .disarm;
    }

    fn onPacketsIn(
        maybe_self: ?*@This(),
        _: *xev.Loop,
        _: *xev.Completion,
        _: *xev.UDP.State,
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

        const self = maybe_self.?;

        span.trace("Getting local address", .{});
        const local_address = self.socket.getLocalEndPoint() catch |err| {
            span.err("Failed to get local address: {s}", .{@errorName(err)});
            @panic("Failed to get local address");
        };

        span.trace("Local address: {}", .{local_address});

        span.trace("Passing packet to lsquic engine", .{});
        if (lsquic.lsquic_engine_packet_in(
            self.lsquic_engine,
            xev_read_buffer.slice.ptr,
            bytes,
            @ptrCast(&toSocketAddress(try self.socket.getLocalEndPoint())),
            @ptrCast(&peer_address.any),

            self,
            0,
        ) != 0) {
            span.err("lsquic_engine_packet_in failed", .{});
            @panic("lsquic_engine_packet_in failed");
        }

        span.trace("Successfully processed incoming packet", .{});
        return .rearm;
    }

    fn getSslContext(peer_ctx: ?*anyopaque, _: ?*const lsquic.struct_sockaddr) callconv(.C) ?*lsquic.struct_ssl_ctx_st {
        return @ptrCast(peer_ctx.?);
    }

    fn sendPacketsOut(
        ctx: ?*anyopaque,
        specs_ptr: ?[*]const lsquic.lsquic_out_spec,
        specs_len: c_uint,
    ) callconv(.C) c_int {
        const span = trace.span(.client_send_packets_out);
        defer span.deinit();
        span.trace("Sending {d} packet specs", .{specs_len});

        const client = @as(*JamSnpClient, @ptrCast(@alignCast(ctx)));
        const specs = specs_ptr.?[0..specs_len];

        var send_packets: c_int = 0;
        send_loop: for (specs, 0..) |spec, i| {
            const iov_slice = spec.iov[0..spec.iovlen];
            span.trace("Processing packet spec {d} with {d} iovecs", .{ i, spec.iovlen });

            // Send the packet
            for (iov_slice) |iov| {
                const packet_buf: [*]const u8 = @ptrCast(iov.iov_base);
                const packet_len: usize = @intCast(iov.iov_len);
                const packet = packet_buf[0..packet_len];

                const dest_addr = std.net.Address.initPosix(@ptrCast(@alignCast(spec.dest_sa)));

                span.trace("Sending packet of {d} bytes to {}", .{ packet_len, dest_addr });

                // Send the packet
                _ = client.socket.sendTo(network.EndPoint.fromSocketAddress(@ptrCast(@alignCast(&dest_addr.any)), dest_addr.getOsSockLen()) catch |err| {
                    span.err("Failed to convert socket address: {s}", .{@errorName(err)});
                    break :send_loop;
                }, packet) catch |err| {
                    span.err("Failed to send packet: {s}", .{@errorName(err)});
                    break :send_loop;
                };
            }
            send_packets += 1;
        }

        span.trace("Successfully sent {d}/{d} packet specs", .{ send_packets, specs_len });
        return send_packets;
    }
};
