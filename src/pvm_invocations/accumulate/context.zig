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

        const InitArgs = struct {
            service_accounts: *state.Delta,
            validator_keys: *state.Iota,
            authorizer_queue: *state.Phi(params.core_count, params.max_authorizations_queue_items),
            privileges: *state.Chi(params.core_count),
            time: *const params.Time(),
            entropy: types.Entropy,
        };

        pub fn build(allocator: std.mem.Allocator, args: InitArgs) @This() {
            return @This(){
                .service_accounts = DeltaSnapshot.init(args.service_accounts),
                .validator_keys = CopyOnWrite(state.Iota).init(allocator, args.validator_keys),
                .authorizer_queue = CopyOnWrite(state.Phi(params.core_count, params.max_authorizations_queue_items)).init(allocator, args.authorizer_queue),
                .privileges = CopyOnWrite(state.Chi(params.core_count)).init(allocator, args.privileges),
                .time = args.time,
                .entropy = args.entropy,
            };
        }

        pub fn commit(self: *@This()) !void {
            self.validator_keys.commit();
            self.authorizer_queue.commit();

            // NOTE: service_accounts is managed by applyContextChanges to ensure
            // graypaper ordering: modifications first, then deletions.
            // try self.service_accounts.commit();

            // NOTE: chi is managed by ChiMerger, so we don't commit it here.
            // self.privileges.commit();
        }

        pub fn deepClone(self: @This()) !@This() {
            return @This(){
                .service_accounts = try self.service_accounts.deepClone(),
                .validator_keys = try self.validator_keys.deepClone(),
                .authorizer_queue = try self.authorizer_queue.deepClone(),
                .privileges = try self.privileges.deepClone(),
                .time = self.time,
                .entropy = self.entropy,
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
