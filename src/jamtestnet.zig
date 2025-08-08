const std = @import("std");
const testing = std.testing;

pub const jamtestnet = @import("jamtestnet/parsers.zig");
pub const state_transitions = @import("jamtestnet/state_transitions.zig");

const stf = @import("stf.zig");
const types = @import("types.zig");
const state = @import("state.zig");
const state_dict = @import("state_dictionary.zig");
const state_delta = @import("state_delta.zig");
const codec = @import("codec.zig");
const services = @import("services.zig");

const jam_params = @import("jam_params.zig");

const tracing = @import("tracing.zig");
const trace = tracing.scoped(.stf_test);

const block_import = @import("block_import.zig");

// W3F Traces Tests
pub const W3F_PARAMS = jam_params.TINY_PARAMS;

test "w3f:traces:fallback" {
    const allocator = std.testing.allocator;
    const loader = jamtestnet.w3f.Loader(W3F_PARAMS){};
    try runBlockImportTests(
        W3F_PARAMS,
        loader.loader(),
        allocator,
        "src/jamtestvectors/data/traces/fallback",
    );
}

test "w3f:traces:safrole" {
    const allocator = std.testing.allocator;
    const loader = jamtestnet.w3f.Loader(W3F_PARAMS){};
    try runBlockImportTests(
        W3F_PARAMS,
        loader.loader(),
        allocator,
        "src/jamtestvectors/data/traces/safrole",
    );
}

test "w3f:traces:preimages" {
    const allocator = std.testing.allocator;
    const loader = jamtestnet.w3f.Loader(W3F_PARAMS){};
    try runBlockImportTests(
        W3F_PARAMS,
        loader.loader(),
        allocator,
        "src/jamtestvectors/data/traces/preimages",
    );
}

test "w3f:traces:preimages_light" {
    const allocator = std.testing.allocator;
    const loader = jamtestnet.w3f.Loader(W3F_PARAMS){};
    try runBlockImportTests(
        W3F_PARAMS,
        loader.loader(),
        allocator,
        "src/jamtestvectors/data/traces/preimages_light",
    );
}

test "w3f:traces:storage" {
    const allocator = std.testing.allocator;
    const loader = jamtestnet.w3f.Loader(W3F_PARAMS){};
    try runBlockImportTests(
        W3F_PARAMS,
        loader.loader(),
        allocator,
        "src/jamtestvectors/data/traces/storage",
    );
}

test "w3f:traces:storage_light" {
    const allocator = std.testing.allocator;
    const loader = jamtestnet.w3f.Loader(W3F_PARAMS){};
    try runBlockImportTests(
        W3F_PARAMS,
        loader.loader(),
        allocator,
        "src/jamtestvectors/data/traces/storage_light",
    );
}

