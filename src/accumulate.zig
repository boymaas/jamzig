const std = @import("std");
const types = @import("types.zig");

const state = @import("state.zig");
const WorkReportAndDeps = state.available_reports.WorkReportAndDeps;

const itertools = @import("itertools.zig");

const Params = @import("jam_params.zig").Params;

/// Partitions reports into those ready for immediate accumulation and those
/// that need to be queued due to dependencies
fn partitionReports(
    reports: []const types.WorkReport,
    immediate: *std.ArrayList(types.WorkReport),
    queued: *std.ArrayList(types.WorkReport),
) !void {
    for (reports) |report| {
        // A report can be accumulated immediately if it has no prerequisites
        // and no segment root lookups
        if (report.context.prerequisites.len == 0 and
            report.segment_root_lookup.len == 0)
        {
            try immediate.append(report);
        } else {
            try queued.append(report);
        }
    }
}

/// Gets reports from the queue that are now ready for accumulation
/// essentially going through Theta, and removing the newly reports
/// for any of the dependencies in the entries. This will
/// result in an updated Theta where some work reports will have no unmet
/// dependencies, and as such are ready to be processed.
///
/// This function will essentially add the queued to Theta, and then
/// remove the workpackages which can be processed immediate from the theta
/// dependencies, which will result in a set of packages which will be immediatly
/// available.
///
/// So theta essentially keeps track of dependencies, and dependencies
/// will be removed, and when dependencies are 0, there will be returned
/// a list of packages which are ready to be accumulated.
fn deinitEntriesAndObject(allocator: std.mem.Allocator, aggregate: anytype) void {
    for (aggregate.items) |*item| {
        item.deinit(allocator);
    }
    aggregate.deinit();
}

