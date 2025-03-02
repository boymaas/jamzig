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
fn queueEditingFunction(
    queued: *QueuedWorkReportAndDepsRefs,
    resolved_reports: *const ResolvedReports,
) void {
    var idx: usize = 0;
    while (idx < queued.items.len) {
        const wradeps = queued.items[idx];

        for (resolved_reports.items) |report| {
            if (std.mem.eql(u8, &wradeps.work_report.package_spec.hash, &report.package_spec.hash)) {
                _ = queued.orderedRemove(idx);
                continue;
            }

            // when dependencies are 0 essentially we can conclude that
            if (wradeps.dependencies.count() == 0) {
                continue;
            }

            // else try to remove and resolve
            _ = wradeps.dependencies.swapRemove(report.package_spec.hash);
            // resolved?
            if (wradeps.dependencies.count() == 0) {
                break; // Exit inner loop since we've resolved this report
            }
        }
        idx += 1;
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
        queueEditingFunction(queued, &resolved);
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
    defer queued.deinit();

    // Partition reports into immediate and queued based on dependencies
    for (reports) |*report| {
        // 12.4 A report can be accumulated immediately if it has no prerequisites
        // and no segment root lookups
        if (report.context.prerequisites.len == 0 and
            report.segment_root_lookup.len == 0)
        {
            try accumulatable.append(report);
        } else {
            try queued.append(try WorkReportAndDeps.fromWorkReport(allocator, report.*));
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
    queueEditingFunction(&pending_reports_queue, &accumulatable); // accumulatable is immediate

    // 12.11 Process reports that are ready from the queue and add to accumulatable
    try processAccumulationQueue(
        allocator,
        &pending_reports_queue,
        &accumulatable,
    );

    // NOTE: here we should execute

    // Add ready reports to accumulation history
    for (accumulatable.items) |report| {
        const work_package_hash = report.package_spec.hash;
        try xi.addWorkPackage(work_package_hash);
    }
    // Track history of accumulation for an epoch in xi
    try xi.shiftDown();

    // Queue remaining unprocessed reports in theta for later epochs
    // for (queued.items) |report| {
    //     try theta.addWorkReport(time.current_slot_in_epoch, report);
    // }

    return [_]u8{0} ** 32;
}
