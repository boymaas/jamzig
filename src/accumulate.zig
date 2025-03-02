const std = @import("std");
const types = @import("types.zig");

const state = @import("state.zig");
const state_delta = @import("state_delta.zig");

const WorkReportAndDeps = state.available_reports.WorkReportAndDeps;
const Params = @import("jam_params.zig").Params;

fn deinitEntriesAndObject(allocator: std.mem.Allocator, aggregate: anytype) void {
    for (aggregate.items) |*item| {
        item.deinit(allocator);
    }
    aggregate.deinit();
}

pub const QueuedWorkReportAndDeps = std.ArrayList(WorkReportAndDeps);
pub const QueuedWorkReportAndDepsRefs = std.ArrayList(*WorkReportAndDeps);
pub const AccumulatableReports = std.ArrayList(*types.WorkReport);
pub const ResolvedReports = std.ArrayList(*types.WorkReport);

// 12.7 Walks the queued, updates dependencies and removes those who are already resolved
fn queueEditingFunctionRefs(
    queued: *QueuedWorkReportAndDepsRefs,
    resolved_reports: []*types.WorkReport,
) void {
    innerQueueEditingFunction(
        *WorkReportAndDeps,
        *types.WorkReport,
        queued,
        resolved_reports,
    );
}

fn queueEditingFunction(
    queued: *QueuedWorkReportAndDeps,
    resolved_reports: []*types.WorkReport,
) void {
    innerQueueEditingFunction(
        WorkReportAndDeps,
        *types.WorkReport,
        queued,
        resolved_reports,
    );
}

// 12.7 Walks the queued, updates dependencies and removes those who are already resolved
fn innerQueueEditingFunction(
    comptime QueuedItemType: type,
    comptime ReportType: type,
    queued: *std.ArrayList(QueuedItemType),
    resolved_reports: []ReportType,
) void {
    // Determine if we're working with pointers
    const queued_is_ptr = @typeInfo(QueuedItemType) == .pointer;
    const report_is_ptr = @typeInfo(ReportType) == .pointer;

    var idx: usize = 0;
    while (idx < queued.items.len) {
        // Get pointer to the item, handling both value and pointer cases
        const item_ref = if (queued_is_ptr)
            queued.items[idx]
        else
            &queued.items[idx];

        var should_remove = false;

        for (resolved_reports) |report| {
            const report_ref = if (report_is_ptr)
                report
            else
                &report;

            // Check if this report matches our current queued item
            if (std.mem.eql(u8, &item_ref.work_report.package_spec.hash, &report_ref.package_spec.hash)) {
                _ = queued.orderedRemove(idx);
                should_remove = true;
                break; // Exit inner loop since we've removed this item
            }

            // Skip if dependencies are already empty
            if (item_ref.dependencies.count() == 0) {
                continue;
            }

            // Try to remove this report from dependencies
            _ = item_ref.dependencies.swapRemove(report_ref.package_spec.hash);

            // If we've resolved all dependencies, break out
            if (item_ref.dependencies.count() == 0) {
                break; // Exit inner loop since we've resolved this report
            }
        }

        // Only increment idx if we didn't remove the item
        if (!should_remove) {
            idx += 1;
        }
    }
}

// 12.8 We further define the accumulation priority queue function Q, which
// provides the sequence of work-reports which are accumulatable given a set of
// not-yet-accumulated work-reports and their dependencies.
fn processAccumulationQueue(
    allocator: std.mem.Allocator,
    queued: *QueuedWorkReportAndDepsRefs,
    accumulatable: *AccumulatableReports,
) !void {
    // Process work reports in dependency order:
    // 1. Start with immediately executable reports (no dependencies)
    // 2. Use their work package hashes to resolve dependencies of queued reports
    // 3. Repeat until no more dependencies can be resolved
    // This creates a natural accumulation order that respects dependencies
    var resolved = ResolvedReports
        .init(allocator);
    errdefer resolved.deinit();

    // Simulate recursion
    while (true) {
        resolved.clearRetainingCapacity();
        for (queued.items) |wradeps| {
            if (wradeps.dependencies.count() == 0) {
                try accumulatable.append(&wradeps.work_report);
                try resolved.append(&wradeps.work_report);
            }
        }

        // exit condition
        if (resolved.items.len == 0) {
            break;
        }

        // update our queue
        queueEditingFunctionRefs(queued, resolved.items);
    }
}

// 1. History and Queuing (12.1):
// - Tracks accumulated work packages
// - Maintains queue of ready but not-yet-accumulated work reports
// - Partitions newly available work reports into immediate accumulation or queued execution
//
// 2. Execution (12.2):
// - Works with a block gas limit
// - Uses sequential execution but tries to optimize by aggregating work items for the same service
// - Defines functions ∆+, ∆* and ∆1 for accumulation at different levels
//
// 3. Deferred Transfers and State Integration (12.3):
// - Handles transfers that result from accumulation
// - Integrates results into posterior state (χ', φ', ι')
// - Creates Beefy commitment map
//
// 4. Preimage Integration (12.4):
// - Final stage that integrates preimages provided in lookup extrinsic
// - Results in final posterior account state δ'

