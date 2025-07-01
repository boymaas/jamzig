const std = @import("std");

const types = @import("../../types.zig");
const state = @import("../../state.zig");

const CopyOnWrite = @import("../../meta.zig").CopyOnWrite;

const DeltaSnapshot = @import("../../services_snapshot.zig").DeltaSnapshot;

const Params = @import("../../jam_params.zig").Params;

// 12.13 State components needed for Accumulation
pub fn AccumulationContext(params: Params) type {
    return struct {
        service_accounts: DeltaSnapshot, // d ∈ D⟨N_S → A⟩
        validator_keys: CopyOnWrite(state.Iota), // i ∈ ⟦K⟧_V
        authorizer_queue: CopyOnWrite(state.Phi(params.core_count, params.max_authorizations_queue_items)), // q ∈ _C⟦H⟧^Q_H_C
        privileges: CopyOnWrite(state.Chi), // x ∈ (N_S, N_S, N_S, D⟨N_S → N_G⟩)
        time: *const params.Time(),

        // Additional context for fetch selectors (JAM graypaper §1.7.2)
        entropy: types.Entropy, // η - entropy for current block (fetch selector 1)
        authorizer_hash_output: ?types.Hash, // ω - authorizer execution output (fetch selector 2)
        outputs: std.ArrayList(types.AccumulateOutput), // accumulated outputs from services (fetch selector 17)
        operand_tuples: ?[]const @import("../accumulate.zig").AccumulationOperand, // operand tuples for fetch selectors 14-15
        current_operand_index: ?usize, // Index of currently processing operand for context-aware authorizer hash

        const InitArgs = struct {
            service_accounts: *state.Delta,
            validator_keys: *state.Iota,
            authorizer_queue: *state.Phi(params.core_count, params.max_authorizations_queue_items),
            privileges: *state.Chi,
            time: *const params.Time(),
            entropy: types.Entropy, // Default entropy if not provided
            authorizer_hash_output: ?types.Hash = null,
            operand_tuples: ?[]const @import("../accumulate.zig").AccumulationOperand = null,
            current_operand_index: ?usize = null,
        };

        pub fn build(allocator: std.mem.Allocator, args: InitArgs) @This() {
            return @This(){
                .service_accounts = DeltaSnapshot.init(args.service_accounts),
                .validator_keys = CopyOnWrite(state.Iota).init(allocator, args.validator_keys),
                .authorizer_queue = CopyOnWrite(state.Phi(params.core_count, params.max_authorizations_queue_items)).init(allocator, args.authorizer_queue),
                .privileges = CopyOnWrite(state.Chi).init(allocator, args.privileges),
                .time = args.time,
                .entropy = args.entropy,
                .authorizer_hash_output = args.authorizer_hash_output,
                .outputs = std.ArrayList(types.AccumulateOutput).init(allocator),
                .operand_tuples = args.operand_tuples,
                .current_operand_index = args.current_operand_index,
            };
        }

        /// Set the current operand index for context-aware authorizer hash extraction
        pub fn setCurrentOperand(self: *@This(), operand_index: usize) void {
            self.current_operand_index = operand_index;
        }

        /// Clear the current operand index
        pub fn clearCurrentOperand(self: *@This()) void {
            self.current_operand_index = null;
        }

        /// Get the authorizer hash for the currently processing operand
        /// Returns the authorizer hash from the current operand if available,
        /// or the global authorizer_hash_output as fallback
        pub fn getCurrentAuthorizerHash(self: @This()) ?types.Hash {
            // If we have operand tuples and a current operand index
            if (self.operand_tuples) |operands| {
                if (self.current_operand_index) |index| {
                    if (index < operands.len) {
                        return operands[index].a; // Return authorizer hash from current operand
                    }
                }
            }

            return null;
        }

        pub fn commit(self: *@This()) !void {
            // Commit changes from each CopyOnWrite component
            self.validator_keys.commit();
            self.authorizer_queue.commit();
            self.privileges.commit();
            // Commit the changes f
            try self.service_accounts.commit();
        }

        // TODO: since its deepCloning the wrappers and not really the wrapped objects
        // maybe we should rename this function as its not really a deepClone
        pub fn deepClone(self: @This()) !@This() {
            return @This(){
                // Create a deep clone of the DeltaSnapshot,
                .service_accounts = try self.service_accounts.deepClone(),
                // Keep references to the other components as they are
                .validator_keys = try self.validator_keys.deepClone(),
                .authorizer_queue = try self.authorizer_queue.deepClone(),
                .privileges = try self.privileges.deepClone(),
                // The above deepClones clone the wrappers, the references stay intack
                // since time is not a wrapper. We just pass the pointer, as this will never be mutated
                .time = self.time,
                .entropy = self.entropy,
                .authorizer_hash_output = self.authorizer_hash_output,
                .outputs = try self.outputs.clone(),
                .operand_tuples = self.operand_tuples, // Slice reference, no deep clone needed
                .current_operand_index = self.current_operand_index,
            };
        }

        pub fn deinit(self: *@This()) void {
            // Deinitialize all CopyOnWrite components
            self.validator_keys.deinit();
            self.authorizer_queue.deinit();
            self.privileges.deinit();
            // Deinitialize the DeltaSnapshot
            self.service_accounts.deinit();
            // Deinitialize the outputs ArrayList
            self.outputs.deinit();

            // Set self to undefined to prevent use-after-free
            self.* = undefined;
        }
    };
}
