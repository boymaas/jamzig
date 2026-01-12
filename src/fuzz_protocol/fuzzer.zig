const std = @import("std");
const net = std.net;
const testing = std.testing;

const messages = @import("messages.zig");
const frame = @import("frame.zig");
const target = @import("target.zig");
const socket_target = @import("socket_target.zig");
const embedded_target = @import("embedded_target.zig");
const target_interface = @import("target_interface.zig");
const state_converter = @import("state_converter.zig");
const report = @import("report.zig");
const version = @import("version.zig");

const jamtestnet = @import("../trace_runner/parsers.zig");
const state_transitions = @import("../trace_runner/state_transitions.zig");
const state_dict_reconstruct = @import("../state_dictionary/reconstruct.zig");

const sequoia = @import("../sequoia.zig");
const types = @import("../types.zig");
const block_import = @import("../block_import.zig");
const jam_params = @import("../jam_params.zig");
const io = @import("../io.zig");
const JamState = @import("../state.zig").JamState;
const state_dictionary = @import("../state_dictionary.zig");

const trace = @import("tracing").scoped(.fuzz_protocol);

const FuzzerState = enum {
    initial,
    connected,
    handshake_complete,
    state_initialized,

    pub fn assertReachedState(self: FuzzerState, state: FuzzerState) !void {
        if (@intFromEnum(self) < @intFromEnum(state)) {
            return error.StateNotReached;
        }
    }
};

/// Result of sending a block
pub const BlockImportResult = union(enum) {
    success: messages.StateRootHash,
    import_error: []const u8,

    pub fn deinit(self: *BlockImportResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .import_error => |msg| allocator.free(msg),
            .success => {},
        }
        self.* = undefined;
    }
};

/// Type aliases for common Fuzzer configurations
pub fn SocketFuzzer(comptime params: jam_params.Params) type {
    return Fuzzer(io.SequentialExecutor, socket_target.SocketTarget, params);
}
pub fn EmbeddedFuzzer(comptime params: jam_params.Params) type {
    return Fuzzer(io.SequentialExecutor, embedded_target.EmbeddedTarget(io.SequentialExecutor, params), params);
}

/// Helper factory functions for creating fuzzer instances with target initialization
pub fn createSocketFuzzer(
    comptime params: jam_params.Params,
    allocator: std.mem.Allocator,
    seed: u64,
    socket_path: []const u8,
) !*SocketFuzzer(params) {
    var target_instance = try socket_target.SocketTarget.init(allocator, .{ .socket_path = socket_path });
    errdefer target_instance.deinit();

    return SocketFuzzer(params).create(allocator, seed, target_instance);
}

pub fn createEmbeddedFuzzer(
    comptime params: jam_params.Params,
    executor: *io.SequentialExecutor,
    allocator: std.mem.Allocator,
    seed: u64,
) !*EmbeddedFuzzer(params) {
    var target_instance = try embedded_target.EmbeddedTarget(io.SequentialExecutor, params).init(allocator, executor, .{});
    errdefer target_instance.deinit();

    return EmbeddedFuzzer(params).create(allocator, seed, target_instance);
}

