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
const ClientConnection = @import("../client/connection.zig");

const toSocketAddress = @import("../ext.zig").toSocketAddress;
const trace = @import("../../tracing.zig").scoped(.network);

// Use shared types
pub const ConnectionId = shared.ConnectionId;
pub const StreamId = shared.StreamId;
pub const EventType = shared.EventType; // Use renamed type
pub const CallbackHandler = shared.CallbackHandler;

// Use specific callback types from shared
pub const ConnectionEstablishedCallbackFn = shared.ConnectionEstablishedCallbackFn;
pub const ConnectionFailedCallbackFn = shared.ConnectionFailedCallbackFn;
pub const ConnectionClosedCallbackFn = shared.ConnectionClosedCallbackFn;
pub const ClientConnectedCallbackFn = shared.ClientConnectedCallbackFn;
pub const ClientDisconnectedCallbackFn = shared.ConnectionClosedCallbackFn;
pub const StreamCreatedCallbackFn = shared.StreamCreatedCallbackFn;
pub const StreamClosedCallbackFn = shared.StreamClosedCallbackFn;
pub const DataWriteCompletedCallbackFn = shared.DataWriteCompletedCallbackFn;
pub const DataErrorCallbackFn = shared.DataErrorCallbackFn;
pub const DataWouldBlockCallbackFn = shared.DataWouldBlockCallbackFn;
pub const DataEndOfStreamCallbackFn = shared.DataEndOfStreamCallbackFn;
pub const DataWriteProgressCallbackFn = shared.DataWriteProgressCallbackFn;
pub const DataReceivedCallbackFn = shared.DataReceivedCallbackFn;

// Argument Union for invokeCallback (using shared types)
const EventArgs = union(EventType) {
    ClientConnected: struct { connection: ConnectionId, endpoint: network.EndPoint },
    ConnectionEstablished: struct { connection: ConnectionId, endpoint: network.EndPoint },
    ConnectionFailed: struct { endpoint: network.EndPoint, err: anyerror },
    ConnectionClosed: struct { connection: ConnectionId },
    StreamCreated: struct { connection: ConnectionId, stream: StreamId },
    StreamClosed: struct { connection: ConnectionId, stream: StreamId },
    DataReceived: struct { connection: ConnectionId, stream: StreamId, data: []const u8 },
    DataEndOfStream: struct { connection: ConnectionId, stream: StreamId, data_read: []const u8 },
    DataReadError: struct { connection: ConnectionId, stream: StreamId, error_code: i32 },
    DataWouldBlock: struct { connection: ConnectionId, stream: StreamId },
    DataWriteProgress: struct { connection: ConnectionId, stream: StreamId, bytes_written: usize, total_size: usize },
    DataWriteCompleted: struct { connection: ConnectionId, stream: StreamId, total_bytes_written: usize },
    DataWriteError: struct { connection: ConnectionId, stream: StreamId, error_code: i32 },
};

