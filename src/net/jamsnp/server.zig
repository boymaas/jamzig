const std = @import("std");
const uuid = @import("uuid");
const lsquic = @import("lsquic");
const ssl = @import("ssl");
const common = @import("common.zig");
const certificate_verifier = @import("certificate_verifier.zig");
const network = @import("network");
const xev = @import("xev");

const shared = @import("shared_types.zig");

const Connection = @import("connection.zig").Connection;
const Stream = @import("stream.zig").Stream;

const toSocketAddress = @import("../ext.zig").toSocketAddress;
const trace = @import("../../tracing.zig").scoped(.network);

// Use shared types
pub const ConnectionId = shared.ConnectionId;
pub const StreamId = shared.StreamId;
pub const EventType = shared.EventType;
pub const CallbackHandler = shared.CallbackHandler;

// -- JamSnpServer Struct

pub const JamSnpServer = struct {
    allocator: std.mem.Allocator,
    keypair: std.crypto.sign.Ed25519.KeyPair,
    socket: network.Socket,
    alpn_id: []const u8,

    // xev state
    loop: ?*xev.Loop = undefined,
    loop_owned: bool = false,

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
        // Mandatory callbacks - point to functions in new modules
        .on_new_conn = Connection(JamSnpServer).onServerConnectionCreated,
        .on_conn_closed = Connection(JamSnpServer).onConnectionClosed,
        .on_new_stream = Stream(JamSnpServer).onStreamCreated,
        .on_read = Stream(JamSnpServer).onStreamRead,
        .on_write = Stream(JamSnpServer).onStreamWrite,
        .on_close = Stream(JamSnpServer).onStreamClosed,
        // Optional callbacks
        .on_hsk_done = Connection(JamSnpServer).onHandshakeDone,
        .on_goaway_received = null,
        .on_new_token = null,
        .on_sess_resume_info = null,
    },

    ssl_ctx: *ssl.SSL_CTX,

    chain_genesis_hash: []const u8,
    allow_builders: bool,

    // Bookkeeping using UUIDs - use refactored types
    connections: std.AutoHashMap(ConnectionId, *Connection(JamSnpServer)),
    streams: std.AutoHashMap(StreamId, *Stream(JamSnpServer)),

    // Callback handlers map (Server-side)
    callback_handlers: shared.CallbackHandlers = shared.CALLBACK_HANDLERS_EMPTY,

    pub fn initWithLoop(
        allocator: std.mem.Allocator,
        keypair: std.crypto.sign.Ed25519.KeyPair,
        chain_genesis_hash: []const u8,
        is_builder: bool,
    ) !*JamSnpServer {
        const server = try initWithoutLoop(allocator, keypair, chain_genesis_hash, is_builder);
        errdefer server.deinit();
        try server.initLoop();
        return server;
    }

    pub fn initAttachLoop(
        allocator: std.mem.Allocator,
        keypair: std.crypto.sign.Ed25519.KeyPair,
        chain_genesis_hash: []const u8,
        is_builder: bool,
        loop: *xev.Loop,
    ) !*JamSnpServer {
        const server = try initWithoutLoop(allocator, keypair, chain_genesis_hash, is_builder);
        errdefer server.deinit();
        try server.attachToLoop(loop);
        return server;
    }

    pub fn initWithoutLoop(
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
            .connections = std.AutoHashMap(ConnectionId, *Connection(JamSnpServer)).init(allocator),
            .streams = std.AutoHashMap(StreamId, *Stream(JamSnpServer)).init(allocator),
            // Initialize callback handlers
            .callback_handlers = [_]CallbackHandler{.{ .callback = null, .context = null }} ** @typeInfo(EventType).@"enum".fields.len,
        };

        // Reserve buffers for incoming packets
        server.packets_in_buffer = try allocator.alloc(u8, 1500);
        errdefer allocator.free(server.packets_in_buffer);

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

        span.debug("Creating LSQUIC engine", .{});
        server.lsquic_engine = lsquic.lsquic_engine_new(
            lsquic.LSENG_SERVER,
            &server.lsquic_engine_api,
        ) orelse {
            span.err("Failed to create lsquic engine", .{});
            return error.LsquicEngineCreationFailed;
        };

        span.debug("JamSnpServer initialization successful", .{});
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
        if (self.loop) |loop| if (self.loop_owned) {
            span.trace("Deinitializing owned event loop", .{});
            loop.deinit();
            self.allocator.destroy(loop);
        };

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

    pub fn listen(self: *JamSnpServer, addr: []const u8, port: u16) !network.EndPoint {
        const span = trace.span(.listen);
        defer span.deinit();
        span.debug("Starting listen on {s}:{d}", .{ addr, port });
        const address = try network.Address.parse(addr);
        const endpoint = network.EndPoint{
            .address = address,
            .port = port,
        };
        try self.socket.bind(endpoint);

        const local_endpoint = try self.socket.getLocalEndPoint();

        span.debug("Socket bound successfully to {}", .{local_endpoint});
        return local_endpoint;
    }

    pub fn initLoop(self: *@This()) !void {
        const loop = try self.allocator.create(xev.Loop);
        errdefer self.allocator.destroy(loop);
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
            500, // Initial timeout, will be adjusted
            @This(),
            self,
            onTick,
        );

        self.packets_in.read(
            self.loop.?,
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
        try self.loop.?.run(.no_wait);
    }

    pub fn runUntilDone(self: *@This()) !void {
        const span = trace.span(.run);
        defer span.deinit();
        span.debug("Starting JamSnpServer event loop", .{});
        try self.loop.?.run(.until_done);
        span.debug("Event loop completed", .{});
    }

    // -- Callback Registration

    pub fn setCallback(self: *@This(), event_type: EventType, callback_fn_ptr: ?*const anyopaque, context: ?*anyopaque) void {
        const span = trace.span(.set_callback);
        defer span.deinit();
        span.trace("Setting server callback for event {s}", .{@tagName(event_type)});
        self.callback_handlers[@intFromEnum(event_type)] = .{
            .callback = callback_fn_ptr,
            .context = context,
        };
    }

    // -- logging
    pub fn enableSslCtxLogging(self: *@This()) void {
        const span = trace.span(.enable_ssl_ctx_logging);
        defer span.deinit();
        @import("../tests/logging.zig").enableDetailedSslCtxLogging(self.ssl_ctx);
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

        span.trace("Calling lsquic_engine_process_conns", .{});
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
        const span = trace.span(.on_packets_in_server);
        defer span.deinit();

        errdefer |err| {
            span.err("onPacketsIn failed with error: {s}", .{@errorName(err)});
            std.debug.panic("onPacketsIn failed with: {s}", .{@errorName(err)});
        }

        const bytes = try xev_read_result;
        span.trace("Received {d} bytes from {}", .{ bytes, peer_address });
        span.trace("Packet data (first 32 bytes): {any}", .{std.fmt.fmtSliceHexLower(xev_read_buffer.slice[0..@min(bytes, 32)])});

        const self = maybe_self.?;

        span.trace("Getting local address", .{});
        const local_address = self.socket.getLocalEndPoint() catch |err| {
            span.err("Failed to get local address: {s}", .{@errorName(err)});
            @panic("Failed to get local address");
        };

        span.trace("Local address: {}", .{local_address});

        span.trace("Passing packet to lsquic engine", .{});
        // When passing pointers across FFI, always pass &instance.field rather than
        // copying the field and passing &field_copy. C functions expect pointers
        // with the proper structural context (alignment, layout, size) defined by
        // the C ABI. A pointer to an isolated field lacks this context, breaking C's
        // assumptions about memory layout and type punning, causing subtle failures.
        // So do not do:
        //   const local_sa = peer_address.any; <== create local copy of the field
        // and then pass &local_sa to lsquic_engine_packet_in. This will lead
        // to a violation of Violation of Type Punning / Structural
        // Assumptions.
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
                span.trace("Packet data (first 32 bytes): {any}", .{std.fmt.fmtSliceHexLower(packet[0..@min(packet.len, 32)])});

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
