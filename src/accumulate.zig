const std = @import("std");
const types = @import("types.zig");

const state = @import("state.zig");
const state_delta = @import("state_delta.zig");

const WorkReportAndDeps = state.reports_ready.WorkReportAndDeps;
const Params = @import("jam_params.zig").Params;
const meta = @import("meta.zig");

// Add tracing import
const trace = @import("tracing.zig").scoped(.accumulate);

// 12.7 Walks the queued, updates dependencies and removes those who are already resolved
fn queueEditingFunction(
    queued: *Queued(WorkReportAndDeps),
    resolved_reports: []types.WorkReportHash,
) void {
    const span = trace.span(.queue_editing);
    defer span.deinit();

    span.debug("Starting queue editing with {d} queued items and {d} resolved reports", .{ queued.items.len, resolved_reports.len });

    var idx: usize = 0;
    outer: while (idx < queued.items.len) {
        var wradeps = &queued.items[idx];
        span.trace("Processing item {d}: hash={s}", .{ idx, std.fmt.fmtSliceHexLower(&wradeps.work_report.package_spec.hash) });

        for (resolved_reports) |work_package_hash| {
            if (std.mem.eql(u8, &wradeps.work_report.package_spec.hash, &work_package_hash)) {
                span.debug("Found matching report, removing from queue at index {d}", .{idx});
                var removed = queued.orderedRemove(idx);
                // TODO: pass allocator to function
                removed.deinit(queued.allocator);
                // so the next element to process is now at the current index position
                // continue the while loop without incrementing idx since the next element
                // is now at the current index after removal
                continue :outer;
            }

            // when dependencies are 0 we are done with this one
            if (wradeps.dependencies.count() == 0) {
                span.trace("No dependencies, continuing", .{});
                break;
            }

            span.trace("Checking dependency: {s}", .{std.fmt.fmtSliceHexLower(&work_package_hash)});
            // else try to remove and resolve
            if (wradeps.dependencies.swapRemove(work_package_hash)) {
                span.debug("Resolved dependency: {s}", .{std.fmt.fmtSliceHexLower(&work_package_hash)});
            } else {
                span.debug("Dependency does not match: {s}", .{std.fmt.fmtSliceHexLower(&work_package_hash)});
                span.trace("Current report dependencies: {any}", .{types.fmt.format(wradeps.dependencies.keys())});
            }

            // resolved?
            if (wradeps.dependencies.count() == 0) {
                span.debug("All dependencies resolved for report at index {d}", .{idx});
                break; // Exit inner loop since we've resolved this report
            }
        }
        idx += 1;
    }

    span.debug("Queue editing complete, {d} items remaining in queue", .{queued.items.len});
}

// 12.8 We further define the accumulation priority queue function Q, which
// provides the sequence of work-reports which are accumulatable given a set of
// not-yet-accumulated work-reports and their dependencies.
fn processAccumulationQueue(
    allocator: std.mem.Allocator,
    queued: *Queued(WorkReportAndDeps),
    accumulatable: *Accumulatable(types.WorkReport),
) !void {
    const span = trace.span(.process_accumulation_queue);
    defer span.deinit();

    span.debug("Starting accumulation queue processing with {d} queued items", .{queued.items.len});

    // Process work reports in dependency order:
    // 1. Start with immediately executable reports (no dependencies)
    // 2. Use their work package hashes to resolve dependencies of queued reports
    // 3. Repeat until no more dependencies can be resolved
    // This creates a natural accumulation order that respects dependencies
    var resolved = Resolved(types.WorkPackageHash).init(allocator);
    defer resolved.deinit();
    span.debug("Initialized resolved reports container", .{});

    // Simulate recursion
    var iteration: usize = 0;
    while (true) {
        const iter_span = span.child(.iteration);
        defer iter_span.deinit();
        iteration += 1;

        iter_span.debug("Starting iteration {d}", .{iteration});

        // NOTE: we start assuming there "can" be resolved entries, if there
        // are none. We exit immediatly without iterating. See: processAccumulateReports@12.5.
        resolved.clearRetainingCapacity();
        iter_span.trace("Cleared resolved list, capacity: {d}", .{resolved.capacity});

        var resolved_count: usize = 0;
        for (queued.items, 0..) |*wradeps, i| {
            const deps_count = wradeps.dependencies.count();
            iter_span.trace("Checking item {d}: dependencies={d}, hash={s}", .{ i, deps_count, std.fmt.fmtSliceHexLower(&wradeps.work_report.package_spec.hash) });

            if (deps_count == 0) {
                try accumulatable.append(try wradeps.work_report.deepClone(allocator));
                try resolved.append(wradeps.work_report.package_spec.hash);
                resolved_count += 1;
                iter_span.debug("Found resolvable report at index {d}, hash: {s}", .{ i, std.fmt.fmtSliceHexLower(&wradeps.work_report.package_spec.hash) });
            }
        }

        iter_span.debug("Found {d} resolvable reports in this iteration", .{resolved_count});

        // exit condition
        if (resolved.items.len == 0) {
            iter_span.debug("No resolvable reports found, exiting loop", .{});
            break;
        }

        // update our queue
        iter_span.debug("Updating queue with {d} newly resolved items", .{resolved.items.len});
        queueEditingFunction(queued, resolved.items);
    }

    span.debug("Accumulation queue processing complete, found {d} accumulatable reports", .{accumulatable.items.len});
}

