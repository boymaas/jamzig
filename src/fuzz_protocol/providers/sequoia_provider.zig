
const std = @import("std");
const types = @import("../../types.zig");
const sequoia = @import("../../sequoia.zig");
const jam_params = @import("../../jam_params.zig");
const JamState = @import("../../state.zig").JamState;
const block_import = @import("../../block_import.zig");
const io = @import("../../io.zig");
const report = @import("../report.zig");
const messages = @import("../messages.zig");
const state_converter = @import("../state_converter.zig");
const state_dictionary = @import("../../state_dictionary.zig");

const trace = @import("tracing").scoped(.sequoia_provider);

pub fn SequoiaProvider(comptime IOExecutor: type, comptime params: jam_params.Params) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        block_builder: *sequoia.BlockBuilder(params),
        block_importer: block_import.BlockImporter(IOExecutor, params),
        current_jam_state: *JamState(params),
        latest_block: ?types.Block,
        num_blocks: usize,
        seed: u64,
        prng: *std.Random.DefaultPrng,
        rng: *std.Random,

        pub const Config = struct {
            seed: u64,
            num_blocks: usize,
        };

        pub fn init(executor: *IOExecutor, allocator: std.mem.Allocator, config: Config) !Self {
            const span = trace.span(@src(), .sequoia_provider_init);
            defer span.deinit();
            span.debug("Initializing SequoiaProvider with seed: {d}, blocks: {d}", .{ config.seed, config.num_blocks });

            const prng = try allocator.create(std.Random.DefaultPrng);
            prng.* = std.Random.DefaultPrng.init(config.seed);
            const rng = try allocator.create(std.Random);
            rng.* = prng.random();

            var genesis_config = try sequoia.GenesisConfig(params).buildWithRng(allocator, rng);
            errdefer genesis_config.deinit(allocator);

            var block_builder = try sequoia.BlockBuilder(params).create(allocator, genesis_config, rng);
            errdefer block_builder.destroy();

            var block_importer = block_import.BlockImporter(IOExecutor, params).init(executor, allocator);
            // NOTE: no deinit on block_importer

            var genesis_block = try block_builder.buildNextBlock();
            errdefer genesis_block.deinit(allocator);

            const current_jam_state = &block_builder.state;

            var import_result = try block_importer.importBlockBuildingRoot(
                current_jam_state,
                &genesis_block,
            );
            defer import_result.deinit();

            try import_result.commit();

            return Self{
                .allocator = allocator,
                .block_builder = block_builder,
                .block_importer = block_importer,
                .current_jam_state = current_jam_state,
                .latest_block = genesis_block,
                .num_blocks = config.num_blocks,
                .seed = config.seed,
                .prng = prng,
                .rng = rng,
            };
        }

        pub fn deinit(self: *Self) void {
            const span = trace.span(@src(), .sequoia_provider_deinit);
            defer span.deinit();
            span.debug("Cleaning up SequoiaProvider", .{});

            if (self.latest_block) |*block| {
                block.deinit(self.allocator);
            }
            self.block_builder.destroy();

            self.allocator.destroy(self.prng);
            self.allocator.destroy(self.rng);
        }

        /// Drive the fuzzing process - this is the main entry point
        pub fn run(self: *Self, comptime FuzzerType: type, fuzzer: *FuzzerType, should_shutdown: ?*const fn () bool) !report.FuzzResult {
            const span = trace.span(@src(), .sequoia_provider_run);
            defer span.deinit();
            span.debug("Starting Sequoia-driven fuzzing with {d} blocks", .{self.num_blocks});

            var initial_state_result = try state_converter.jamStateToFuzzState(
                params,
                self.allocator,
                self.current_jam_state,
            );
            defer initial_state_result.deinit();

            const local_state_root = try self.current_jam_state.buildStateRoot(self.allocator);

            const header = self.latest_block.?.header;
            const target_state_root = try fuzzer.setState(header, initial_state_result.state);

            if (!std.mem.eql(u8, &local_state_root, &target_state_root)) {
                span.err("Initial state root mismatch! Local: {s}, Target: {s}", .{
                    std.fmt.fmtSliceHexLower(&local_state_root),
                    std.fmt.fmtSliceHexLower(&target_state_root),
                });
                return error.InitialStateRootMismatch;
            }

            span.debug("Initial state roots match: {s}", .{std.fmt.fmtSliceHexLower(&local_state_root)});

            for (0..self.num_blocks) |block_num| {
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
                block_span.debug("Processing block {d}/{d}", .{ block_num + 1, self.num_blocks });

                var block = try self.block_builder.buildNextBlock();
                errdefer block.deinit(self.allocator);

                var block_result = try fuzzer.sendBlock(&block);
                defer block_result.deinit(self.allocator);

                const block_target_state_root = switch (block_result) {
                    .success => |root| root,
                    .import_error => |err_msg| {
                        block_span.err("Block import failed: {s}", .{err_msg});
                        return report.FuzzResult{
                            .seed = self.seed,
                            .blocks_processed = block_num,
                            .mismatch = null,
                            .success = false,
                            .err = error.BlockImportFailed,
                            .err_details = try self.allocator.dupe(u8, err_msg),
                        };
                    },
                };

                const local_root = try self.processBlockLocally(&block);

                self.latest_block.?.deinit(self.allocator);
                self.latest_block = block;

                sequoia.logging.printBlockEntropyDebug(params, &self.latest_block.?, self.current_jam_state);

                if (!FuzzerType.compareStateRoots(local_root, block_target_state_root)) {
                    block_span.debug("State root mismatch detected!", .{});

                    var local_dict = try self.current_jam_state.buildStateMerklizationDictionary(self.allocator);
                    errdefer local_dict.deinit();

                    const block_header_hash = try self.latest_block.?.header.header_hash(params, self.allocator);
                    var target_state: ?messages.State = fuzzer.getState(block_header_hash) catch |err| blk: {
                        block_span.err("Failed to retrieve target state: {s}", .{@errorName(err)});
                        break :blk null;
                    };
                    defer if (target_state) |*ts| {
                        ts.deinit(self.allocator);
                    };

                    var target_dict: ?state_dictionary.MerklizationDictionary = null;
                    var target_computed_root: ?messages.StateRootHash = null;
                    if (target_state) |ts| {
                        target_dict = try state_converter.fuzzStateToMerklizationDictionary(self.allocator, ts);
                        errdefer if (target_dict) |*td| td.deinit();

                        const computed_root = try target_dict.?.buildStateRoot(self.allocator);
                        target_computed_root = computed_root;
                    }

                    return report.FuzzResult{
                        .seed = self.seed,
                        .blocks_processed = block_num + 1,
                        .mismatch = report.Mismatch{
                            .block_number = block_num,
                            .block = try self.latest_block.?.deepClone(self.allocator),
                            .reported_state_root = block_target_state_root,
                            .local_dict = local_dict,
                            .target_dict = target_dict,
                            .target_computed_root = target_computed_root,
                        },
                        .success = false,
                        .err = null,
                    };
                } else {
                    block_span.debug("State roots match: {s}", .{std.fmt.fmtSliceHexLower(&local_root)});
                }
            }

            span.debug("Sequoia fuzzing completed successfully. Blocks: {d}", .{self.num_blocks});

            return report.FuzzResult{
                .seed = self.seed,
                .blocks_processed = self.num_blocks,
                .mismatch = null,
                .success = true,
                .err = null,
            };
        }

        /// Process block locally and return state root
        fn processBlockLocally(self: *Self, block: *const types.Block) !messages.StateRootHash {
            const span = trace.span(@src(), .sequoia_provider_process_local);
            defer span.deinit();

            var import_result = try self.block_importer.importBlockBuildingRoot(
                self.current_jam_state,
                block,
            );
            defer import_result.deinit();

            try import_result.commit();

            const state_root = try self.current_jam_state.buildStateRoot(self.allocator);

            span.debug("Local state root: {s}", .{std.fmt.fmtSliceHexLower(&state_root)});
            return state_root;
        }
    };
}
