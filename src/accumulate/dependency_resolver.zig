const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const meta = @import("../meta.zig");
const Params = @import("../jam_params.zig").Params;

const accumulate_types = @import("types.zig");
const Queued = accumulate_types.Queued;
const Accumulatable = accumulate_types.Accumulatable;
const Resolved = accumulate_types.Resolved;
const PreparedReports = accumulate_types.PreparedReports;
const FilterResult = accumulate_types.FilterResult;
const PartitionResult = accumulate_types.PartitionResult;

const WorkReportAndDeps = state.reports_ready.WorkReportAndDeps;

const trace = @import("tracing").scoped(.accumulate);

/// Error types specific to dependency resolution
pub const DependencyError = error{
    CircularDependency,
    UnresolvedDependency,
    InvalidDependencyChain,
} || error{OutOfMemory};

pub fn DependencyResolver(comptime params: Params) type {
    return struct {
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        /// Main entry point: Prepares reports for accumulation by resolving dependencies
        /// 
        /// This function takes a slice of work reports and prepares them for accumulation by:
        /// 1. Partitioning into immediately accumulatable vs queued reports
        /// 2. Filtering out already accumulated reports
        /// 3. Resolving dependencies between reports
        /// 
        /// Ownership: This function clones the input reports as needed. The caller retains
        /// ownership of the original reports slice. The returned PreparedReports contains
        /// newly allocated data that the caller must eventually clean up.
        pub fn prepareReportsForAccumulation(
            self: Self,
            xi: *state.Xi(params.epoch_length),
            theta: *state.VarTheta(params.epoch_length),
            reports: []types.WorkReport,
            current_slot_in_epoch: u32,
        ) !PreparedReports {
            const span = trace.span(@src(), .prepare_reports_for_accumulation);
            defer span.deinit();

            var map_buffer = try std.ArrayList(types.WorkReportHash).initCapacity(self.allocator, 32);
            errdefer map_buffer.deinit();

            // Initialize lists for various report categories
            var accumulatable_buffer = Accumulatable(types.WorkReport).init(self.allocator);
            errdefer meta.deinit.deinitEntriesAndAggregate(self.allocator, accumulatable_buffer);
            var queued = Queued(WorkReportAndDeps).init(self.allocator);
            errdefer meta.deinit.deinitEntriesAndAggregate(self.allocator, queued);

            span.debug("Initialized accumulatable and queued containers", .{});
            const partition_result = try self.partitionReports(reports, &accumulatable_buffer, &queued);
            span.debug("Partitioned reports: {d} immediate, {d} queued", .{ partition_result.immediate_count, partition_result.queued_count });

            // Filter out already accumulated reports and resolve dependencies
            const filter_result = try self.filterAccumulatedReports(&queued, xi);
            span.debug("Filtered reports: removed {d}, resolved {d} dependencies", .{ filter_result.filtered_out, filter_result.resolved_deps });

            // Build the initial set of pending reports
            var pending_reports_queue = try self.buildPendingReportsQueue(
                theta,
                &queued,
                current_slot_in_epoch,
            );
            defer meta.deinit.deinitEntriesAndAggregate(self.allocator, pending_reports_queue);

            // Resolve dependencies using queue editing function
            span.debug("Resolving dependencies using queue editing function", .{});
            self.processQueueUpdates(
                &pending_reports_queue,
                try mapWorkPackageHash(&map_buffer, accumulatable_buffer.items),
            );

            // Process reports that are ready from the queue
            span.debug("Processing accumulation queue to find accumulatable reports", .{});
            span.debug("Accumulatable buffer before processing: {d} items", .{accumulatable_buffer.items.len});
            try self.resolveAccumulatableReports(
                &pending_reports_queue,
                &accumulatable_buffer,
            );
            span.debug("Accumulatable buffer after processing: {d} items", .{accumulatable_buffer.items.len});

            return .{
                .accumulatable_buffer = accumulatable_buffer,
                .queued = queued,
                .map_buffer = map_buffer,
            };
        }

        /// Processes queue updates by removing resolved reports and updating dependencies (§12.7)
        fn processQueueUpdates(
            self: Self,
            queued: *Queued(WorkReportAndDeps),
            resolved_reports: []types.WorkReportHash,
        ) void {
            const span = trace.span(@src(), .process_queue_updates);
            defer span.deinit();

            span.debug("Starting queue updates with {d} queued items and {d} resolved reports", .{ queued.items.len, resolved_reports.len });

            var idx: usize = 0;
            outer: while (idx < queued.items.len) {
                var wradeps = &queued.items[idx];
                span.trace("Processing item {d}: hash={s}", .{ idx, std.fmt.fmtSliceHexLower(&wradeps.work_report.package_spec.hash) });

                // Check if this report itself was resolved
                for (resolved_reports) |work_package_hash| {
                    if (std.mem.eql(u8, &wradeps.work_report.package_spec.hash, &work_package_hash)) {
                        span.debug("Found matching report, removing from queue at index {d}", .{idx});
                        var removed = queued.orderedRemove(idx);
                        removed.deinit(self.allocator);
                        continue :outer;
                    }
                }

                // Update dependencies if this report has any
                if (wradeps.dependencies.count() > 0) {
                    for (resolved_reports) |work_package_hash| {
                        span.trace("Checking dependency: {s}", .{std.fmt.fmtSliceHexLower(&work_package_hash)});
                        if (wradeps.dependencies.swapRemove(work_package_hash)) {
                            span.debug("Resolved dependency: {s}", .{std.fmt.fmtSliceHexLower(&work_package_hash)});
                        } else {
                            span.debug("Dependency does not match: {s}", .{std.fmt.fmtSliceHexLower(&work_package_hash)});
                            span.trace("Current report dependencies: {any}", .{types.fmt.format(wradeps.dependencies.keys())});
                        }

                        if (wradeps.dependencies.count() == 0) {
                            span.debug("All dependencies resolved for report at index {d}", .{idx});
                            break;
                        }
                    }
                }
                idx += 1;
            }

            span.debug("Queue updates complete, {d} items remaining in queue", .{queued.items.len});
        }

        /// Processes the accumulation queue to find reports ready for accumulation (§12.8)
        fn resolveAccumulatableReports(
            self: Self,
            queued: *Queued(WorkReportAndDeps),
            accumulatable: *Accumulatable(types.WorkReport),
        ) !void {
            const span = trace.span(@src(), .resolve_accumulatable_reports);
            defer span.deinit();

            span.debug("Starting accumulation queue processing with {d} queued items", .{queued.items.len});

            var resolved = Resolved(types.WorkPackageHash).init(self.allocator);
            defer resolved.deinit();
            span.debug("Initialized resolved reports container", .{});

            // Iteratively resolve dependencies
            var iteration: usize = 0;
            while (true) {
                const iter_span = span.child(@src(), .iteration);
                defer iter_span.deinit();
                iteration += 1;

                iter_span.debug("Starting iteration {d}", .{iteration});

                resolved.clearRetainingCapacity();
                iter_span.trace("Cleared resolved list, capacity: {d}", .{resolved.capacity});

                var resolved_count: usize = 0;
                for (queued.items, 0..) |*wradeps, i| {
                    const deps_count = wradeps.dependencies.count();
                    iter_span.trace("Checking item {d}: dependencies={d}, hash={s}", .{ i, deps_count, std.fmt.fmtSliceHexLower(&wradeps.work_report.package_spec.hash) });

                    if (deps_count == 0) {
                        const cloned_report = try wradeps.work_report.deepClone(self.allocator);
                        try accumulatable.append(cloned_report);
                        try resolved.append(wradeps.work_report.package_spec.hash);
                        resolved_count += 1;
                        iter_span.debug("Found resolvable report at index {d} (core={d}, results={d}), hash: {s}", .{ i, wradeps.work_report.core_index.value, wradeps.work_report.results.len, std.fmt.fmtSliceHexLower(&wradeps.work_report.package_spec.hash) });
                    }
                }

                iter_span.debug("Found {d} resolvable reports in this iteration", .{resolved_count});

                if (resolved.items.len == 0) {
                    iter_span.debug("No resolvable reports found, exiting loop", .{});
                    break;
                }

                // Update our queue
                iter_span.debug("Updating queue with {d} newly resolved items", .{resolved.items.len});
                self.processQueueUpdates(queued, resolved.items);
            }

            span.debug("Accumulation queue processing complete, found {d} accumulatable reports", .{accumulatable.items.len});
        }

        /// Partitions work reports into immediately accumulatable and queued reports
        fn partitionReports(
            self: Self,
            reports: []types.WorkReport,
            accumulatable_buffer: *Accumulatable(types.WorkReport),
            queued: *Queued(WorkReportAndDeps),
        ) !PartitionResult {
            const span = trace.span(@src(), .partition_reports);
            defer span.deinit();

            span.debug("Partitioning {d} reports into immediate and queued", .{reports.len});

            var immediate_count: usize = 0;
            var queued_count: usize = 0;

            for (reports, 0..) |*report, i| {
                span.trace("Checking report {d}, hash: {s}", .{ i, std.fmt.fmtSliceHexLower(&report.package_spec.hash) });

                // A report can be accumulated immediately if it has no prerequisites
                // and no segment root lookups (§12.4)
                if (report.context.prerequisites.len == 0 and
                    report.segment_root_lookup.len == 0)
                {
                    span.debug("Report {d} (core={d}, results={d}) is immediately accumulatable", .{ i, report.core_index.value, report.results.len });
                    const cloned_report = try report.deepClone(self.allocator);
                    try accumulatable_buffer.append(cloned_report);
                    immediate_count += 1;
                } else {
                    span.debug("Report {d} (core={d}, results={d}) has dependencies (prereqs: {d}, lookups: {d})", .{ i, report.core_index.value, report.results.len, report.context.prerequisites.len, report.segment_root_lookup.len });
                    const cloned_report = try report.deepClone(self.allocator);
                    const work_report_deps = try WorkReportAndDeps.fromWorkReport(self.allocator, cloned_report);
                    try queued.append(work_report_deps);
                    queued_count += 1;
                }
            }

            span.debug("Partitioning complete: {d} immediate, {d} queued", .{ immediate_count, queued_count });
            return .{ .immediate_count = immediate_count, .queued_count = queued_count };
        }

        /// Filters out already accumulated reports and removes resolved dependencies
        fn filterAccumulatedReports(
            self: Self,
            queued: *Queued(WorkReportAndDeps),
            xi: *state.Xi(params.epoch_length),
        ) !FilterResult {
            const span = trace.span(@src(), .filter_accumulated_reports);
            defer span.deinit();

            span.debug("Filtering already accumulated reports from {d} queued items", .{queued.items.len});

            var filtered_out: usize = 0;
            var resolved_deps: usize = 0;

            var idx: usize = 0;
            while (idx < queued.items.len) {
                const queued_item = &queued.items[idx];
                const work_package_hash = queued_item.work_report.package_spec.hash;

                span.trace("Checking queued item {d}, hash: {s}", .{ idx, std.fmt.fmtSliceHexLower(&work_package_hash) });

                if (xi.containsWorkPackage(work_package_hash)) {
                    span.debug("Report already accumulated, removing from queue", .{});
                    @constCast(&queued.orderedRemove(idx)).deinit(self.allocator);
                    filtered_out += 1;
                    continue;
                }

                var deps_resolved: usize = 0;
                {
                    const dep_span = span.child(@src(), .check_dependencies);
                    defer dep_span.deinit();

                    const keys = queued_item.dependencies.keys();
                    var i: usize = keys.len;
                    while (i > 0) {
                        i -= 1;
                        const workpackage_hash = keys[i];
                        dep_span.trace("Checking dependency: {s}", .{std.fmt.fmtSliceHexLower(&workpackage_hash)});

                        if (xi.containsWorkPackage(workpackage_hash)) {
                            dep_span.debug("Removing from dependencies: {s}", .{std.fmt.fmtSliceHexLower(&workpackage_hash)});
                            _ = queued_item.dependencies.swapRemove(workpackage_hash);
                            deps_resolved += 1;
                            resolved_deps += 1;

                            if (queued_item.dependencies.count() == 0) {
                                dep_span.debug("All dependencies resolved for report at index {d}", .{idx});
                                break;
                            }
                        }
                    }
                }

                span.trace("Resolved {d} dependencies for item {d}", .{ deps_resolved, idx });
                idx += 1;
            }

            span.debug("Filtering complete: removed {d} reports, resolved {d} dependencies", .{ filtered_out, resolved_deps });
            return .{ .filtered_out = filtered_out, .resolved_deps = resolved_deps };
        }

        /// Builds the pending reports queue from theta and queued reports
        fn buildPendingReportsQueue(
            self: Self,
            theta: *state.VarTheta(params.epoch_length),
            queued: *Queued(WorkReportAndDeps),
            current_slot_in_epoch: u32,
        ) !Queued(WorkReportAndDeps) {
            const span = trace.span(@src(), .build_pending_reports_queue);
            defer span.deinit();

            span.debug("Building initial set of pending reports", .{});

            var pending_reports_queue = Queued(WorkReportAndDeps).init(self.allocator);
            errdefer meta.deinit.deinitEntriesAndAggregate(self.allocator, pending_reports_queue);

            // Walk theta from current slot onwards (§12.12)
            span.debug("Walking theta from slot {d}", .{current_slot_in_epoch});

            var pending_reports = theta.iteratorStartingFrom(current_slot_in_epoch);
            var reports_from_theta: usize = 0;

            while (pending_reports.next()) |wradeps| {
                span.trace("Found report in theta, hash: {s}", .{std.fmt.fmtSliceHexLower(&wradeps.work_report.package_spec.hash)});
                const cloned_wradeps = try wradeps.deepClone(self.allocator);
                try pending_reports_queue.append(cloned_wradeps);
                reports_from_theta += 1;
            }

            span.debug("Collected {d} reports from theta", .{reports_from_theta});

            // Add the new queued imports
            span.debug("Adding {d} queued reports to pending queue", .{queued.items.len});
            for (queued.items) |*wradeps| {
                span.trace("Adding queued report: {s}", .{std.fmt.fmtSliceHexLower(&wradeps.work_report.package_spec.hash)});
                const cloned_wradeps = try wradeps.deepClone(self.allocator);
                try pending_reports_queue.append(cloned_wradeps);
            }

            span.debug("Total pending reports: {d}", .{pending_reports_queue.items.len});
            return pending_reports_queue;
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

