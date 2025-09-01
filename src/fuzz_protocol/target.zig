const std = @import("std");
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

const trace = @import("../tracing.zig").scoped(.fuzz_protocol);

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
    /// Handshake completed, ready to receive SetState
    handshake_complete,
    /// State initialized, ready for block operations
    ready,
    /// Shutting down
    shutting_down,
};

/// Target server that implements the JAM protocol conformance testing target
pub fn TargetServer(comptime IOExecutor: type) type {
    return struct {
        allocator: std.mem.Allocator,
        socket_path: []const u8,

        // State management
        current_state: ?jamstate.JamState(messages.FUZZ_PARAMS) = null,
        current_state_root: ?messages.StateRootHash = null,
        server_state: ServerState = .initial,

        // Block importer
        executor: IOExecutor,
        block_importer: block_import.BlockImporter(IOExecutor, messages.FUZZ_PARAMS),

        // Server management
        restart_behavior: RestartBehavior = .restart_on_disconnect,

        const Self = @This();

        pub fn init(executor: *IOExecutor, allocator: std.mem.Allocator, socket_path: []const u8, restart_behavior: RestartBehavior) !Self {
            const block_importer = block_import.BlockImporter(IOExecutor, messages.FUZZ_PARAMS).init(executor, allocator);

            return Self{
                .allocator = allocator,
                .socket_path = socket_path,
                .executor = executor.*,
                .block_importer = block_importer,
                .restart_behavior = restart_behavior,
            };
        }

        pub fn deinit(self: *Self) void {
            // Deinit JAM state
            if (self.current_state) |*s| s.deinit(self.allocator);

            // Clean up socket file if it exists
            std.fs.deleteFileAbsolute(self.socket_path) catch |err| {
                // Log but don't fail on cleanup error
                const inner_span = trace.span(.cleanup_error);
                defer inner_span.deinit();
                inner_span.err("Failed to delete socket file: {s}", .{@errorName(err)});
            };

            self.* = undefined; // Clear the struct
        }

        /// Request server shutdown
        pub fn shutdown(self: *Self) void {
            self.server_state = .shutting_down;
        }

        /// Start the server and bind to Unix domain socket
        pub fn start(self: *Self) !void {
            const span = trace.span(.start_server);
            defer span.deinit();
            span.debug("Starting target server at socket: {s}", .{self.socket_path});

            // Remove existing socket file if it exists
            std.fs.deleteFileAbsolute(self.socket_path) catch {};

            // Create Unix domain socket address
            const address = try net.Address.initUnix(self.socket_path);

            // Create and bind server socket
            // SOCK_STREAM is used for reliable, ordered, and error-checked delivery
            // https://github.com/davxy/jam-stuff/issues/3
            var server_socket = try address.listen(.{});
            defer server_socket.deinit();

            // Accept connections loop
            while (true) {
                // Check shutdown state at beginning of each loop iteration
                if (self.server_state == .shutting_down) {
                    span.debug("Server shutting down", .{});
                    break;
                }

                span.debug("Server bound and listening on Unix socket", .{});

                // Use poll to check for incoming connections with timeout
                // This allows periodic shutdown checks every 100ms
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

                // Check shutdown state again after poll
                if (self.server_state == .shutting_down) {
                    span.debug("Server shutting down", .{});
                    break;
                }

                // If poll timed out (no connections ready), continue loop to check shutdown state
                if (poll_result == 0) {
                    continue;
                }

                // Check if socket is ready for reading (incoming connection)
                if (poll_fds[0].revents & std.posix.POLL.IN == 0) {
                    continue;
                }

                // Now we know a connection is ready, so accept() won't block
                const connection = server_socket.accept() catch |err| {
                    span.err("Failed to accept connection: {s}", .{@errorName(err)});
                    continue;
                };

                span.debug("Accepted new connection", .{});

                // Handle connection (synchronous for now)
                self.handleConnection(connection.stream) catch |err| {
                    const inner_span = trace.span(.handle_error);
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

                // Ensure connection is closed properly
                connection.stream.close();
                span.debug("Connection closed", .{});

                // Check if we should restart or exit after disconnect
                if (self.restart_behavior == .exit_on_disconnect) {
                    span.debug("restart_behavior is exit_on_disconnect, exiting server loop", .{});
                    break;
                }
            }
        }

        /// Handle a single client connection
        fn handleConnection(self: *Self, stream: net.Stream) !void {
            const span = trace.span(.handle_connection);
            defer span.deinit();

            while (true) {
                // Read message from client
                var request_message = self.readMessage(stream) catch |err| {
                    if (err == error.EndOfStream) {
                        span.debug("Client disconnected", .{});
                        return;
                    }
                    return err;
                };
                defer request_message.deinit(self.allocator);

                span.debug("Received message: {s}", .{@tagName(request_message)});

                // Process message and generate response
                var response_message = self.processMessage(request_message) catch |err| {
                    std.debug.print("Error processing message {s}: {s}. Stopping processing after this message.\n", .{ @tagName(request_message), @errorName(err) });
                    return err;
                };
                defer if (response_message) |*msg| {
                    msg.deinit(self.allocator);
                };

                // Send response if one was generated
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

            // Decode message using JAM codec
            return messages.decodeMessage(self.allocator, frame_data);
        }

        /// Send a message to the stream
        pub fn sendMessage(self: *Self, stream: net.Stream, message: messages.Message) !void {
            const encoded = try messages.encodeMessage(self.allocator, message);
            defer self.allocator.free(encoded);

            try frame.writeFrame(stream, encoded);
        }

        /// Process an incoming message and generate appropriate response
        pub fn processMessage(self: *Self, message: messages.Message) !?messages.Message {
            const span = trace.span(.process_message);
            defer span.deinit();

            switch (message) {
                .peer_info => |peer_info| {
                    span.debug("Processing PeerInfo from: {s}", .{peer_info.name});

                    // Respond with our own peer info, need to allocate
                    // as we are moving ownership to calling scope which will deinit
                    const our_peer_info = try messages.PeerInfo.buildFromStaticString(
                        self.allocator,
                        version.TARGET_NAME,
                        version.FUZZ_TARGET_VERSION,
                        version.PROTOCOL_VERSION,
                    );

                    self.server_state = .handshake_complete;
                    return messages.Message{ .peer_info = our_peer_info };
                },

                .set_state => |set_state| {
                    if (self.server_state != .handshake_complete and self.server_state != .ready) return error.HandshakeNotComplete;

                    span.debug("Processing SetState with {d} key-value pairs", .{set_state.state.items.len});

                    // Clear current state
                    if (self.current_state) |*s| s.deinit(self.allocator);

                    // Reconstruct JAM state from fuzz protocol state
                    self.current_state = try state_converter.fuzzStateToJamState(
                        messages.FUZZ_PARAMS,
                        self.allocator,
                        set_state.state,
                    );

                    self.current_state_root = try self.computeStateRoot();
                    self.server_state = .ready;

                    return messages.Message{ .state_root = self.current_state_root.? };
                },

                .import_block => |block| {
                    if (self.server_state != .ready) return error.StateNotReady;

                    span.debug("Processing ImportBlock", .{});
                    span.trace("{}", .{types.fmt.format(block)});

                    // Use unified block importer with validation
                    var result = self.block_importer.importBlock(
                        &self.current_state.?,
                        &block,
                    ) catch |err| {
                        std.debug.print("Failed to import block: {s}. State remains unchanged.\n", .{@errorName(err)});
                        return messages.Message{ .state_root = self.current_state_root.? };
                    };
                    defer result.deinit();

                    span.debug("Block imported successfully, sealed with tickets: {}", .{result.sealed_with_tickets});

                    // SET TO TRUE to simulate a failing state transition
                    if (false) {
                        var pi_prime: *@import("../state.zig").Pi = result.state_transition.get(.pi_prime) catch |err| {
                            span.err("State transition failed: {s}", .{@errorName(err)});
                            return err;
                        };
                        pi_prime.current_epoch_stats.items[0].blocks_produced += 1; // Increment epoch stats for testing
                    }

                    // Merge the transition results into our current state
                    try result.state_transition.mergePrimeOntoBase();

                    // Update our cached state root
                    self.current_state_root = try self.computeStateRoot();

                    return messages.Message{ .state_root = self.current_state_root.? };
                },

                .get_state => |header_hash| {
                    if (self.server_state != .ready) return error.StateNotReady;

                    span.debug("Processing GetState for header: {s}", .{std.fmt.fmtSliceHexLower(&header_hash)});

                    // Convert current JAM state to fuzz protocol state format
                    var result = try state_converter.jamStateToFuzzState(
                        messages.FUZZ_PARAMS,
                        self.allocator,
                        &self.current_state.?,
                    );
                    // Transfer ownership to the message response
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
            return try state_merklization.merklizeState(messages.FUZZ_PARAMS, self.allocator, &self.current_state.?);
        }
    };
}
