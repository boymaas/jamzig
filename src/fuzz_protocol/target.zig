
const std = @import("std");
const builtin = @import("builtin");
const net = std.net;
const messages = @import("messages.zig");
const frame = @import("frame.zig");
const version = @import("version.zig");
const state_converter = @import("state_converter.zig");
const state_dictionary = @import("../state_dictionary.zig");
const sequoia = @import("../sequoia.zig");
const jamstate = @import("../state.zig");
const state_merklization = @import("../state_merklization.zig");
const types = @import("../types.zig");
const block_import = @import("../block_import.zig");
const io = @import("../io.zig");

const trace = @import("tracing").scoped(.fuzz_protocol);

/// Server restart behavior after client disconnect
pub const RestartBehavior = enum {
    /// Exit the server after client disconnects
    exit_on_disconnect,
    /// Restart and wait for new connection after client disconnects
    restart_on_disconnect,
};

/// Server state for the fuzz protocol target
pub const ServerState = enum {
    /// Initial state, no connection established
    initial,
    /// Handshake completed, ready to receive Initialize
    handshake_complete,
    /// State initialized, ready for block operations
    ready,
    /// Shutting down
    shutting_down,
};

/// Target server that implements the JAM protocol conformance testing target
pub fn TargetServer(comptime IOExecutor: type, comptime params: @import("../jam_params.zig").Params) type {
    return struct {
        allocator: std.mem.Allocator,
        socket_path: []const u8,

        current_state: ?jamstate.JamState(params) = null,
        current_state_root: ?messages.StateRootHash = null,
        server_state: ServerState = .initial,
        negotiated_features: messages.Features = 0,

        block_importer: block_import.BlockImporter(IOExecutor, params),

        last_block_parent: ?types.Hash = null,
        last_block_hash: ?types.Hash = null,
        last_block_state_root: ?messages.StateRootHash = null,

        pending_result: ?block_import.BlockImporter(IOExecutor, params).ImportResult = null,

        restart_behavior: RestartBehavior = .restart_on_disconnect,

        const Self = @This();

        pub fn init(executor: *IOExecutor, allocator: std.mem.Allocator, socket_path: []const u8, restart_behavior: RestartBehavior) !Self {
            const block_importer = block_import.BlockImporter(IOExecutor, params).init(executor, allocator);

            return Self{
                .allocator = allocator,
                .socket_path = socket_path,
                .block_importer = block_importer,
                .restart_behavior = restart_behavior,
            };
        }

        pub fn deinit(self: *Self) void {
            const span = trace.span(@src(), .deinit);
            defer span.deinit();

            if (self.current_state) |*s| s.deinit(self.allocator);

            if (self.pending_result) |*result| result.deinit();

            if (self.socket_path.len > 0 and std.fs.path.isAbsolute(self.socket_path)) {
                const stat = std.fs.cwd().statFile(self.socket_path) catch |err| switch (err) {
                    error.FileNotFound => {
                        return;
                    },
                    else => {
                        span.warn("Cannot stat socket file for cleanup: {s}", .{@errorName(err)});
                        return;
                    },
                };

                if (stat.kind == .unix_domain_socket) {
                    std.fs.deleteFileAbsolute(self.socket_path) catch |err| {
                        span.err("Failed to delete socket file: {s}", .{@errorName(err)});
                    };
                } else {
                    span.warn("Path exists but is not a socket (kind={s}), not deleting: {s}", .{ @tagName(stat.kind), self.socket_path });
                }
            }

            self.* = undefined;
        }

        /// Request server shutdown
        pub fn shutdown(self: *Self) void {
            self.server_state = .shutting_down;
        }

        /// Start the server and bind to Unix domain socket
        pub fn start(self: *Self) !void {
            const span = trace.span(@src(), .start_server);
            defer span.deinit();
            span.debug("Starting target server at socket: {s}", .{self.socket_path});

            std.fs.deleteFileAbsolute(self.socket_path) catch {};

            const address = try net.Address.initUnix(self.socket_path);

            var server_socket = try address.listen(.{});
            defer server_socket.deinit();

            while (true) {
                if (self.server_state == .shutting_down) {
                    span.debug("Server shutting down", .{});
                    break;
                }

                span.debug("Server bound and listening on Unix socket", .{});

                var poll_fds = [_]std.posix.pollfd{
                    .{
                        .fd = server_socket.stream.handle,
                        .events = std.posix.POLL.IN,
                        .revents = 0,
                    },
                };

                const poll_result = std.posix.poll(&poll_fds, 100) catch |err| {
                    span.err("Poll error: {s}", .{@errorName(err)});
                    continue;
                };

                if (self.server_state == .shutting_down) {
                    span.debug("Server shutting down", .{});
                    break;
                }

                if (poll_result == 0) {
                    continue;
                }

                if (poll_fds[0].revents & std.posix.POLL.IN == 0) {
                    continue;
                }

                const connection = server_socket.accept() catch |err| {
                    span.err("Failed to accept connection: {s}", .{@errorName(err)});
                    continue;
                };

                span.debug("Accepted new connection", .{});

                self.handleConnection(connection.stream) catch |err| {
                    const inner_span = trace.span(@src(), .handle_error);
                    defer inner_span.deinit();

                    switch (err) {
                        error.EndOfStream, error.UnexpectedEndOfStream => {
                            inner_span.debug("Connection closed by client", .{});
                        },
                        error.BrokenPipe => {
                            inner_span.debug("Client disconnected unexpectedly", .{});
                        },
                        else => {
                            inner_span.err("Error handling connection: {s}", .{@errorName(err)});
                        },
                    }
                };

                connection.stream.close();
                span.debug("Connection closed", .{});

                if (self.restart_behavior == .exit_on_disconnect) {
                    span.debug("restart_behavior is exit_on_disconnect, exiting server loop", .{});
                    break;
                }
            }
        }

        /// Handle a single client connection
        fn handleConnection(self: *Self, stream: net.Stream) !void {
            const span = trace.span(@src(), .handle_connection);
            defer span.deinit();

            while (true) {
                var request_message = self.readMessage(stream) catch |err| {
                    if (err == error.EndOfStream) {
                        span.debug("Client disconnected", .{});
                        return;
                    }
                    return err;
                };
                defer request_message.deinit(self.allocator);

                span.debug("Received message: {s}", .{@tagName(request_message)});

                var response_message = self.processMessage(request_message) catch |err| {
                    std.debug.print("Error processing message {s}: {s}. Stopping processing after this message.\n", .{ @tagName(request_message), @errorName(err) });
                    return err;
                };
                defer if (response_message) |*msg| {
                    msg.deinit(self.allocator);
                };

                if (response_message) |response| {
                    try self.sendMessage(stream, response);
                    span.debug("Sent response: {s}", .{@tagName(response)});
                }
            }
        }

        /// Read a message from the stream
        pub fn readMessage(self: *Self, stream: net.Stream) !messages.Message {
            const frame_data = try frame.readFrame(self.allocator, stream);
            defer self.allocator.free(frame_data);

            return messages.decodeMessage(params, self.allocator, frame_data);
        }

        /// Send a message to the stream
        pub fn sendMessage(self: *Self, stream: net.Stream, message: messages.Message) !void {
            const encoded = try messages.encodeMessage(params, self.allocator, message);
            defer self.allocator.free(encoded);

            try frame.writeFrame(stream, encoded);
        }

        /// Process an incoming message and generate appropriate response
        pub fn processMessage(self: *Self, message: messages.Message) !?messages.Message {
            const span = trace.span(@src(), .process_message);
            defer span.deinit();

            switch (message) {
                .peer_info => |peer_info| {
                    span.debug("Processing PeerInfo v{d} from: {s}", .{ peer_info.fuzz_version, peer_info.app_name });
                    span.debug("Remote features: 0x{x}", .{peer_info.fuzz_features});

                    const negotiated_features = peer_info.fuzz_features & version.IMPLEMENTED_FUZZ_FEATURES;
                    self.negotiated_features = negotiated_features;
                    span.debug("Negotiated features: 0x{x}", .{negotiated_features});

                    const our_peer_info = try messages.PeerInfo.buildFromStaticString(
                        self.allocator,
                        version.FUZZ_PROTOCOL_VERSION,
                        version.IMPLEMENTED_FUZZ_FEATURES,
                        version.PROTOCOL_VERSION,
                        version.FUZZ_TARGET_VERSION,
                        version.TARGET_NAME,
                    );

                    self.server_state = .handshake_complete;
                    return messages.Message{ .peer_info = our_peer_info };
                },

                .initialize => |initialize| {
                    if (self.server_state != .handshake_complete and self.server_state != .ready) return error.HandshakeNotComplete;

                    span.debug("Processing Initialize with {d} key-value pairs, ancestry length: {d}", .{ initialize.keyvals.items.len, initialize.ancestry.items.len });

                    if (self.current_state) |*s| s.deinit(self.allocator);

                    if (self.pending_result) |*result| {
                        result.deinit();
                        self.pending_result = null;
                    }

                    self.last_block_parent = null;
                    self.last_block_parent = null;
                    span.debug("Fork detection state reset for fresh initialization", .{});

                    const enable_ancestry = (self.negotiated_features & messages.FEATURE_ANCESTRY) != 0;

                    self.current_state = try state_converter.fuzzStateToJamState(
                        params,
                        self.allocator,
                        initialize.keyvals,
                    );

                    if (enable_ancestry) {
                        try self.current_state.?.initAncestry(self.allocator);
                        if (self.current_state.?.ancestry) |*ancestry| {
                            for (initialize.ancestry.items) |item| {
                                try ancestry.addHeader(item.header_hash, item.slot);
                            }
                        }
                    }

                    self.current_state_root = try self.computeStateRoot();
                    self.server_state = .ready;

                    self.last_block_state_root = self.current_state_root;

                    return messages.Message{ .state_root = self.current_state_root.? };
                },

                .import_block => |block| {
                    const import_block_span = span.child(@src(), .import_block);
                    defer import_block_span.deinit();

                    if (self.server_state != .ready) return error.StateNotReady;

                    const block_hash = try block.header.header_hash(params, self.allocator);

                    span.debug("Processing ImportBlock: block_hash={x}", .{std.fmt.fmtSliceHexLower(&block_hash)});
                    span.trace("{}", .{types.fmt.format(block)});

                    import_block_span.debug("Fork detection: last_block_hash={?s}, last_block_parent={?s}, current_block_parent={s}", .{
                        if (self.last_block_hash) |h| std.fmt.fmtSliceHexLower(&h) else null,
                        if (self.last_block_parent) |h| std.fmt.fmtSliceHexLower(&h) else null,
                        std.fmt.fmtSliceHexLower(&block.header.parent),
                    });
                    const is_fork = if (self.last_block_hash) |last_block_hash| blk: {
                        if (std.mem.eql(u8, &block.header.parent, &last_block_hash)) {
                            import_block_span.debug("Sequential block detected", .{});
                            break :blk false;
                        } else if (self.last_block_parent) |last_block_parent| {
                            if (std.mem.eql(u8, &block.header.parent, &last_block_parent)) {
                                import_block_span.debug("Fork detected: block is sibling of last block", .{});
                                break :blk true;
                            } else {
                                import_block_span.err("Invalid block parent: expected {s} or {s}, got {s}", .{
                                    std.fmt.fmtSliceHexLower(&last_block_hash),
                                    std.fmt.fmtSliceHexLower(&last_block_parent),
                                    std.fmt.fmtSliceHexLower(&block.header.parent),
                                });
                                const error_msg = try std.fmt.allocPrint(
                                    self.allocator,
                                    "Invalid parent hash: not last block or parent",
                                    .{},
                                );
                                return messages.Message{ .@"error" = error_msg };
                            }
                        } else {
                            break :blk false;
                        }
                    } else false;

                    if (is_fork) {
                        if (self.pending_result) |*result| {
                            result.deinit();
                            self.pending_result = null;
                        }
                        self.current_state_root = self.last_block_state_root;
                    } else if (self.pending_result) |*result| {
                        span.debug("Sequential block: committing pending changes", .{});
                        try result.commit();
                        result.deinit();
                        self.pending_result = null;


                        if (comptime builtin.mode == .Debug) {
                            const state_root = try self.current_state.?.buildStateRoot(self.allocator);
                            if (!std.mem.eql(u8, &state_root, &self.current_state_root.?)) {
                                span.err("State root differs after commit, this is an internal state problem. Check fuzz target code", .{});
                                return error.StateRootDiffersAfterCommit;
                            }
                        }
                    }

                    if (!is_fork) {
                        self.last_block_state_root = self.current_state_root;
                    }

                    self.last_block_hash = block_hash;
                    self.last_block_parent = block.header.parent;

                    var result = self.block_importer.importBlockWithCachedRoot(
                        &self.current_state.?,
                        self.current_state_root.?, // CACHED value (required)
                        &block,
                    ) catch |err| {
                        span.err("Failed to import block: {s}. Sending error response.", .{@errorName(err)});
                        const error_msg = try std.fmt.allocPrint(self.allocator, "Block import failed: {s}", .{@errorName(err)});
                        return messages.Message{ .@"error" = error_msg };
                    };

                    span.debug("Block imported successfully, sealed with tickets: {}", .{result.sealed_with_tickets});

                    if (self.pending_result) |*prev| prev.deinit();
                    self.pending_result = result;

                    const new_state_root = try result.state_transition.computeStateRoot(self.allocator);
                    self.current_state_root = new_state_root;

                    span.debug("Block processed, state root: {s}", .{std.fmt.fmtSliceHexLower(&new_state_root)});

                    return messages.Message{ .state_root = new_state_root };
                },

                .get_state => |header_hash| {
                    if (self.server_state != .ready) return error.StateNotReady;

                    span.debug("Processing GetState for header: {s}", .{std.fmt.fmtSliceHexLower(&header_hash)});

                    // NOTE: Must call jamStateToFuzzState inside the branch to avoid
                    var result = if (self.pending_result) |*pending| blk: {
                        span.debug("GetState: Using merged view with pending changes", .{});
                        const merged_view = pending.state_transition.createMergedView();
                        break :blk try state_converter.jamStateToFuzzState(
                            params,
                            self.allocator,
                            &merged_view,
                        );
                    } else blk: {
                        span.debug("GetState: Using current committed state", .{});
                        break :blk try state_converter.jamStateToFuzzState(
                            params,
                            self.allocator,
                            &self.current_state.?,
                        );
                    };
                    const state = result.state;
                    result.state = messages.State.Empty; // Clear to prevent double-free
                    result.deinit(); // Clean up the result struct

                    return messages.Message{ .state = state };
                },

                .kill => {
                    span.debug("Received Kill message, shutting down server", .{});
                    self.server_state = .shutting_down;
                    return null; // No response needed
                },

                else => {
                    span.err("Unexpected message type in target server", .{});
                    return error.UnexpectedMessage;
                },
            }
        }

        fn computeStateRoot(self: *Self) !messages.StateRootHash {
            return try state_merklization.merklizeState(params, self.allocator, &self.current_state.?);
        }
    };
}
