
const std = @import("std");
const types = @import("../../types.zig");
const jam_params = @import("../../jam_params.zig");
const jamtestnet = @import("../../trace_runner/parsers.zig");
const state_transitions = @import("../../trace_runner/state_transitions.zig");
const report = @import("../report.zig");
const messages = @import("../messages.zig");
const state_converter = @import("../state_converter.zig");

const trace = @import("tracing").scoped(.trace_provider);

pub fn TraceProvider(comptime params: jam_params.Params) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        transitions: state_transitions.StateTransitions,
        loader: jamtestnet.Loader,

        pub const Config = struct {
            directory: []const u8,
        };

        pub fn init(allocator: std.mem.Allocator, config: Config) !Self {
            const span = trace.span(@src(), .trace_provider_init);
            defer span.deinit();
            span.debug("Initializing TraceProvider from directory: {s}", .{config.directory});

            const w3f_loader = jamtestnet.w3f.Loader(params){};
            const loader = w3f_loader.loader();

            var all_transitions = try state_transitions.collectStateTransitions(config.directory, allocator);
            errdefer all_transitions.deinit(allocator);

            span.debug("Found {d} valid state transitions", .{all_transitions.count()});

            if (all_transitions.count() == 0) {
                return error.NoValidTransitions;
            }

            return Self{
                .allocator = allocator,
                .transitions = all_transitions,
                .loader = loader,
            };
        }

        pub fn deinit(self: *Self) void {
            const span = trace.span(@src(), .trace_provider_deinit);
            defer span.deinit();
            span.debug("Cleaning up TraceProvider", .{});

            self.transitions.deinit(self.allocator);
            self.* = undefined;
        }

        /// Drive the trace replay process - this is the main entry point
        pub fn run(self: *Self, comptime FuzzerType: type, fuzzer: *FuzzerType, should_shutdown: ?*const fn () bool) !report.FuzzResult {
            const span = trace.span(@src(), .trace_provider_run);
            defer span.deinit();
            span.debug("Starting trace-driven replay with {d} transitions", .{self.transitions.count()});

            var result = report.FuzzResult{
                .seed = 0, // No seed for trace mode
                .blocks_processed = 0,
                .mismatch = null,
                .success = true,
                .err = null,
            };

            const pre_state_root = blk: {
                const first_transition = self.transitions.items()[0];
                span.debug("Processing first transition for SetState: {s}", .{first_transition.bin.name});

                var state_transition = try self.loader.loadTestVector(self.allocator, first_transition.bin.path);
                defer state_transition.deinit(self.allocator);

                const block = state_transition.block();

                var pre_state_dict = try state_transition.preStateAsMerklizationDict(self.allocator);
                defer pre_state_dict.deinit();

                var fuzz_state = try state_converter.dictionaryToFuzzState(self.allocator, &pre_state_dict);
                defer fuzz_state.deinit(self.allocator);

                const target_state_root = try fuzzer.setState(block.*.header, fuzz_state);

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

            var previous_state_root: messages.StateRootHash = pre_state_root;
            for (self.transitions.items(), 0..) |transition, i| {
                if (should_shutdown) |check_fn| {
                    if (check_fn()) {
                        span.debug("Shutdown requested, stopping at trace {d}", .{i});
                        result.blocks_processed = i;
                        result.success = true; // Clean shutdown is considered success
                        return result;
                    }
                }

                const block_span = span.child(@src(), .process_trace);
                defer block_span.deinit();
                block_span.debug("Processing trace {d}/{d}: {s}", .{ i + 1, self.transitions.count(), transition.bin.name });

                var state_transition = try self.loader.loadTestVector(self.allocator, transition.bin.path);
                defer state_transition.deinit(self.allocator);

                const block = state_transition.block();

                const expected_state_root = state_transition.postStateRoot();

                var block_result = fuzzer.sendBlock(block) catch |err| {
                    block_span.err("Error sending block to target: {s}", .{@errorName(err)});
                    result.blocks_processed = i;
                    result.success = false;
                    result.err = err;
                    return result;
                };
                defer block_result.deinit(self.allocator);

                const target_state_root_after = switch (block_result) {
                    .success => |root| root,
                    .import_error => |err_msg| {
                        block_span.err("Target rejected valid test vector block: {s}", .{err_msg});
                        result.blocks_processed = i;
                        result.success = false;
                        result.err = error.BlockRejectedByTarget;
                        result.err_details = try self.allocator.dupe(u8, err_msg);
                        return result;
                    },
                };

                if (FuzzerType.compareStateRoots(previous_state_root, target_state_root_after)) {
                    block_span.warn("Target reported same state root as previous: {s}", .{std.fmt.fmtSliceHexLower(&target_state_root_after)});
                }

                if (!std.mem.eql(u8, &expected_state_root, &target_state_root_after)) {
                    block_span.err("Post-state root mismatch at trace {s}", .{transition.bin.name});
                    result.mismatch = report.Mismatch{
                        .block_number = block.header.slot,
                        .block = try block.deepClone(self.allocator),
                        .reported_state_root = target_state_root_after,
                    };
                    result.success = false;
                    result.blocks_processed = i + 1;
                    return result;
                }

                previous_state_root = expected_state_root;

                block_span.debug("Trace {s} passed", .{transition.bin.name});
                result.blocks_processed += 1;
            }

            span.debug("Trace replay completed successfully. Traces: {d}", .{self.transitions.count()});
            return result;
        }
    };
}
