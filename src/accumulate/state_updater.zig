//! State coordination for accumulation process
//!
//! This module handles all state updates after accumulation, including
//! Xi (accumulation history), Theta (pending reports), and Delta (service accounts).
//! It ensures coordinated updates to prevent state inconsistencies.

const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const Params = @import("../jam_params.zig").Params;

const accumulate_types = @import("types.zig");
const Queued = accumulate_types.Queued;
const TimeInfo = accumulate_types.TimeInfo;

const WorkReportAndDeps = state.reports_ready.WorkReportAndDeps;

const trace = @import("../tracing.zig").scoped(.accumulate);

/// Error types for state updates
pub const StateUpdateError = error{
    InvalidStateTransition,
    InconsistentState,
    UpdateFailed,
} || error{OutOfMemory};

pub fn StateUpdater(comptime params: Params) type {
    return struct {
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        /// Updates theta state after accumulation (§12.27)
        pub fn updateThetaState(
            self: Self,
            theta: *state.VarTheta(params.epoch_length),
            queued: *Queued(WorkReportAndDeps),
            accumulated: []const types.WorkReport,
            map_buffer: *std.ArrayList(types.WorkReportHash),
            time: TimeInfo,
        ) !void {
            const span = trace.span(.update_theta_state);
            defer span.deinit();

            span.debug("Updating theta pending reports for epoch length {d}", .{params.epoch_length});

            for (0..params.epoch_length) |i| {
                const widx = if (i <= time.current_slot_in_epoch)
                    time.current_slot_in_epoch - i
                else
                    params.epoch_length - (i - time.current_slot_in_epoch);

                span.trace("Processing slot {d}, widx: {d}", .{ i, widx });

                if (i == 0) {
                    span.debug("Updating current slot {d}", .{widx});
                    self.processQueueUpdates(queued, try mapWorkPackageHash(map_buffer, accumulated));
                    theta.clearTimeSlot(@intCast(widx));

                    span.debug("Adding {d} queued items to time slot {d}", .{ queued.items.len, widx });
                    for (queued.items, 0..) |*wradeps, qidx| {
                        // Only add items that still have dependencies
                        if (wradeps.dependencies.count() > 0) {
                            span.trace("Adding queued item {d} to slot {d}", .{ qidx, widx });
                            const cloned_wradeps = try wradeps.deepClone(self.allocator);
                            try theta.addEntryToTimeSlot(@intCast(widx), cloned_wradeps);
                        } else {
                            span.trace("Skipping queued item {d} to slot {d}: no dependencies", .{ qidx, widx });
                        }
                    }
                } else if (i >= 1 and i < time.current_slot - time.prior_slot) {
                    span.debug("Clearing time slot {d}", .{widx});
                    theta.clearTimeSlot(@intCast(widx));
                } else if (i >= time.current_slot - time.prior_slot) {
                    span.debug("Processing entries for time slot {d}", .{widx});
                    // Convert to managed to handle removals properly
                    var entries = theta.entries[widx].toManaged(self.allocator);
                    self.processQueueUpdates(&entries, try mapWorkPackageHash(map_buffer, accumulated));
                    theta.entries[widx] = entries.moveToUnmanaged();

                    // Remove reports without dependencies
                    theta.removeReportsWithoutDependenciesAtSlot(@intCast(widx));
                }
            }
        }

        /// Process queue updates by removing resolved reports
        fn processQueueUpdates(
            self: Self,
            queued: *Queued(WorkReportAndDeps),
            resolved_reports: []types.WorkReportHash,
        ) void {
            const span = trace.span(.process_queue_updates);
            defer span.deinit();

            span.debug("Processing queue updates with {d} queued items and {d} resolved reports", .{ 
                queued.items.len, resolved_reports.len 
            });

            var idx: usize = 0;
            outer: while (idx < queued.items.len) {
                var wradeps = &queued.items[idx];
                span.trace("Processing item {d}: hash={s}", .{ 
                    idx, std.fmt.fmtSliceHexLower(&wradeps.work_report.package_spec.hash) 
                });

                // Check if this report was resolved
                for (resolved_reports) |work_package_hash| {
                    if (std.mem.eql(u8, &wradeps.work_report.package_spec.hash, &work_package_hash)) {
                        span.debug("Found matching report, removing from queue at index {d}", .{idx});
                        var removed = queued.orderedRemove(idx);
                        removed.deinit(self.allocator);
                        continue :outer;
                    }
                }

                // Update dependencies
                if (wradeps.dependencies.count() > 0) {
                    for (resolved_reports) |work_package_hash| {
                        if (wradeps.dependencies.swapRemove(work_package_hash)) {
                            span.debug("Resolved dependency: {s}", .{
                                std.fmt.fmtSliceHexLower(&work_package_hash)
                            });
                        }

                        if (wradeps.dependencies.count() == 0) {
                            span.debug("All dependencies resolved for report at index {d}", .{idx});
                            break;
                        }
                    }
                }
                idx += 1;
            }

            span.debug("Queue updates complete, {d} items remaining", .{queued.items.len});
        }
    };
}

/// Helper function to map work reports to their package hashes
fn mapWorkPackageHash(buffer: anytype, items: anytype) ![]types.WorkReportHash {
    buffer.clearRetainingCapacity();
    for (items) |item| {
        try buffer.append(item.package_spec.hash);
    }
    return buffer.items;
}