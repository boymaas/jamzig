const std = @import("std");
const types = @import("types.zig");
const jam_params = @import("jam_params.zig");
const stf = @import("stf.zig");
const JamState = @import("state.zig").JamState;
const StateTransition = @import("state_delta.zig").StateTransition;
const HeaderValidator = @import("header_validator.zig").HeaderValidator;

const tracing = @import("tracing.zig");
const trace = tracing.scoped(.block_import);

/// Re-export validation error from header_validator
pub const ValidationError = @import("header_validator.zig").HeaderValidationError;

/// Re-export validation config from header_validator
pub const ValidationConfig = @import("header_validator.zig").ValidationConfig;

/// Unified block importer with state-based validation
pub fn BlockImporter(comptime params: jam_params.Params) type {
    return struct {
        allocator: std.mem.Allocator,
        header_validator: HeaderValidator(params),

        const Self = @This();

        /// Result of block import operation
        pub const ImportResult = struct {
            /// The state transition that was applied
            state_transition: *StateTransition(params),
            /// Whether the block was sealed with tickets
            sealed_with_tickets: bool,
        };

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .header_validator = HeaderValidator(params).init(allocator),
            };
        }

        pub fn initWithConfig(allocator: std.mem.Allocator, config: ValidationConfig) Self {
            return .{
                .allocator = allocator,
                .header_validator = HeaderValidator(params).initWithConfig(allocator, config),
            };
        }

        /// Import a block with state-based validation and state transition
        pub fn importBlock(
            self: *Self,
            current_state: *const JamState(params),
            block: *const types.Block,
        ) !ImportResult {
            const span = trace.span(.import_block);
            defer span.deinit();

            // Build current state root for validation
            const current_state_root = try current_state.buildStateRoot(self.allocator);

            // Step 1: Validate header using the header validator
            const validation_result = try self.header_validator.validateHeader(
                current_state,
                &block.header,
                current_state_root,
                &block.extrinsic,
            );

            span.debug("Header validated, sealed with tickets: {}", .{validation_result.sealed_with_tickets});

            // Step 2: Apply state transition
            const state_transition = try stf.stateTransition(
                params,
                self.allocator,
                current_state,
                block,
            );

            return ImportResult{
                .state_transition = state_transition,
                .sealed_with_tickets = validation_result.sealed_with_tickets,
            };
        }

    };
}
