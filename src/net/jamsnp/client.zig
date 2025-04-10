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

    // XEVState: Store the event loop and read buffer
    loop: xev.Loop = undefined,
    read_buffer: []u8 = undefined,
    tick_complete: xev.Completion = undefined,
    packets_in_complete: xev.Completion = undefined,
    udp_state: xev.UDP.State = undefined,

    packets_in_event: xev.UDP,
    tick_event: xev.Timer,

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
        const span = trace.span(.init);
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
        errdefer {
            span.debug("Cleaning up socket after error", .{});
            socket.deinit();
        }

        // Configure SSL context
        span.debug("Configuring SSL context", .{});
        const ssl_ctx = try common.configureSSLContext(
            allocator,
            keypair,
            chain_genesis_hash,
            true, // is_client
            is_builder,
        );
        errdefer {
            span.debug("Cleaning up SSL context after error", .{});
            ssl.SSL_CTX_free(ssl_ctx);
        }

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

        // Create ALPN identifier
        span.debug("Building ALPN identifier", .{});
        const alpn_id = try common.buildAlpnIdentifier(allocator, chain_genesis_hash, is_builder);
        span.debug("ALPN id: {s}", .{alpn_id});

        // Since lsquic references these settings
        // we need this to be on the heap with a lifetime which outlasts the
        // engine
        span.debug("Allocating client struct", .{});
        const client = try allocator.create(JamSnpClient);
        client.* = JamSnpClient{
            .allocator = allocator,
            .keypair = keypair,
            .socket = socket,
            .alpn = alpn_id,

            .lsquic_engine = undefined,
            .lsquic_engine_settings = engine_settings,
            .lsquic_engine_api = .{
                .ea_settings = &engine_settings,
                .ea_stream_if = &client.lsquic_stream_iterface,
                .ea_stream_if_ctx = null, // Will be set later
                .ea_packets_out = &sendPacketsOut,
                .ea_packets_out_ctx = null, // Will be set later
                .ea_get_ssl_ctx = &getSslContext,
                .ea_lookup_cert = null,
                .ea_cert_lu_ctx = null,
                .ea_alpn = @ptrCast(alpn_id.ptr),
            },
            .ssl_ctx = ssl_ctx,
            .chain_genesis_hash = try allocator.dupe(u8, chain_genesis_hash),
            .is_builder = is_builder,
            // TODO:
            .packets_in_event = xev.UDP.initFd(socket.socket),
            .tick_event = try xev.Timer.init(),
        };

        client.lsquic_engine_api.ea_packets_out_ctx = &client.socket;

        // Create lsquic engine
        span.debug("Creating lsquic engine", .{});
        client.*.lsquic_engine = lsquic.lsquic_engine_new(0, &client.*.lsquic_engine_api) orelse {
            span.err("lsquic engine creation failed", .{});
            return error.LsquicEngineCreationFailed;
        };

        // Build the loop
        try client.buildLoop();

        span.debug("JamSnpClient initialization successful", .{});
        return client;
    }

    pub fn buildLoop(self: *@This()) !void {
        const span = trace.span(.build_loop);
        defer span.deinit();
        span.debug("Building event loop for JamSnpClient", .{});

        span.debug("Initializing event loop", .{});
        self.loop = try xev.Loop.init(.{});

        // Allocate the read buffer
        self.read_buffer = try self.allocator.alloc(u8, 1500);

        // Set up tick timer if not already running
        self.tick_event.run(
            &self.loop,
            &self.tick_complete,
            500,
            @This(),
            self,
            onTick,
        );

        // Set up packet receiving if not already running
        self.packets_in_event.read(
            &self.loop,
            &self.packets_in_complete,
            &self.udp_state,
            .{ .slice = self.read_buffer },
            @This(),
            self,
            onPacketsIn,
        );

        span.debug("Event loop built successfully", .{});
    }

    pub fn runTick(self: *@This()) !void {
        const span = trace.span(.run_tick);
        defer span.deinit();
        span.debug("Running a single tick on JamSnpClient", .{});

        // Run a single tick
        span.debug("Running event loop for a single tick", .{});
        try self.loop.run(.once);
        span.debug("Event loop tick completed", .{});
    }

    pub fn runUntilDone(self: *@This()) !void {
        const span = trace.span(.run);
        defer span.deinit();
        span.debug("Starting JamSnpClient event loop", .{});

        span.debug("Starting event loop", .{});
        try self.loop.run(.until_done);
        span.debug("Event loop completed", .{});
    }

    fn onTick(
        maybe_self: ?*@This(),
        xev_loop: *xev.Loop,
        xev_completion: *xev.Completion,
        xev_timer_error: xev.Timer.RunError!void,
    ) xev.CallbackAction {
        const span = trace.span(.on_tick);
        defer span.deinit();

        errdefer |err| {
            span.err("onTick failed with error: {s}", .{@errorName(err)});
            std.debug.panic("onTick failed with: {s}", .{@errorName(err)});
        }
        try xev_timer_error;

        const self = maybe_self.?;
        span.debug("Processing connections", .{});
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

        span.debug("Scheduling next tick in {d}ms", .{timeout_in_ms});
        self.tick_event.run(
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
        xev_read_error: xev.ReadError!usize,
    ) xev.CallbackAction {
        const span = trace.span(.on_packets_in);
        defer span.deinit();

        errdefer |err| {
            span.err("onPacketsIn failed with error: {s}", .{@errorName(err)});
            std.debug.panic("onPacketsIn failed with: {s}", .{@errorName(err)});
        }

        const bytes = try xev_read_error;
        span.debug("Received {d} bytes from {}", .{ bytes, peer_address });
        span.trace("Packet data: {any}", .{std.fmt.fmtSliceHexLower(xev_read_buffer.slice[0..bytes])});

        const self = maybe_self.?;

        span.debug("Getting local address", .{});
        const local_address = self.socket.getLocalAddress() catch |err| {
            span.err("Failed to get local address: {s}", .{@errorName(err)});
            @panic("Failed to get local address");
        };
        span.trace("Local address: {}", .{local_address});

        span.debug("Passing packet to lsquic engine", .{});
        if (0 > lsquic.lsquic_engine_packet_in(
            self.lsquic_engine,
            xev_read_buffer.slice.ptr,
            bytes,
            @ptrCast(&local_address.any),
            @ptrCast(&peer_address.any),
            self,
            0,
        )) {
            span.err("lsquic_engine_packet_in failed", .{});
            @panic("lsquic_engine_packet_in failed");
        }

        span.debug("Successfully processed incoming packet", .{});
        return .rearm;
    }

    pub fn deinit(self: *JamSnpClient) void {
        const span = trace.span(.deinit);
        defer span.deinit();

        lsquic.lsquic_engine_destroy(self.lsquic_engine);
        ssl.SSL_CTX_free(self.ssl_ctx);

        self.socket.deinit();

        self.loop.deinit();
        self.allocator.free(self.read_buffer);

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
        span.debug("Binding to local address ::1:0", .{});
        try self.socket.bind("::1", 0);

        // Get the local socket address after binding
        span.debug("Getting local address after binding", .{});
        const local_endpoint = try self.socket.getLocalAddress();
        span.trace("Local endpoint: {}", .{local_endpoint});

        // Parse peer address
        span.debug("Parsing peer address", .{});
        const peer_endpoint = try std.net.Address.parseIp(peer_addr, peer_port);
        span.trace("Peer endpoint: {}", .{peer_endpoint});

        // Create a connection
        span.debug("Creating connection context", .{});
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
            "e123456", // hostname for SNI
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
        const span = trace.span(.send_packets_out);
        defer span.deinit();
        span.debug("Sending {d} packet specs", .{specs_len});

        const socket = @as(*UdpSocket, @ptrCast(@alignCast(ctx)));
        const specs = specs_ptr.?[0..specs_len];

        var send_packets: c_int = 0;
        send_loop: for (specs, 0..) |spec, i| {
            const iov = spec.iov[0..spec.iovlen];
            span.debug("Processing packet spec {d} with {d} iovecs", .{ i, spec.iovlen });

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
                span.debug("Successfully sent iovec {d}", .{j});
            }
            send_packets += 1;
        }

        span.debug("Successfully sent {d}/{d} packet specs", .{ send_packets, specs_len });
        return send_packets;
    }
};