/// Run state transition tests using BlockImporter for full validation
pub fn runBlockImportTests(
    comptime params: jam_params.Params,
    loader: jamtestnet.Loader,
    allocator: std.mem.Allocator,
    test_dir: []const u8,
) !void {
    std.log.err("\nRunning block import tests from: {s}", .{test_dir});

    // Read the OFFSET env var to start from a certain offset
    const offset_str = std.process.getEnvVarOwned(allocator, "OFFSET") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    defer if (offset_str) |s| allocator.free(s);

    const offset = if (offset_str) |s| try std.fmt.parseInt(usize, s, 10) else 0;

    var state_transition_vectors = try jamtestnet.state_transitions.collectStateTransitions(test_dir, allocator);
    defer state_transition_vectors.deinit(allocator);
    std.log.err("Collected {d} state transition vectors", .{state_transition_vectors.items().len});

    if (offset > 0) {
        if (offset >= state_transition_vectors.items().len) {
            std.debug.print("Warning: Offset {d} is >= total vectors {d}, no tests will run\n", .{ offset, state_transition_vectors.items().len });
        } else {
            std.debug.print("Starting from offset: {d}\n", .{offset});
        }
    }

    // Initialize block importer
    var importer = block_import.BlockImporter(params).init(allocator);

    var current_state: ?state.JamState(params) = null;
    defer {
        if (current_state) |*cs| cs.deinit(allocator);
    }

    for (state_transition_vectors.items()[offset..]) |state_transition_vector| {
        // This is sometimes placed in the dir
        if (std.mem.eql(u8, state_transition_vector.bin.name, "genesis.bin")) {
            continue;
        }

        std.debug.print("\nProcessing block import: {s}\n\n", .{state_transition_vector.bin.name});

        var state_transition = try loader.loadTestVector(allocator, state_transition_vector.bin.path);
        defer state_transition.deinit(allocator);

        // First validate the roots
        var pre_state_mdict = try state_transition.preStateAsMerklizationDict(allocator);
        defer pre_state_mdict.deinit();

        // Validator Root Calculations
        try state_transition.validateRoots(allocator);

        // Initialize genesis state if needed
        if (current_state == null) {
            // std.debug.print("Initializing genesis state...\n", .{});
            var dict = try state_transition.preStateAsMerklizationDict(allocator);
            defer dict.deinit();
            current_state = try state_dict.reconstruct.reconstructState(
                params,
                allocator,
                &dict,
            );

            var current_state_mdict = try current_state.?.buildStateMerklizationDictionary(allocator);
            defer current_state_mdict.deinit();
            var genesis_state_diff = try current_state_mdict.diff(&dict);
            defer genesis_state_diff.deinit();

            if (genesis_state_diff.has_changes()) {
                std.debug.print("Genesis State Reconstruction Failed. Dict -> Reconstruct -> Dict not symmetrical. Check state encode and decode\n", .{});
                std.debug.print("{}", .{genesis_state_diff});
                return error.GenesisStateDiff;
            }
        }

        // Ensure we are starting with the same roots.
        const pre_state_root = try current_state.?.buildStateRoot(allocator);
        try std.testing.expectEqualSlices(
            u8,
            &state_transition.preStateRoot(),
            &pre_state_root,
        );

        // Use BlockImporter for full validation and state transition
        std.debug.print("Using BlockImporter for full validation...\n", .{});

        // Debug: Calculate and print extrinsic hash to stderr
        const block = state_transition.block();

        // Show extrinsic contents
        std.log.err("Extrinsic contents: tickets={d}, preimages={d}, guarantees={d}, assurances={d}, disputes(v={d},c={d},f={d})", .{
            block.extrinsic.tickets.data.len,
            block.extrinsic.preimages.data.len,
            block.extrinsic.guarantees.data.len,
            block.extrinsic.assurances.data.len,
            block.extrinsic.disputes.verdicts.len,
            block.extrinsic.disputes.culprits.len,
            block.extrinsic.disputes.faults.len,
        });

        const calculated_hash = try block.extrinsic.calculateHash(params, allocator);
        std.log.err("Expected extrinsic hash: {s}", .{std.fmt.fmtSliceHexLower(&block.header.extrinsic_hash)});
        std.log.err("Calculated extrinsic hash: {s}", .{std.fmt.fmtSliceHexLower(&calculated_hash)});

        var import_result = importer.importBlock(
            &current_state.?,
            state_transition.block(),
        ) catch |err| {
            // Enhanced error reporting with BlockImporter context
            std.debug.print("\x1b[31m=== Block Import Failed ===\x1b[0m\n", .{});
            std.debug.print("Error: {s}\n", .{@errorName(err)});
            std.debug.print("Block slot: {d}\n", .{state_transition.block().header.slot});
            std.debug.print("Parent hash: {s}\n", .{std.fmt.fmtSliceHexLower(&state_transition.block().header.parent)});
            std.debug.print("Parent state root: {s}\n", .{std.fmt.fmtSliceHexLower(&state_transition.block().header.parent_state_root)});

            // If runtime tracing is enabled, retry with detailed tracing
            if (comptime tracing.tracing_mode == .runtime) {
                std.debug.print("\nRetrying with debug tracing enabled...\n\n", .{});

                try tracing.runtime.setScope("block_import", .trace);
                defer tracing.runtime.disableScope("block_import") catch {};

                try tracing.runtime.setScope("block_import", .trace);
                defer tracing.runtime.disableScope("block_import") catch {};

                // Retry the import with tracing
                var result = importer.importBlock(
                    &current_state.?,
                    state_transition.block(),
                ) catch |retry_err| {
                    std.debug.print("\n=== Detailed trace above shows failure context ===\n", .{});
                    std.debug.print("Error persists: {s}\n\n", .{@errorName(retry_err)});
                    return retry_err;
                };
                defer result.deinit();
            }

            return err;
        };
        defer import_result.deinit();

        // Log seal type for debugging
        std.debug.print("Block sealed with tickets: {}\n", .{import_result.sealed_with_tickets});

        // Merge transition into base state
        try import_result.state_transition.mergePrimeOntoBase();

        // Log block information for debugging
        @import("sequoia.zig").logging.printBlockEntropyDebug(
            params,
            state_transition.block(),
            &current_state.?,
        );

        // Validate against expected state
        var current_state_mdict = try current_state.?.buildStateMerklizationDictionary(allocator);
        defer current_state_mdict.deinit();

        var expected_state_mdict = try state_transition.postStateAsMerklizationDict(allocator);
        defer expected_state_mdict.deinit();

        var expected_state_diff = try current_state_mdict.diff(&expected_state_mdict);
        defer expected_state_diff.deinit();

        // Check for differences from expected state
        if (expected_state_diff.has_changes()) {
            std.debug.print("\x1b[31m=== Expected State Difference Detected ===\x1b[0m\n", .{});
            std.debug.print("{}\n\n", .{expected_state_diff});

            var expected_state = try state_dict.reconstruct.reconstructState(params, allocator, &expected_state_mdict);
            defer expected_state.deinit(allocator);

            var state_diff = try @import("tests/state_diff.zig").JamStateDiff(params).build(allocator, &current_state.?, &expected_state);
            defer state_diff.deinit();

            state_diff.printToStdErr();

            return error.UnexpectedStateDiff;
        }

        // Validate state root
        const state_root = try current_state.?.buildStateRoot(allocator);
        try std.testing.expectEqualSlices(
            u8,
            &state_transition.postStateRoot(),
            &state_root,
        );
    }
}