pub fn processAccumulateReports(
    comptime params: Params,
    stx: *state_delta.StateTransition(params),
    reports: []types.WorkReport,
) !types.AccumulateRoot {
    const allocator = stx.allocator;

    // Initialize the necessary state components
    var xi: *state.Xi(params.epoch_length) = try stx.ensure(.xi_prime);

    // Initialize lists for various report categories
    var accumulatable = AccumulatableReports.init(allocator);
    defer accumulatable.deinit();
    var queued = QueuedWorkReportAndDeps.init(allocator);
    defer {
        for (queued.items) |*q| {
            q.deinit(allocator);
        }

        queued.deinit();
    }

    // Partition reports into immediate and queued based on dependencies
    for (reports) |*report| {
        // 12.4 A report can be accumulated immediately if it has no prerequisites
        // and no segment root lookups
        if (report.context.prerequisites.len == 0 and
            report.segment_root_lookup.len == 0)
        {
            try accumulatable.append(report);
        } else {
            try queued.append(try WorkReportAndDeps.fromWorkReport(allocator, try report.deepClone(allocator)));
        }
    }
    // 12,5
    // Filter out any reports which we already accumulated, and remove any dependencies
    // which we already acummulated. This can potentially produce new resolved work reports
    var idx: usize = 0;
    while (idx < queued.items.len) {
        if (xi.containsWorkPackage(queued.items[idx].work_report.package_spec.hash)) {
            _ = queued.orderedRemove(idx); // TODO: optimize
            continue;
        }
        for (queued.items[idx].dependencies.keys()) |workpackage_hash| {
            if (xi.containsWorkPackage(workpackage_hash)) {
                _ = queued.items[idx].dependencies.swapRemove(workpackage_hash);
                if (queued.items[idx].dependencies.count() == 0) {
                    break;
                }
            }
        }
        idx += 1;
    }

    // 12.12: Build the initial set of pending_reports
    var theta: *state.Theta(params.epoch_length) = try stx.ensure(.theta_prime);

    var pending_reports_queue = QueuedWorkReportAndDepsRefs.init(allocator);
    defer pending_reports_queue.deinit();

    // 12.12: walk theta(current_slot_in_epoch..) join theta(..current_slot_in_epoch)
    var pending_reports = theta.iteratorStartingFrom(stx.time.current_slot_in_epoch);
    while (pending_reports.next()) |wradeps| {
        try pending_reports_queue.append(wradeps);
    }

    // add the new queued imports
    for (queued.items) |*wradeps| {
        try pending_reports_queue.append(wradeps);
    }

    // Now resolve dependenceies using E 12.7
    queueEditingFunctionRefs(&pending_reports_queue, accumulatable.items); // accumulatable is immediate

    // 12.11 Process reports that are ready from the queue and add to accumulatable
    try processAccumulationQueue(
        allocator,
        &pending_reports_queue,
        &accumulatable,
    );

    // NOTE: here we should execute within the gas limit, lets assume we can process 20
    const n = @min(20, accumulatable.items.len);

    const accumulated = accumulatable.items[0..n];

    // Add ready reports to accumulation history
    for (accumulated) |report| {
        const work_package_hash = report.package_spec.hash;
        try xi.addWorkPackage(work_package_hash);
    }
    // Track history of accumulation for an epoch in xi
    try xi.shiftDown();

    // Queue remaining unprocessed reports in theta for later epochs
    for (pending_reports_queue.items) |wradeps| {
        try theta.addEntryToTimeSlot(stx.time.current_slot_in_epoch, try wradeps.deepClone(allocator));
    }

    for (0..params.epoch_length) |i| {
        const widx = if (i <= stx.time.current_slot_in_epoch)
            stx.time.current_slot_in_epoch - i
        else
            i - stx.time.current_slot_in_epoch;

        if (i == 0) {
            queueEditingFunction(&queued, accumulated);
            theta.clearTimeSlot(@intCast(widx));
            for (queued.items) |*wradeps| {
                try theta.addEntryToTimeSlot(@intCast(widx), try wradeps.deepClone(allocator));
            }

            // try theta.entries[widx].insertSlice(allocator, 0, queued.items);
        } else if (i >= stx.time.current_slot and i < stx.time.current_slot - stx.time.prior_slot) {
            theta.clearTimeSlot(@intCast(widx));
        } else if (i >= stx.time.current_slot - stx.time.prior_slot) {
            var entries = theta.entries[widx].toManaged(allocator);
            queueEditingFunction(&entries, accumulated);
        }
    }

    return [_]u8{0} ** 32;
}
