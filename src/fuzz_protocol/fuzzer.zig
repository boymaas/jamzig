const std = @import("std");
const net = std.net;
const testing = std.testing;

const messages = @import("messages.zig");
const frame = @import("frame.zig");
const target = @import("target.zig");
const state_converter = @import("state_converter.zig");
const shared = @import("tests/shared.zig");
const report = @import("report.zig");

const sequoia = @import("../sequoia.zig");
const types = @import("../types.zig");
const stf = @import("../stf.zig");
const jam_params = @import("../jam_params.zig");
const JamState = @import("../state.zig").JamState;
const state_merklization = @import("../state_merklization.zig");

const trace = @import("../tracing.zig").scoped(.fuzz_protocol);

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

/// Main Fuzzer implementation for JAM protocol conformance testing
pub const Fuzzer = struct {
    allocator: std.mem.Allocator,

    // Deterministic execution
    prng: std.Random.DefaultPrng,
    rng: std.Random,
    seed: u64,

    // JAM components
    block_builder: sequoia.BlockBuilder(messages.FUZZ_PARAMS),
    current_jam_state: *const JamState(messages.FUZZ_PARAMS),
    latest_block: ?types.Block = null,

    // Target communication
    socket: ?net.Stream = null,
    socket_path: []const u8,

    // REFACTOR: we also need to track the current block, as sometimes we need to use the header hash
    // of the block
    state: FuzzerState = .initial,

    /// Initialize fuzzer with deterministic seed and target socket path
    pub fn create(allocator: std.mem.Allocator, seed: u64, socket_path: []const u8) !*Fuzzer {
        const span = trace.span(.fuzzer_init);
        defer span.deinit();

        span.debug("Initializing fuzzer with seed: {d}, socket: {s}", .{ seed, socket_path });

        // Create fuzzer struct first to ensure stable addresses
        const fuzzer = try allocator.create(Fuzzer);
        fuzzer.* = undefined;
        fuzzer.socket_path = socket_path;
        fuzzer.allocator = allocator;
        fuzzer.prng = std.Random.DefaultPrng.init(seed);

        // Initialize the rng from the prng stored in fuzzer
        fuzzer.rng = fuzzer.prng.random();
        //
        // // Create a block builder using the stable rng
        var config = try sequoia.GenesisConfig(messages.FUZZ_PARAMS).buildWithRng(allocator, &fuzzer.rng);
        errdefer config.deinit(allocator);

        fuzzer.block_builder = try sequoia.BlockBuilder(messages.FUZZ_PARAMS).init(allocator, config, &fuzzer.rng);
        errdefer fuzzer.block_builder.deinit();

        fuzzer.current_jam_state = &fuzzer.block_builder.state;

        // // Process the first (genesis) block to get proper state
        var first_block = try fuzzer.block_builder.buildNextBlock();
        errdefer first_block.deinit(allocator);

        fuzzer.latest_block = first_block;

        // Process the genesis block with sequoia STF to get proper header and state
        var state_transition = try stf.stateTransition(
            messages.FUZZ_PARAMS,
            allocator,
            fuzzer.current_jam_state,
            &first_block,
        );
        defer state_transition.deinitHeap();

        // Merge the transition results into the current state
        try state_transition.mergePrimeOntoBase();

        span.debug("Fuzzer initialized successfully", .{});
        return fuzzer;
    }

    /// Clean up all fuzzer resources
    pub fn destroy(self: *Fuzzer) void {
        const span = trace.span(.fuzzer_deinit);
        defer span.deinit();

        // // Clean up JAM components
        self.block_builder.deinit();
        //
        if (self.latest_block) |*b| b.deinit(self.allocator);

        const allocator = self.allocator;
        self.* = undefined; // Clear the fuzzer struct
        allocator.destroy(self);
    }

    /// Connect to target socket
    pub fn connectToTarget(self: *Fuzzer) !void {
        const span = trace.span(.connect_target);
        defer span.deinit();
        span.debug("Connecting to target socket: {s}", .{self.socket_path});

        self.socket = try std.net.connectUnixSocket(self.socket_path);
        self.state = .connected;

        span.debug("Connected to target successfully", .{});
    }

    /// Disconnect from target
    pub fn disconnect(self: *Fuzzer) void {
        if (self.socket) |socket| {
            socket.close();
            self.socket = null;
        }
    }

    /// Perform handshake with target
    pub fn performHandshake(self: *Fuzzer) !void {
        const span = trace.span(.fuzzer_handshake);
        defer span.deinit();
        span.debug("Performing handshake with target", .{});

        if (self.state != .connected) {
            return error.NotConnected;
        }

        // Send fuzzer peer info
        const fuzzer_peer_info = messages.PeerInfo{
            .name = "jamzig-fuzzer",
            .version = .{ .major = 0, .minor = 1, .patch = 0 },
            .protocol_version = .{ .major = 0, .minor = 6, .patch = 6 },
        };

        // REFACTOR: I see  a pattern here, send message and waiting for a response. Seperate this
        // and also add a timeout. So if we do not get a repsonse in a certain time, we error out.
        try self.sendMessage(.{ .peer_info = fuzzer_peer_info });

        // Receive target peer info
        var response = try self.readMessage();
        defer response.deinit();

        switch (response.value) {
            .peer_info => |peer_info| {
                span.debug("Received peer info from: {s}", .{peer_info.name});
                // TODO: Validate protocol compatibility
                self.state = .handshake_complete;
            },
            else => return error.UnexpectedHandshakeResponse,
        }

        span.debug("Handshake completed successfully", .{});
    }

    /// Set state on target
    pub fn setState(self: *Fuzzer, header: types.Header, state: messages.State) !messages.StateRootHash {
        const span = trace.span(.fuzzer_set_state);
        defer span.deinit();
        span.debug("Setting state on target with {d} key-value pairs", .{state.len});

        if (self.state != .handshake_complete) {
            return error.HandshakeNotComplete;
        }

        // Send SetState message
        try self.sendMessage(.{ .set_state = .{ .header = header, .state = state } });

        // Receive StateRoot response
        var response = try self.readMessage();
        defer response.deinit();

        switch (response.value) {
            .state_root => |state_root| {
                self.state = .state_initialized;
                span.debug("State set successfully, root: {s}", .{std.fmt.fmtSliceHexLower(&state_root)});
                return state_root;
            },
            else => return error.UnexpectedSetStateResponse,
        }
    }

    /// Send block to target for processing
    pub fn sendBlock(self: *Fuzzer, block: types.Block) !messages.StateRootHash {
        const span = trace.span(.fuzzer_send_block);
        defer span.deinit();
        span.debug("Sending block to target", .{});

        if (self.state != .state_initialized) {
            return error.StateNotInitialized;
        }

        // Send ImportBlock message
        try self.sendMessage(.{ .import_block = block });

        // Receive StateRoot response
        var response = try self.readMessage();
        defer response.deinit();

        switch (response.value) {
            .state_root => |state_root| {
                try self.state.assertReachedState(.state_initialized);
                span.debug("Block processed, state root: {s}", .{std.fmt.fmtSliceHexLower(&state_root)});
                return state_root;
            },
            else => return error.UnexpectedImportBlockResponse,
        }
    }

    /// Get state from target by header hash
    pub fn getState(self: *Fuzzer, header_hash: messages.HeaderHash) !messages.State {
        const span = trace.span(.fuzzer_get_state);
        defer span.deinit();
        span.debug("Getting state from target for header: {s}", .{std.fmt.fmtSliceHexLower(&header_hash)});

        try self.state.assertReachedState(.state_initialized);

        // Send GetState message
        try self.sendMessage(.{ .get_state = header_hash });

        // Receive State response
        var response = try self.readMessage();
        defer response.deinit();

        switch (response.value) {
            .state => |state| {
                span.debug("Received state with {d} key-value pairs", .{state.len});
                // Transfer ownership to caller - clear response to prevent double-free
                const result = state;
                response.value = .{ .state = &[_]messages.KeyValue{} };
                return result;
            },
            else => return error.UnexpectedGetStateResponse,
        }
    }

    /// Process block locally and return state root
    pub fn processBlockLocally(self: *Fuzzer, block: types.Block) !messages.StateRootHash {
        const span = trace.span(.fuzzer_process_local);
        defer span.deinit();
        span.debug("Processing block locally", .{});

        // Apply state transition using the STF
        var state_transition = try stf.stateTransition(
            messages.FUZZ_PARAMS,
            self.allocator,
            self.current_jam_state,
            &block,
        );
        defer state_transition.deinitHeap();

        // Merge the transition results into our current state
        try state_transition.mergePrimeOntoBase();

        // Compute and return state root
        const state_root = try state_merklization.merklizeState(
            messages.FUZZ_PARAMS,
            self.allocator,
            self.current_jam_state,
        );

        span.debug("Local state root: {s}", .{std.fmt.fmtSliceHexLower(&state_root)});
        return state_root;
    }

    /// Compare two state roots
    pub fn compareStateRoots(local_root: messages.StateRootHash, target_root: messages.StateRootHash) bool {
        return std.mem.eql(u8, &local_root, &target_root);
    }

    /// Run a complete fuzzing cycle with the specified number of blocks
    pub fn runFuzzCycle(self: *Fuzzer, num_blocks: usize) !report.FuzzResult {
        const span = trace.span(.fuzzer_run_cycle);
        defer span.deinit();
        span.debug("Starting fuzz cycle with {d} blocks", .{num_blocks});

        // Initialize state on target
        var initial_state_result = try state_converter.jamStateToFuzzState(
            messages.FUZZ_PARAMS,
            self.allocator,
            self.current_jam_state,
        );
        defer initial_state_result.deinit();

        // Set initial state on target
        const header = self.latest_block.?.header;
        _ = try self.setState(header, initial_state_result.state);

        span.debug("Initial state set, starting block processing", .{});

        // Process blocks
        for (0..num_blocks) |block_num| {
            const block_span = span.child(.process_block);
            defer block_span.deinit();
            block_span.debug("Processing block {d}/{d}", .{ block_num + 1, num_blocks });

            // Generate next block
            var block = try self.block_builder.buildNextBlock();
            errdefer block.deinit(self.allocator);

            // Process locally
            const local_root = try self.processBlockLocally(block);

            // Update latest block
            self.latest_block.?.deinit(self.allocator);
            self.latest_block = block;

            sequoia.logging.printBlockEntropyDebug(jam_params.TINY_PARAMS, &block, self.current_jam_state);

            // Send to target
            const target_root = try self.sendBlock(block);

            // Compare state roots
            if (!compareStateRoots(local_root, target_root)) {
                block_span.debug("State root mismatch detected!", .{});

                // Retrieve full target state for analysis
                const block_header_hash = try block.header.header_hash(messages.FUZZ_PARAMS, self.allocator);
                const target_state = self.getState(block_header_hash) catch |err| blk: {
                    block_span.err("Failed to retrieve target state: {s}", .{@errorName(err)});
                    break :blk null;
                };

                // Create mismatch entry
                const mismatch = report.Mismatch{
                    .block_number = block_num,
                    .block = try block.deepClone(self.allocator),
                    .local_state_root = local_root,
                    .target_state_root = target_root,
                    .target_state = target_state,
                };

                // Create result
                return report.FuzzResult{
                    .seed = self.seed,
                    .blocks_processed = block_num,
                    .mismatch = mismatch,
                    .success = false,
                    .allocator = self.allocator,
                };
            } else {
                block_span.debug("State roots match: {s}", .{std.fmt.fmtSliceHexLower(&local_root)});
            }
        }

        span.debug("Fuzz cycle completed. Blocks: {d}", .{num_blocks});

        // Create result
        return report.FuzzResult{
            .seed = self.seed,
            .blocks_processed = num_blocks,
            .mismatch = null,
            .success = true,
            .allocator = self.allocator,
        };
    }

    pub fn endSession(self: *Fuzzer) void {
        const span = trace.span(.fuzzer_end_session);
        defer span.deinit();
        span.debug("Ending fuzzer session", .{});

        // Disconnect from target
        self.disconnect();

        // Reset state
        self.state = .initial;

        // Clear socket
        self.socket = null;

        span.debug("Fuzzer session ended successfully", .{});
    }

    /// Helper to send a message via socket
    fn sendMessage(self: *Fuzzer, message: messages.Message) !void {
        const socket = self.socket orelse return error.NotConnected;
        const encoded = try messages.encodeMessage(self.allocator, message);
        defer self.allocator.free(encoded);
        try frame.writeFrame(socket, encoded);
    }

    /// Helper to read a message from socket
    fn readMessage(self: *Fuzzer) !messages.codec.Deserialized(messages.Message) {
        const socket = self.socket orelse return error.NotConnected;
        const frame_data = try frame.readFrame(self.allocator, socket);
        defer self.allocator.free(frame_data);
        return messages.decodeMessage(self.allocator, frame_data);
    }

    /// Target thread main function
    const TargetThreadContext = struct {
        allocator: std.mem.Allocator,
        socket_path: []const u8,
    };

    fn targetThreadMain(context: *const TargetThreadContext) void {
        defer context.allocator.destroy(context);

        var target_server = target.TargetServer.init(context.allocator, context.socket_path) catch |err| {
            std.log.err("Failed to initialize target server: {s}", .{@errorName(err)});
            return;
        };
        defer target_server.deinit();

        target_server.start() catch |err| {
            std.log.err("Target server error: {s}", .{@errorName(err)});
        };
    }
};
