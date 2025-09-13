const std = @import("std");
const net = std.net;
const testing = std.testing;

const messages = @import("messages.zig");
const frame = @import("frame.zig");
const target = @import("target.zig");
const state_converter = @import("state_converter.zig");
const shared = @import("tests/shared.zig");
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

/// Main Fuzzer implementation for JAM protocol conformance testing
pub fn Fuzzer(comptime IOExecutor: type) type {
    return struct {
        allocator: std.mem.Allocator,

        // Deterministic execution
        prng: std.Random.DefaultPrng,
        rng: std.Random,
        seed: u64,

        // JAM components
        block_builder: sequoia.BlockBuilder(messages.FUZZ_PARAMS),
        block_importer: block_import.BlockImporter(IOExecutor, messages.FUZZ_PARAMS),
        current_jam_state: *const JamState(messages.FUZZ_PARAMS),
        latest_block: ?types.Block = null,

        // Target communication
        socket: ?net.Stream = null,
        socket_path: []const u8,

        // REFACTOR: we also need to track the current block, as sometimes we need to use the header hash
        // of the block
        state: FuzzerState = .initial,

        /// Initialize fuzzer with deterministic seed and target socket path
        pub fn create(executor: *IOExecutor, allocator: std.mem.Allocator, seed: u64, socket_path: []const u8) !*Self {
            const span = trace.span(@src(), .fuzzer_init);
            defer span.deinit();

            span.debug("Initializing fuzzer with seed: {d}, socket: {s}", .{ seed, socket_path });

            // Create fuzzer struct first to ensure stable addresses
            const fuzzer = try allocator.create(Self);
            errdefer allocator.destroy(fuzzer);

            // Initialize fields to safe defaults
            fuzzer.* = .{
                .allocator = allocator,
                .socket_path = socket_path,
                .prng = std.Random.DefaultPrng.init(seed),
                .rng = undefined,
                .seed = seed,
                .block_builder = undefined,
                .block_importer = undefined,
                .current_jam_state = undefined,
                .latest_block = null,
                .socket = null,
                .state = .initial,
            };

            // Initialize the rng from the prng stored in fuzzer
            fuzzer.rng = fuzzer.prng.random();

            // Create a block builder using the stable rng
            var config = try sequoia.GenesisConfig(messages.FUZZ_PARAMS).buildWithRng(allocator, &fuzzer.rng);
            errdefer config.deinit(allocator);

            fuzzer.block_builder = try sequoia.BlockBuilder(messages.FUZZ_PARAMS).init(allocator, config, &fuzzer.rng);
            errdefer fuzzer.block_builder.deinit();

            fuzzer.block_importer = block_import.BlockImporter(IOExecutor, messages.FUZZ_PARAMS).init(executor, allocator);
            fuzzer.current_jam_state = &fuzzer.block_builder.state;

            // Process the first (genesis) block to get proper state
            var genesis_block = try fuzzer.block_builder.buildNextBlock();
            errdefer genesis_block.deinit(allocator);

            fuzzer.latest_block = genesis_block;

            // Process the genesis block with block importer to get proper header and state
            var import_result = try fuzzer.block_importer.importBlockBuildingRoot(
                fuzzer.current_jam_state,
                &genesis_block,
            );
            defer import_result.deinit();

            // Commit the state transition
            try import_result.commit();

            span.debug("Fuzzer initialized successfully", .{});
            return fuzzer;
        }

        /// Clean up all fuzzer resources
        pub fn destroy(self: *Self) void {
            const span = trace.span(@src(), .fuzzer_deinit);
            defer span.deinit();

            // Ensure socket is closed before destroying
            self.disconnect();

            // Clean up JAM components
            self.block_builder.deinit();

            if (self.latest_block) |*b| b.deinit(self.allocator);

            const allocator = self.allocator;
            allocator.destroy(self);
        }

        const Self = @This();

        /// Connect to target socket
        pub fn connectToTarget(self: *Self) !void {
            const span = trace.span(@src(), .connect_target);
            defer span.deinit();
            span.debug("Connecting to target socket: {s}", .{self.socket_path});

            self.socket = try std.net.connectUnixSocket(self.socket_path);
            self.state = .connected;

            span.debug("Connected to target successfully", .{});
        }

        /// Disconnect from target
        pub fn disconnect(self: *Self) void {
            const span = trace.span(@src(), .disconnect_target);
            defer span.deinit();

            if (self.socket) |socket| {
                socket.close();
                self.socket = null;
                self.state = .connected; // Reset state to connected
                span.debug("Disconnected from target", .{});
            } else {
                span.debug("No active connection to disconnect", .{});
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

            // Send fuzzer peer info (v1 format)
            const fuzzer_peer_info = messages.PeerInfo{
                .fuzz_version = version.FUZZ_PROTOCOL_VERSION,
                .fuzz_features = version.DEFAULT_FUZZ_FEATURES,
                .jam_version = version.PROTOCOL_VERSION,
                .app_version = version.FUZZ_TARGET_VERSION,
                .app_name = "jamzig-fuzzer", // NOTE: static string here => no deinit
            };

            // REFACTOR: I see  a pattern here, send message and waiting for a response. Seperate this
            // and also add a timeout. So if we do not get a repsonse in a certain time, we error out.
            try self.sendMessage(.{ .peer_info = fuzzer_peer_info });

            // Receive target peer info
            var response = try self.readMessage();
            defer response.deinit(self.allocator);

            switch (response) {
                .peer_info => |peer_info| {
                    span.debug("Received peer info from: {s}", .{peer_info.app_name});
                    // TODO: Validate protocol compatibility
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

            // Send Initialize message (v1) - no ancestry for now
            try self.sendMessage(.{ .initialize = .{
                .header = header,
                .keyvals = state,
                .ancestry = messages.Ancestry.Empty,
            } });

            // Receive StateRoot response
            var response = try self.readMessage();
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
        pub fn sendBlock(self: *Self, block: *const types.Block) !messages.StateRootHash {
            const span = trace.span(@src(), .fuzzer_send_block);
            defer span.deinit();
            span.debug("Sending block to target", .{});
            span.trace("{s}", .{types.fmt.format(block)});

            if (self.state != .state_initialized) {
                return error.StateNotInitialized;
            }

            // Send ImportBlock message, do not free message we do not own the block
            try self.sendMessage(.{ .import_block = block.* });

            // Receive StateRoot response
            var response = try self.readMessage();
            defer response.deinit(self.allocator);

            switch (response) {
                .state_root => |state_root| {
                    try self.state.assertReachedState(.state_initialized);
                    span.debug("Block processed, state root: {s}", .{std.fmt.fmtSliceHexLower(&state_root)});
                    return state_root;
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

            // Send GetState message
            try self.sendMessage(.{ .get_state = header_hash });

            // Receive State response
            var response = try self.readMessage();
            defer response.deinit(self.allocator);

            switch (response) {
                .state => |state| {
                    span.debug("Received state with {d} key-value pairs", .{state.items.len});
                    // Transfer ownership to caller - clear response to prevent double-free
                    const result = state;
                    response = .{ .state = messages.State.Empty };
                    return result;
                },
                else => return error.UnexpectedGetStateResponse,
            }
        }

        /// Process block locally and return state root
        pub fn processBlockLocally(self: *Self, block: types.Block) !messages.StateRootHash {
            const span = trace.span(@src(), .fuzzer_process_local);
            defer span.deinit();
            span.debug("Processing block locally", .{});

            // Use block importer to process the block
            var import_result = try self.block_importer.importBlockBuildingRoot(
                self.current_jam_state,
                &block,
            );
            defer import_result.deinit();

            // Commit the state transition
            try import_result.commit();

            // Calculate and return the new state root
            const state_root = try self.current_jam_state.buildStateRoot(self.allocator);

            span.debug("Local state root: {s}", .{std.fmt.fmtSliceHexLower(&state_root)});
            return state_root;
        }

        /// Compare two state roots
        pub fn compareStateRoots(local_root: messages.StateRootHash, target_root: messages.StateRootHash) bool {
            return std.mem.eql(u8, &local_root, &target_root);
        }

        /// Run a complete fuzzing cycle with the specified number of blocks
        pub fn runFuzzCycle(self: *Self, num_blocks: usize) !report.FuzzResult {
            return self.runFuzzCycleWithShutdown(num_blocks, null);
        }

        /// Run a complete fuzzing cycle with optional shutdown check
        pub fn runFuzzCycleWithShutdown(self: *Self, num_blocks: usize, should_shutdown: ?*const fn () bool) !report.FuzzResult {
            const span = trace.span(@src(), .fuzzer_run_cycle);
            defer span.deinit();
            span.debug("Starting fuzz cycle with {d} blocks", .{num_blocks});

            // Initialize state on target
            var initial_state_result = try state_converter.jamStateToFuzzState(
                messages.FUZZ_PARAMS,
                self.allocator,
                self.current_jam_state,
            );
            defer initial_state_result.deinit();

            // Calculate local state root
            const local_state_root = try self.current_jam_state.buildStateRoot(self.allocator);

            // Set initial state on target and get target's state root
            const header = self.latest_block.?.header;
            const target_state_root = try self.setState(header, initial_state_result.state);

            // Verify state roots match
            if (!std.mem.eql(u8, &local_state_root, &target_state_root)) {
                std.debug.print("State root mismatch! Local: {s}, Target: {s}\n", .{
                    std.fmt.fmtSliceHexLower(&local_state_root),
                    std.fmt.fmtSliceHexLower(&target_state_root),
                });
                return error.InitialStateRootMismatch;
            }

            std.debug.print("Initial state roots match: {s}\n", .{std.fmt.fmtSliceHexLower(&local_state_root)});

            // Process blocks
            for (0..num_blocks) |block_num| {
                // Check for shutdown signal
                if (should_shutdown) |check_fn| {
                    if (check_fn()) {
                        span.debug("Shutdown requested, stopping at block {d}", .{block_num});
                        return report.FuzzResult{
                            .seed = self.seed,
                            .blocks_processed = block_num,
                            .mismatch = null,
                            .success = true, // Clean shutdown is considered success
                            .err = null,
                        };
                    }
                }

                const block_span = span.child(@src(), .process_block);
                defer block_span.deinit();

                block_span.debug("Processing block {d}/{d}", .{ block_num + 1, num_blocks });

                // Generate next block
                var block = try self.block_builder.buildNextBlock();
                errdefer block.deinit(self.allocator);

                // Send to target
                const reported_target_root = self.sendBlock(&block) catch |err| {
                    block_span.err("Error sending block to target: {s}", .{@errorName(err)});

                    // Return partial result with the error
                    return report.FuzzResult{
                        .seed = self.seed,
                        .blocks_processed = block_num,
                        .mismatch = null,
                        .success = false,
                        .err = err,
                    };
                };

                // If the reported target root is the same the local root we can end the
                // fuzz cycle early. As we know the target could not or would not process the block.
                if (compareStateRoots(reported_target_root, try self.current_jam_state.buildStateRoot(self.allocator))) {
                    block_span.warn("Target reported same state root as local: {s}", .{std.fmt.fmtSliceHexLower(&reported_target_root)});
                    return error.SameRootReturned; // Skip further processing for this block
                }

                var local_root: messages.StateRootHash = undefined;

                // Scope for block generation and ownership transfer
                {

                    // Process locally
                    local_root = try self.processBlockLocally(block);

                    // Update latest block - ownership transfers here
                    self.latest_block.?.deinit(self.allocator);
                    self.latest_block = block;
                }

                sequoia.logging.printBlockEntropyDebug(messages.FUZZ_PARAMS, &self.latest_block.?, self.current_jam_state);

                // Compare state roots
                if (!compareStateRoots(local_root, reported_target_root)) {
                    block_span.debug("State root mismatch detected!", .{});

                    // Build local dictionary
                    var local_dict = try self.current_jam_state.buildStateMerklizationDictionary(self.allocator);
                    errdefer local_dict.deinit();

                    // Retrieve full target state for analysis
                    const block_header_hash = try self.latest_block.?.header.header_hash(messages.FUZZ_PARAMS, self.allocator);
                    var target_state: ?messages.State = self.getState(block_header_hash) catch |err| blk: {
                        block_span.err("Failed to retrieve target state: {s}", .{@errorName(err)});
                        break :blk null;
                    };
                    defer if (target_state) |*ts| {
                        ts.deinit(self.allocator);
                    };

                    // Build target dictionary and validate if we got state
                    var target_dict: ?state_dictionary.MerklizationDictionary = null;
                    var target_computed_root: ?messages.StateRootHash = null;
                    if (target_state) |ts| {
                        // Convert to MerklizationDictionary
                        target_dict = try state_converter.fuzzStateToMerklizationDictionary(self.allocator, ts);
                        errdefer if (target_dict) |*td| td.deinit();

                        // Verify state root
                        const computed_root = try target_dict.?.buildStateRoot(self.allocator);
                        target_computed_root = computed_root;
                    }

                    // Create mismatch entry
                    const mismatch = report.Mismatch{
                        .block_number = block_num,
                        .block = try self.latest_block.?.deepClone(self.allocator),
                        .reported_state_root = reported_target_root,
                        .local_dict = local_dict,
                        .target_dict = target_dict,
                        .target_computed_root = target_computed_root,
                    };

                    // Create result
                    return report.FuzzResult{
                        .seed = self.seed,
                        .blocks_processed = block_num,
                        .mismatch = mismatch,
                        .success = false,
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
            };
        }

        /// Run trace mode - replay W3F format traces from a directory
        pub fn runTraceMode(self: *Self, trace_dir: []const u8) !report.FuzzResult {
            const span = trace.span(@src(), .fuzzer_run_trace_mode);
            defer span.deinit();
            span.debug("Starting trace mode from directory: {s}", .{trace_dir});

            // Create W3F loader directly
            const w3f_loader = jamtestnet.w3f.Loader(messages.FUZZ_PARAMS){};
            const loader = w3f_loader.loader();

            // Collect state transitions from directory
            var transitions = try state_transitions.collectStateTransitions(trace_dir, self.allocator);
            defer transitions.deinit(self.allocator);

            // Filter transitions to only keep valid format (digits + .bin)
            var valid_transitions = std.ArrayList(state_transitions.StateTransitionPair).init(self.allocator);
            defer valid_transitions.deinit();

            for (transitions.items()) |transition| {
                // Check if filename matches pattern: digits_digits.bin
                const name = transition.bin.name;
                if (std.mem.endsWith(u8, name, ".bin")) // exclude genesis.bin
                {
                    // Verify it contains only digits and underscore before .bin
                    const basename = name[0 .. name.len - 4];
                    var valid = true;
                    for (basename) |c| {
                        if (!std.ascii.isDigit(c)) {
                            valid = false;
                            break;
                        }
                    }
                    if (valid) {
                        try valid_transitions.append(transition);
                    }
                }
            }

            span.debug("Found {d} valid state transitions", .{valid_transitions.items.len});

            if (valid_transitions.items.len == 0) {
                // REFACTOR: explain the format of the expected traces
                return error.NoValidTransitions;
            }

            // Initialize result
            var result = report.FuzzResult{
                .seed = 0, // No seed for trace mode
                .blocks_processed = 0,
                .mismatch = null,
                .success = true,
            };
            errdefer result.deinit(self.allocator);

            // Process first transition with SetState
            const pre_state_root = blk: {
                const first_transition = valid_transitions.items[0];
                span.debug("Processing first transition for SetState: {s}", .{first_transition.bin.name});

                // Load the state transition
                var state_transition = try loader.loadTestVector(self.allocator, first_transition.bin.path);
                defer state_transition.deinit(self.allocator);

                // Get the block header
                const block = state_transition.block();

                // Convert pre-state dictionary directly to fuzz format
                var pre_state_dict = try state_transition.preStateAsMerklizationDict(self.allocator);
                defer pre_state_dict.deinit();

                var fuzz_state = try state_converter.dictionaryToFuzzState(self.allocator, &pre_state_dict);
                defer fuzz_state.deinit(self.allocator);

                // Send state to target
                const target_state_root = try self.setState(block.*.header, fuzz_state);

                // Verify pre-state root matches
                const pre_state_root = state_transition.preStateRoot();

                if (!std.mem.eql(u8, &pre_state_root, &target_state_root)) {
                    span.err("Initial state root mismatch at trace {s}", .{first_transition.bin.name});
                    result.mismatch = report.Mismatch{
                        .block_number = block.header.slot,
                        .block = try block.deepClone(self.allocator),
                        .reported_state_root = target_state_root,
                    };
                    result.success = false;
                    return result;
                }

                span.debug("Initial state set successfully and confirmed on target", .{});
                break :blk pre_state_root;
            };

            // Process remaining transitions by sending blocks
            var previous_state_root: messages.StateRootHash = pre_state_root;
            for (valid_transitions.items, 0..) |transition, i| {
                span.debug("Processing block {d}: {s}", .{ i, transition.bin.name });

                // Load the state transition
                var state_transition = try loader.loadTestVector(self.allocator, transition.bin.path);
                defer state_transition.deinit(self.allocator);

                // Get the block
                const block = state_transition.block();

                // Calculate expected state root
                const expected_state_root = state_transition.postStateRoot();

                // Send block to target
                const target_state_root_after = try self.sendBlock(block);

                // If the reported target root is the same the local root we can end the
                // fuzz cycle early. As we know the target could not or would not process the block.
                if (compareStateRoots(previous_state_root, target_state_root_after)) {
                    span.warn("Target reported same state root as previous: {s}", .{std.fmt.fmtSliceHexLower(&target_state_root_after)});
                    return error.SameRootReturned; // Skip further processing for this block
                }

                // Compare results
                if (!std.mem.eql(u8, &expected_state_root, &target_state_root_after)) {
                    span.err("Post-state root mismatch at trace {s}", .{transition.bin.name});
                    result.mismatch = report.Mismatch{
                        .block_number = block.header.slot,
                        .block = try block.deepClone(self.allocator),
                        .reported_state_root = target_state_root_after,
                    };
                    result.success = false;
                    break;
                }

                // Update previous state root
                previous_state_root = expected_state_root;

                span.debug("Trace {s} passed", .{transition.bin.name});
                result.blocks_processed += 1;
            }

            return result;
        }

        pub fn endSession(self: *Self) void {
            const span = trace.span(@src(), .fuzzer_end_session);
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
        fn sendMessage(self: *Self, message: messages.Message) !void {
            const socket = self.socket orelse return error.NotConnected;
            const encoded = try messages.encodeMessage(self.allocator, message);
            defer self.allocator.free(encoded);
            try frame.writeFrame(socket, encoded);
        }

        /// Helper to read a message from socket
        fn readMessage(self: *Self) !messages.Message {
            const socket = self.socket orelse return error.NotConnected;
            const frame_data = try frame.readFrame(self.allocator, socket);
            defer self.allocator.free(frame_data);
            return messages.decodeMessage(self.allocator, frame_data);
        }

        /// Target thread main function
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
