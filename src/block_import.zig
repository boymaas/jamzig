const std = @import("std");
const types = @import("types.zig");
const jam_params = @import("jam_params.zig");
const stf = @import("stf.zig");
const JamState = @import("state.zig").JamState;
const StateTransition = @import("state_delta.zig").StateTransition;
const HeaderValidator = @import("header_validator.zig").HeaderValidator;

const tracing = @import("tracing.zig");
const trace = tracing.scoped(.block_import);
const tracy = @import("tracy");

/// Re-export validation error from header_validator
pub const ValidationError = @import("header_validator.zig").HeaderValidationError;

/// Re-export validation config from header_validator
pub const ValidationConfig = @import("header_validator.zig").ValidationConfig;

/// Unified block importer with state-based validation
pub fn BlockImporter(comptime IOExecutor: type, comptime params: jam_params.Params) type {
    return struct {
        allocator: std.mem.Allocator,
        header_validator: HeaderValidator(IOExecutor, params),
        executor: *IOExecutor,

        const Self = @This();

        /// Result of block import operation
        pub const ImportResult = struct {
            /// The state transition that was applied
            state_transition: *StateTransition(params),
            /// Whether the block was sealed with tickets
            sealed_with_tickets: bool,

            pub fn commit(self: *ImportResult) !void {
                // Commit the state transition to the heap
                try self.state_transition.mergePrimeOntoBase();
            }

            pub fn deinit(self: *ImportResult) void {
                // Deinitialize the state transition
                self.state_transition.destroy(self.state_transition.allocator);
                // Clear the struct to avoid dangling pointers
                self.* = undefined;
            }
        };

        pub fn init(executor: *IOExecutor, allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .header_validator = HeaderValidator(IOExecutor, params).init(allocator, executor),
                .executor = executor,
            };
        }

        pub fn initWithConfig(executor: *IOExecutor, allocator: std.mem.Allocator, config: ValidationConfig) Self {
            return .{
                .allocator = allocator,
                .header_validator = HeaderValidator(IOExecutor, params).initWithConfig(allocator, executor, config),
                .executor = executor,
            };
        }

        /// Import a block building the state root for validation
        pub fn importBlockBuildingRoot(
            self: *Self,
            current_state: *const JamState(params),
            block: *const types.Block,
        ) !ImportResult {
            const span = trace.span(.import_block_building_root);
            defer span.deinit();

            const tracy_zone = tracy.ZoneN(@src(), "block_import_build_root");
            defer tracy_zone.End();

            // Build current state root for validation
            const current_state_root = try current_state.buildStateRoot(self.allocator);

            return self.importBlockWithCachedRoot(
                current_state,
                current_state_root,
                block,
            );
        }

        /// Import a block using a cached state root for validation
        pub fn importBlockWithCachedRoot(
            self: *Self,
            current_state: *const JamState(params),
            cached_state_root: types.StateRoot,
            block: *const types.Block,
        ) !ImportResult {
            const span = trace.span(.import_block_with_cached_root);
            defer span.deinit();

            // Frame per block
            const tracy_zone = tracy.ZoneN(@src(), "block_import_with_cached_root");
            defer tracy_zone.End();
            defer tracy.FrameMarkNamed("Block");

            // Step 1: Validate header using the cached state root
            const validation_result = blk: {
                const header_zone = tracy.ZoneN(@src(), "validate_header");
                defer header_zone.End();
                break :blk try self.header_validator.validateHeader(
                    current_state,
                    &block.header,
                    cached_state_root,
                    &block.extrinsic,
                );
            };

            span.debug("Header validated, sealed with tickets: {}", .{validation_result.sealed_with_tickets});

            // Step 2: Apply state transition
            const state_transition = blk: {
                const stf_zone = tracy.ZoneN(@src(), "stf_transition");
                defer stf_zone.End();
                break :blk try stf.stateTransition(
                    IOExecutor,
                    self.executor,
                    params,
                    self.allocator,
                    current_state,
                    block,
                );
            };

            return ImportResult{
                .state_transition = state_transition,
                .sealed_with_tickets = validation_result.sealed_with_tickets,
            };
        }
    };
}
