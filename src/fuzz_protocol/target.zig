const std = @import("std");
const net = std.net;
const messages = @import("messages.zig");
const frame = @import("frame.zig");
const version = @import("version.zig");

const trace = @import("../tracing.zig").scoped(.fuzz_protocol);

/// Target server that implements the JAM protocol conformance testing target
pub const TargetServer = struct {
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    server_socket: ?net.Server = null,

    // State management
    current_state: std.AutoHashMap(messages.TrieKey, []u8),
    current_state_root: ?messages.StateRootHash = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, socket_path: []const u8) Self {
        return Self{
            .allocator = allocator,
            .socket_path = socket_path,
            .current_state = std.AutoHashMap(messages.TrieKey, []u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.server_socket) |*server| {
            server.deinit();
        }

        // Free stored state values
        var iterator = self.current_state.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.current_state.deinit();
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
        self.server_socket = try address.listen(.{});
        span.debug("Server bound and listening on Unix socket", .{});

        // Accept connections loop
        while (true) {
            const connection = self.server_socket.?.accept() catch |err| {
                span.err("Failed to accept connection: {s}", .{@errorName(err)});
                continue;
            };

            span.debug("Accepted new connection", .{});

            // Handle connection (synchronous for now)
            self.handleConnection(connection.stream) catch |err| {
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

        var handshake_complete = false;

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
            const response_message = try self.processMessage(request_message.value, &handshake_complete);
            defer if (response_message) |msg| {
                // Only deinit if we allocated memory for response
                switch (msg) {
                    .state => |state| {
                        for (state) |kv| {
                            self.allocator.free(kv.value);
                        }
                        self.allocator.free(state);
                    },
                    else => {},
                }
            };

            // Send response if one was generated
            if (response_message) |response| {
                try self.sendMessage(stream, response);
                span.debug("Sent response: {s}", .{@tagName(response)});
            }
        }
    }

    /// Read a message from the stream
    fn readMessage(self: *Self, stream: net.Stream) !messages.codec.Deserialized(messages.Message) {
        const frame_data = try frame.readFrame(self.allocator, stream);
        defer self.allocator.free(frame_data);

        // Decode message using JAM codec
        return messages.decodeMessage(self.allocator, frame_data);
    }

    /// Send a message to the stream
    fn sendMessage(self: *Self, stream: net.Stream, message: messages.Message) !void {
        const encoded = try messages.encodeMessage(self.allocator, message);
        defer self.allocator.free(encoded);

        try frame.writeFrame(stream, encoded);
    }

    /// Process an incoming message and generate appropriate response
    fn processMessage(self: *Self, message: messages.Message, handshake_complete: *bool) !?messages.Message {
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

                handshake_complete.* = true;
                return messages.Message{ .peer_info = our_peer_info };
            },

            .set_state => |set_state| {
                if (!handshake_complete.*) return error.HandshakeNotComplete;

                span.debug("Processing SetState with {d} key-value pairs", .{set_state.state.len});

                // Clear current state
                var iterator = self.current_state.iterator();
                while (iterator.next()) |entry| {
                    self.allocator.free(entry.value_ptr.*);
                }
                self.current_state.clearAndFree();

                for (set_state.state) |kv| {
                    const value_copy = try self.allocator.dupe(u8, kv.value);
                    try self.current_state.put(kv.key, value_copy);
                }

                self.current_state_root = try self.computeStateRoot();

                return messages.Message{ .state_root = self.current_state_root.? };
            },

            .import_block => |_| {
                if (!handshake_complete.*) return error.HandshakeNotComplete;

                span.debug("Processing ImportBlock", .{});

                // TODO: Implement actual block processing
                // For now, just return current state root
                if (self.current_state_root) |root| {
                    return messages.Message{ .state_root = root };
                } else {
                    // Return zero state root if no state set
                    return messages.Message{ .state_root = std.mem.zeroes(messages.StateRootHash) };
                }
            },

            .get_state => |header_hash| {
                if (!handshake_complete.*) return error.HandshakeNotComplete;

                span.debug("Processing GetState for header: {s}", .{std.fmt.fmtSliceHexLower(&header_hash)});

                return messages.Message{ .state = &[_]messages.KeyValue{} };
            },

            else => {
                span.err("Unexpected message type in target server", .{});
                return error.UnexpectedMessage;
            },
        }
    }

    fn computeStateRoot(_: *Self) !messages.StateRootHash {
        return [_]u8{0x00} ** 32;
    }
};
