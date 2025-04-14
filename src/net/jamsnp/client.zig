const std = @import("std");
const lsquic = @import("lsquic");
const ssl = @import("ssl");
const common = @import("common.zig");
const certificate_verifier = @import("certificate_verifier.zig");
const constants = @import("constants.zig");
const UdpSocket = @import("../udp_socket.zig").UdpSocket;
const xev = @import("xev");

// Import the tracing module
const trace = @import("../../tracing.zig").scoped(.network);

pub const JamSnpClient = struct {
    allocator: std.mem.Allocator,
    keypair: std.crypto.sign.Ed25519.KeyPair,
    socket: UdpSocket,
    alpn: []const u8,

    loop: xev.Loop = undefined,

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

    pub fn init(
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
        var socket = try UdpSocket.init();
        errdefer socket.deinit();

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

            .socket = socket,
            .alpn = alpn_id,

            .packets_in = xev.UDP.initFd(socket.socket),
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

        client.lsquic_engine_api.ea_packets_out_ctx = &client.socket;

        // Create lsquic engine
        span.debug("Creating lsquic engine", .{});
        client.*.lsquic_engine = lsquic.lsquic_engine_new(0, &client.*.lsquic_engine_api) orelse {
            span.err("lsquic engine creation failed", .{});
            return error.LsquicEngineCreationFailed;
        };

        // Build the client loop
        try client.buildLoop();

        span.debug("JamSnpClient initialization successful", .{});
        return client;
    }

    pub fn buildLoop(self: *@This()) !void {
        const span = trace.span(.build_loop);
        defer span.deinit();

        span.debug("Initializing event loop", .{});
        self.loop = try xev.Loop.init(.{});

        self.tick.run(
            &self.loop,
            &self.tick_c,
            500,
            @This(),
            self,
            onTick,
        );

        self.packets_in.read(
            &self.loop,
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
        const span = trace.span(.run_tick);
        defer span.deinit();
        span.trace("Running a single tick on JamSnpClient", .{});
        try self.loop.run(.no_wait);
    }

    pub fn runUntilDone(self: *@This()) !void {
        const span = trace.span(.run);
        defer span.deinit();
        span.debug("Starting JamSnpClient event loop", .{});
        try self.loop.run(.until_done);
        span.debug("Event loop completed", .{});
    }

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
        const local_address = self.socket.getLocalAddress() catch |err| {
            span.err("Failed to get local address: {s}", .{@errorName(err)});
            @panic("Failed to get local address");
        };
        span.trace("Local address: {}", .{local_address});

        span.trace("Passing packet to lsquic engine", .{});
        if (lsquic.lsquic_engine_packet_in(
            self.lsquic_engine,
            xev_read_buffer.slice.ptr,
            bytes,
            @ptrCast(&local_address.any),
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

    pub fn deinit(self: *JamSnpClient) void {
        const span = trace.span(.deinit);
        defer span.deinit();

        lsquic.lsquic_engine_destroy(self.lsquic_engine);
        ssl.SSL_CTX_free(self.ssl_ctx);

        self.socket.deinit();

        self.tick.deinit();
        self.loop.deinit();

        self.allocator.free(self.packet_in_buffer);
        self.allocator.free(self.chain_genesis_hash);
        self.allocator.free(self.alpn);

        self.allocator.destroy(self);

        span.debug("JamSnpClient deinitialization complete", .{});
    }

    pub fn connect(self: *JamSnpClient, peer_addr: []const u8, peer_port: u16) !void {
        const span = trace.span(.connect);
        defer span.deinit();
        span.debug("Connecting to {s}:{d}", .{ peer_addr, peer_port });

        // Bind to a local address (use any address)
        try self.socket.bind("::1", 0);

        // Get the local socket address after binding
        const local_endpoint = try self.socket.getLocalAddress();
        span.debug("Bound to local endpoint: {}", .{local_endpoint});

        // Parse peer address
        span.debug("Parsing peer address", .{});
        const peer_endpoint = try std.net.Address.parseIp(peer_addr, peer_port);
        span.debug("Peer endpoint: {}", .{peer_endpoint});

        // Create a connection
        span.trace("Creating connection context", .{});
        const connection = try self.allocator.create(Connection);
        connection.* = .{
            .lsquic_connection = undefined,
            .client = self,
            .endpoint = peer_endpoint,
        };

        // Create QUIC connection
        span.debug("Creating QUIC connection", .{});
        _ = lsquic.lsquic_engine_connect(
            self.lsquic_engine,
            lsquic.N_LSQVER, // Use default version
            @ptrCast(&local_endpoint.any),
            @ptrCast(&peer_endpoint.any),
            self.ssl_ctx, // peer_ctx
            @ptrCast(connection), // conn_ctx
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
    }

    pub const Connection = struct {
        lsquic_connection: *lsquic.lsquic_conn_t,
        endpoint: std.net.Address,
        client: *JamSnpClient,

        fn onNewConn(
            _: ?*anyopaque,
            maybe_lsquic_connection: ?*lsquic.lsquic_conn_t,
        ) callconv(.C) *lsquic.lsquic_conn_ctx_t {
            const span = trace.span(.on_new_conn);
            defer span.deinit();
            span.debug("New connection callback", .{});

            const conn_ctx = lsquic.lsquic_conn_get_ctx(maybe_lsquic_connection).?;
            const connection: *Connection = @alignCast(@ptrCast(conn_ctx));
            span.debug("Connected to {}", .{connection.endpoint});

            connection.lsquic_connection = maybe_lsquic_connection.?;
            span.debug("Connection initialized", .{});

            return @ptrCast(connection);
        }

        fn onConnClosed(maybe_lsquic_connection: ?*lsquic.lsquic_conn_t) callconv(.C) void {
            const span = trace.span(.on_conn_closed);
            defer span.deinit();
            span.debug("Connection closed callback", .{});

            const conn_ctx = lsquic.lsquic_conn_get_ctx(maybe_lsquic_connection).?;
            const conn: *Connection = @alignCast(@ptrCast(conn_ctx));

            span.debug("Clearing connection context", .{});
            lsquic.lsquic_conn_set_ctx(maybe_lsquic_connection, null);

            span.debug("Destroying connection", .{});
            conn.client.allocator.destroy(conn);
            span.debug("Connection cleanup complete", .{});
        }
    };

    /// Handle incoming packets
    pub fn processPacket(self: *JamSnpClient, packet: []const u8, peer_addr: std.posix.sockaddr, local_addr: std.posix.sockaddr) !void {
        const span = trace.span(.process_packet);
        defer span.deinit();
        span.debug("Processing incoming packet of {d} bytes", .{packet.len});
        span.trace("Packet data: {any}", .{std.fmt.fmtSliceHexLower(packet)});

        span.debug("Passing packet to lsquic engine", .{});
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
            span.err("lsquic_engine_packet_in failed with result: {d}", .{result});
            return error.PacketProcessingFailed;
        }

        // Process connection after receiving packet
        span.debug("Processing connections", .{});
        lsquic.lsquic_engine_process_conns(self.lsquic_engine);
        span.debug("Packet processing complete", .{});
    }

    fn getStreamInterface() lsquic.lsquic_stream_if {
        return .{
            // Mandatory callbacks
            .on_new_conn = Connection.onNewConn,
            .on_conn_closed = Connection.onConnClosed,
            .on_new_stream = Stream.onNewStream,
            .on_read = Stream.onRead,
            .on_write = Stream.onWrite,
            .on_close = Stream.onClose,
            // Optional callbacks
            // .on_hsk_done = null,
            // .on_goaway_received = null,
            // .on_new_token = null,
            // .on_sess_resume_info = null,
        };
    }

    const Stream = struct {
        lsquic_stream: *lsquic.lsquic_stream_t,
        connection: *Connection,

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
                .lsquic_stream = maybe_lsquic_stream.?,
                .connection = connection,
            };

            span.debug("Setting stream to want-write", .{});
            _ = lsquic.lsquic_stream_wantwrite(maybe_lsquic_stream, 1);
            span.debug("Stream initialization complete", .{});
            return @ptrCast(stream);
        }

        fn onRead(
            _: ?*lsquic.lsquic_stream_t,
            _: ?*lsquic.lsquic_stream_ctx_t,
        ) callconv(.C) void {
            const span = trace.span(.on_read);
            defer span.deinit();
            span.err("Unexpected read on uni-directional stream", .{});
            @panic("uni-directional streams should never receive data");
        }

        fn onWrite(
            maybe_lsquic_stream: ?*lsquic.lsquic_stream_t,
            maybe_stream: ?*lsquic.lsquic_stream_ctx_t,
        ) callconv(.C) void {
            const span = trace.span(.on_write);
            defer span.deinit();
            span.debug("Stream write callback", .{});

            const stream: *Stream = @alignCast(@ptrCast(maybe_stream.?));

            _ = stream;

            // if (stream.packet.size != lsquic.lsquic_stream_write(
            //     maybe_lsquic_stream,
            //     &stream.packet.data,
            //     stream.packet.size,
            // )) {
            //     @panic("failed to write complete packet to stream");
            // }

            span.debug("Flushing stream", .{});
            _ = lsquic.lsquic_stream_flush(maybe_lsquic_stream);

            span.debug("Disabling write interest", .{});
            _ = lsquic.lsquic_stream_wantwrite(maybe_lsquic_stream, 0);

            span.debug("Closing stream", .{});
            _ = lsquic.lsquic_stream_close(maybe_lsquic_stream);
            span.debug("Stream write handling complete", .{});
        }

        fn onClose(
            _: ?*lsquic.lsquic_stream_t,
            maybe_stream: ?*lsquic.lsquic_stream_ctx_t,
        ) callconv(.C) void {
            const span = trace.span(.on_stream_close);
            defer span.deinit();
            span.debug("Stream close callback", .{});

            const stream: *Stream = @alignCast(@ptrCast(maybe_stream.?));

            span.debug("Destroying stream", .{});
            stream.connection.client.allocator.destroy(stream);
            span.debug("Stream cleanup complete", .{});
        }
    };

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

        const socket = @as(*UdpSocket, @ptrCast(@alignCast(ctx)));
        const specs = specs_ptr.?[0..specs_len];

        var send_packets: c_int = 0;
        send_loop: for (specs, 0..) |spec, i| {
            const iov = spec.iov[0..spec.iovlen];
            span.trace("Processing packet spec {d} with {d} iovecs", .{ i, spec.iovlen });

            // Send the packet
            for (iov, 0..) |iovec, j| {
                const buf_ptr: [*]const u8 = @ptrCast(iovec.iov_base);
                const buf_len: usize = @intCast(iovec.iov_len);
                const buffer = buf_ptr[0..buf_len];

                const dest_address = std.net.Address.initPosix(@ptrCast(@alignCast(spec.dest_sa)));

                span.trace("Sending {} to {}", .{ std.fmt.fmtSliceHexLower(buffer), dest_address });

                _ = socket.sendTo(buffer, dest_address) catch |err| {
                    span.err("Failed to send packet: {}", .{err});
                    break :send_loop;
                };
                span.trace("Successfully sent iovec {d}", .{j});
            }
            send_packets += 1;
        }

        span.trace("Successfully sent {d}/{d} packet specs", .{ send_packets, specs_len });
        return send_packets;
    }
};
