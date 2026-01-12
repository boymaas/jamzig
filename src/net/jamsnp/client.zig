
const std = @import("std");
const uuid = @import("uuid");
const lsquic = @import("lsquic");
const ssl = @import("ssl");
const common = @import("common.zig");
const certificate_verifier = @import("certificate_verifier.zig");
const constants = @import("constants.zig");
const network = @import("network");
const xev = @import("xev");

const shared = @import("shared_types.zig");
const Connection = @import("connection.zig").Connection;
const Stream = @import("stream.zig").Stream;

const toSocketAddress = @import("../ext.zig").toSocketAddress;
const trace = @import("tracing").scoped(.network);

pub const ConnectionId = shared.ConnectionId;
pub const StreamId = shared.StreamId;
pub const EventType = shared.CallbackType; // Use renamed type
pub const CallbackHandler = shared.CallbackHandler;


pub const JamSnpClient = struct {
    /// Note on Stream Creation Callbacks and Timeouts:
    ///
    /// Calling `Connection.createStream()` successfully queues a request with lsquic via
    /// `lsquic_conn_make_stream()`. The corresponding `Stream.onStreamCreated` callback (which
    /// triggers the user's `StreamCreatedCallbackFn`) might be delayed if the connection
    /// handshake is not yet complete or if stream limits imposed by the peer have been reached.
    ///
    /// While lsquic documentation doesn't provide a single, explicit guarantee that *every*
    /// successful `lsquic_conn_make_stream()` call will *always* result in *either*
    /// `on_new_stream` or a connection closure/error callback, the library's documented
    /// behavior strongly implies this is the case. Critical errors that prevent stream
    /// creation or affect the connection typically lead to connection termination,
    /// which triggers the `Connection.onConnectionClosed` callback (`ConnectionClosedCallbackFn`).
    ///
    /// **Practical Implication:** Applications should primarily rely on the
    /// `ConnectionClosedCallbackFn` as the signal that any pending stream creation
    /// requests on that connection have implicitly failed if the `StreamCreatedCallbackFn`
    /// was not received.
    ///
    /// Explicit application-level timeouts for stream creation are generally NOT implemented
    /// in this client due to the added complexity. They should only be considered if
    /// application logic requires absolute certainty of success/failure reporting within a
    /// specific timeframe, potentially as a fallback for rare, undocumented edge cases.
    allocator: std.mem.Allocator,
    keypair: std.crypto.sign.Ed25519.KeyPair,
    socket: network.Socket,
    alpn: []const u8,

    /// Bookkeeping for connections and streams
    connections: std.AutoHashMap(ConnectionId, *Connection(JamSnpClient)), // Use refactored type
    streams: std.AutoHashMap(StreamId, *Stream(JamSnpClient)), // Keep internal Stream struct for now

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
        .on_new_conn = Connection(JamSnpClient).onClientConnectionCreated,
        .on_conn_closed = Connection(JamSnpClient).onConnectionClosed,
        .on_new_stream = Stream(JamSnpClient).onStreamCreated,
        .on_read = Stream(JamSnpClient).onStreamRead,
        .on_write = Stream(JamSnpClient).onStreamWrite,
        .on_close = Stream(JamSnpClient).onStreamClosed,
    },

    ssl_ctx: *ssl.SSL_CTX,
    chain_genesis_hash: []const u8,

    is_builder: bool,

    callback_handlers: [@typeInfo(EventType).@"enum".fields.len]CallbackHandler = [_]CallbackHandler{.{ .callback = null, .context = null }} ** @typeInfo(EventType).@"enum".fields.len,

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
        const span = trace.span(@src(), .init_client);
        defer span.deinit();
        span.debug("Initializing JamSnpClient", .{});

        if (lsquic.lsquic_global_init(lsquic.LSQUIC_GLOBAL_CLIENT) != 0) {
            span.err("lsquic global initialization failed", .{});
            return error.LsquicInitFailed;
        }

        span.debug("Creating UDP socket", .{});
        var socket = try network.Socket.create(.ipv6, .udp);
        errdefer socket.close();

        const alpn_id = try common.buildAlpnIdentifier(allocator, chain_genesis_hash, is_builder);
        errdefer allocator.free(alpn_id);

        const ssl_ctx = try common.configureSSLContext(
            allocator,
            keypair,
            chain_genesis_hash,
            true, // is_client
            is_builder,
            alpn_id,
        );
        errdefer ssl.SSL_CTX_free(ssl_ctx);

        span.debug("Setting up certificate verification", .{});
        ssl.SSL_CTX_set_cert_verify_callback(ssl_ctx, certificate_verifier.verifyCertificate, null);

        var engine_settings: lsquic.lsquic_engine_settings = .{};
        lsquic.lsquic_engine_init_settings(&engine_settings, 0);
        engine_settings.es_versions = 1 << lsquic.LSQVER_ID29; // IETF QUIC v1

        var error_buffer: [128]u8 = undefined;
        if (lsquic.lsquic_engine_check_settings(
            &engine_settings,
            0,
            @ptrCast(&error_buffer),
            @sizeOf(@TypeOf(error_buffer)),
        ) != 0) {
            span.err("Client engine settings problem: {s}", .{error_buffer});
            return error.LsquicEngineSettingsInvalid;
        }

        const client = try allocator.create(JamSnpClient);
        errdefer client.deinit(); // Can now use errdefer safely

        client.* = JamSnpClient{
            .allocator = allocator,
            .keypair = keypair,
            .chain_genesis_hash = try allocator.dupe(u8, chain_genesis_hash),
            .is_builder = is_builder,
            .connections = std.AutoHashMap(ConnectionId, *Connection(JamSnpClient)).init(allocator), // Use refactored type
            .streams = std.AutoHashMap(StreamId, *Stream(JamSnpClient)).init(allocator), // Keep internal Stream
            .socket = socket,
            .alpn = alpn_id,

            .packets_in = xev.UDP.initFd(socket.internal),
            .packet_in_buffer = try allocator.alloc(u8, 1500),
            .tick = try xev.Timer.init(),
            .lsquic_engine = undefined, // Initialize later
            .lsquic_engine_settings = engine_settings,
            .lsquic_engine_api = .{
                .ea_settings = &client.lsquic_engine_settings, // Use client's field
                .ea_stream_if = &client.lsquic_stream_iterface, // Use client's field
                .ea_stream_if_ctx = null,
                .ea_packets_out = &sendPacketsOut,
                .ea_packets_out_ctx = client, // Pass client itself as context
                .ea_get_ssl_ctx = &getSslContext,
                .ea_lookup_cert = null,
                .ea_cert_lu_ctx = null,
                .ea_alpn = @ptrCast(alpn_id.ptr),
            },
            .ssl_ctx = ssl_ctx,
            .callback_handlers = [_]CallbackHandler{.{ .callback = null, .context = null }} ** @typeInfo(EventType).@"enum".fields.len,
        };

        span.debug("Creating LSQUIC engine", .{});
        client.lsquic_engine = lsquic.lsquic_engine_new(0, &client.lsquic_engine_api) orelse {
            span.err("lsquic engine creation failed", .{});
            return error.LsquicEngineCreationFailed;
        };

        span.debug("JamSnpClient initialization successful", .{});
        return client;
    }

    pub fn initLoop(self: *@This()) !void {
        const loop = try self.allocator.create(xev.Loop);
        errdefer self.allocator.destroy(loop);
        loop.* = try xev.Loop.init(.{});
        self.loop = loop;
        self.loop_owned = true;
        self.buildLoop();
    }

    pub fn attachToLoop(self: *@This(), loop: *xev.Loop) !void {
        if (self.loop) |_| {
            return error.ClientLoopAlreadyInitialized;
        }

        self.loop = loop;
        self.loop_owned = false;
        self.buildLoop();
    }

    pub fn buildLoop(self: *@This()) void {
        const span = trace.span(@src(), .build_loop);
        defer span.deinit();
        span.debug("Initializing event loop", .{});

        const current_loop = self.loop orelse {
            std.debug.panic("Cannot build loop, loop is null", .{});
            return;
        };

        self.tick.run(
            current_loop,
            &self.tick_c,
            500, // Initial timeout, will be adjusted by lsquic
            @This(),
            self,
            onTick,
        );

        self.packets_in.read(
            current_loop,
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
        const span = trace.span(@src(), .run_client_tick);
        defer span.deinit();
        if (self.loop) |loop| {
            span.trace("Running a single tick on JamSnpClient", .{});
            try loop.run(.no_wait);
        } else {
            span.warn("runTick called but loop is null", .{});
        }
    }

    pub fn runUntilDone(self: *@This()) !void {
        const span = trace.span(@src(), .run);
        defer span.deinit();
        if (self.loop) |loop| {
            span.debug("Starting JamSnpClient event loop", .{});
            try loop.run(.until_done);
            span.debug("Event loop completed", .{});
        } else {
            span.err("runUntilDone called but loop is null", .{});
            return error.LoopNotInitialized;
        }
    }


    /// Sets the callback function and context for a specific event type.
    /// The caller is responsible for ensuring the `callback_fn_ptr` points to a
    /// function with the correct signature corresponding to the `event_type`
    pub fn setCallback(self: *@This(), event_type: EventType, callback_fn_ptr: ?*const anyopaque, context: ?*anyopaque) void {
        const span = trace.span(@src(), .set_callback);
        defer span.deinit();
        span.trace("Setting callback for event {s}", .{@tagName(event_type)});
        self.callback_handlers[@intFromEnum(event_type)] = .{
            .callback = callback_fn_ptr,
            .context = context,
        };
    }

    pub fn deinit(self: *JamSnpClient) void {
        const span = trace.span(@src(), .deinit);
        defer span.deinit();
        span.debug("Deinitializing JamSnpClient", .{});

        span.trace("Destroying lsquic engine", .{});
        lsquic.lsquic_engine_destroy(self.lsquic_engine);

        span.trace("Freeing SSL context", .{});
        ssl.SSL_CTX_free(self.ssl_ctx);

        span.trace("Closing socket", .{});
        self.socket.close(); // Assuming close() handles already closed state

        span.trace("Deinitializing timer", .{});
        self.tick.deinit();

        if (self.loop) |loop| if (self.loop_owned) {
            span.trace("Deinitializing owned event loop", .{});
            loop.deinit();
            self.allocator.destroy(loop);
        };

        span.trace("Freeing buffers", .{});
        self.allocator.free(self.packet_in_buffer);
        self.allocator.free(self.chain_genesis_hash);
        self.allocator.free(self.alpn);

        if (self.streams.count() > 0) {
            span.warn("Streams map not empty during deinit. Count: {d}", .{self.streams.count()});
            var stream_it = self.streams.iterator();
            while (stream_it.next()) |entry| {
                const stream = entry.value_ptr.*;
                span.warn(" Force destroying stream: {}", .{stream.id});
                stream.destroy(self.allocator);
            }
        }
        span.trace("Deinitializing streams map", .{});
        self.streams.deinit();

        if (self.connections.count() > 0) {
            span.warn("Connections map not empty during deinit. Count: {d}", .{self.connections.count()});
            var conn_it = self.connections.iterator();
            while (conn_it.next()) |entry| {
                const conn = entry.value_ptr.*;
                span.warn(" Force destroying connection: {}", .{conn.id});
                conn.destroy(self.allocator);
            }
        }
        span.trace("Deinitializing connections map", .{});
        self.connections.deinit();

        for (&self.callback_handlers) |*handler| {
            handler.* = .{ .callback = null, .context = null };
        }

        span.trace("Destroying JamSnpClient object", .{});
        const alloc = self.allocator;
        self.* = undefined;
        alloc.destroy(self);

        span.trace("JamSnpClient deinitialization complete", .{});
    }

    pub fn connectUsingAddressAndPort(
        self: *JamSnpClient,
        address: []const u8,
        port: u16,
    ) !ConnectionId {
        const span = trace.span(@src(), .connect_address_and_port);
        defer span.deinit();
        span.debug("Connecting to {s}:{d}", .{ address, port });

        const parsable = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ address, port });
        defer self.allocator.free(parsable);

        const peer_endpoint = try network.EndPoint.parse(parsable);

        const connection_id = uuid.v4.new();

        try self.connect(peer_endpoint, connection_id);

        return connection_id;
    }

    pub fn connect(self: *JamSnpClient, peer_endpoint: network.EndPoint, connection_id: ConnectionId) !void {
        const span = trace.span(@src(), .connect);
        defer span.deinit();
        span.debug("Connecting to {s}", .{peer_endpoint});

        const local_address: network.Address = switch (peer_endpoint.address) {
            .ipv6 => |ipv6| if (std.mem.eql(u8, &ipv6.value, &network.Address.IPv6.loopback.value))
                .{ .ipv6 = network.Address.IPv6.loopback }
            else
                .{ .ipv6 = network.Address.IPv6.any },
            .ipv4 => |ipv4| if (std.mem.eql(u8, &ipv4.value, &network.Address.IPv4.loopback.value))
                .{ .ipv4 = network.Address.IPv4.loopback }
            else
                .{ .ipv4 = network.Address.IPv4.any },
        };
        self.socket.bind(.{ .address = local_address, .port = 0 }) catch |err| {
            span.err("Failed to bind to local address: {s}", .{@errorName(err)});
            return err;
        };

        const local_endpoint = self.socket.getLocalEndPoint() catch |err| {
            span.err("Failed to get local endpoint: {s}", .{@errorName(err)});
            return err;
        };
        span.debug("Bound to local endpoint: {}", .{local_endpoint});

        // TODO: double check if network.EndPoint.SockAddr maps to
        const local_sa = toSocketAddress(local_endpoint);
        const peer_sa = toSocketAddress(peer_endpoint);

        span.trace("Creating connection context", .{});
        const conn = try Connection(JamSnpClient).create(self.allocator, self, null, peer_endpoint, connection_id); // Use refactored path
        errdefer conn.destroy(self.allocator); // destroy is now part of ClientConnection.Connection


        span.debug("Creating QUIC connection {*}", .{conn});
        if (lsquic.lsquic_engine_connect(
            self.lsquic_engine,
            lsquic.LSQVER_VERNEG,
            @ptrCast(&local_sa), // Pass pointer to local sockaddr
            @ptrCast(&peer_sa), // Pass pointer to peer sockaddr
            self.ssl_ctx, // Pass SSL context (used via getSslContext)
            @ptrCast(conn), // Pass our connection struct as context
            null, // Hostname (optional, for SNI/verification if not using SSL_set_tlsext_host_name)
            0, // base_plpmtu (0 = use default)
            null, // session resumption buffer
            0, // session resumption length
            null, // token buffer
            0, // token length
        ) == null) { // Check for NULL return (failure)
            span.err("lsquic_engine_connect failed", .{});
            return error.ConnectionFailed;
        }

        try self.connections.put(connection_id, conn);

        span.debug("Connection request initiated successfully for ID: {}", .{conn.id});
    }

    pub fn enableSslCtxLogging(self: *@This()) void {
        const span = trace.span(@src(), .enable_ssl_ctx_logging);
        defer span.deinit();
        @import("../tests/logging.zig").enableDetailedSslCtxLogging(self.ssl_ctx);
    }

    fn onTick(
        maybe_self: ?*@This(),
        xev_loop: *xev.Loop,
        xev_completion: *xev.Completion,
        xev_timer_result: xev.Timer.RunError!void,
    ) xev.CallbackAction {
        const span = trace.span(@src(), .on_client_tick);
        defer span.deinit();

        errdefer |err| {
            span.err("onTick failed with timer error: {s}", .{@errorName(err)});
            std.debug.panic("onTick failed with: {s}", .{@errorName(err)}); // Or handle more gracefully
        }
        try xev_timer_result; // Check for timer errors first

        const self = maybe_self orelse {
            span.err("onTick called with null self context!", .{});
            return .disarm; // Cannot proceed
        };

        span.trace("Processing connections via lsquic_engine_process_conns", .{});
        lsquic.lsquic_engine_process_conns(self.lsquic_engine);

        var delta: c_int = undefined;
        var timeout_in_ms: u64 = 100; // Default timeout if lsquic gives no advice
        span.trace("Checking for earliest connection activity", .{});
        if (lsquic.lsquic_engine_earliest_adv_tick(self.lsquic_engine, &delta) != 0) {
            if (delta <= 0) {
                timeout_in_ms = 0; // Schedule ASAP (or small value like 1ms?)
                span.trace("Next tick scheduled immediately (delta={d})", .{delta});
            } else {
                timeout_in_ms = @intCast(@divTrunc(delta, 1000));
                span.trace("Next tick scheduled in {d}ms (delta={d}us)", .{ timeout_in_ms, delta });
            }
        } else {
            span.trace("No specific next tick advised by lsquic, using default {d}ms", .{timeout_in_ms});
        }

        if (timeout_in_ms == 0 and delta > 0) timeout_in_ms = 1;

        span.trace("Scheduling next tick with timeout: {d}ms", .{timeout_in_ms});
        self.tick.run(
            xev_loop,
            xev_completion,
            timeout_in_ms,
            @This(),
            self,
            onTick,
        );

        return .disarm; // Timer was re-armed by run()
    }

    fn onPacketsIn(
        maybe_self: ?*@This(),
        _: *xev.Loop, // Unused loop ptr
        _: *xev.Completion, // Unused completion ptr
        _: *xev.UDP.State, // Unused state ptr
        peer_address: std.net.Address, // Peer address provided by xev
        _: xev.UDP, // Unused UDP handle
        xev_read_buffer: xev.ReadBuffer, // Buffer containing the data
        xev_read_result: xev.ReadError!usize, // Result of the read operation
    ) xev.CallbackAction {
        const span = trace.span(@src(), .on_packets_in_client);
        defer span.deinit();

        errdefer |read_err| {
            span.err("xev UDP read failed: {s}", .{@errorName(read_err)});
            // TODO: Decide if this is fatal. Maybe just log and re-arm?
        }

        const bytes_read = xev_read_result catch |err| {
            span.err("Failed to read bytes: {s}", .{@errorName(err)});
            return .rearm;
        };
        if (bytes_read == 0) {
            span.warn("Received 0 bytes from UDP read, rearming.", .{});
            return .rearm;
        }
        span.trace("Received {d} bytes from {}", .{ bytes_read, peer_address });

        const self = maybe_self orelse {
            std.debug.panic("onPacketsIn called with null self context!", .{});
        };

        const local_endpoint = self.socket.getLocalEndPoint() catch |err| {
            std.debug.panic("Failed to get local endpoint in onPacketsIn: {s}", .{@errorName(err)});
        };
        span.trace("Packet received on local endpoint: {}", .{local_endpoint});

        // TODO: Check if network.EndPoint.SockAddr maps to sockaddr correctly
        const local_sa = &toSocketAddress(local_endpoint);
        // NOTE: this needs to be a stable pointer
        const peer_sa = &peer_address.any; // xev provides std.net.Address which has .any

        span.trace("Passing packet to lsquic engine", .{});
        if (lsquic.lsquic_engine_packet_in(
            self.lsquic_engine,
            xev_read_buffer.slice.ptr, // Pointer to received data
            bytes_read, // Length of received data
            @ptrCast(local_sa), // Pointer to local sockaddr
            @ptrCast(peer_sa), // Pointer to peer sockaddr
            @ptrCast(self), // Pass client as connection context hint (lsquic might ignore for existing conn)
            0, // ECN value (0 = Not-ECT)
        ) != 0) {
            span.err("lsquic_engine_packet_in failed (return value != 0)", .{});
            // TODO: Maybe log error and continue? Panicking might be too harsh.
            std.debug.panic("lsquic_engine_packet_in failed", .{});
        } else {
            span.trace("lsquic_engine_packet_in processed successfully", .{});
        }

        return .rearm;
    }

    fn getSslContext(
        peer_ctx: ?*anyopaque, // Context passed as 5th arg to lsquic_engine_connect
        _: ?*const lsquic.struct_sockaddr, // Remote address (unused here)
    ) callconv(.C) ?*lsquic.struct_ssl_ctx_st {
        return @ptrCast(peer_ctx.?);
    }

    fn sendPacketsOut(
        ctx: ?*anyopaque, // Context provided in lsquic_engine_api (the JamSnpClient*)
        specs_ptr: ?[*]const lsquic.lsquic_out_spec,
        specs_len: c_uint,
    ) callconv(.C) c_int {
        const span = trace.span(@src(), .client_send_packets_out);
        defer span.deinit();
        span.trace("Request to send {d} packet specs", .{specs_len});

        if (specs_len == 0) {
            return 0;
        }

        const client = @as(*JamSnpClient, @ptrCast(@alignCast(ctx.?)));
        const specs = specs_ptr.?[0..specs_len];

        var packets_sent_count: c_int = 0;
        send_loop: for (specs) |*spec| {

            // TODO: Implement sendmsg for coalescing if performance is critical.

            const iov_slice = spec.iov[0..spec.iovlen];
            span.trace(" Processing spec with {d} iovecs to peer_ctx={*}", .{ spec.iovlen, spec.peer_ctx });

            const dest_addr = std.net.Address.initPosix(@ptrCast(@alignCast(spec.dest_sa)));
            const dest_endpoint = network.EndPoint.fromSocketAddress(@ptrCast(@alignCast(spec.dest_sa)), dest_addr.getOsSockLen()) catch |err| {
                span.err("Failed to convert destination sockaddr: {s}", .{@errorName(err)});
                break :send_loop;
            };

            for (iov_slice) |iov| {
                const packet_buf: [*]const u8 = @ptrCast(iov.iov_base);
                const packet_len: usize = @intCast(iov.iov_len);
                if (packet_len == 0) continue; // Skip empty buffers
                const packet = packet_buf[0..packet_len];

                span.trace("  Sending iovec of {d} bytes to {}", .{ packet_len, dest_endpoint });

                _ = client.socket.sendTo(dest_endpoint, packet) catch |err| {
                    span.warn("Failed to send packet spec to {}: {s}", .{ dest_endpoint, @errorName(err) });
                    switch (err) {
                        error.WouldBlock => { // Corresponds to EAGAIN/EWOULDBLOCK
                            span.warn("Socket send would block (EAGAIN). Stopping batch.", .{});
                            break :send_loop;
                        },
                        else => {
                            span.err("Unhandled socket send error: {s}", .{@errorName(err)});
                            break :send_loop;
                        },
                    }
                };
            }
            packets_sent_count += 1;
        }

        span.trace("Attempted to send {d}/{d} packet specs", .{ packets_sent_count, specs_len });
        return packets_sent_count;
    }
};
