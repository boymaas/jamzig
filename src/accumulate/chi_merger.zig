const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const Params = @import("../jam_params.zig").Params;

const trace = @import("tracing").scoped(.chi_merger);

/// R(o, a, b) function from graypaper §12.17
pub fn replaceIfChanged(
    original: types.ServiceId,
    manager_value: types.ServiceId,
    privileged_value: types.ServiceId,
) types.ServiceId {
    return if (manager_value == original) privileged_value else manager_value;
}

pub fn ChiMerger(comptime params: Params) type {
    const Chi = state.Chi(params.core_count);

    return struct {
        original_manager: types.ServiceId,
        original_assigners: [params.core_count]types.ServiceId,
        original_delegator: types.ServiceId,
        original_registrar: types.ServiceId,

        const Self = @This();

        pub fn init(
            original_manager: types.ServiceId,
            original_assigners: [params.core_count]types.ServiceId,
            original_delegator: types.ServiceId,
            original_registrar: types.ServiceId,
        ) Self {
            return .{
                .original_manager = original_manager,
                .original_assigners = original_assigners,
                .original_delegator = original_delegator,
                .original_registrar = original_registrar,
            };
        }

        /// Apply R() function per graypaper §12.17: R(o,a,b) = b when a=o, else a
        pub fn merge(
            self: *const Self,
            manager_chi: ?*const Chi,
            service_chi_map: *const std.AutoHashMap(types.ServiceId, *const Chi),
            output_chi: *Chi,
        ) !void {
            const span = trace.span(@src(), .chi_merge);
            defer span.deinit();

            const e_star = manager_chi orelse {
                span.debug("Manager didn't accumulate, no chi changes", .{});
                return;
            };

            span.debug("Applying R() for chi fields, original_manager={d}", .{self.original_manager});

            output_chi.manager = e_star.manager;
            span.debug("manager: {d} (direct from manager)", .{output_chi.manager});

            output_chi.always_accumulate.clearRetainingCapacity();
            var it = e_star.always_accumulate.iterator();
            while (it.next()) |entry| {
                try output_chi.always_accumulate.put(entry.key_ptr.*, entry.value_ptr.*);
            }
            span.debug("always_accumulate: {d} entries (direct from manager)", .{output_chi.always_accumulate.count()});

            for (0..params.core_count) |c| {
                const original_assigner = self.original_assigners[c];
                const manager_assigner = e_star.assign[c];

                const privileged_assigner = if (service_chi_map.get(original_assigner)) |chi|
                    chi.assign[c]
                else
                    original_assigner;

                output_chi.assign[c] = replaceIfChanged(
                    original_assigner,
                    manager_assigner,
                    privileged_assigner,
                );

                if (output_chi.assign[c] != original_assigner) {
                    span.debug("assign[{d}]: {d} -> {d} (R: orig={d}, mgr={d}, priv={d})", .{
                        c,
                        original_assigner,
                        output_chi.assign[c],
                        original_assigner,
                        manager_assigner,
                        privileged_assigner,
                    });
                }
            }

            const delegator_chi = service_chi_map.get(self.original_delegator);
            const delegator_value = if (delegator_chi) |chi| chi.designate else self.original_delegator;
            output_chi.designate = replaceIfChanged(
                self.original_delegator,
                e_star.designate,
                delegator_value,
            );
            span.debug("designate: {d} (R: orig={d}, mgr={d}, priv={d})", .{
                output_chi.designate,
                self.original_delegator,
                e_star.designate,
                delegator_value,
            });

            const registrar_chi = service_chi_map.get(self.original_registrar);
            const registrar_value = if (registrar_chi) |chi| chi.registrar else self.original_registrar;
            output_chi.registrar = replaceIfChanged(
                self.original_registrar,
                e_star.registrar,
                registrar_value,
            );
            span.debug("registrar: {d} (R: orig={d}, mgr={d}, priv={d})", .{
                output_chi.registrar,
                self.original_registrar,
                e_star.registrar,
                registrar_value,
            });

            span.debug("Chi R() resolution complete", .{});
        }
    };
}

const testing = std.testing;

test "R function: manager unchanged uses privileged" {
    try testing.expectEqual(@as(types.ServiceId, 10), replaceIfChanged(5, 5, 10));
}

test "R function: manager changed uses manager" {
    try testing.expectEqual(@as(types.ServiceId, 8), replaceIfChanged(5, 8, 10));
}

test "R function: both unchanged" {
    try testing.expectEqual(@as(types.ServiceId, 5), replaceIfChanged(5, 5, 5));
}

test "R function: manager changed to same as privileged" {
    try testing.expectEqual(@as(types.ServiceId, 10), replaceIfChanged(5, 10, 10));
}

test "R function: privileged changed but manager didn't" {
    try testing.expectEqual(@as(types.ServiceId, 7), replaceIfChanged(5, 5, 7));
}