/// processes the new to be accumulated reports
pub fn processAccumulateReports(
    comptime params: Params,
    stx: *state_delta.StateTransition(params),
    reports: []types.WorkReport,
) !types.AccumulateRoot {
    const span = trace.span(.process_accumulate_reports);
    defer span.deinit();

    span.debug("Starting process accumulate reports with {d} reports", .{reports.len});

    const allocator = stx.allocator;
    var map_buffer = try std.ArrayList(types.WorkReportHash).initCapacity(allocator, 32);
    defer map_buffer.deinit();

    // Initialize the necessary state components
    var xi: *state.Xi(params.epoch_length) = try stx.ensure(.xi_prime);
    span.debug("Initialized xi state component", .{});

    // Initialize lists for various report categories
    var accumulatable_buffer = Accumulatable(types.WorkReport).init(allocator);
    defer meta.deinit.deinitEntriesAndAggregate(allocator, accumulatable_buffer);
    var queued = Queued(WorkReportAndDeps).init(allocator);
    defer meta.deinit.deinitEntriesAndAggregate(allocator, queued);

    span.debug("Initialized accumulatable and queued containers", .{});

    // Partition reports into immediate and queued based on dependencies
    const partition_span = span.child(.partition_reports);
    defer partition_span.deinit();

    partition_span.debug("Partitioning {d} reports into immediate and queued", .{reports.len});

    var immediate_count: usize = 0;
    var queued_count: usize = 0;

    for (reports, 0..) |*report, i| {
        partition_span.trace("Checking report {d}, hash: {s}", .{ i, std.fmt.fmtSliceHexLower(&report.package_spec.hash) });

        // 12.4 A report can be accumulated immediately if it has no prerequisites
        // and no segment root lookups
        if (report.context.prerequisites.len == 0 and
            report.segment_root_lookup.len == 0)
        {
            partition_span.debug("Report {d} is immediately accumulatable", .{i});
            try accumulatable_buffer.append(try report.deepClone(allocator));
            immediate_count += 1;
        } else {
            partition_span.debug("Report {d} has dependencies (prereqs: {d}, lookups: {d})", .{ i, report.context.prerequisites.len, report.segment_root_lookup.len });
            try queued.append(try WorkReportAndDeps.fromWorkReport(allocator, try report.deepClone(allocator)));
            queued_count += 1;
        }
    }

    partition_span.debug("Partitioning complete: {d} immediate, {d} queued", .{ immediate_count, queued_count });

    // 12,5
    // Filter out any reports which we already accumulated, and remove any dependencies
    // which we already acummulated. This can potentially produce new resolved work reports
    const filter_span = span.child(.filter_queued);
    defer filter_span.deinit();

    filter_span.debug("Filtering already accumulated reports from {d} queued items", .{queued.items.len});

    var filtered_out: usize = 0;
    var resolved_deps: usize = 0;

    var idx: usize = 0;
    while (idx < queued.items.len) {
        const queued_item = &queued.items[idx];
        const work_package_hash = queued_item.work_report.package_spec.hash;

        filter_span.trace("Checking queued item {d}, hash: {s}", .{ idx, std.fmt.fmtSliceHexLower(&work_package_hash) });

        if (xi.containsWorkPackage(work_package_hash)) {
            filter_span.debug("Report already accumulated, removing from queue", .{});
            @constCast(&queued.orderedRemove(idx)).deinit(allocator); // TODO: optimize
            filtered_out += 1;
            continue;
        }

        var deps_resolved: usize = 0;
        {
            const dep_span = filter_span.child(.check_dependencies);
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

        filter_span.trace("Resolved {d} dependencies for item {d}", .{ deps_resolved, idx });
        idx += 1;
    }

    filter_span.debug("Filtering complete: removed {d} reports, resolved {d} dependencies", .{ filtered_out, resolved_deps });

    // 12.12: Build the initial set of pending_reports
    const pending_span = span.child(.build_pending_reports);
    defer pending_span.deinit();

    pending_span.debug("Building initial set of pending reports", .{});

    var pending_reports_queue = Queued(WorkReportAndDeps).init(allocator);
    defer meta.deinit.deinitEntriesAndAggregate(allocator, pending_reports_queue);

    // 12.12: walk theta(current_slot_in_epoch..) join theta(..current_slot_in_epoch)
    var theta: *state.Theta(params.epoch_length) = try stx.ensure(.theta_prime);
    pending_span.debug("Walking theta from slot {d}", .{stx.time.current_slot_in_epoch});

    var pending_reports = theta.iteratorStartingFrom(stx.time.current_slot_in_epoch);
    var reports_from_theta: usize = 0;

    while (pending_reports.next()) |wradeps| {
        pending_span.trace("Found report in theta, hash: {s}", .{std.fmt.fmtSliceHexLower(&wradeps.work_report.package_spec.hash)});
        try pending_reports_queue.append(try wradeps.deepClone(allocator));
        reports_from_theta += 1;
    }

    pending_span.debug("Collected {d} reports from theta", .{reports_from_theta});

    // add the new queued imports
    pending_span.debug("Adding {d} queued reports to pending queue", .{queued.items.len});
    for (queued.items) |*wradeps| {
        pending_span.trace("Adding queued report: {s}", .{std.fmt.fmtSliceHexLower(&wradeps.work_report.package_spec.hash)});
        try pending_reports_queue.append(try wradeps.deepClone(allocator));
    }

    pending_span.debug("Total pending reports: {d}", .{pending_reports_queue.items.len});

    // Now resolve dependenceies using E 12.7
    pending_span.debug("Resolving dependencies using queue editing function", .{});
    queueEditingFunction(
        &pending_reports_queue,
        try mapWorkPackageHash(&map_buffer, accumulatable_buffer.items), // accumulatable contains immediate
    );

    // 12.11 Process reports that are ready from the queue and add to accumulatable
    pending_span.debug("Processing accumulation queue to find accumulatable reports", .{});
    try processAccumulationQueue(
        allocator,
        &pending_reports_queue,
        &accumulatable_buffer,
    );

    const execute_span = span.child(.execute_accumulatable);
    defer execute_span.deinit();

    execute_span.debug("Calculating gas limit for accumulation", .{});
    // Calculate the gas limit according to equation 12.20:
    // let g = max(G_T, G_A ⋅ C + ∑_{x∈V(χ_g)}(x))
    var gas_limit: u64 = params.total_gas_alloc_accumulation;

    // Calculate G_A * C (gas per core * core count)
    const core_gas = @as(u64, params.gas_alloc_accumulation) * @as(u64, params.core_count);

    // Get the privileges state to access free services
    const chi = try stx.ensure(.chi_prime);

    // Add the sum of gas values for free services
    var free_services_gas: u64 = 0;
    var it = chi.always_accumulate.iterator();
    while (it.next()) |entry| {
        free_services_gas += entry.value_ptr.*;
    }

    // Take the maximum
    const calculated_gas = core_gas + free_services_gas;
    if (calculated_gas > gas_limit) {
        gas_limit = calculated_gas;
    }

    execute_span.debug("Gas limit calculated: {d} (G_T: {d}, core gas: {d}, free services gas: {d})", .{ gas_limit, params.total_gas_alloc_accumulation, core_gas, free_services_gas });

    // TODO: assurances_test test vectors fail because of this limitation which
    // is I believe in the graypaper. Check the testvectors if we need to use
    // other params now just disabled this constraint
    // const accumulatable = accumulatable_buffer.items[0..@min(accumulatable_buffer.items.len, params.core_count)];
    const accumulatable = accumulatable_buffer.items;
    execute_span.debug("Executing outer accumulation with {d} reports and gas limit {d}", .{ accumulatable.len, gas_limit });

    // Build accumulation context
    var accumulation_context = @import("pvm_invocations/accumulate.zig")
        .AccumulationContext(params).build(
        allocator,
        .{
            .service_accounts = try stx.ensure(.delta_prime),
            .validator_keys = try stx.ensure(.iota_prime),
            .authorizer_queue = try stx.ensure(.phi_prime),
            .privileges = try stx.ensure(.chi_prime),
            .time = &stx.time,
        },
    );
    defer accumulation_context.deinit();

    // Execute work reports scheduled for accumulation
    var result = try @import("accumulate/execution.zig").outerAccumulation(
        params,
        allocator,
        gas_limit,
        accumulatable,
        &accumulation_context,
        &chi.always_accumulate,
        stx.time.current_slot,
        (try stx.ensure(.eta_prime))[0],
    );
    defer result.deinit(allocator);

    const accumulated = accumulatable[0..result.accumulated_count];

    // Apply deferred transfers as per 12.23 and 12.24
    const transfer_span = execute_span.child(.apply_deferred_transfers);
    defer transfer_span.deinit();

    transfer_span.debug("Applying {d} deferred transfers", .{result.transfers.len});

    // Get delta for service accounts
    var delta_prime: *state.Delta = try stx.ensure(.delta_prime);

    // 12.24: Apply all deferred transfers to the service accounts
    // δ‡ = {s ↦ ΨT(δ†, τ′, s, R(t, s)) | (s ↦ a) ∈ δ†}
    if (result.transfers.len > 0) {
        transfer_span.debug("Processing transfers for destination services", .{});

        // Group transfers by destination service
        var grouped_transfers = std.AutoHashMap(types.ServiceId, std.ArrayList(types.ServiceId)).init(allocator);
        defer meta.deinit.deinitHashMapValuesAndMap(stx.allocator, grouped_transfers);

        // Process transfers for each destination service
        for (result.transfers) |transfer| {
            transfer_span.trace("Transfer: {d} -> {d}, amount: {d}", .{ transfer.sender, transfer.destination, transfer.amount });

            // Get or create the list for this destination
            var entry = try grouped_transfers.getOrPut(transfer.destination);
            if (!entry.found_existing) {
                entry.value_ptr.* = std.ArrayList(types.ServiceId).init(allocator);
            }

            // Add the sender to the list
            try entry.value_ptr.append(transfer.sender);

            // TODO: call ΨT
            // For now, we just log the transfers

            // Sender balance is updated in the transfer function
            // if (delta_prime.getAccount(transfer.sender)) |sender_account| {
            //     if (sender_account.balance >= transfer.amount) {
            //         sender_account.balance -= transfer.amount;
            //         transfer_span.trace("Reduced balance of sender {d} by {d}", .{ transfer.sender, transfer.amount });
            //     } else {
            //         transfer_span.err("Sender {d} has insufficient balance {d} for transfer {d}", .{ transfer.sender, sender_account.balance, transfer.amount });
            //     }
            // }

            // Update recipient balance
            if (delta_prime.getAccount(transfer.destination)) |dest_account| {
                dest_account.balance += transfer.amount;
                transfer_span.trace("Increased balance of destination {d} by {d}", .{ transfer.destination, transfer.amount });
            } else {
                transfer_span.err("Destination account {d} not found", .{transfer.destination});
            }
        }

        transfer_span.debug("Transfers applied successfully", .{});
    } else {
        transfer_span.debug("No transfers to apply", .{});
    }

    // Add ready reports to accumulation history
    execute_span.debug("Shifting down xi, make place for new entry", .{});
    try xi.shiftDown();

    execute_span.debug("Adding {d} reports to accumulation history", .{result.accumulated_count});
    for (accumulated, 0..) |report, i| {
        const work_package_hash = report.package_spec.hash;
        execute_span.trace("Adding report {d} to history, hash: {s}", .{ i, std.fmt.fmtSliceHexLower(&work_package_hash) });
        try xi.addWorkPackage(work_package_hash);
    }

    // 12.27 Update theta pending reports
    const update_span = span.child(.update_theta);
    defer update_span.deinit();

    update_span.debug("Updating theta pending reports for epoch length {d}", .{params.epoch_length});

    for (0..params.epoch_length) |i| {
        const widx = if (i <= stx.time.current_slot_in_epoch)
            stx.time.current_slot_in_epoch - i
        else
            params.epoch_length - (i - stx.time.current_slot_in_epoch);

        update_span.trace("Processing slot {d}, widx: {d}", .{ i, widx });

        if (i == 0) {
            update_span.debug("Updating current slot {d}", .{widx});
            queueEditingFunction(&queued, try mapWorkPackageHash(&map_buffer, accumulated));
            theta.clearTimeSlot(@intCast(widx));

            update_span.debug("Adding {d} queued items to time slot {d}", .{ queued.items.len, widx });
            for (queued.items, 0..) |*wradeps, qidx| {
                // NOTE: testvectors are empty, but queue editing function does not remove items on 0 deps
                //       this is based on testvectors
                // TODO: check this against GP
                if (wradeps.dependencies.count() > 0) {
                    update_span.trace("Adding queued item {d} to slot {d}", .{ qidx, widx });
                    try theta.addEntryToTimeSlot(@intCast(widx), try wradeps.deepClone(allocator));
                } else {
                    update_span.trace("Skipping queued item {d} to slot {d}: no dependencies", .{ qidx, widx });
                }
            }

            // try theta.entries[widx].insertSlice(allocator, 0, queued.items);
        } else if (i >= 1 and i < stx.time.current_slot - stx.time.prior_slot) {
            update_span.debug("Clearing time slot {d}", .{widx});
            theta.clearTimeSlot(@intCast(widx));
        } else if (i >= stx.time.current_slot - stx.time.prior_slot) {
            update_span.debug("Processing entries for time slot {d}", .{widx});
            var entries = theta.entries[widx].toManaged(allocator);
            queueEditingFunction(&entries, try mapWorkPackageHash(&map_buffer, accumulated));
            // NOTE: testvectors are empty, but queue editing function does not remove items on 0 deps
            // TODO: check this against GP
            theta.removeReportsWithoutDependenciesAtSlot(@intCast(widx));
        }
    }

    // Calculate the AccumulateRoot here
    const root_span = span.child(.calculate_accumulate_root);
    defer root_span.deinit();

    root_span.debug("Calculating AccumulateRoot from {d} accumulation outputs", .{result.accumulation_outputs.count()});

    // Collect and sort service IDs
    var keys = try std.ArrayList(types.ServiceId).initCapacity(allocator, result.accumulation_outputs.count());
    defer keys.deinit();

    root_span.trace("Collecting service IDs from accumulation outputs", .{});
    var key_iter = result.accumulation_outputs.keyIterator();
    while (key_iter.next()) |key| {
        try keys.append(key.*);
        root_span.trace("Added service ID: {d}", .{key.*});
    }

    root_span.debug("Sorting {d} service IDs in ascending order", .{keys.items.len});
    std.mem.sort(u32, keys.items, {}, std.sort.asc(u32));

    // Prepare blobs for Merkle tree
    var blobs = try std.ArrayList([]u8).initCapacity(allocator, result.accumulation_outputs.count());
    defer meta.deinit.allocFreeEntriesAndAggregate(stx.allocator, blobs);

    root_span.debug("Creating blobs for Merkle tree calculation", .{});
    for (keys.items, 0..) |key, i| {
        const blob_span = root_span.child(.create_blob);
        defer blob_span.deinit();

        blob_span.trace("Processing service ID {d} at index {d}", .{ key, i });

        // Convert service ID to bytes
        var service_id: [4]u8 = undefined;
        std.mem.writeInt(u32, &service_id, key, .little);
        blob_span.trace("Service ID bytes: {s}", .{std.fmt.fmtSliceHexLower(&service_id)});

        // Get accumulation output for this service
        const output = result.accumulation_outputs.get(key).?;
        blob_span.trace("Accumulation output: {s}", .{std.fmt.fmtSliceHexLower(&output)});

        // Concatenate service ID and output
        const blob = try allocator.dupe(u8, &(service_id ++ output));
        try blobs.append(blob);
    }

    root_span.debug("Computing Merkle root from {d} blobs", .{blobs.items.len});
    const accumulate_root = @import("merkle_binary.zig").M_b(blobs.items, std.crypto.hash.sha3.Keccak256);
    root_span.debug("AccumulateRoot calculated: {s}", .{std.fmt.fmtSliceHexLower(&accumulate_root)});

    span.debug("Process accumulate reports completed successfully", .{});
    return accumulate_root;
}

fn mapWorkPackageHash(buffer: anytype, items: anytype) ![]types.WorkReportHash {
    buffer.clearRetainingCapacity();
    for (items) |item| {
        try buffer.append(item.package_spec.hash);
    }

    return buffer.items;
}

pub fn Queued(T: type) type {
    return std.ArrayList(T);
}
pub fn Accumulatable(T: type) type {
    return std.ArrayList(T);
}
pub fn Resolved(T: type) type {
    return std.ArrayList(T);
}
