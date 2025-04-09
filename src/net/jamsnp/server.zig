const std = @import("std");
const lsquic = @import("lsquic");
const ssl = @import("ssl");
const common = @import("common.zig");
const certificate_verifier = @import("certificate_verifier.zig");
const constants = @import("constants.zig");
const UdpSocket = @import("../udp_socket.zig").UdpSocket;

// Add tracing module import
const trace = @import("../../tracing.zig").scoped(.network);

pub const JamSnpServer = struct {
    allocator: std.mem.Allocator,
    keypair: std.crypto.sign.Ed25519.KeyPair,
    socket: UdpSocket,

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
        chain_genesis_hash: []const u8,
        allow_builders: bool,
    ) !*JamSnpServer {
        const span = trace.span(.init);
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
            false, // is_client
            false, // is_builder (not applicable for server)
        );
        errdefer {
            span.debug("Cleaning up SSL context after error", .{});
            ssl.SSL_CTX_free(ssl_ctx);
        }

        // Set up certificate verification
        span.debug("Setting up certificate verification", .{});
        ssl.SSL_CTX_set_cert_verify_callback(ssl_ctx, certificate_verifier.verifyCertificate, null);

        // Allocate the server object on the heap to ensure settings lifetime
        span.debug("Allocating server object", .{});
        const server = try allocator.create(JamSnpServer);
        errdefer {
            span.debug("Cleaning up server object after error", .{});
            allocator.destroy(server);
        }

        // Initialize lsquic engine settings
        span.debug("Initializing engine settings", .{});
        var engine_settings: lsquic.lsquic_engine_settings = undefined;
        lsquic.lsquic_engine_init_settings(&engine_settings, lsquic.LSENG_SERVER);
        engine_settings.es_versions = 1 << lsquic.LSQVER_ID29; // IETF QUIC v1
        span.trace("Engine settings: es_versions={d}", .{engine_settings.es_versions});

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
            .chain_genesis_hash = try allocator.dupe(u8, chain_genesis_hash),
            .allow_builders = allow_builders,
        };
        span.trace("Chain genesis hash length: {d} bytes", .{chain_genesis_hash.len});
        span.trace("Chain genesis hash: {s}", .{std.fmt.fmtSliceHexLower(chain_genesis_hash)});

        // Set up engine API with the server object as context
        span.debug("Setting up engine API", .{});
        server.lsquic_engine_api = lsquic.lsquic_engine_api{
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
        server.lsquic_engine = lsquic.lsquic_engine_new(lsquic.LSENG_SERVER, &server.lsquic_engine_api) orelse {
            span.err("Failed to create lsquic engine", .{});
            allocator.free(server.chain_genesis_hash);
            allocator.destroy(server);
            return error.LsquicEngineCreationFailed;
        };

        span.debug("Successfully initialized JamSnpServer", .{});
        return server;
    }

    pub fn deinit(self: *JamSnpServer) void {
        const span = trace.span(.deinit);
        defer span.deinit();
        span.debug("Deinitializing JamSnpServer", .{});

        span.debug("Destroying lsquic engine", .{});
        lsquic.lsquic_engine_destroy(self.lsquic_engine);

        span.debug("Freeing SSL context", .{});
        ssl.SSL_CTX_free(self.ssl_ctx);

        span.debug("Deinitializing socket", .{});
        self.socket.deinit();

        span.debug("Freeing chain genesis hash", .{});
        self.allocator.free(self.chain_genesis_hash);

        span.debug("Freeing server object", .{});
        self.allocator.destroy(self);

        span.debug("JamSnpServer deinitialized successfully", .{});
    }

    pub fn listen(self: *JamSnpServer, addr: []const u8, port: u16) !void {
        const span = trace.span(.listen);
        defer span.deinit();
        span.debug("Starting server listen on {s}:{d}", .{ addr, port });

        try self.socket.bind(addr, port);
        span.debug("Successfully bound to {s}:{d}", .{ addr, port });

        // TODO: process incoming packets via processPacket
        span.debug("Server listening successfully", .{});
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

        span.debug("Packet processed successfully, result: {d}", .{result});

        // Process connections after receiving packet
        span.debug("Processing engine connections", .{});
        lsquic.lsquic_engine_process_conns(self.lsquic_engine);
        span.debug("Engine connections processed", .{});
    }

    pub const Connection = struct {
        lsquic_connection: *lsquic.lsquic_conn_t,
        server: *JamSnpServer,
        peer_addr: std.net.Address,

        // Add any additional connection-specific state here

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

            span.debug("Connection established successfully", .{});
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

    fn getSslContext(peer_ctx: ?*anyopaque, _: ?*const lsquic.struct_sockaddr) callconv(.C) ?*lsquic.struct_ssl_ctx_st {
        const span = trace.span(.get_ssl_context);
        defer span.deinit();
        span.debug("SSL context request", .{});
        return @ptrCast(peer_ctx.?);
    }

    fn lookupCertificate(
        cert_lu_ctx: ?*anyopaque,
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

        return @ptrCast(cert_lu_ctx.?);
    }

    fn sendPacketsOut(
        ctx: ?*anyopaque,
        specs: ?[*]const lsquic.lsquic_out_spec,
        n_specs: c_uint,
    ) callconv(.C) c_int {
        const span = trace.span(.send_packets);
        defer span.deinit();
        span.debug("Sending {d} packet(s)", .{n_specs});

        _ = specs;
        _ = ctx;

        return @intCast(n_specs);
    }
};