// -- JamSnpClient Struct

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
    connections: std.AutoHashMap(ConnectionId, *ClientConnection.Connection), // Use refactored type
    streams: std.AutoHashMap(StreamId, *Stream), // Keep internal Stream struct for now

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
        .on_new_conn = ClientConnection.Connection.onConnectionCreated,
        .on_conn_closed = ClientConnection.Connection.onConnectionClosed,
        .on_new_stream = Stream.onStreamCreated,
        .on_read = Stream.onStreamRead,
        .on_write = Stream.onStreamWrite,
        .on_close = Stream.onStreamClosed,
        // Optional callbacks...
    },

    ssl_ctx: *ssl.SSL_CTX,
    chain_genesis_hash: []const u8,

    is_builder: bool,

    // Using an array instead of HashMap for callbacks provides better performance
    // as it avoids hash calculation and memory allocation overhead
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
        const span = trace.span(.init_client);
        defer span.deinit();
        span.debug("Initializing JamSnpClient", .{});

        // Initialize lsquic globally
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
            span.err("Client engine settings problem: {s}", .{error_buffer});
            // Consider returning an error instead of panicking
            return error.LsquicEngineSettingsInvalid;
            // std.debug.panic("Client engine settings problem: {s}", .{error_buffer});
        }

        span.debug("Allocating client struct", .{});
        const client = try allocator.create(JamSnpClient);
        errdefer client.deinit(); // Can now use errdefer safely

        // Initialize client fields
        client.* = JamSnpClient{
            .allocator = allocator,
            .keypair = keypair,
            .chain_genesis_hash = try allocator.dupe(u8, chain_genesis_hash),
            .is_builder = is_builder,
            .connections = std.AutoHashMap(ConnectionId, *ClientConnection.Connection).init(allocator), // Use refactored type
            .streams = std.AutoHashMap(StreamId, *Stream).init(allocator), // Keep internal Stream
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
            // Initialize the new handlers map
            .callback_handlers = [_]CallbackHandler{.{ .callback = null, .context = null }} ** @typeInfo(EventType).@"enum".fields.len,
        };

        // Create lsquic engine
        span.debug("Creating lsquic engine", .{});
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
        const span = trace.span(.build_loop);
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
        const span = trace.span(.run_client_tick);
        defer span.deinit();
        if (self.loop) |loop| {
            span.trace("Running a single tick on JamSnpClient", .{});
            try loop.run(.no_wait);
        } else {
            span.warn("runTick called but loop is null", .{});
        }
    }

    pub fn runUntilDone(self: *@This()) !void {
        const span = trace.span(.run);
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

    // -- Callback Registration

    /// Sets the callback function and context for a specific event type.
    /// The caller is responsible for ensuring the `callback_fn_ptr` points to a
    /// function with the correct signature corresponding to the `event_type`
    pub fn setCallback(self: *@This(), event_type: EventType, callback_fn_ptr: ?*const anyopaque, context: ?*anyopaque) void {
        const span = trace.span(.set_callback);
        defer span.deinit();
        span.debug("Setting callback for event {s}", .{@tagName(event_type)});
        self.callback_handlers[@intFromEnum(event_type)] = .{
            .callback = callback_fn_ptr,
            .context = context,
        };
    }

    // -- Refactored Callback Invocation

    // Single invokeCallback function
    pub fn invokeCallback(self: *@This(), event_tag: EventType, args: EventArgs) void {
        const span = trace.span(.invoke_callback);
        defer span.deinit();
        std.debug.assert(event_tag == @as(EventType, @enumFromInt(@intFromEnum(args)))); // Ensure tag matches union

        const handler = &self.callback_handlers[@intFromEnum(event_tag)];
        if (handler.callback) |callback_ptr| {
            span.debug("Invoking callback for event {s}", .{@tagName(event_tag)});

            // Switch on the event type to cast to the correct function signature and call it
            switch (args) {
                .ClientConnected => |ev_args| {
                    const callback: ClientConnectedCallbackFn = @ptrCast(@alignCast(callback_ptr));
                    callback(ev_args.connection, ev_args.endpoint, handler.context);
                },
                .ConnectionEstablished => |ev_args| {
                    const callback: ConnectionEstablishedCallbackFn = @ptrCast(@alignCast(callback_ptr));
                    callback(ev_args.connection, ev_args.endpoint, handler.context);
                },
                .ConnectionFailed => |ev_args| {
                    const callback: ConnectionFailedCallbackFn = @ptrCast(@alignCast(callback_ptr));
                    callback(ev_args.endpoint, ev_args.err, handler.context);
                },
                .ConnectionClosed => |ev_args| {
                    const callback: ConnectionClosedCallbackFn = @ptrCast(@alignCast(callback_ptr));
                    callback(ev_args.connection, handler.context);
                },
                .StreamCreated => |ev_args| {
                    const callback: StreamCreatedCallbackFn = @ptrCast(@alignCast(callback_ptr));
                    callback(ev_args.connection, ev_args.stream, handler.context);
                },
                .StreamClosed => |ev_args| {
                    const callback: StreamClosedCallbackFn = @ptrCast(@alignCast(callback_ptr));
                    callback(ev_args.connection, ev_args.stream, handler.context);
                },
                .DataReceived => |ev_args| {
                    const callback: DataReceivedCallbackFn = @ptrCast(@alignCast(callback_ptr));
                    callback(ev_args.connection, ev_args.stream, ev_args.data, handler.context);
                },
                .DataEndOfStream => |ev_args| {
                    const callback: DataEndOfStreamCallbackFn = @ptrCast(@alignCast(callback_ptr));
                    callback(ev_args.connection, ev_args.stream, ev_args.data_read, handler.context);
                },
                .DataReadError => |ev_args| {
                    const callback: DataErrorCallbackFn = @ptrCast(@alignCast(callback_ptr));
                    callback(ev_args.connection, ev_args.stream, ev_args.error_code, handler.context);
                },
                .DataWouldBlock => |ev_args| {
                    const callback: DataWouldBlockCallbackFn = @ptrCast(@alignCast(callback_ptr));
                    callback(ev_args.connection, ev_args.stream, handler.context);
                },
                .DataWriteProgress => |ev_args| {
                    const callback: DataWriteProgressCallbackFn = @ptrCast(@alignCast(callback_ptr));
                    callback(ev_args.connection, ev_args.stream, ev_args.bytes_written, ev_args.total_size, handler.context);
                },
                .DataWriteCompleted => |ev_args| {
                    const callback: DataWriteCompletedCallbackFn = @ptrCast(@alignCast(callback_ptr));
                    callback(ev_args.connection, ev_args.stream, ev_args.total_bytes_written, handler.context);
                },
                .DataWriteError => |ev_args| {
                    const callback: DataErrorCallbackFn = @ptrCast(@alignCast(callback_ptr));
                    callback(ev_args.connection, ev_args.stream, ev_args.error_code, handler.context);
                },
            }
        } else {
            span.debug("No callback registered for event type {s}", .{@tagName(event_tag)});
        }
    }

    pub fn deinit(self: *JamSnpClient) void {
        const span = trace.span(.deinit);
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

        // Cleanup remaining streams (Safety net)
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

        // Cleanup remaining connections (Safety net)
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

        // Cleanup callback handlers
        // but good practice to clear references)
        for (&self.callback_handlers) |*handler| {
            handler.* = .{ .callback = null, .context = null };
        }

        // Destroy the client object itself LAST
        span.trace("Destroying JamSnpClient object", .{});
        self.allocator.destroy(self);

        span.trace("JamSnpClient deinitialization complete", .{});
    }

    pub fn connectUsingAddressAndPort(
        self: *JamSnpClient,
        address: []const u8,
        port: u16,
    ) !ConnectionId {
        const span = trace.span(.connect_address_and_port);
        defer span.deinit();
        span.debug("Connecting to {s}:{d}", .{ address, port });

        // Create the endpoint
        const parsable = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ address, port });
        defer self.allocator.free(parsable);

        const peer_endpoint = try network.EndPoint.parse(parsable);

        // Call the main connect function
        return self.connect(peer_endpoint);
    }

    pub fn connect(self: *JamSnpClient, peer_endpoint: network.EndPoint) !ConnectionId {
        const span = trace.span(.connect);
        defer span.deinit();
        span.debug("Connecting to {s}", .{peer_endpoint});

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

        // TODO: double check if network.EndPoint.SockAddr maps to
        // a std.posix sockaddr struct
        const local_sa = toSocketAddress(local_endpoint);
        const peer_sa = toSocketAddress(peer_endpoint);

        // Create a connection context *before* calling lsquic_engine_connect
        span.trace("Creating connection context", .{});
        const conn = try ClientConnection.Connection.create(self.allocator, self, peer_endpoint); // Use refactored path
        errdefer conn.destroy(self.allocator); // destroy is now part of ClientConnection.Connection

        // Create QUIC connection

        span.debug("Creating QUIC connection", .{});
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
            // Don't invoke callback here, let caller handle connect() error
            return error.ConnectionFailed;
        }

        // Add to connections map *after* successful call to lsquic_engine_connect
        try self.connections.put(conn.id, conn);

        span.debug("Connection request initiated successfully for ID: {}", .{conn.id});
        return conn.id;
    }

    // --- Internal Stream Struct (for lsquic context) ---
    // This struct holds the state needed *within* the lsquic callbacks.
    // The user interacts via Client.StreamHandle which sends commands.
    pub const Stream = struct {
        id: StreamId,
        connection: *ClientConnection.Connection, // Use refactored type
        lsquic_stream: *lsquic.lsquic_stream_t, // Set in onStreamCreated

        // Internal state for reading/writing (managed by lsquic callbacks)
        want_write: bool = false,
        write_buffer: ?[]const u8 = null, // Buffer provided by user via command
        write_buffer_pos: usize = 0,

        want_read: bool = false,
        read_buffer: ?[]u8 = null, // Buffer provided by user via command
        read_buffer_pos: usize = 0,

        fn create(alloc: std.mem.Allocator, connection: *ClientConnection.Connection, lsquic_stream: *lsquic.lsquic_stream_t) !*Stream {
            const span = trace.span(.stream_create_internal);
            defer span.deinit();
            span.debug("Creating internal Stream context for connection ID: {}", .{connection.id});
            const stream = try alloc.create(Stream);
            errdefer alloc.destroy(stream);

            stream.* = .{
                .id = uuid.v4.new(),
                .lsquic_stream = lsquic_stream,
                .connection = connection,
                .want_write = false,
                .write_buffer = null,
                .write_buffer_pos = 0,
                .want_read = false,
                .read_buffer = null,
                .read_buffer_pos = 0,
            };
            span.debug("Internal Stream context created with ID: {}", .{stream.id});
            return stream;
        }

        pub fn destroy(self: *Stream, alloc: std.mem.Allocator) void {
            // Just free the memory, lsquic handles its stream resources.
            const span = trace.span(.stream_destroy_internal);
            defer span.deinit();
            span.debug("Destroying internal Stream struct for ID: {}", .{self.id});

            // Buffers are managed by the caller

            alloc.destroy(self);
        }

        pub fn wantRead(self: *Stream, want: bool) void {
            const span = trace.span(.stream_want_read_internal);
            defer span.deinit();
            const want_val: c_int = if (want) 1 else 0;
            span.debug("Setting internal stream want-read to {} for ID: {}", .{ want, self.id });
            _ = lsquic.lsquic_stream_wantread(self.lsquic_stream, want_val);
            self.want_read = want; // Update internal state
        }

        pub fn wantWrite(self: *Stream, want: bool) void {
            const span = trace.span(.stream_want_write_internal);
            defer span.deinit();
            const want_val: c_int = if (want) 1 else 0;
            span.debug("Setting internal stream want-write to {} for ID: {}", .{ want, self.id });
            _ = lsquic.lsquic_stream_wantwrite(self.lsquic_stream, want_val);
            self.want_write = want; // Update internal state
        }

        /// Prepare the stream to read into the provided buffer.
        /// Called internally when a Stream read command is processed.
        pub fn setReadBuffer(self: *Stream, buffer: []u8) !void {
            const span = trace.span(.stream_set_read_buffer);
            defer span.deinit();
            span.debug("Setting read buffer (len={d}) for internal stream ID: {}", .{ buffer.len, self.id });

            if (buffer.len == 0) {
                span.warn("Read buffer set with zero-length for stream ID: {}", .{self.id});
                return error.InvalidArgument;
            }
            // Overwrite previous buffer if any? Let's overwrite for simplicity.
            if (self.read_buffer != null) {
                span.warn("Overwriting existing read buffer for stream ID: {}", .{self.id});
            }

            self.read_buffer = buffer;
            self.read_buffer_pos = 0;
            // wantRead should be set by the command handler based on user request
        }

        /// Prepare the stream to write the provided data.
        pub fn setWriteBuffer(self: *Stream, data: []const u8) !void {
            const span = trace.span(.stream_set_write_buffer);
            defer span.deinit();
            span.debug("Setting write buffer ({d} bytes) for internal stream ID: {}", .{ data.len, self.id });

            if (data.len == 0) {
                span.warn("Write buffer set with zero-length data for stream ID: {}. Ignoring.", .{self.id});
                return error.ZeroDataLen;
            }
            // Let's overwrite for simplicity.
            if (self.write_buffer != null) {
                span.err("Stream ID {} is already writing, cannot issue new write.", .{self.id});
                return error.StreamAlreadyWriting;
            }

            self.write_buffer = data;
            self.write_buffer_pos = 0;
            // wantWrite should be set by the command handler
        }

        pub fn flush(self: *Stream) !void {
            const span = trace.span(.stream_flush_internal);
            defer span.deinit();
            span.debug("Flushing internal stream ID: {}", .{self.id});
            if (lsquic.lsquic_stream_flush(self.lsquic_stream) != 0) {
                span.err("Failed to flush internal stream ID: {}", .{self.id});
                return error.StreamFlushFailed;
            }
        }

        pub fn shutdown(self: *Stream, how: c_int) !void {
            const span = trace.span(.stream_shutdown_internal);
            defer span.deinit();
            const direction = switch (how) {
                0 => "read",
                1 => "write",
                2 => "read and write",
                else => "unknown",
            };
            span.debug("Shutting down internal stream ID {} ({s} side)", .{ self.id, direction });
            if (lsquic.lsquic_stream_shutdown(self.lsquic_stream, how) != 0) {
                span.err("Failed to shutdown internal stream ID {}: {s}", .{ self.id, direction });
                return error.StreamShutdownFailed;
            }
        }

        pub fn close(self: *Stream) !void {
            const span = trace.span(.stream_close_internal);
            defer span.deinit();
            span.debug("Closing internal stream ID: {}", .{self.id});
            // This signals intent to close; onStreamClosed callback handles final cleanup.
            if (lsquic.lsquic_stream_close(self.lsquic_stream) != 0) {
                span.err("Failed to close internal stream ID: {}", .{self.id});
                return error.StreamCloseFailed;
            }
        }

        // -- LSQUIC Stream Callbacks
        fn onStreamCreated(
            _: ?*anyopaque, // ea_stream_if_ctx (unused)
            maybe_lsquic_stream: ?*lsquic.lsquic_stream_t,
        ) callconv(.C) *lsquic.lsquic_stream_ctx_t {
            const span = trace.span(.on_stream_created);
            defer span.deinit();
            span.debug("LSQUIC stream created callback received", .{});

            // Get the parent Connection context
            const lsquic_connection = lsquic.lsquic_stream_conn(maybe_lsquic_stream);
            const conn_ctx = lsquic.lsquic_conn_get_ctx(lsquic_connection).?; // Assume parent conn context is valid
            const connection: *ClientConnection.Connection = @alignCast(@ptrCast(conn_ctx)); // Use refactored type

            span.debug("Creating internal Stream context for connection ID: {}", .{connection.id});
            // Use the internal Stream.create
            const stream = Stream.create(connection.client.allocator, connection, maybe_lsquic_stream orelse unreachable) catch |err| {
                span.err("Failed to allocate memory for internal Stream context: {s}", .{@errorName(err)});
                std.debug.panic("OutOfMemory creating internal Stream context: {s}", .{@errorName(err)});
            };

            // Add stream to the client's map
            connection.client.streams.put(stream.id, stream) catch |err| {
                span.err("Failed to add internal stream {} to map: {s}", .{ stream.id, @errorName(err) });
                stream.destroy(connection.client.allocator); // Clean up allocated stream
                std.debug.panic("Failed to add internal stream to map: {s}", .{@errorName(err)});
            };

            // Invoke the user-facing callback via the client
            connection.client.invokeCallback(.StreamCreated, .{
                .StreamCreated = .{
                    .connection = connection.id,
                    .stream = stream.id,
                },
            });

            // Return our internal stream struct pointer as the context for lsquic
            return @ptrCast(stream);
        }

        fn onStreamRead(
            maybe_lsquic_stream: ?*lsquic.lsquic_stream_t,
            maybe_stream_ctx: ?*lsquic.lsquic_stream_ctx_t,
        ) callconv(.C) void {
            const span = trace.span(.on_stream_read);
            defer span.deinit();

            const stream_ctx = maybe_stream_ctx orelse {
                span.err("onStreamRead called with null context!", .{});
                return;
            };
            const stream: *Stream = @alignCast(@ptrCast(stream_ctx)); // This is the internal Stream
            span.debug("onStreamRead triggered for internal stream ID: {}", .{stream.id});

            // Check if a read buffer has been provided via command
            if (stream.read_buffer == null) {
                span.warn("onStreamRead called for stream ID {} but no read buffer set via command. Disabling wantRead.", .{stream.id});
                stream.wantRead(false);
                return;
            }

            const buffer_available = stream.read_buffer.?[stream.read_buffer_pos..];
            if (buffer_available.len == 0) {
                span.warn("onStreamRead called for stream ID {} but read buffer is full.", .{stream.id});
                stream.wantRead(false);
                return;
            }

            const read_size = lsquic.lsquic_stream_read(maybe_lsquic_stream, buffer_available.ptr, buffer_available.len);

            if (read_size == 0) {
                span.debug("End of stream reached for stream ID: {}", .{stream.id});
                stream.connection.client.invokeCallback(.DataEndOfStream, .{
                    .DataEndOfStream = .{
                        .connection = stream.connection.id,
                        .stream = stream.id,
                        .data_read = stream.read_buffer.?[0..stream.read_buffer_pos],
                    },
                });
                stream.read_buffer = null;
                stream.read_buffer_pos = 0;
                stream.wantRead(false);
            } else if (read_size < 0) {
                switch (std.posix.errno(read_size)) {
                    std.posix.E.AGAIN => {
                        span.debug("Read would block for stream ID: {}", .{stream.id});
                        stream.connection.client.invokeCallback(.DataWouldBlock, .{
                            .DataWouldBlock = .{
                                .connection = stream.connection.id,
                                .stream = stream.id,
                            },
                        });
                        // Keep wantRead true
                    },
                    else => |err| {
                        span.err("Error reading from stream ID {}: {s}", .{ stream.id, @tagName(err) });
                        stream.connection.client.invokeCallback(.DataReadError, .{
                            .DataReadError = .{
                                .connection = stream.connection.id,
                                .stream = stream.id,
                                .error_code = @intFromEnum(err),
                            },
                        });
                        stream.read_buffer = null;
                        stream.read_buffer_pos = 0;
                        stream.wantRead(false);
                    },
                }
            } else { // read_size > 0
                const bytes_read: usize = @intCast(read_size);
                span.debug("Read {d} bytes from stream ID: {}", .{ bytes_read, stream.id });

                const prev_pos = stream.read_buffer_pos;
                stream.read_buffer_pos += bytes_read;
                const data_just_read = stream.read_buffer.?[prev_pos..stream.read_buffer_pos];

                stream.connection.client.invokeCallback(.DataReceived, .{
                    .DataReceived = .{
                        .connection = stream.connection.id,
                        .stream = stream.id,
                        .data = data_just_read,
                    },
                });

                if (stream.read_buffer_pos == stream.read_buffer.?.len) {
                    span.debug("User read buffer full for stream ID: {}. Disabling wantRead.", .{stream.id});
                    stream.read_buffer = null;
                    stream.read_buffer_pos = 0;
                    stream.wantRead(false);
                    // TODO: Signal buffer full? Or rely on DataReceived?
                }
            }
        }

        fn onStreamWrite(
            maybe_lsquic_stream: ?*lsquic.lsquic_stream_t,
            maybe_stream_ctx: ?*lsquic.lsquic_stream_ctx_t,
        ) callconv(.C) void {
            const span = trace.span(.on_stream_write);
            defer span.deinit();

            _ = maybe_lsquic_stream; // Unused in this context

            const stream_ctx = maybe_stream_ctx orelse {
                span.err("onStreamWrite called with null context!", .{});
                return;
            };
            const stream: *Stream = @alignCast(@ptrCast(stream_ctx)); // Internal Stream
            span.debug("onStreamWrite triggered for internal stream ID: {}", .{stream.id});

            if (stream.write_buffer == null) {
                span.warn("onStreamWrite called for stream ID {} but no write buffer set via command. Disabling wantWrite.", .{stream.id});
                stream.wantWrite(false);
                return;
            }

            const data_to_write = stream.write_buffer.?[stream.write_buffer_pos..];
            const total_size = stream.write_buffer.?.len;

            if (data_to_write.len == 0) {
                span.warn("onStreamWrite called for stream ID {} but write buffer position indicates completion.", .{stream.id});
                stream.wantWrite(false);
                return;
            }

            const written = lsquic.lsquic_stream_write(stream.lsquic_stream, data_to_write.ptr, data_to_write.len);

            if (written == 0) {
                span.trace("No data written to stream ID {} (likely blocked)", .{stream.id});
                // Keep wantWrite true
                return;
            } else if (written < 0) {
                if (std.posix.errno(written) == std.posix.E.AGAIN) {
                    span.trace("Stream write would block (EAGAIN) for stream ID {}", .{stream.id});
                    // Keep wantWrite true
                    return;
                } else {
                    const err_code = -written;
                    span.err("Stream write failed for stream ID {} with error code: {d}", .{ stream.id, err_code });
                    stream.connection.client.invokeCallback(.DataWriteError, .{
                        .DataWriteError = .{
                            .connection = stream.connection.id,
                            .stream = stream.id,
                            .error_code = @intCast(err_code),
                        },
                    });
                    stream.write_buffer = null;
                    stream.write_buffer_pos = 0;
                    stream.wantWrite(false);
                    return;
                }
            }

            // written > 0
            const bytes_written: usize = @intCast(written);
            span.debug("Written {d} bytes to stream ID: {}", .{ bytes_written, stream.id });
            stream.write_buffer_pos += bytes_written;

            stream.connection.client.invokeCallback(.DataWriteProgress, .{
                .DataWriteProgress = .{
                    .connection = stream.connection.id,
                    .stream = stream.id,
                    .bytes_written = stream.write_buffer_pos,
                    .total_size = total_size,
                },
            });

            if (stream.write_buffer_pos >= total_size) {
                span.debug("Write complete for user buffer (total {d} bytes) on stream ID: {}", .{ total_size, stream.id });

                stream.connection.client.invokeCallback(.DataWriteCompleted, .{
                    .DataWriteCompleted = .{
                        .connection = stream.connection.id,
                        .stream = stream.id,
                        .total_bytes_written = stream.write_buffer_pos,
                    },
                });

                stream.write_buffer = null;
                stream.write_buffer_pos = 0;
                span.trace("Disabling write interest for stream ID {}", .{stream.id});
                stream.wantWrite(false);
            }
            // else: Keep wantWrite true
        }

        fn onStreamClosed(
            _: ?*lsquic.lsquic_stream_t,
            maybe_stream_ctx: ?*lsquic.lsquic_stream_ctx_t,
        ) callconv(.C) void {
            const span = trace.span(.on_stream_closed);
            defer span.deinit();
            span.debug("LSQUIC stream closed callback received", .{});

            const stream_ctx = maybe_stream_ctx orelse {
                span.err("onStreamClosed called with null context!", .{});
                return;
            };
            const stream: *Stream = @alignCast(@ptrCast(stream_ctx)); // Internal Stream
            span.debug("Processing internal stream closure for ID: {}", .{stream.id});

            // Invoke the user-facing callback
            stream.connection.client.invokeCallback(.StreamClosed, .{
                .StreamClosed = .{
                    .connection = stream.connection.id,
                    .stream = stream.id,
                },
            });

            // Remove the internal stream from the client's map
            if (stream.connection.client.streams.fetchRemove(stream.id)) |_| {
                span.debug("Removed internal stream ID {} from map.", .{stream.id});
            } else {
                span.warn("Closing an internal stream (ID: {}) that was not found in the map.", .{stream.id});
            }

            // Destroy our internal stream context struct
            stream.destroy(stream.connection.client.allocator);

            span.debug("Internal stream cleanup complete for formerly ID: {}", .{stream.id});
        }
    };

    // --- Event Loop and C Interop Helpers
    fn onTick(
        maybe_self: ?*@This(),
        xev_loop: *xev.Loop,
        xev_completion: *xev.Completion,
        xev_timer_result: xev.Timer.RunError!void,
    ) xev.CallbackAction {
        const span = trace.span(.on_client_tick);
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

        // Determine next tick time based on lsquic's advice
        var delta: c_int = undefined;
        var timeout_in_ms: u64 = 100; // Default timeout if lsquic gives no advice
        span.trace("Checking for earliest connection activity", .{});
        if (lsquic.lsquic_engine_earliest_adv_tick(self.lsquic_engine, &delta) != 0) {
            // lsquic provided a next tick time
            if (delta <= 0) {
                // Need to tick immediately or very soon
                timeout_in_ms = 0; // Schedule ASAP (or small value like 1ms?)
                span.trace("Next tick scheduled immediately (delta={d})", .{delta});
            } else {
                // Convert microseconds delta to milliseconds timeout
                timeout_in_ms = @intCast(@divTrunc(delta, 1000));
                // Add a minimum timeout? e.g., max(1, timeout_in_ms) ?
                span.trace("Next tick scheduled in {d}ms (delta={d}us)", .{ timeout_in_ms, delta });
            }
        } else {
            // No connections need ticking according to lsquic right now. Use default.
            span.trace("No specific next tick advised by lsquic, using default {d}ms", .{timeout_in_ms});
        }

        // Clamp minimum timeout to avoid busy-waiting if delta is very small but non-zero
        if (timeout_in_ms == 0 and delta > 0) timeout_in_ms = 1;
        // Or clamp maximum timeout?
        // const max_timeout_ms: u64 = 5000;
        // timeout_in_ms = @min(timeout_in_ms, max_timeout_ms);

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
        const span = trace.span(.on_packets_in);
        defer span.deinit();

        errdefer |read_err| {
            // Log specific read errors from xev
            span.err("xev UDP read failed: {s}", .{@errorName(read_err)});
            // TODO: Decide if this is fatal. Maybe just log and re-arm?
            // FIXME: remove this
            std.debug.panic("onPacketsIn failed with: {s}", .{@errorName(read_err)});
        }

        const bytes_read = try xev_read_result;
        if (bytes_read == 0) {
            // Should not happen with UDP? But handle defensively.
            span.warn("Received 0 bytes from UDP read, rearming.", .{});
            return .rearm;
        }
        span.trace("Received {d} bytes from {}", .{ bytes_read, peer_address });
        // span.trace("Packet data: {any}", .{std.fmt.fmtSliceHexLower(xev_read_buffer.slice[0..bytes_read])});

        const self = maybe_self orelse {
            std.debug.panic("onPacketsIn called with null self context!", .{});
        };

        // Get local address packet was received on (needed by lsquic)
        const local_endpoint = self.socket.getLocalEndPoint() catch |err| {
            span.err("Failed to get local endpoint in onPacketsIn: {s}", .{@errorName(err)});
            std.debug.panic("Failed to get local address: {s}", .{@errorName(err)}); // Probably fatal
            // return .disarm;
        };
        span.trace("Packet received on local endpoint: {}", .{local_endpoint});

        // Convert addresses to sockaddr format for lsquic
        // TODO: Check if network.EndPoint.SockAddr maps to sockaddr correctly
        const local_sa = toSocketAddress(local_endpoint);
        const peer_sa = peer_address.any; // xev provides std.net.Address which has .any

        span.trace("Passing packet to lsquic engine", .{});
        if (lsquic.lsquic_engine_packet_in(
            self.lsquic_engine,
            xev_read_buffer.slice.ptr, // Pointer to received data
            bytes_read, // Length of received data
            @ptrCast(&local_sa), // Pointer to local sockaddr
            @ptrCast(&peer_sa), // Pointer to peer sockaddr
            @ptrCast(self), // Pass client as connection context hint (lsquic might ignore for existing conn)
            0, // ECN value (0 = Not-ECT)
        ) != 0) {
            // This indicates an error processing the packet *within lsquic*
            span.err("lsquic_engine_packet_in failed (return value != 0)", .{});
            // What does non-zero return mean? Connection error? Engine error? Check docs.
            // TODO: Maybe log error and continue? Panicking might be too harsh.
            std.debug.panic("lsquic_engine_packet_in failed", .{});
        } else {
            span.trace("lsquic_engine_packet_in processed successfully", .{});
        }

        // Always re-arm the UDP read to receive the next packet
        return .rearm;
    }

    // Helper for lsquic engine API: provides SSL context for new connections
    fn getSslContext(
        peer_ctx: ?*anyopaque, // Context passed as 5th arg to lsquic_engine_connect
        _: ?*const lsquic.struct_sockaddr, // Remote address (unused here)
    ) callconv(.C) ?*lsquic.struct_ssl_ctx_st {
        // In our client setup, peer_ctx is always the main client SSL_CTX
        // Return the opaque pointer cast back to the SSL_CTX type
        return @ptrCast(peer_ctx.?);
    }

    // Helper for lsquic engine API: sends packets out via the underlying socket
    fn sendPacketsOut(
        ctx: ?*anyopaque, // Context provided in lsquic_engine_api (the JamSnpClient*)
        specs_ptr: ?[*]const lsquic.lsquic_out_spec,
        specs_len: c_uint,
    ) callconv(.C) c_int {
        const span = trace.span(.client_send_packets_out);
        defer span.deinit();
        span.trace("Request to send {d} packet specs", .{specs_len});

        if (specs_len == 0) {
            return 0;
        }

        const client = @as(*JamSnpClient, @ptrCast(@alignCast(ctx.?)));
        const specs = specs_ptr.?[0..specs_len];

        var packets_sent_count: c_int = 0;
        send_loop: for (specs) |*spec| {
            // Note: lsquic often provides multiple iovecs per spec for coalescing.
            // We need to send them as a single datagram using sendmsg or similar
            // if we want to benefit from coalescing.
            // The current simple loop sends each iovec as a separate packet,
            // which is less efficient but easier to implement with basic sendTo.

            // TODO: Implement sendmsg for coalescing if performance is critical.
            // For now, iterate iovecs (less efficient).

            const iov_slice = spec.iov[0..spec.iovlen];
            span.trace(" Processing spec with {d} iovecs to peer_ctx={*}", .{ spec.iovlen, spec.peer_ctx });

            // Get destination address once per spec
            const dest_addr = std.net.Address.initPosix(@ptrCast(@alignCast(spec.dest_sa)));
            const dest_endpoint = network.EndPoint.fromSocketAddress(@ptrCast(@alignCast(spec.dest_sa)), dest_addr.getOsSockLen()) catch |err| {
                span.err("Failed to convert destination sockaddr: {s}", .{@errorName(err)});
                // Stop sending this batch if conversion fails
                break :send_loop;
            };

            for (iov_slice) |iov| {
                const packet_buf: [*]const u8 = @ptrCast(iov.iov_base);
                const packet_len: usize = @intCast(iov.iov_len);
                if (packet_len == 0) continue; // Skip empty buffers
                const packet = packet_buf[0..packet_len];

                span.trace("  Sending iovec of {d} bytes to {}", .{ packet_len, dest_endpoint });

                // Send the individual iovec using sendTo
                _ = client.socket.sendTo(dest_endpoint, packet) catch |err| {
                    // Handle send errors
                    span.warn("Failed to send packet spec to {}: {s}", .{ dest_endpoint, @errorName(err) });
                    // Per lsquic docs, check errno:
                    switch (err) {
                        error.WouldBlock => { // Corresponds to EAGAIN/EWOULDBLOCK
                            span.warn("Socket send would block (EAGAIN). Stopping batch.", .{});
                            // Stop processing this batch, lsquic expects us to return packets_sent_count
                            // and call lsquic_engine_send_unsent_packets() later.
                            break :send_loop;
                        },
                        else => {
                            // Unexpected error
                            span.err("Unhandled socket send error: {s}", .{@errorName(err)});
                            break :send_loop;
                        },
                    }
                };
            }
            // If we successfully sent all iovecs for this spec:
            packets_sent_count += 1;
        }

        span.trace("Attempted to send {d}/{d} packet specs", .{ packets_sent_count, specs_len });
        // Return the number of specs whose iovecs were *all* successfully submitted for sending
        return packets_sent_count;
    }
};
