const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const Params = @import("../jam_params.zig").Params;

const trace = @import("tracing").scoped(.accumulate);

pub const HistoryError = error{
    InvalidHistoryState,
    DuplicateEntry,
};

pub fn HistoryTracker(comptime params: Params) type {
    return struct {
        const Self = @This();

        pub fn updateAccumulationHistory(
            self: Self,
            xi: *state.Xi(params.epoch_length),
            accumulated: []const types.WorkReport,
        ) !void {
            _ = self;
            const span = trace.span(@src(), .update_accumulation_history);
            defer span.deinit();

            try xi.shiftDown();

            span.debug("Adding {d} reports to accumulation history", .{accumulated.len});
            for (accumulated, 0..) |report, i| {
                const work_package_hash = report.package_spec.hash;
                span.trace("Report {d} hash: {s}", .{
                    i, std.fmt.fmtSliceHexLower(&work_package_hash)
                });
                try xi.addWorkPackage(work_package_hash);
            }

            span.debug("Accumulation history updated successfully", .{});
        }

        pub fn isAccumulated(
            self: Self,
            xi: *const state.Xi(params.epoch_length),
            work_package_hash: types.WorkPackageHash,
        ) bool {
            _ = self;
            return xi.containsWorkPackage(work_package_hash);
        }

        pub fn getCurrentSlotCount(
            self: Self,
            xi: *const state.Xi(params.epoch_length),
        ) usize {
            _ = self;
            return xi.entries[0].count();
        }

        pub fn validateHistory(
            self: Self,
            xi: *const state.Xi(params.epoch_length),
        ) !void {
            _ = self;
            const span = trace.span(@src(), .validate_history);
            defer span.deinit();

            for (xi.entries, 0..) |slot, i| {
                var seen = std.AutoHashMap(types.WorkPackageHash, void).init(span.allocator);
                defer seen.deinit();

                var iter = slot.iterator();
                while (iter.next()) |hash| {
                    if (seen.contains(hash.*)) {
                        span.err("Duplicate hash in slot {d}: {s}", .{ 
                            i, std.fmt.fmtSliceHexLower(&hash.*) 
                        });
                        return error.DuplicateEntry;
                    }
                    try seen.put(hash.*, {});
                }
            }

            span.debug("History validation passed", .{});
        }

        pub fn getHistoryStats(
            self: Self,
            xi: *const state.Xi(params.epoch_length),
        ) struct { total_accumulated: usize, slots_used: usize } {
            _ = self;
            var total: usize = 0;
            var slots_used: usize = 0;

            for (xi.entries) |slot| {
                const count = slot.count();
                if (count > 0) {
                    total += count;
                    slots_used += 1;
                }
            }

            return .{
                .total_accumulated = total,
                .slots_used = slots_used,
            };
        }
    };
}