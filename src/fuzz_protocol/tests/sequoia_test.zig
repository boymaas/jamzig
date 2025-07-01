const std = @import("std");
const testing = std.testing;
const net = std.net;
const messages = @import("../messages.zig");
const TargetServer = @import("../target.zig").TargetServer;
const sequoia = @import("../../sequoia.zig");
const types = @import("../../types.zig");
const codec = @import("../../codec.zig");
const shared = @import("shared.zig");
const state_converter = @import("../state_converter.zig");

const trace = @import("../../tracing.zig").scoped(.fuzz_protocol);

test "basic_block_import" {
    const span = trace.span(.test_multiple_blocks);
    defer span.deinit();

    const allocator = testing.allocator;

    // Setup genesis state, block builder, and first block
    var genesis_setup = try setupGenesisWithFirstBlock(allocator, 54321);
    defer genesis_setup.deinit();

    // Setup
    var sockets = try shared.createSocketPair();
    defer sockets.deinit();

    var target = try TargetServer.init(allocator, "unused");
    defer target.deinit();

    // Perform handshake
    _ = try shared.performHandshake(allocator, sockets.fuzzer, sockets.target, &target);

    // Convert processed state to fuzz protocol format
    var genesis_state_result = try state_converter.jamStateToFuzzState(
        messages.FUZZ_PARAMS,
        allocator,
        &genesis_setup.genesis_state,
    );
    defer genesis_state_result.deinit();

    // Use the processed header from genesis block processing
    const set_state_msg = messages.Message{
        .set_state = .{
            .header = genesis_setup.processed_header,
            .state = genesis_state_result.state,
        },
    };

    try shared.sendMessage(allocator, sockets.fuzzer, set_state_msg);

    var set_request = try target.readMessage(sockets.target);
    defer set_request.deinit();
    const set_response = try target.processMessage(set_request.value);
    try target.sendMessage(sockets.target, set_response.?);

    var set_reply = try shared.readMessage(allocator, sockets.fuzzer);
    defer set_reply.deinit();

    // Continue using the same block builder for subsequent blocks

    const num_blocks = 5;
    var state_roots = std.ArrayList(messages.StateRootHash).init(allocator);
    defer state_roots.deinit();

    for (0..num_blocks) |i| {
        span.debug("Processing block {d}/{d}", .{ i + 1, num_blocks });

        // Generate block for this iteration
        var block = try genesis_setup.block_builder.buildNextBlock();
        defer block.deinit(allocator);

        const result = try runFuzzingCycle(
            allocator,
            sockets.fuzzer,
            sockets.target,
            &target,
            block,
        );

        try state_roots.append(result.target_root);

        // Verify each block import succeeded
        // In current implementation, all should return the same state root
        if (i > 0) {
            try testing.expectEqualSlices(u8, &state_roots.items[0], &state_roots.items[i]);
        }
    }

    span.debug("Multiple blocks test completed successfully", .{});
}

/// Helper to run one fuzzing cycle: import block and verify
fn runFuzzingCycle(
    allocator: std.mem.Allocator,
    fuzzer_sock: net.Stream,
    target_sock: net.Stream,
    target: *TargetServer,
    block: types.Block,
) !struct { original_root: messages.StateRootHash, target_root: messages.StateRootHash } {
    const span = trace.span(.run_fuzzing_cycle);
    defer span.deinit();

    // Import the block into the fuzzer (for reference state root)
    // TODO: For now, we'll use a placeholder since we don't have fuzzer state management
    const fuzzer_state_root = std.mem.zeroes(messages.StateRootHash);

    // Send ImportBlock to target
    const import_msg = messages.Message{ .import_block = block };
    try shared.sendMessage(allocator, fuzzer_sock, import_msg);

    // Target processes ImportBlock
    var request = try target.readMessage(target_sock);
    defer request.deinit();
    const response = try target.processMessage(request.value);
    try target.sendMessage(target_sock, response.?);

    // Read target's response
    var reply = try shared.readMessage(allocator, fuzzer_sock);
    defer reply.deinit();

    const target_state_root = switch (reply.value) {
        .state_root => |root| root,
        else => return error.UnexpectedResponse,
    };

    span.debug("Fuzzing cycle completed - roots match: {}", .{std.mem.eql(u8, &fuzzer_state_root, &target_state_root)});

    return .{ .original_root = fuzzer_state_root, .target_root = target_state_root };
}

/// Result type for genesis setup that manages memory automatically
const GenesisSetup = struct {
    genesis_state: @import("../../state.zig").JamState(messages.FUZZ_PARAMS),
    block_builder: sequoia.BlockBuilder(messages.FUZZ_PARAMS),
    first_block: types.Block,
    processed_header: types.Header,
    prng: std.Random.DefaultPrng,
    allocator: std.mem.Allocator,

    /// Free all allocated memory
    pub fn deinit(self: *GenesisSetup) void {
        self.genesis_state.deinit(self.allocator);
        self.block_builder.deinit();
        self.first_block.deinit(self.allocator);
    }
};

/// Setup genesis state, block builder, and process first block
fn setupGenesisWithFirstBlock(
    allocator: std.mem.Allocator,
    seed: u64,
) !GenesisSetup {
    // Initialize RNG with provided seed
    var prng = std.Random.DefaultPrng.init(seed);
    var rng = prng.random();

    // Create genesis config and get genesis state
    const config = try sequoia.GenesisConfig(messages.FUZZ_PARAMS).buildWithRng(allocator, &rng);
    defer allocator.free(config.validator_keys);

    var genesis_state = try config.buildJamState(allocator, &rng);
    errdefer genesis_state.deinit(allocator);

    // Create a genesis block using the block builder
    var block_builder = try sequoia.createTinyBlockBuilder(allocator, &rng);
    errdefer block_builder.deinit();

    var first_block = try block_builder.buildNextBlock();
    errdefer first_block.deinit(allocator);

    // Process the genesis block with sequoia STF to get proper header and state
    const stf = @import("../../stf.zig");
    var state_transition = try stf.stateTransition(
        messages.FUZZ_PARAMS,
        allocator,
        &genesis_state,
        &first_block,
    );
    defer state_transition.deinitHeap();

    // Merge the transition results into the genesis state
    try state_transition.mergePrimeOntoBase();

    // Get the resulting header
    const processed_header = first_block.header;

    return GenesisSetup{
        .genesis_state = genesis_state,
        .block_builder = block_builder,
        .first_block = first_block,
        .processed_header = processed_header,
        .prng = prng,
        .allocator = allocator,
    };
}
