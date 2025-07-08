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
const stf = @import("../stf.zig");
const types = @import("../types.zig");

const trace = @import("../tracing.zig").scoped(.fuzz_protocol);

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
pub const TargetServer = struct {
    allocator: std.mem.Allocator,
    socket_path: []const u8,

    // State management
    current_state: ?jamstate.JamState(messages.FUZZ_PARAMS) = null,
    current_state_root: ?messages.StateRootHash = null,
    server_state: ServerState = .initial,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, socket_path: []const u8) !Self {
        return Self{
            .allocator = allocator,
            .socket_path = socket_path,
        };
    }

    pub fn deinit(self: *Self) void {
        // Deinit JAM state
        if (self.current_state) |*s| s.deinit(self.allocator);

        // Remove existing socket file if it exists
        self.* = undefined; // Clear the struct
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

        span.debug("Server bound and listening on Unix socket", .{});

        // Accept connections loop
        while (true) {
            const connection = server_socket.accept() catch |err| {
                span.err("Failed to accept connection: {s}", .{@errorName(err)});
                continue;
            };

            span.debug("Accepted new connection", .{});

            // Handle connection (synchronous for now)
            self.handleConnection(connection.stream) catch |err| {
                if (err == error.UnexpectedEndOfStream) {
                    span.debug("Connection closed by server", .{});
                    break; // Just skip this connection

                }
                span.err("Error handling connection: {s}", .{@errorName(err)});
            };

            connection.stream.close();
            span.debug("Connection closed", .{});
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
            defer request_message.deinit();

            span.debug("Received message: {s}", .{@tagName(request_message.value)});

            // Process message and generate response
            var response_message = try self.processMessage(request_message.value);
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
    pub fn readMessage(self: *Self, stream: net.Stream) !messages.codec.Deserialized(messages.Message) {
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

                // Respond with our own peer info
                const our_peer_info = messages.PeerInfo{
                    .name = version.TARGET_NAME,
                    .version = version.FUZZ_TARGET_VERSION,
                    .protocol_version = version.PROTOCOL_VERSION,
                };

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

                // Apply state transition using the STF
                var state_transition = try stf.stateTransition(
                    messages.FUZZ_PARAMS,
                    self.allocator,
                    &self.current_state.?,
                    &block,
                );
                defer state_transition.deinitHeap();

                // Merge the transition results into our current state
                try state_transition.mergePrimeOntoBase();

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
