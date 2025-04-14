const std = @import("std");
const lsquic = @import("lsquic");
const ssl = @import("ssl");
const common = @import("common.zig");
const certificate_verifier = @import("certificate_verifier.zig");
const constants = @import("constants.zig");
const UdpSocket = @import("../udp_socket.zig").UdpSocket;
// Add xev import
const xev = @import("xev");

// Add tracing module import
const trace = @import("../../tracing.zig").scoped(.network);

pub const JamSnpServer = struct {
    allocator: std.mem.Allocator,
    keypair: std.crypto.sign.Ed25519.KeyPair,

    socket: UdpSocket,

    // Protocol negotiation identifier(s)
    alpn_id: []const u8,

    // xev: owned state
    loop: xev.Loop = undefined,

    // xev: udp memory
    packets_in: xev.UDP,
    packets_in_c: xev.Completion = undefined,
    packets_in_s: xev.UDP.State = undefined,
    packets_in_buffer: []u8 = undefined,

    // xev: tick
    tick: xev.Timer,
    tick_c: xev.Completion = undefined,

    // lsquic: configuraiton
    lsquic_engine: *lsquic.lsquic_engine_t,
    lsquic_engine_api: lsquic.lsquic_engine_api,
    lsquic_engine_settings: lsquic.lsquic_engine_settings,
    lsquic_stream_interface: lsquic.lsquic_stream_if = .{
        // Mandatory callbacks
        .on_new_conn = Connection.onNewConn,
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

    pub fn init(
        allocator: std.mem.Allocator,
        keypair: std.crypto.sign.Ed25519.KeyPair,
        genesis_hash: []const u8,
        allow_builders: bool,
    ) !*JamSnpServer {
        const span = trace.span(.init_server);
        defer span.deinit();
        span.debug("Initializing JamSnpServer", .{});

        // Initialize lsquic globally (if not already initialized)
        if (lsquic.lsquic_global_init(lsquic.LSQUIC_GLOBAL_SERVER) != 0) {
            span.err("Failed to initialize lsquic globally", .{});
            return error.LsquicInitFailed;
        }
        span.debug("lsquic global init successful", .{});

        // Create UDP socket
        span.debug("Creating UDP socket", .{});
        var socket = try UdpSocket.init();
        errdefer socket.deinit();

        // Create ALPN identifier for server
        const alpn_id = try common.buildAlpnIdentifier(allocator, genesis_hash, false // is_builder (not applicable for server)
        );
        errdefer allocator.free(alpn_id);

        // Configure SSL context
        span.debug("Configuring SSL context", .{});
        const ssl_ctx = try common.configureSSLContext(
            allocator,
            keypair,
            genesis_hash,
            false, // is_client
            false, // is_builder (not applicable for server)
            alpn_id,
        );
        errdefer ssl.SSL_CTX_free(ssl_ctx);

        // Set up certificate verification
        span.debug("Setting up certificate verification", .{});
        ssl.SSL_CTX_set_cert_verify_callback(ssl_ctx, certificate_verifier.verifyCertificate, null);

        // Allocate the server object on the heap to ensure settings lifetime
        span.debug("Allocating server object", .{});
        const server = try allocator.create(JamSnpServer);
        errdefer allocator.destroy(server);

        // Initialize lsquic engine settings
        span.debug("Initializing engine settings", .{});
        var engine_settings: lsquic.lsquic_engine_settings = undefined;
        lsquic.lsquic_engine_init_settings(&engine_settings, lsquic.LSENG_SERVER);
        engine_settings.es_versions = 1 << lsquic.LSQVER_ID29; // IETF QUIC v1
        span.trace("Engine settings: es_versions={d}", .{engine_settings.es_versions});

        // Check settings
        var error_buffer: [128]u8 = undefined;
        if (lsquic.lsquic_engine_check_settings(&engine_settings, 0, @ptrCast(&error_buffer), @sizeOf(@TypeOf(error_buffer))) != 0) {
            std.debug.panic("Server engine settings problem: {s}", .{error_buffer});
        }

        // Initialize server structure first
        span.debug("Setting up server structure", .{});
        server.* = JamSnpServer{
            .allocator = allocator,
            .keypair = keypair,
            .socket = socket,
            .lsquic_engine = undefined,
            .lsquic_engine_api = undefined,
            .lsquic_engine_settings = engine_settings,
            .ssl_ctx = ssl_ctx,
            .chain_genesis_hash = try allocator.dupe(u8, genesis_hash),
            .allow_builders = allow_builders,
            // Store ALPN ID for later cleanup
            .alpn_id = alpn_id,
            // Initialize xev event handlers
            .packets_in = xev.UDP.initFd(socket.socket),
            .tick = try xev.Timer.init(),
        };

        span.trace("Chain genesis hash: {s}", .{std.fmt.fmtSliceHexLower(genesis_hash)});

        // Set up engine API with the server object as context
        span.debug("Setting up engine API", .{});
        server.lsquic_engine_api = .{
            .ea_settings = &server.lsquic_engine_settings,
            .ea_stream_if = &server.lsquic_stream_interface,
            .ea_stream_if_ctx = server,
            .ea_packets_out = &sendPacketsOut,
            .ea_packets_out_ctx = server,
            .ea_get_ssl_ctx = &getSslContext,
            .ea_lookup_cert = &lookupCertificate,
            .ea_cert_lu_ctx = server,
            .ea_alpn = null, // Server does not specify ALPN..
        };

        // Create lsquic engine
        span.debug("Creating lsquic engine", .{});
        server.lsquic_engine = lsquic.lsquic_engine_new(
            lsquic.LSENG_SERVER,
            &server.lsquic_engine_api,
        ) orelse {
            span.err("Failed to create lsquic engine", .{});
            allocator.free(server.chain_genesis_hash);
            allocator.destroy(server);
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

        lsquic.lsquic_engine_destroy(self.lsquic_engine);
        ssl.SSL_CTX_free(self.ssl_ctx);

        self.socket.deinit();

        self.tick.deinit();
        self.loop.deinit();

        self.allocator.free(self.packets_in_buffer);
        self.allocator.free(self.chain_genesis_hash);
        self.allocator.free(self.alpn_id);

        self.allocator.destroy(self);

        span.debug("JamSnpServer deinitialization complete", .{});
    }

    pub fn listen(self: *JamSnpServer, addr: []const u8, port: u16) !void {
        const span = trace.span(.listen);
        defer span.deinit();
        span.debug("Started listening on {s}:{d}", .{ addr, port });

        try self.socket.bind(addr, port);
    }

    pub fn buildLoop(self: *@This()) !void {
        const span = trace.span(.build_loop);
        defer span.deinit();

        span.debug("Initializing event loop", .{});
        self.loop = try xev.Loop.init(.{});

        // Allocate the read buffer
        self.packets_in_buffer = try self.allocator.alloc(u8, 1500);

        // Set up tick timer if not already running
        self.tick.run(
            &self.loop,
            &self.tick_c,
            500,
            @This(),
            self,
            onTick,
        );

        // Set up packet receiving if not already running
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
        const span = trace.span(.run_tick);
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

    // Callbacks

    fn onTick(
        maybe_self: ?*@This(),
        xev_loop: *xev.Loop,
        xev_completion: *xev.Completion,
        xev_timer_error: xev.Timer.RunError!void,
    ) xev.CallbackAction {
        const span = trace.span(.on_server_tick);
        defer span.deinit();

        errdefer |err| {
            span.err("onTick failed with error: {s}", .{@errorName(err)});
            std.debug.panic("onTick failed with: {s}", .{@errorName(err)});
        }
        try xev_timer_error;

        const self = maybe_self.?;
        span.trace("Processing connections", .{});
        lsquic.lsquic_engine_process_conns(self.lsquic_engine);

        // Delta is in 1/1_000_000 so we divide by 1000 to get ms
        var delta: c_int = undefined;
        var timeout_in_ms: u64 = 100; // Default timeout

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
        // TODO: check teh rearm option her
        return .disarm;
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

        // Now change some bytes
        // xev_read_buffer.slice[6] = 0x66;

        const self = maybe_self.?;

        span.trace("Getting local address", .{});
        const local_address = self.socket.getLocalAddress() catch |err| {
            span.err("Failed to get local address: {s}", .{@errorName(err)});
            @panic("Failed to get local address");
        };
        span.trace("Local address: {}", .{local_address});

        span.trace("Passing packet to lsquic engine", .{});
        if (0 > lsquic.lsquic_engine_packet_in(
            self.lsquic_engine,
            xev_read_buffer.slice.ptr,
            bytes,
            @ptrCast(&local_address.any),
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

    pub fn processPacket(self: *JamSnpServer, packet: []const u8, peer_addr: std.posix.sockaddr, local_addr: std.posix.sockaddr) !void {
        const span = trace.span(.process_packet);
        defer span.deinit();
        span.debug("Processing incoming packet of {d} bytes", .{packet.len});
        span.trace("Packet data: {s}", .{std.fmt.fmtSliceHexLower(packet)});

        const result = lsquic.lsquic_engine_packet_in(
            self.lsquic_engine,
            packet.ptr,
            packet.len,
            &local_addr,
            &peer_addr,
            self, // peer_ctx
            0, // ecn
        );

        if (result < 0) {
            span.err("Packet processing failed with result: {d}", .{result});
            return error.PacketProcessingFailed;
        }

        span.trace("Packet processed successfully, result: {d}", .{result});

        // Process connections after receiving packet
        span.trace("Processing engine connections", .{});
        lsquic.lsquic_engine_process_conns(self.lsquic_engine);
        span.trace("Engine connections processed", .{});
    }

    pub const Connection = struct {
        lsquic_connection: *lsquic.lsquic_conn_t,
        server: *JamSnpServer,
        peer_addr: std.net.Address,

        fn onNewConn(
            ctx: ?*anyopaque,
            maybe_lsquic_connection: ?*lsquic.lsquic_conn_t,
        ) callconv(.C) ?*lsquic.lsquic_conn_ctx_t {
            const span = trace.span(.on_new_conn);
            defer span.deinit();
            span.debug("New connection callback triggered", .{});

            const server = @as(*JamSnpServer, @ptrCast(@alignCast(ctx)));

            // Get peer address from connection
            var local_addr: ?*const lsquic.struct_sockaddr = null;
            var peer_addr: ?*const lsquic.struct_sockaddr = null;
            _ = lsquic.lsquic_conn_get_sockaddr(maybe_lsquic_connection, &local_addr, &peer_addr);

            // Create connection context
            const connection = server.allocator.create(Connection) catch {
                span.err("Failed to allocate connection context", .{});
                return null;
            };

            connection.* = .{
                .lsquic_connection = maybe_lsquic_connection.?,
                .server = server,
                .peer_addr = std.net.Address.initPosix(@ptrCast(@alignCast(peer_addr.?))),
            };

            span.debug("Connection established successfully, peer: {}", .{connection.peer_addr});
            return @ptrCast(connection);
        }

        fn onConnClosed(maybe_lsquic_connection: ?*lsquic.lsquic_conn_t) callconv(.C) void {
            const span = trace.span(.on_conn_closed);
            defer span.deinit();
            span.debug("Connection closed callback triggered", .{});

            const conn_ctx = lsquic.lsquic_conn_get_ctx(maybe_lsquic_connection);
            if (conn_ctx == null) {
                span.debug("No connection context found", .{});
                return;
            }

            const connection: *Connection = @ptrCast(@alignCast(conn_ctx));

            // Clean up connection resources
            span.debug("Cleaning up connection resources", .{});
            lsquic.lsquic_conn_set_ctx(maybe_lsquic_connection, null);
            connection.server.allocator.destroy(connection);
            span.debug("Connection resources cleaned up", .{});
        }

        fn onHandshakeDone(conn: ?*lsquic.lsquic_conn_t, status: lsquic.lsquic_hsk_status) callconv(.C) void {
            const span = trace.span(.on_handshake_done);
            defer span.deinit();
            span.debug("Handshake completed with status: {}", .{status});

            const conn_ctx = lsquic.lsquic_conn_get_ctx(conn);
            if (conn_ctx == null) {
                span.debug("No connection context found", .{});
                return;
            }

            // const connection: *Connection = @ptrCast(@alignCast(conn_ctx));

            // Check if handshake succeeded
            if (status != lsquic.LSQ_HSK_OK) {
                span.err("Handshake failed with status: {}, closing connection", .{status});
                lsquic.lsquic_conn_close(conn);
                return;
            }

            // Handshake succeeded, can open UP streams now
            span.debug("Creating new stream after successful handshake", .{});
            lsquic.lsquic_conn_make_stream(conn);
            span.debug("Stream creation request sent", .{});
            // The stream will be set up in the onNewStream callback
        }
    };

    pub const Stream = struct {
        lsquic_stream: *lsquic.lsquic_stream_t,
        connection: *Connection,
        kind: ?u8, // Stream kind (UP or CE identifier)
        buffer: []u8,

        // Add any other stream-specific state here

        fn onNewStream(
            _: ?*anyopaque,
            maybe_lsquic_stream: ?*lsquic.lsquic_stream_t,
        ) callconv(.C) ?*lsquic.lsquic_stream_ctx_t {
            const span = trace.span(.on_new_stream);
            defer span.deinit();
            span.debug("New stream callback triggered", .{});

            // First get the connection this stream belongs to
            const lsquic_connection = lsquic.lsquic_stream_conn(maybe_lsquic_stream);
            const conn_ctx = lsquic.lsquic_conn_get_ctx(lsquic_connection);
            if (conn_ctx == null) {
                span.err("No connection context for stream", .{});
                return null;
            }

            const connection: *Connection = @ptrCast(@alignCast(conn_ctx));

            // Create stream context
            const stream = connection.server.allocator.create(Stream) catch {
                span.err("Failed to allocate stream context", .{});
                return null;
            };

            // Allocate buffer for reading from the stream
            const buffer = connection.server.allocator.alloc(u8, 4096) catch {
                span.err("Failed to allocate stream buffer", .{});
                connection.server.allocator.destroy(stream);
                return null;
            };
            span.debug("Allocated buffer of size 4096 bytes", .{});

            stream.* = .{
                .lsquic_stream = maybe_lsquic_stream.?,
                .connection = connection,
                .kind = null, // Will be set on first read
                .buffer = buffer,
            };

            // We need to read the first byte to determine the stream kind
            span.debug("Requesting read to determine stream kind", .{});
            _ = lsquic.lsquic_stream_wantread(maybe_lsquic_stream, 1);

            span.debug("Stream context created successfully", .{});
            return @ptrCast(stream);
        }

        fn onRead(
            maybe_lsquic_stream: ?*lsquic.lsquic_stream_t,
            maybe_stream_ctx: ?*lsquic.lsquic_stream_ctx_t,
        ) callconv(.C) void {
            const span = trace.span(.on_stream_read);
            defer span.deinit();
            span.debug("Stream read callback triggered", .{});

            if (maybe_stream_ctx == null) {
                span.err("No stream context in read callback", .{});
                return;
            }

            const stream: *Stream = @ptrCast(@alignCast(maybe_stream_ctx.?));
            span.debug("Stream read for stream with kind: {?}", .{stream.kind});

            // Add detailed read implementation here
            _ = maybe_lsquic_stream;
        }

        fn onWrite(
            maybe_lsquic_stream: ?*lsquic.lsquic_stream_t,
            maybe_stream_ctx: ?*lsquic.lsquic_stream_ctx_t,
        ) callconv(.C) void {
            const span = trace.span(.on_stream_write);
            defer span.deinit();
            span.debug("Stream write callback triggered", .{});

            if (maybe_stream_ctx == null) {
                span.err("No stream context in write callback", .{});
                return;
            }

            const stream: *Stream = @ptrCast(@alignCast(maybe_stream_ctx.?));
            span.debug("Stream write for stream with kind: {?}", .{stream.kind});

            // Add detailed write implementation here
            _ = maybe_lsquic_stream;
        }

        fn onClose(
            _: ?*lsquic.lsquic_stream_t,
            maybe_stream_ctx: ?*lsquic.lsquic_stream_ctx_t,
        ) callconv(.C) void {
            const span = trace.span(.on_stream_close);
            defer span.deinit();
            span.debug("Stream close callback triggered", .{});

            if (maybe_stream_ctx == null) {
                span.err("No stream context in close callback", .{});
                return;
            }

            const stream: *Stream = @ptrCast(@alignCast(maybe_stream_ctx.?));

            // Log stream details before cleanup
            if (stream.kind) |kind| {
                span.debug("Closing stream with kind: {}", .{kind});
            } else {
                span.debug("Closing stream with unknown kind", .{});
            }

            // Clean up stream resources
            span.debug("Freeing stream buffer of {d} bytes", .{stream.buffer.len});
            stream.connection.server.allocator.free(stream.buffer);
            span.debug("Destroying stream context", .{});
            stream.connection.server.allocator.destroy(stream);
            span.debug("Stream resources cleaned up", .{});
        }
    };

    fn getSslContext(ctx: ?*anyopaque, _: ?*const lsquic.struct_sockaddr) callconv(.C) ?*lsquic.struct_ssl_ctx_st {
        const span = trace.span(.get_ssl_context);
        defer span.deinit();
        span.trace("SSL context request", .{});
        const server: ?*JamSnpServer = @ptrCast(@alignCast(ctx));
        return @ptrCast(server.?.ssl_ctx);
    }

    fn lookupCertificate(
        ctx: ?*anyopaque,
        _: ?*const lsquic.struct_sockaddr,
        sni: ?[*:0]const u8,
    ) callconv(.C) ?*lsquic.struct_ssl_ctx_st {
        const span = trace.span(.lookup_certificate);
        defer span.deinit();

        if (sni) |server_name| {
            span.debug("Certificate lookup for SNI: {s}", .{server_name});
        } else {
            span.debug("Certificate lookup without SNI", .{});
        }

        const server: ?*JamSnpServer = @ptrCast(@alignCast(ctx));
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
        for (specs_slice, 0..) |spec, i| {
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
                _ = server.socket.sendTo(packet, dest_addr) catch |err| {
                    span.err("Failed to send packet: {s}", .{@errorName(err)});
                    continue;
                };
            }

            packets_sent += 1;
        }

        span.trace("Successfully sent {d}/{d} packets", .{ packets_sent, n_specs });
        return packets_sent;
    }
};
