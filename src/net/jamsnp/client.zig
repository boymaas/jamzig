const std = @import("std");
const lsquic = @import("lsquic");
const ssl = @import("ssl");
const common = @import("common.zig");
const certificate_verifier = @import("certificate_verifier.zig");
const constants = @import("constants.zig");
const UdpSocket = @import("../udp_socket.zig").UdpSocket;

pub const JamSnpClient = struct {
    allocator: std.mem.Allocator,
    keypair: std.crypto.sign.Ed25519.KeyPair,
    socket: UdpSocket,

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
        // Initialize lsquic globally (if not already initialized)
        if (lsquic.lsquic_global_init(lsquic.LSQUIC_GLOBAL_CLIENT) != 0) {
            return error.LsquicInitFailed;
        }

        // Create UDP socket
        var socket = try UdpSocket.init();
        errdefer socket.deinit();

        // Configure SSL context
        const ssl_ctx = try common.configureSSLContext(
            keypair,
            chain_genesis_hash,
            true, // is_client
            is_builder,
        );
        errdefer ssl.SSL_CTX_free(ssl_ctx);

        // Set up certificate verification
        ssl.SSL_CTX_set_cert_verify_callback(ssl_ctx, certificate_verifier.verifyCertificate, null);

        // Initialize lsquic engine settings
        var engine_settings: lsquic.lsquic_engine_settings = .{};
        lsquic.lsquic_engine_init_settings(&engine_settings, 0);
        engine_settings.es_versions = 1 << lsquic.LSQVER_ID29; // IETF QUIC v1

        // Create ALPN identifier
        var alpn_buffer: [64:0]u8 = undefined;
        var alpn_id = try common.buildAlpnIdentifier(&alpn_buffer, chain_genesis_hash, is_builder);

        // Since lsquic references these settings
        // we need this to be on the heap with a lifetime which outlasts the
        // engine
        const client = try allocator.create(JamSnpClient);
        client.* = JamSnpClient{
            .allocator = allocator,
            .keypair = keypair,
            .socket = socket,
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
                .ea_alpn = @ptrCast(&alpn_id), // FIXME: we should own this memory
            },
            .ssl_ctx = ssl_ctx,
            .chain_genesis_hash = try allocator.dupe(u8, chain_genesis_hash),
            .is_builder = is_builder,
            // TODO:
            // .packets_in_event = xev.UDP.initFd(self.socket.internal),
            // .tick_event = try xev.Timer.init(),
        };

        // Create lsquic engine
        client.*.lsquic_engine = lsquic.lsquic_engine_new(0, &client.*.lsquic_engine_api) orelse {
            return error.LsquicEngineCreationFailed;
        };

        return client;
    }

    pub fn deinit(self: *JamSnpClient) void {
        lsquic.lsquic_engine_destroy(self.lsquic_engine);
        ssl.SSL_CTX_free(self.ssl_ctx);
        self.socket.deinit();
        self.allocator.free(self.chain_genesis_hash);
        // Global cleanup should be done at program exit
        self.allocator.destroy(self);
    }

    pub fn connect(self: *JamSnpClient, peer_addr: []const u8, peer_port: u16) !void {
        // Bind to a local address (use any address)
        try self.socket.bind("::1", 0);

        // Get the local socket address after binding
        const local_endpoint = try self.socket.getLocalAddress();

        // Parse peer address
        const peer_endpoint = try std.net.Address.parseIp(peer_addr, peer_port);

        // Create a connection
        const connection = try self.allocator.create(Connection);
        connection.* = .{
            .lsquic_connection = undefined,
            .client = self,
            .endpoint = peer_endpoint,
        };

        // Create QUIC connection
        _ = lsquic.lsquic_engine_connect(
            self.lsquic_engine,
            lsquic.N_LSQVER, // Use default version
            @ptrCast(&local_endpoint.any),
            @ptrCast(&peer_endpoint.any),
            self.ssl_ctx, // peer_ctx
            @ptrCast(connection), // conn_ctx
            null, // hostname for SNI
            0, // base_plpmtu - use default
            null,
            0, // session resumption
            null,
            0, // token
        ) orelse {
            return error.ConnectionFailed;
        };

        // Process connection establishment
        // lsquic.lsquic_engine_process_conns(self.lsquic_engine);
    }

    pub const Connection = struct {
        lsquic_connection: *lsquic.lsquic_conn_t,
        endpoint: std.net.Address,
        client: *JamSnpClient,

        fn onNewConn(
            _: ?*anyopaque,
            maybe_lsquic_connection: ?*lsquic.lsquic_conn_t,
        ) callconv(.C) *lsquic.lsquic_conn_ctx_t {
            const conn_ctx = lsquic.lsquic_conn_get_ctx(maybe_lsquic_connection).?;
            const self: *Connection = @alignCast(@ptrCast(conn_ctx));

            self.lsquic_connection = maybe_lsquic_connection.?;

            return @ptrCast(self);
        }

        fn onConnClosed(maybe_lsquic_connection: ?*lsquic.lsquic_conn_t) callconv(.C) void {
            const conn_ctx = lsquic.lsquic_conn_get_ctx(maybe_lsquic_connection).?;
            const conn: *Connection = @alignCast(@ptrCast(conn_ctx));

            lsquic.lsquic_conn_set_ctx(maybe_lsquic_connection, null);
            conn.client.allocator.destroy(conn);
        }
    };

    /// Handle incoming packets
    pub fn processPacket(self: *JamSnpClient, packet: []const u8, peer_addr: std.posix.sockaddr, local_addr: std.posix.sockaddr) !void {
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

        // Process connection after receiving packet
        lsquic.lsquic_engine_process_conns(self.lsquic_engine);
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
            const lsquic_connection = lsquic.lsquic_stream_conn(maybe_lsquic_stream);
            const conn_ctx = lsquic.lsquic_conn_get_ctx(lsquic_connection).?;
            const connection: *Connection = @alignCast(@ptrCast(conn_ctx));

            const stream = connection.client.allocator.create(Stream) catch
                @panic("OutOfMemory");
            stream.* = .{
                .lsquic_stream = maybe_lsquic_stream.?,
                .connection = connection,
            };

            _ = lsquic.lsquic_stream_wantwrite(maybe_lsquic_stream, 1);
            return @ptrCast(stream);
        }

        fn onRead(
            _: ?*lsquic.lsquic_stream_t,
            _: ?*lsquic.lsquic_stream_ctx_t,
        ) callconv(.C) void {
            @panic("uni-directional streams should never receive data");
        }

        fn onWrite(
            maybe_lsquic_stream: ?*lsquic.lsquic_stream_t,
            maybe_stream: ?*lsquic.lsquic_stream_ctx_t,
        ) callconv(.C) void {
            const stream: *Stream = @alignCast(@ptrCast(maybe_stream.?));

            _ = stream;

            // if (stream.packet.size != lsquic.lsquic_stream_write(
            //     maybe_lsquic_stream,
            //     &stream.packet.data,
            //     stream.packet.size,
            // )) {
            //     @panic("failed to write complete packet to stream");
            // }

            _ = lsquic.lsquic_stream_flush(maybe_lsquic_stream);
            _ = lsquic.lsquic_stream_wantwrite(maybe_lsquic_stream, 0);
            _ = lsquic.lsquic_stream_close(maybe_lsquic_stream);
        }

        fn onClose(
            _: ?*lsquic.lsquic_stream_t,
            maybe_stream: ?*lsquic.lsquic_stream_ctx_t,
        ) callconv(.C) void {
            const stream: *Stream = @alignCast(@ptrCast(maybe_stream.?));
            stream.connection.client.allocator.destroy(stream);
        }
    };

    fn getSslContext(peer_ctx: ?*anyopaque, _: ?*const lsquic.struct_sockaddr) callconv(.C) ?*lsquic.struct_ssl_ctx_st {
        return @ptrCast(peer_ctx.?);
    }

    fn sendPacketsOut(
        ctx: ?*anyopaque,
        specs: ?[*]const lsquic.lsquic_out_spec,
        n_specs: c_uint,
    ) callconv(.C) c_int {
        const self = @as(*JamSnpClient, @ptrCast(@alignCast(ctx)));
        var count: c_uint = 0;

        for (0..n_specs) |i| {
            const spec = specs.?[i];

            // Convert iovec to a slice
            var total_size: usize = 0;
            for (0..spec.iovlen) |j| {
                total_size += spec.iov.?[j].iov_len;
            }

            var buffer = self.allocator.alloc(u8, total_size) catch break;
            defer self.allocator.free(buffer);

            var offset: usize = 0;
            for (0..spec.iovlen) |j| {
                const iov = spec.iov.?[j];
                @memcpy(buffer[offset .. offset + iov.iov_len], @as([*]const u8, @ptrCast(iov.iov_base))[0..iov.iov_len]);
                offset += iov.iov_len;
            }

            // Send the packet
            _ = self.socket.sendToSockAddr(buffer, @ptrCast(@alignCast(spec.dest_sa))) catch break;
            count += 1;
        }

        return @intCast(count);
    }
};
