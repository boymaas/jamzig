const std = @import("std");

const types = @import("../../types.zig");
const state = @import("../../state.zig");

const CopyOnWrite = @import("../../meta.zig").CopyOnWrite;

const DeltaSnapshot = @import("../../services_snapshot.zig").DeltaSnapshot;

const Params = @import("../../jam_params.zig").Params;

pub fn AccumulationContext(params: Params) type {
    return struct {
        service_accounts: DeltaSnapshot,
        validator_keys: CopyOnWrite(state.Iota),
        authorizer_queue: CopyOnWrite(state.Phi(params.core_count, params.max_authorizations_queue_items)),
        privileges: CopyOnWrite(state.Chi(params.core_count)),
        time: *const params.Time(),

        entropy: types.Entropy,

        // Original chi values from input partial state (graypaper §12.17)
        // Used for R() function to select between manager and privileged services' changes.
        // See accumulate/chi_merger.zig for R() implementation.
        original_manager: types.ServiceId,
        original_assigners: [params.core_count]types.ServiceId,
        original_delegator: types.ServiceId,
        original_registrar: types.ServiceId,

        const InitArgs = struct {
            service_accounts: *state.Delta,
            validator_keys: *state.Iota,
            authorizer_queue: *state.Phi(params.core_count, params.max_authorizations_queue_items),
            privileges: *state.Chi(params.core_count),
            time: *const params.Time(),
            entropy: types.Entropy,
            original_manager: types.ServiceId,
            original_assigners: [params.core_count]types.ServiceId,
            original_delegator: types.ServiceId,
            original_registrar: types.ServiceId,
        };

        pub fn build(allocator: std.mem.Allocator, args: InitArgs) @This() {
            return @This(){
                .service_accounts = DeltaSnapshot.init(args.service_accounts),
                .validator_keys = CopyOnWrite(state.Iota).init(allocator, args.validator_keys),
                .authorizer_queue = CopyOnWrite(state.Phi(params.core_count, params.max_authorizations_queue_items)).init(allocator, args.authorizer_queue),
                .privileges = CopyOnWrite(state.Chi(params.core_count)).init(allocator, args.privileges),
                .time = args.time,
                .entropy = args.entropy,
                .original_manager = args.original_manager,
                .original_assigners = args.original_assigners,
                .original_delegator = args.original_delegator,
                .original_registrar = args.original_registrar,
            };
        }

        pub fn commit(self: *@This()) !void {
            self.validator_keys.commit();
            self.authorizer_queue.commit();
            self.privileges.commit();
            try self.service_accounts.commit();
        }

        /// Commit state changes for a specific service.
        /// Per graypaper §12.17: stagingset' = (acc(delegator)_poststate)_stagingset
        /// Only the original delegator's validator_keys changes are committed.
        /// Per graypaper §12.17: ∀ c ∈ coreindex: authqueue'[c] = acc(assigners[c])_poststate_authqueue[c]
        /// Only the original assigners' authorization queue changes are committed.
        /// NOTE: privileges (chi) is NOT committed here - handled by R() resolution
        /// in applyChiRResolution() after all services complete.
        pub fn commitForService(self: *@This(), service_id: types.ServiceId) !void {
            if (service_id == self.original_delegator) {
                self.validator_keys.commit();
            }

            const is_assigner = for (self.original_assigners) |assigner| {
                if (service_id == assigner) break true;
            } else false;

            if (is_assigner) {
                self.authorizer_queue.commit();
            }

            try self.service_accounts.commit();
        }

        pub fn deepClone(self: @This()) !@This() {
            return @This(){
                .service_accounts = try self.service_accounts.deepClone(),
                .validator_keys = try self.validator_keys.deepClone(),
                .authorizer_queue = try self.authorizer_queue.deepClone(),
                .privileges = try self.privileges.deepClone(),
                .time = self.time,
                .entropy = self.entropy,
                .original_manager = self.original_manager,
                .original_assigners = self.original_assigners,
                .original_delegator = self.original_delegator,
                .original_registrar = self.original_registrar,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.validator_keys.deinit();
            self.authorizer_queue.deinit();
            self.privileges.deinit();
            self.service_accounts.deinit();
            self.* = undefined;
        }
    };
}