/// Process the Accumulation Queue returing an ordered list of accumulatable
/// work reports in the correct order
fn processAccumulationQueue(
    comptime params: Params,
    allocator: std.mem.Allocator,
    time: params.Time(),
    xi: *state.Xi(params.epoch_length),
    theta: *state.Theta(params.epoch_length),
    reports_immediate: []const types.WorkReport,
    reports_queued: []const types.WorkReport,
) !std.ArrayList(types.WorkReport) {
    // Transform reports_queued to a WorkReportAndDeps queue
    var reports_queued_w_deps = try std.ArrayList(WorkReportAndDeps).initCapacity(allocator, reports_queued.len);
    defer deinitEntriesAndObject(allocator, reports_queued_w_deps);

    // 12.5 Resolve the dependencies of our new reports queued against our already processed work_packages
    // The end result should be a set of work reports with unresolved dependencies, and if we for some
    // reason already accumulated this work report it will be removed from this list
    for (reports_queued) |queued_report| {
        var qr_w_d = try WorkReportAndDeps.fromWorkReport(allocator, queued_report);
        errdefer qr_w_d.deinit(allocator);

        if (xi.containsWorkPackage(queued_report.package_spec.hash)) {
            // we already processed this
            continue;
        }
        for (qr_w_d.dependencies.keys()) |workpackage_hash| {
            if (xi.containsWorkPackage(workpackage_hash)) {
                _ = qr_w_d.dependencies.swapRemove(workpackage_hash);
                if (qr_w_d.dependencies.count() == 0) {
                    // no more dependencies to resolve
                    // NOTE: this does not play well with the algo below, as there
                    // we skip an entry based on their dependency count
                    break;
                }
            }
        }
        try reports_queued_w_deps.append(qr_w_d);
    }

    // Prepare the full pending_reports_queue, this will hold all pending workreports
    // with pending dependencies.
    var pending_reports_queue = std.ArrayList(*WorkReportAndDeps).init(allocator);
    defer pending_reports_queue.deinit();

    // walk theta(current_slot_in_epoch..) join theta(..current_slot_in_epoch)
    var pending_reports = theta.iteratorStartingFrom(time.current_slot_in_epoch);
    while (pending_reports.next()) |wradeps| {
        try pending_reports_queue.append(wradeps);
    }
    for (reports_queued_w_deps.items) |*wradeps| {
        try pending_reports_queue.append(wradeps);
    }

    // Now create the return set taking ownership of the appropiate values
    var accumulatable = std.ArrayList(types.WorkReport).init(allocator);
    errdefer accumulatable.deinit();

    // add the immediates as these can be processed immediately
    for (reports_immediate) |work_report| {
        try accumulatable.append(work_report);
    }

    // Process work reports in dependency order:
    // 1. Start with immediately executable reports (no dependencies)
    // 2. Use their work package hashes to resolve dependencies of queued reports
    // 3. Repeat until no more dependencies can be resolved
    // This creates a natural accumulation order that respects dependencies
    var resolved_reports = try std.ArrayList(*const types.WorkPackageHash)
        .initCapacity(allocator, reports_immediate.len);
    errdefer resolved_reports.deinit();

    // Start with the immediate reports, as these will allow for the
    // resolving of dependencies
    for (reports_immediate) |wr| {
        try resolved_reports.append(&wr.package_spec.hash);
    }

    // The newly resolved
    var resolved_reports_new = std.ArrayList(*const types.WorkPackageHash).init(allocator);
    defer resolved_reports_new.deinit();

    while (true) {
        // Now also process our queued_reports where we already resolved the dependencies
        // against our database of processed workpackages
        // Process queued reports, using while loop to handle removals correctly
        var idx: usize = 0;
        while (idx < pending_reports_queue.items.len) : (idx += 1) {
            var wradeps = pending_reports_queue.items[idx];

            // when dependencies are 0 essentially we can conclude that
            // this dependency is removed. This avoids doing an ordered remove
            if (wradeps.dependencies.count() == 0) {
                continue;
            }

            for (resolved_reports.items) |work_package_hash| {
                _ = wradeps.dependencies.swapRemove(work_package_hash.*);
                // after this remove we ended up with an empty set
                // of deps which means this works report dependencies are completely
                // resolved.
                if (wradeps.dependencies.count() == 0) {
                    try resolved_reports_new.append(&wradeps.work_report.package_spec.hash);
                    try accumulatable.append(wradeps.work_report);
                    break; // Exit inner loop since we've resolved this report
                }
            }
        }

        if (resolved_reports.items.len == 0) {
            break;
        }

        // now repeat and try to resolve more dependencies
        std.mem.swap(std.ArrayList(*const types.WorkPackageHash), &resolved_reports, &resolved_reports_new);
        resolved_reports_new.clearRetainingCapacity();
    }

    return accumulatable;
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
    allocator: std.mem.Allocator,
    reports: []types.WorkReport,
    time: params.Time(),
    delta: *state.Delta,
    theta: *state.Theta(params.epoch_length),
    chi: *state.Chi,
    xi: *state.Xi(params.epoch_length),
) !types.AccumulateRoot {
    _ = delta;
    _ = chi;

    // Initialize lists for various report categories
    var immediate = std.ArrayList(types.WorkReport).init(allocator);
    defer immediate.deinit();
    var queued = std.ArrayList(types.WorkReport).init(allocator);
    defer queued.deinit();

    // Partition reports into immediate and queued based on dependencies
    try partitionReports(reports, &immediate, &queued);

    // Process reports that are ready from the queue
    var accumulatable_reports = try processAccumulationQueue(
        params,
        allocator,
        time,
        xi,
        theta,
        immediate.items,
        queued.items,
    );
    defer accumulatable_reports.deinit();

    // NOTE: here we should execute

    // Add ready reports to accumulation history
    for (accumulatable_reports.items) |report| {
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

fn calculateAccumulateRoot(
    allocator: std.mem.Allocator,
    processed: *itertools.ConcatSlicesIterator(types.WorkPackageHash),
) !types.AccumulateRoot {
    _ = allocator;
    _ = processed;
    return [_]u8{0} ** 32;
}
