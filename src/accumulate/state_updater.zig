const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const Params = @import("../jam_params.zig").Params;

const accumulate_types = @import("types.zig");
const Queued = accumulate_types.Queued;
const TimeInfo = accumulate_types.TimeInfo;

const WorkReportAndDeps = state.reports_ready.WorkReportAndDeps;

const trace = @import("tracing").scoped(.accumulate);

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

        pub fn updateThetaState(
            self: Self,
            theta: *state.VarTheta(params.epoch_length),
            queued: *Queued(WorkReportAndDeps),
            accumulated: []const types.WorkReport,
            map_buffer: *std.ArrayList(types.WorkReportHash),
            time: TimeInfo,
        ) !void {
            const span = trace.span(@src(), .update_theta_state);
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

        fn processQueueUpdates(
            self: Self,
            queued: *Queued(WorkReportAndDeps),
            resolved_reports: []types.WorkReportHash,
        ) void {
            const span = trace.span(@src(), .process_queue_updates);
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

                for (resolved_reports) |work_package_hash| {
                    if (std.mem.eql(u8, &wradeps.work_report.package_spec.hash, &work_package_hash)) {
                        span.debug("Found matching report, removing from queue at index {d}", .{idx});
                        var removed = queued.orderedRemove(idx);
                        removed.deinit(self.allocator);
                        continue :outer;
                    }
                }

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

        pub fn updateAccumulationOutputs(
            _: Self,
            theta: *state.Theta,
            accumulation_outputs: anytype, // HashSet(ServiceAccumulationOutput)
        ) !void {
            const span = trace.span(@src(), .update_accumulation_outputs);
            defer span.deinit();

            span.debug("Updating theta with {d} accumulation outputs", .{accumulation_outputs.count()});

            theta.outputs.clearRetainingCapacity();

            var iter = accumulation_outputs.iterator();
            while (iter.next()) |entry| {
                try theta.outputs.append(.{
                    .service_id = entry.key_ptr.service_id,
                    .hash = entry.key_ptr.output,
                });
            }

            std.mem.sort(
                @import("../accumulation_outputs.zig").AccumulationOutput,
                theta.outputs.items,
                {},
                struct {
                    fn lessThan(_: void, a: @import("../accumulation_outputs.zig").AccumulationOutput, b: @import("../accumulation_outputs.zig").AccumulationOutput) bool {
                        if (a.service_id != b.service_id) {
                            return a.service_id < b.service_id;
                        }
                        return std.mem.lessThan(u8, &a.hash, &b.hash);
                    }
                }.lessThan,
            );

            span.debug("Theta updated with {d} sorted outputs", .{theta.outputs.items.len});
        }
    };
}

fn mapWorkPackageHash(buffer: anytype, items: anytype) ![]types.WorkReportHash {
    buffer.clearRetainingCapacity();
    for (items) |item| {
        try buffer.append(item.package_spec.hash);
    }
    return buffer.items;
}