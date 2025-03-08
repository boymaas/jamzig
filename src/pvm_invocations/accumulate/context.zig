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

        const InitArgs = struct {
            service_accounts: *state.Delta,
            validator_keys: *state.Iota,
            authorizer_queue: *state.Phi(params.core_count, params.max_authorizations_queue_items),
            privileges: *state.Chi,
        };

        pub fn build(allocator: std.mem.Allocator, args: InitArgs) @This() {
            return @This(){
                .service_accounts = DeltaSnapshot.init(args.service_accounts),
                .validator_keys = CopyOnWrite(state.Iota).init(allocator, args.validator_keys),
                .authorizer_queue = CopyOnWrite(state.Phi(params.core_count, params.max_authorizations_queue_items)).init(allocator, args.authorizer_queue),
                .privileges = CopyOnWrite(state.Chi).init(allocator, args.privileges),
            };
        }

        pub fn commit(self: *@This()) !void {
            // Commit changes from each CopyOnWrite component
            self.validator_keys.commit();
            self.authorizer_queue.commit();
            self.privileges.commit();
            // Commit the changes f
            try self.service_accounts.commit();
        }

        pub fn deepClone(self: @This()) !@This() {
            return @This(){
                // Create a deep clone of the DeltaSnapshot,
                .service_accounts = try self.service_accounts.deepClone(),
                // Keep references to the other components as they are
                .validator_keys = try self.validator_keys.deepClone(),
                .authorizer_queue = try self.authorizer_queue.deepClone(),
                .privileges = try self.privileges.deepClone(),
            };
        }

        pub fn deinit(self: *@This()) void {
            // Deinitialize all CopyOnWrite components
            self.validator_keys.deinit();
            self.authorizer_queue.deinit();
            self.privileges.deinit();
            // Deinitialize the DeltaSnapshot
            self.service_accounts.deinit();

            // Set self to undefined to prevent use-after-free
            self.* = undefined;
        }
    };
}
