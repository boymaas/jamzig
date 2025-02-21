const std = @import("std");
const jam_params = @import("jam_params.zig");
const sequoia = @import("sequoia.zig");
const types = @import("types.zig");
const state = @import("state.zig");
const codec = @import("codec.zig");
const state_dictionary = @import("state_dictionary.zig");
const jamtestnet = @import("jamtestnet.zig");
const jamtestnet_json = @import("jamtestnet/json.zig");

const stf = @import("stf.zig");

const TestStateTransition = @import("jamtestnet/parsers/bin/state_transition.zig").TestStateTransition;
const KeyVal = @import("jamtestnet/parsers/bin/state_transition.zig").KeyVal;

pub fn writeStateTransition(
    comptime params: jam_params.Params,
    allocator: std.mem.Allocator,
    current_state: *const state.JamState(params),
    block: types.Block,
    next_state: *const state.JamState(params),
    output_dir: []const u8,
) !void {
    // Create base paths
    const epoch = block.header.slot / params.epoch_length;
    const slot_in_epoch = block.header.slot % params.epoch_length;

    // Create filenames
    const bin_path_buf = try std.fmt.allocPrint(allocator, "{s}/{:0>4}_{:0>4}.bin", .{
        output_dir, epoch, slot_in_epoch,
    });
    defer allocator.free(bin_path_buf);

    const json_path_buf = try std.fmt.allocPrint(allocator, "{s}/{:0>4}_{:0>4}.json", .{
        output_dir, epoch, slot_in_epoch,
    });
    defer allocator.free(json_path_buf);

    // Build state transition data
    var transition = TestStateTransition{
        .pre_state = .{
            .state_root = try current_state.buildStateRoot(allocator),
            .keyvals = try buildKeyValsFromState(params, allocator, current_state),
        },
        .block = try block.deepClone(allocator),
        .post_state = .{
            .state_root = try next_state.buildStateRoot(allocator),
            .keyvals = try buildKeyValsFromState(params, allocator, next_state),
        },
    };
    defer transition.deinit(allocator);

    // Create output directory if it doesn't exist
    try std.fs.cwd().makePath(output_dir);

    // Write binary format
    {
        const file = try std.fs.cwd().createFile(bin_path_buf, .{});
        defer file.close();
        try codec.serialize(TestStateTransition, params, file.writer(), transition);
    }

    // Write JSON format
    {
        const file = try std.fs.cwd().createFile(json_path_buf, .{});
        defer file.close();

        try jamtestnet_json.stringify(
            transition,
            .{
                .whitespace = .indent_2,
                .emit_strings_as_arrays = true,
                .emit_bytes_as_hex = true,
            },
            file.writer(),
        );
    }
}

fn buildKeyValsFromState(comptime params: jam_params.Params, allocator: std.mem.Allocator, jam_state: *const state.JamState(params)) ![]KeyVal {
    var mdict = try jam_state.buildStateMerklizationDictionary(allocator);
    defer mdict.deinit();

    const entries = try mdict.toOwnedSliceSortedByKey();
    defer allocator.free(entries);

    var keyvals = try std.ArrayList(KeyVal).initCapacity(allocator, entries.len);
    defer keyvals.deinit();

    for (entries) |entry| {
        try keyvals.append(.{
            .key = try allocator.dupe(u8, &entry.k),
            .val = try allocator.dupe(u8, entry.v),
            .id = try allocator.dupe(u8, &[_]u8{}), // Empty for now
            .desc = try allocator.dupe(u8, &[_]u8{}), // Empty for now
        });
    }

    return keyvals.toOwnedSlice();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Setup seeded RNG for deterministic test vectors
    const seed: [32]u8 = [_]u8{42} ** 32;
    var prng = std.Random.ChaCha.init(seed);
    var rng = prng.random();

    // Params
    const PARAMS = jamtestnet.JAMDUNA_PARAMS;

    // Create genesis config and block builder
    const config = try sequoia.GenesisConfig(PARAMS).buildWithRng(allocator, &rng);
    var builder = try sequoia.BlockBuilder(PARAMS).init(allocator, config, &rng);
    defer builder.deinit();

    const output_dir = "src/jamtestnet/teams/jamzig/safrole/state_transitions";
    const num_blocks = 64;

    std.debug.print("Generating {d} blocks...\n", .{num_blocks});

    // Generate and process multiple blocks
    for (0..num_blocks) |_| {
        var pre_state = try builder.state.deepClone(allocator);
        defer pre_state.deinit(allocator);

        // Build next block
        var block = try builder.buildNextBlock();
        defer block.deinit(allocator);

        // Perform state transition
        var state_transition = try stf.stateTransition(PARAMS, allocator, &builder.state, &block);
        defer state_transition.deinitHeap();

        try state_transition.mergePrimeOntoBase();

        // Log block information for debugging
        sequoia.logging.printBlockEntropyDebug(
            PARAMS,
            &block,
            &builder.state,
        );

        try writeStateTransition(
            PARAMS,
            allocator,
            &pre_state,
            block,
            &builder.state,
            output_dir,
        );
    }
}