/// Main Fuzzer implementation for JAM protocol conformance testing
/// Parameterized by JAM params, IOExecutor for async operations and Target for communication
pub fn Fuzzer(comptime IOExecutor: type, comptime Target: type, comptime params: jam_params.Params) type {
    return struct {
        allocator: std.mem.Allocator,

        // Deterministic execution
        prng: std.Random.DefaultPrng,
        rng: std.Random,
        seed: u64,

        // Target communication
        target: Target,

        state: FuzzerState = .initial,

        /// Initialize fuzzer with deterministic seed and pre-initialized target
        pub fn create(allocator: std.mem.Allocator, seed: u64, target_instance: Target) !*Self {
            const span = trace.span(@src(), .fuzzer_init);
            defer span.deinit();

            span.debug("Initializing fuzzer with seed: {d}", .{seed});

            const fuzzer = try allocator.create(Self);
            errdefer allocator.destroy(fuzzer);

            fuzzer.* = .{
                .allocator = allocator,
                .target = target_instance,
                .prng = std.Random.DefaultPrng.init(seed),
                .rng = undefined,
                .seed = seed,
                .state = .initial,
            };

            fuzzer.rng = fuzzer.prng.random();

            span.debug("Fuzzer initialized successfully", .{});

            return fuzzer;
        }

        /// Clean up all fuzzer resources
        pub fn destroy(self: *Self) void {
            const span = trace.span(@src(), .fuzzer_deinit);
            defer span.deinit();

            self.target.deinit();

            const allocator = self.allocator;
            allocator.destroy(self);
        }

        const Self = @This();

        /// Connect to target (if supported)
        pub fn connectToTarget(self: *Self) !void {
            const span = trace.span(@src(), .connect_target);
            defer span.deinit();

            if (@hasDecl(Target, "connectToTarget")) {
                try self.target.connectToTarget();
                self.state = .connected;
                span.debug("Connected to target successfully", .{});
            } else {
                self.state = .connected;
                span.debug("Embedded target ready", .{});
            }
        }

        /// Disconnect from target (if supported)
        pub fn disconnect(self: *Self) void {
            const span = trace.span(@src(), .disconnect_target);
            defer span.deinit();

            if (@hasDecl(Target, "disconnect")) {
                self.target.disconnect();
                self.state = .initial;
                span.debug("Disconnected from target", .{});
            } else {
                span.debug("No disconnection needed for embedded target", .{});
            }
        }

        /// Perform handshake with target
        pub fn performHandshake(self: *Self) !void {
            const span = trace.span(@src(), .fuzzer_handshake);
            defer span.deinit();
            span.debug("Performing handshake with target", .{});

            if (self.state != .connected) {
                return error.NotConnected;
            }

            const fuzzer_peer_info = messages.PeerInfo{
                .fuzz_version = version.FUZZ_PROTOCOL_VERSION,
                .fuzz_features = version.IMPLEMENTED_FUZZ_FEATURES,
                .jam_version = version.PROTOCOL_VERSION,
                .app_version = version.FUZZ_TARGET_VERSION,
                .app_name = "jamzig-fuzzer",
            };

            try self.target.sendMessage(params, .{ .peer_info = fuzzer_peer_info });

            var response = try self.target.readMessage(params);
            defer response.deinit(self.allocator);

            switch (response) {
                .peer_info => |peer_info| {
                    span.debug("Received peer info from: {s}", .{peer_info.app_name});
                    self.state = .handshake_complete;
                },
                else => return error.UnexpectedHandshakeResponse,
            }

            span.debug("Handshake completed successfully", .{});
        }

        /// Initialize state on target (v1)
        pub fn setState(self: *Self, header: types.Header, state: messages.State) !messages.StateRootHash {
            const span = trace.span(@src(), .fuzzer_initialize_state);
            defer span.deinit();
            span.debug("Initializing state on target with {d} key-value pairs", .{state.items.len});

            if (self.state != .handshake_complete) {
                return error.HandshakeNotComplete;
            }

            var ancestry_items = std.ArrayList(messages.AncestryItem).init(self.allocator);
            defer ancestry_items.deinit();

            var ancestry = messages.Ancestry{
                .items = try ancestry_items.toOwnedSlice(),
            };
            defer ancestry.deinit(self.allocator);

            try self.target.sendMessage(params, .{ .initialize = .{
                .header = header,
                .keyvals = state,
                .ancestry = ancestry,
            } });

            var response = try self.target.readMessage(params);
            defer response.deinit(self.allocator);

            switch (response) {
                .state_root => |state_root| {
                    self.state = .state_initialized;
                    span.debug("State set successfully, root: {s}", .{std.fmt.fmtSliceHexLower(&state_root)});
                    return state_root;
                },
                else => return error.UnexpectedSetStateResponse,
            }
        }

        /// Send block to target for processing
        pub fn sendBlock(self: *Self, block: *const types.Block) !BlockImportResult {
            const span = trace.span(@src(), .fuzzer_send_block);
            defer span.deinit();
            span.debug("Sending block to target", .{});
            span.trace("{s}", .{types.fmt.format(block)});

            if (self.state != .state_initialized) {
                return error.StateNotInitialized;
            }

            try self.target.sendMessage(params, .{ .import_block = block.* });

            var response = try self.target.readMessage(params);
            defer response.deinit(self.allocator);

            switch (response) {
                .state_root => |state_root| {
                    try self.state.assertReachedState(.state_initialized);
                    span.debug("Block processed, state root: {s}", .{std.fmt.fmtSliceHexLower(&state_root)});
                    return BlockImportResult{ .success = state_root };
                },
                .@"error" => |err| {
                    span.err("Block import error: {s}", .{err});
                    const error_msg = try self.allocator.dupe(u8, err);
                    return BlockImportResult{ .import_error = error_msg };
                },
                else => return error.UnexpectedImportBlockResponse,
            }
        }

        /// Get state from target by header hash
        pub fn getState(self: *Self, header_hash: messages.HeaderHash) !messages.State {
            const span = trace.span(@src(), .fuzzer_get_state);
            defer span.deinit();
            span.debug("Getting state from target for header: {s}", .{std.fmt.fmtSliceHexLower(&header_hash)});

            try self.state.assertReachedState(.state_initialized);

            try self.target.sendMessage(params, .{ .get_state = header_hash });

            var response = try self.target.readMessage(params);
            defer response.deinit(self.allocator);

            switch (response) {
                .state => |state| {
                    span.debug("Received state with {d} key-value pairs", .{state.items.len});
                    const result = state;
                    response = .{ .state = messages.State.Empty };
                    return result;
                },
                else => return error.UnexpectedGetStateResponse,
            }
        }

        /// Compare two state roots (utility for providers)
        pub fn compareStateRoots(local_root: messages.StateRootHash, target_root: messages.StateRootHash) bool {
            return std.mem.eql(u8, &local_root, &target_root);
        }

        pub fn endSession(self: *Self) void {
            const span = trace.span(@src(), .fuzzer_end_session);
            defer span.deinit();
            span.debug("Ending fuzzer session", .{});

            self.disconnect();

            self.state = .initial;

            span.debug("Fuzzer session ended successfully", .{});
        }

        const TargetThreadContext = struct {
            allocator: std.mem.Allocator,
            socket_path: []const u8,
            executor: *IOExecutor,
        };

        fn targetThreadMain(context: *const TargetThreadContext) void {
            defer context.allocator.destroy(context);

            var target_server = target.TargetServer(IOExecutor).init(context.allocator, context.socket_path, .restart_on_disconnect, context.executor) catch |err| {
                std.log.err("Failed to initialize target server: {s}", .{@errorName(err)});
                return;
            };
            defer target_server.deinit();

            target_server.start() catch |err| {
                std.log.err("Target server error: {s}", .{@errorName(err)});
            };
        }
    };
}
