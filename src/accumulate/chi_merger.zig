const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const Params = @import("../jam_params.zig").Params;

const trace = @import("tracing").scoped(.chi_merger);

// Graypaper §12.17
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
        const Self = @This();

        // Graypaper §12.17
        pub fn merge(
            original_chi: *Chi,
            service_chi_map: *const std.AutoHashMap(types.ServiceId, *const Chi),
        ) !void {
            const span = trace.span(@src(), .chi_merge);
            defer span.deinit();

            const orig = .{
                .manager = original_chi.manager,
                .delegator = original_chi.designate,
                .registrar = original_chi.registrar,
                .assigners = original_chi.assign,
            };

            const manager_chi = service_chi_map.get(orig.manager);

            span.debug("Applying R() (manager accumulated: {any})", .{manager_chi != null});

            original_chi.manager = if (manager_chi) |m| m.manager else orig.manager;
            span.debug("manager: {d}", .{original_chi.manager});

            if (manager_chi) |e_star| {
                original_chi.always_accumulate.clearRetainingCapacity();
                var it = e_star.always_accumulate.iterator();
                while (it.next()) |entry| {
                    try original_chi.always_accumulate.put(entry.key_ptr.*, entry.value_ptr.*);
                }
                span.debug("always_accumulate: {d} entries", .{original_chi.always_accumulate.count()});
            }

            for (0..params.core_count) |c| {
                const original = orig.assigners[c];
                const manager_value = if (manager_chi) |m| m.assign[c] else original;
                const privileged_value = if (service_chi_map.get(original)) |s| s.assign[c] else original;

                original_chi.assign[c] = replaceIfChanged(original, manager_value, privileged_value);

                if (original_chi.assign[c] != original) {
                    span.debug("assign[{d}]: {d} -> {d}", .{ c, original, original_chi.assign[c] });
                }
            }

            const manager_delegator = if (manager_chi) |m| m.designate else orig.delegator;
            const privileged_delegator = if (service_chi_map.get(orig.delegator)) |s| s.designate else orig.delegator;
            original_chi.designate = replaceIfChanged(orig.delegator, manager_delegator, privileged_delegator);
            span.debug("designate: {d}", .{original_chi.designate});

            const manager_registrar = if (manager_chi) |m| m.registrar else orig.registrar;
            const privileged_registrar = if (service_chi_map.get(orig.registrar)) |s| s.registrar else orig.registrar;
            original_chi.registrar = replaceIfChanged(orig.registrar, manager_registrar, privileged_registrar);
            span.debug("registrar: {d}", .{original_chi.registrar});

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
