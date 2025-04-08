const std = @import("std");
const lsquic = @import("lsquic");
const ssl = @import("ssl");
const common = @import("common.zig");
const certificate_verifier = @import("certificate_verifier.zig");
const constants = @import("constants.zig");
const UdpSocket = @import("../udp_socket.zig").UdpSocket;

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
        // Initialize lsquic globally (if not already initialized)
        if (lsquic.lsquic_global_init(lsquic.LSQUIC_GLOBAL_SERVER) != 0) {
            return error.LsquicInitFailed;
        }

        // Create UDP socket
        var socket = try UdpSocket.init();
        errdefer socket.deinit();

        // Configure SSL context
        const ssl_ctx = try common.configureSSLContext(
            keypair,
            chain_genesis_hash,
            false, // is_client
            false, // is_builder (not applicable for server)
        );
        errdefer ssl.SSL_CTX_free(ssl_ctx);

        // Set up certificate verification
        ssl.SSL_CTX_set_cert_verify_callback(ssl_ctx, certificate_verifier.verifyCertificate, null);

        // Allocate the server object on the heap to ensure settings lifetime
        const server = try allocator.create(JamSnpServer);
        errdefer allocator.destroy(server);

        // Initialize lsquic engine settings
        var engine_settings: lsquic.lsquic_engine_settings = undefined;
        lsquic.lsquic_engine_init_settings(&engine_settings, lsquic.LSENG_SERVER);
        engine_settings.es_versions = 1 << lsquic.LSQVER_ID29; // IETF QUIC v1

        // Initialize server structure first
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

        // Set up engine API with the server object as context
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
        server.lsquic_engine = lsquic.lsquic_engine_new(lsquic.LSENG_SERVER, &server.lsquic_engine_api) orelse {
            allocator.free(server.chain_genesis_hash);
            allocator.destroy(server);
            return error.LsquicEngineCreationFailed;
        };

        return server;
    }

    pub fn deinit(self: *JamSnpServer) void {
        lsquic.lsquic_engine_destroy(self.lsquic_engine);
        ssl.SSL_CTX_free(self.ssl_ctx);
        self.socket.deinit();
        self.allocator.free(self.chain_genesis_hash);
        // Global cleanup should be done at program exit
        self.allocator.destroy(self);
    }

    pub fn listen(self: *JamSnpServer, addr: []const u8, port: u16) !void {
        try self.socket.bind(addr, port);

        // TODO: process incoming packets via processPacket
    }

    pub fn processPacket(self: *JamSnpServer, packet: []const u8, peer_addr: std.posix.sockaddr, local_addr: std.posix.sockaddr) !void {
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
            return error.PacketProcessingFailed;
        }

        // Process connections after receiving packet
        lsquic.lsquic_engine_process_conns(self.lsquic_engine);
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
            const server = @as(*JamSnpServer, @ptrCast(@alignCast(ctx)));

            // Get peer address from connection
            var local_addr: ?*const lsquic.struct_sockaddr = null;
            var peer_addr: ?*const lsquic.struct_sockaddr = null;
            _ = lsquic.lsquic_conn_get_sockaddr(maybe_lsquic_connection, &local_addr, &peer_addr);

            // Create connection context
            const connection = server.allocator.create(Connection) catch {
                return null;
            };

            connection.* = .{
                .lsquic_connection = maybe_lsquic_connection.?,
                .server = server,
                .peer_addr = std.net.Address.initPosix(@ptrCast(@alignCast(peer_addr.?))),
            };

            std.log.debug("Connection: onNewConn called", .{});

            return @ptrCast(connection);
        }

        fn onConnClosed(maybe_lsquic_connection: ?*lsquic.lsquic_conn_t) callconv(.C) void {
            const conn_ctx = lsquic.lsquic_conn_get_ctx(maybe_lsquic_connection);
            if (conn_ctx == null) return;

            const connection: *Connection = @ptrCast(@alignCast(conn_ctx));

            std.log.debug("Connection: onConnClosed called", .{});

            // Clean up connection resources
            lsquic.lsquic_conn_set_ctx(maybe_lsquic_connection, null);
            connection.server.allocator.destroy(connection);
        }

        fn onHandshakeDone(conn: ?*lsquic.lsquic_conn_t, status: lsquic.lsquic_hsk_status) callconv(.C) void {
            const conn_ctx = lsquic.lsquic_conn_get_ctx(conn);
            if (conn_ctx == null) return;

            // const connection: *Connection = @ptrCast(@alignCast(conn_ctx));

            std.log.debug("Connection: onHandshakeDone called with status: {}", .{status});

            // Check if handshake succeeded
            if (status != lsquic.LSQ_HSK_OK) {
                std.log.err("Handshake failed, closing connection", .{});
                lsquic.lsquic_conn_close(conn);
                return;
            }

            // Handshake succeeded, can open UP streams now

            lsquic.lsquic_conn_make_stream(conn);
            std.log.debug("Created new stream after handshake", .{});
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
            std.log.debug("Stream: onNewStream called", .{});

            // First get the connection this stream belongs to
            const lsquic_connection = lsquic.lsquic_stream_conn(maybe_lsquic_stream);
            const conn_ctx = lsquic.lsquic_conn_get_ctx(lsquic_connection);
            if (conn_ctx == null) return null;

            const connection: *Connection = @ptrCast(@alignCast(conn_ctx));

            // Create stream context
            const stream = connection.server.allocator.create(Stream) catch {
                std.log.err("Failed to allocate stream context", .{});
                return null;
            };

            // Allocate buffer for reading from the stream
            const buffer = connection.server.allocator.alloc(u8, 4096) catch {
                std.log.err("Failed to allocate stream buffer", .{});
                connection.server.allocator.destroy(stream);
                return null;
            };

            stream.* = .{
                .lsquic_stream = maybe_lsquic_stream.?,
                .connection = connection,
                .kind = null, // Will be set on first read
                .buffer = buffer,
            };

            // We need to read the first byte to determine the stream kind
            _ = lsquic.lsquic_stream_wantread(maybe_lsquic_stream, 1);

            return @ptrCast(stream);
        }

        fn onRead(
            maybe_lsquic_stream: ?*lsquic.lsquic_stream_t,
            maybe_stream_ctx: ?*lsquic.lsquic_stream_ctx_t,
        ) callconv(.C) void {
            std.log.debug("Stream: onRead called", .{});
            _ = maybe_lsquic_stream;
            _ = maybe_stream_ctx;
        }

        fn onWrite(
            maybe_lsquic_stream: ?*lsquic.lsquic_stream_t,
            maybe_stream_ctx: ?*lsquic.lsquic_stream_ctx_t,
        ) callconv(.C) void {
            std.log.debug("Stream: onWrite called", .{});
            _ = maybe_lsquic_stream;
            _ = maybe_stream_ctx;
        }

        fn onClose(
            _: ?*lsquic.lsquic_stream_t,
            maybe_stream_ctx: ?*lsquic.lsquic_stream_ctx_t,
        ) callconv(.C) void {
            std.log.debug("Stream: onClose called", .{});

            const stream: *Stream = @ptrCast(@alignCast(maybe_stream_ctx.?));

            // Log stream details before cleanup
            if (stream.kind) |kind| {
                std.log.debug("Stream: Closing stream with kind: {}", .{kind});
            } else {
                std.log.debug("Stream: Closing stream with unknown kind", .{});
            }

            // Clean up stream resources
            stream.connection.server.allocator.free(stream.buffer);
            stream.connection.server.allocator.destroy(stream);
        }
    };

    fn getSslContext(peer_ctx: ?*anyopaque, _: ?*const lsquic.struct_sockaddr) callconv(.C) ?*lsquic.struct_ssl_ctx_st {
        return @ptrCast(peer_ctx.?);
    }

    fn lookupCertificate(
        cert_lu_ctx: ?*anyopaque,
        _: ?*const lsquic.struct_sockaddr,
        sni: ?[*:0]const u8,
    ) callconv(.C) ?*lsquic.struct_ssl_ctx_st {
        _ = sni;

        return @ptrCast(cert_lu_ctx.?);
    }

    fn sendPacketsOut(
        ctx: ?*anyopaque,
        specs: ?[*]const lsquic.lsquic_out_spec,
        n_specs: c_uint,
    ) callconv(.C) c_int {
        _ = ctx;
        _ = specs;

        std.log.debug("Sending {} packet(s)", .{n_specs});
        return @intCast(n_specs);
    }
};
