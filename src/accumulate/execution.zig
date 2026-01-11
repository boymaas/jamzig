const std = @import("std");

const pvm_accumulate = @import("../pvm_invocations/accumulate.zig");
const types = @import("../types.zig");
const state = @import("../state.zig");
const state_delta = @import("../state_delta.zig");
const jam_params = @import("../jam_params.zig");
const meta = @import("../meta.zig");
const services = @import("../services.zig");

const HashSet = @import("../datastruct/hash_set.zig").HashSet;
const DeltaSnapshot = @import("../services_snapshot.zig").DeltaSnapshot;
const Delta = services.Delta;

const trace = @import("tracing").scoped(.accumulate);

const AccumulationContext = pvm_accumulate.AccumulationContext;
const AccumulationOperand = pvm_accumulate.AccumulationOperand;
const AccumulationResult = pvm_accumulate.AccumulationResult;
const DeferredTransfer = pvm_accumulate.DeferredTransfer;

const ChiMerger = @import("chi_merger.zig").ChiMerger;

pub const ServiceAccumulationOutput = struct {
    service_id: types.ServiceId,
    output: types.AccumulateRoot,
};

const ServiceAccumulationOperandsMap = @import("service_operands_map.zig").ServiceAccumulationOperandsMap;

/// Result of calculating how many reports can fit within gas limit
const BatchCalculation = struct {
    reports_to_process: usize,
    gas_to_use: types.Gas,
};

/// Statistics for a single service's accumulation within a block (Part of 'I' stats).
pub const AccumulationServiceStats = struct {
    gas_used: u64,
    accumulated_count: u32,
};

/// Result of the outer accumulation function
pub const OuterAccumulationResult = struct {
    accumulated_count: usize,
    accumulation_outputs: HashSet(ServiceAccumulationOutput),
    gas_used_per_service: std.AutoHashMap(types.ServiceId, types.Gas),
    invoked_services: std.AutoArrayHashMap(types.ServiceId, void),

    pub fn takeInvokedServices(self: *@This()) std.AutoArrayHashMap(types.ServiceId, void) {
        const result = self.invoked_services;
        self.invoked_services = std.AutoArrayHashMap(types.ServiceId, void).init(self.invoked_services.allocator);
        return result;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.accumulation_outputs.deinit(allocator);
        self.gas_used_per_service.deinit();
        self.invoked_services.deinit();
        self.* = undefined;
    }
};

/// Aggregated result after processing reports, including the AccumulateRoot and statistics.
pub const ProcessAccumulationResult = struct {
    accumulate_root: types.AccumulateRoot,
    accumulation_stats: std.AutoHashMap(types.ServiceId, AccumulationServiceStats),
    invoked_services: std.AutoArrayHashMap(types.ServiceId, void),

    pub fn deinit(self: *@This(), _: std.mem.Allocator) void {
        self.accumulation_stats.deinit();
        self.invoked_services.deinit();
        self.* = undefined;
    }
};

/// 12.16 Outer accumulation function Δ+
/// Transforms a gas limit, sequence of work reports, initial partial state,
/// and a dictionary of services with free accumulation into a tuple containing:
/// - Number of work results accumulated
/// - Posterior state context
/// - Resultant deferred transfers
/// - Accumulation output pairings
pub fn outerAccumulation(
    comptime IOExecutor: type,
    io_executor: *IOExecutor,
    comptime params: @import("../jam_params.zig").Params,
    allocator: std.mem.Allocator,
    context: *const AccumulationContext(params),
    work_reports: []const types.WorkReport,
    gas_limit: types.Gas,
) !OuterAccumulationResult {
    const span = trace.span(@src(), .outer_accumulation);
    defer span.deinit();

    span.debug("Starting outer accumulation with gas limit: {d}", .{gas_limit});

    span.trace("Processing following work_reports: {}", .{types.fmt.format(work_reports)});

    var accumulation_outputs = HashSet(ServiceAccumulationOutput).init();
    errdefer accumulation_outputs.deinit(allocator);

    var gas_used_per_service = std.AutoHashMap(types.ServiceId, types.Gas).init(allocator);
    errdefer gas_used_per_service.deinit();

    // v0.7.2: Track invoked services (maintains insertion order for consistency)
    var invoked_services = std.AutoArrayHashMap(types.ServiceId, void).init(allocator);
    errdefer invoked_services.deinit();

    if (work_reports.len == 0) {
        span.debug("No work reports to process", .{});
        return .{
            .accumulated_count = 0,
            .accumulation_outputs = accumulation_outputs,
            .gas_used_per_service = gas_used_per_service,
            .invoked_services = invoked_services,
        };
    }

    var current_gas_limit = gas_limit;
    var current_reports = work_reports;
    var total_accumulated_count: usize = 0;
    var first_batch = true;

    // NEW (v0.7.1): Track pending transfers for inline processing
    // Transfers generated in one batch become inputs to the next batch
    var pending_transfers = std.ArrayList(pvm_accumulate.TransferOperand).init(allocator);
    defer pending_transfers.deinit();

    // Process reports in batches until we've processed all reports AND transfers, or run out of gas
    // Per graypaper §12.16: n = len(t) + i + len(f) - continue while n > 0
    // Transfer destinations must be processed to credit their balances (v0.7.1 inline transfers)
    while ((current_reports.len > 0 or pending_transfers.items.len > 0) and current_gas_limit > 0) {
        // Calculate how many reports fit within gas limit
        const batch = calculateBatchSize(current_reports, current_gas_limit);

        span.debug("Will process {d}/{d} reports using {d}/{d} gas", .{
            batch.reports_to_process, current_reports.len, batch.gas_to_use, current_gas_limit,
        });

        // If no reports can be processed AND no pending transfers, break the loop
        // Per graypaper §12.17: services to accumulate include transfer destinations
        if (batch.reports_to_process == 0 and pending_transfers.items.len == 0) {
            span.debug("No more reports or transfers to process", .{});
            break;
        }

        var parallelized_result = try parallelizedAccumulation(
            IOExecutor,
            io_executor,
            params,
            allocator,
            context,
            current_reports[0..batch.reports_to_process],
            pending_transfers.items,
            first_batch,
            &invoked_services, // v0.7.2
        );
        defer parallelized_result.deinit(allocator);

        // Apply R() function for chi fields per graypaper §12.17
        // This merges manager's and privileged services' chi changes
        try applyChiRResolution(params, allocator, &parallelized_result, context);

        // Process all service results in a single loop:
        // - Apply provided preimages
        // - Collect generated transfers for next batch
        // - Aggregate gas usage
        // - Collect accumulation outputs
        var batch_gas_used: types.Gas = 0;

        var new_transfers = std.ArrayList(pvm_accumulate.TransferOperand).init(allocator);
        defer new_transfers.deinit();

        // Iterate in ascending service ID order per graypaper Eq. 207 "orderedin"
        var ordered_it = try parallelized_result.iteratorByServiceId(allocator);
        defer allocator.free(ordered_it.service_ids_sorted);

        while (ordered_it.next()) |entry| {
            const service_id = entry.service_id;
            const result = entry.result;

            try result.collapsed_dimension.applyProvidedPreimages(context.time.current_slot);

            // Collect generated transfers for next batch (v0.7.1 inline processing)
            try new_transfers.appendSlice(result.generated_transfers);
            if (result.generated_transfers.len > 0) {
                span.debug("Service {d} generated {d} transfers for next batch", .{
                    service_id, result.generated_transfers.len,
                });
            }

            // Add accumulation output to our output set if present
            if (result.accumulation_output) |output| {
                try accumulation_outputs.add(allocator, .{ .service_id = service_id, .output = output });
            }

            // Aggregate gas used for this service
            const current_gas = gas_used_per_service.get(service_id) orelse 0;
            try gas_used_per_service.put(service_id, current_gas + result.gas_used);

            // Track total gas for this batch
            batch_gas_used += result.gas_used;
        }

        // Apply context changes from all service dimensions (after preimages are applied)
        // This commits the dimension state to the context's Delta
        // Uses two-phase commit: deletions collected first, then applied globally to prevent
        // ejected services from being restored by their own concurrent modifications.
        try parallelized_result.applyContextChanges(allocator);

        span.debug("Applied state changes for all services", .{});

        // v0.7.1: Calculate gas refund from processed transfers
        // Refunded gas becomes available for subsequent batches, enabling further
        // accumulation within the same block (per graypaper §12.16: g* = g + sum(t.gas))
        var gas_refund: types.Gas = 0;
        for (pending_transfers.items) |transfer| {
            gas_refund += transfer.gas_limit;
        }

        // Update loop variables for next iteration
        total_accumulated_count += batch.reports_to_process;

        // v0.7.1: gas' = gas - used + sum(transfer.gas_limit)
        current_gas_limit = (current_gas_limit -| batch_gas_used) + gas_refund;

        span.debug("Batch finished. Accumulated: {d}, Gas Used: {d}, Gas Refund: {d}, Remaining: {d}", .{
            batch.reports_to_process, batch_gas_used, gas_refund, current_gas_limit,
        });

        // Replace pending transfers with new ones for next batch
        pending_transfers.clearRetainingCapacity();
        try pending_transfers.appendSlice(new_transfers.items);
        // We only execute our privileged_services once
        first_batch = false;

        // If all reports processed AND no pending transfers for next batch, break
        // Per graypaper §12.16: continue while n = len(t) + i + len(f) > 0
        if (current_reports.len == batch.reports_to_process and pending_transfers.items.len == 0) {
            span.debug("Processed all work reports and transfers", .{});
            break;
        }

        current_reports = current_reports[batch.reports_to_process..];

        span.debug("Continuing with remaining {d} reports and {d} gas", .{
            current_reports.len, current_gas_limit,
        });
    }

    return .{
        .accumulated_count = total_accumulated_count,
        .accumulation_outputs = accumulation_outputs,
        .gas_used_per_service = gas_used_per_service,
        .invoked_services = invoked_services,
    };
}

pub fn ParallelizedAccumulationResult(params: jam_params.Params) type {
    return struct {
        service_results: std.AutoHashMap(types.ServiceId, AccumulationResult(params)),

        /// Returns standard HashMap iterator for direct access
        pub fn iterator(self: *@This()) std.AutoHashMap(types.ServiceId, AccumulationResult(params)).Iterator {
            return self.service_results.iterator();
        }

        /// Iterator that yields (service_id, result) pairs in ascending service ID order
        /// Implements graypaper Eq. 207 "orderedin" specification: results ordered by service ID
        pub const ServiceIdOrderedIterator = struct {
            service_ids_sorted: []types.ServiceId,
            results: *std.AutoHashMap(types.ServiceId, AccumulationResult(params)),
            index: usize,

            pub fn next(self: *@This()) ?struct { service_id: types.ServiceId, result: *AccumulationResult(params) } {
                if (self.index >= self.service_ids_sorted.len) return null;

                const service_id = self.service_ids_sorted[self.index];
                self.index += 1;

                const result = self.results.getPtr(service_id) orelse return self.next();
                return .{ .service_id = service_id, .result = result };
            }
        };

        /// Returns an iterator that yields results in ascending service ID order (graypaper Eq. 207)
        /// Caller must free the returned iterator's service_ids_sorted slice
        pub fn iteratorByServiceId(self: *@This(), allocator: std.mem.Allocator) !ServiceIdOrderedIterator {
            var service_id_list = std.ArrayList(types.ServiceId).init(allocator);
            errdefer service_id_list.deinit();

            var it = self.service_results.iterator();
            while (it.next()) |entry| {
                try service_id_list.append(entry.key_ptr.*);
            }

            const service_ids_sorted = try service_id_list.toOwnedSlice();
            std.mem.sort(types.ServiceId, service_ids_sorted, {}, comptime std.sort.asc(types.ServiceId));

            return ServiceIdOrderedIterator{
                .service_ids_sorted = service_ids_sorted,
                .results = &self.service_results,
                .index = 0,
            };
        }

        /// Apply context changes from all service dimensions.
        /// Per graypaper Eq. 12.17: δ' = (δ ∪ n) \ m
        /// First apply all modifications (∪ n), then enforce deletions (\ m).
        /// See: https://github.com/davxy/jam-conformance/discussions/148
        pub fn applyContextChanges(self: *@This(), allocator: std.mem.Allocator) !void {
            const span = trace.span(@src(), .apply_context_changes);
            defer span.deinit();

            // Phase 1: Collect ALL deleted service IDs from ALL snapshots
            var global_deletions = std.AutoHashMap(types.ServiceId, void).init(allocator);
            defer global_deletions.deinit();

            var first_snapshot: ?*const DeltaSnapshot = null;
            {
                var it = self.service_results.iterator();
                while (it.next()) |entry| {
                    const snapshot = &entry.value_ptr.collapsed_dimension.context.service_accounts;
                    if (first_snapshot == null) first_snapshot = snapshot;
                    var deleted_it = snapshot.deleted_services.keyIterator();
                    while (deleted_it.next()) |id| {
                        try global_deletions.put(id.*, {});
                    }
                }
            }

            if (global_deletions.count() > 0) {
                span.debug("Collected {d} global deletions across all services", .{global_deletions.count()});
            }

            // Phase 2: Normal commits (apply all modifications)
            var it = self.service_results.iterator();
            while (it.next()) |entry| {
                try entry.value_ptr.collapsed_dimension.commit();
            }

            // Phase 3: Enforce deletions - remove all globally deleted services
            if (global_deletions.count() > 0) {
                if (first_snapshot) |snapshot| {
                    const destination: *Delta = @constCast(snapshot.original);
                    var deletion_it = global_deletions.keyIterator();
                    while (deletion_it.next()) |deleted_id| {
                        if (destination.accounts.fetchRemove(deleted_id.*)) |removed| {
                            span.debug("Final cleanup: removed globally deleted service {d}", .{deleted_id.*});
                            @constCast(&removed.value).deinit();
                        }
                    }
                }
            }
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            var it = self.service_results.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(allocator);
            }
            self.service_results.deinit();
            self.* = undefined;
        }
    };
}

/// Apply R() function for chi field updates per graypaper §12.17
///
/// R(o, a, b) = b when a = o (manager unchanged), a otherwise (manager wins)
///
/// This function:
/// 1. Gets manager's chi from the batch results (if manager accumulated)
/// 2. Gets each privileged service's chi from results (if they accumulated)
/// 3. Applies R() to select final values for assigners, delegator, registrar
/// 4. Commits the merged chi to state
fn applyChiRResolution(
    comptime params: jam_params.Params,
    allocator: std.mem.Allocator,
    parallelized_result: *ParallelizedAccumulationResult(params),
    context: *const AccumulationContext(params),
) !void {
    const span = trace.span(@src(), .apply_chi_r_resolution);
    defer span.deinit();

    // Create chi merger with original values
    const merger = ChiMerger(params).init(
        context.original_manager,
        context.original_assigners,
        context.original_delegator,
        context.original_registrar,
    );

    // Build map of service_id -> chi pointer from batch results
    var service_chi_map = std.AutoHashMap(types.ServiceId, *const state.Chi(params.core_count)).init(allocator);
    defer service_chi_map.deinit();

    var it = parallelized_result.service_results.iterator();
    while (it.next()) |entry| {
        const service_id = entry.key_ptr.*;
        const chi_ptr = entry.value_ptr.collapsed_dimension.context.privileges.getReadOnly();
        try service_chi_map.put(service_id, chi_ptr);
    }

    span.debug("Built service chi map with {d} entries", .{service_chi_map.count()});

    // Get manager's result (if manager accumulated in this batch)
    const manager_result = parallelized_result.service_results.getPtr(context.original_manager) orelse {
        span.debug("Manager {d} did not accumulate in this batch, skipping R() resolution", .{context.original_manager});
        return;
    };

    // Get manager's chi from the map
    const manager_chi = service_chi_map.get(context.original_manager);

    // Get mutable chi through manager's dimension context (not const)
    const output_chi = try manager_result.collapsed_dimension.context.privileges.getMutable();

    // Apply R() merge
    try merger.merge(manager_chi, &service_chi_map, output_chi);

    // Commit the merged chi through manager's dimension context
    manager_result.collapsed_dimension.context.privileges.commit();

    span.debug("Chi R() resolution complete", .{});
}

/// 12.17 Parallelized accumulation function Δ*
/// Transforms an initial state context and sequence of work reports
/// into a tuple containing:
/// - Total gas utilized in PVM execution
/// - Posterior state context
/// - Resultant deferred transfers
/// - Accumulation output pairings
pub fn parallelizedAccumulation(
    comptime IOExecutor: type,
    io_executor: *IOExecutor,
    comptime params: jam_params.Params,
    allocator: std.mem.Allocator,
    context: *const AccumulationContext(params),
    work_reports: []const types.WorkReport,
    pending_transfers: []const pvm_accumulate.TransferOperand,
    include_privileged: bool, // Whether to include privileged services (first batch only)
    invoked_services: *std.AutoArrayHashMap(types.ServiceId, void), // v0.7.2: Track invoked services
) !ParallelizedAccumulationResult(params) {
    const span = trace.span(@src(), .parallelized_accumulation);
    defer span.deinit();

    // Assertions - function parameters are guaranteed to be valid

    span.debug("Starting parallelized accumulation for {d} work reports, {d} pending transfers", .{
        work_reports.len, pending_transfers.len,
    });

    // Collect all unique service IDs (work, privileged, and transfer destinations)
    var service_ids = try collectServiceIds(allocator, context, work_reports, pending_transfers, include_privileged);
    defer service_ids.deinit();

    // v0.7.2: Add all collected services to invoked_services for last_accumulation_slot tracking
    for (service_ids.keys()) |service_id| {
        try invoked_services.put(service_id, {});
    }

    span.debug("Found {d} unique services to accumulate", .{service_ids.count()});

    // Group work items by service
    var service_operands = try groupWorkItemsByService(allocator, work_reports);
    defer service_operands.deinit();

    // Store results for each service
    var service_results = std.AutoHashMap(types.ServiceId, AccumulationResult(params)).init(allocator);
    errdefer meta.deinit.deinitHashMapValuesAndMap(allocator, service_results);

    // Parallelization threshold: 2+ services justifies thread coordination overhead
    const PARALLEL_SERVICE_THRESHOLD = 2;

    // Calculate total work complexity
    var total_gas_complexity: u64 = 0;
    var service_it = service_ids.iterator();
    while (service_it.next()) |entry| {
        const service_id = entry.key_ptr.*;
        if (service_operands.getOperands(service_id)) |operands| {
            total_gas_complexity += operands.calcGasLimit();
        }
    }

    const use_parallel = service_ids.count() >= PARALLEL_SERVICE_THRESHOLD;

    span.debug("Parallelization decision: services={d}, gas_complexity={d}, use_parallel={}", .{ service_ids.count(), total_gas_complexity, use_parallel });

    // Process services using either sequential or parallel execution
    if (service_ids.count() == 0) {
        // No services to process
    } else if (!use_parallel) {
        const seq_span = span.child(@src(), .sequential_accumulation);
        defer seq_span.deinit();

        // Use optimized sequential processing - avoids thread coordination overhead
        for (service_ids.keys()) |service_id| {
            const maybe_operands = service_operands.getOperands(service_id);
            const context_snapshot = try context.deepClone();

            const result = try singleServiceAccumulation(
                params,
                allocator,
                context_snapshot,
                service_id,
                maybe_operands,
                pending_transfers,
            );
            try service_results.put(service_id, result);
        }
    } else {
        const par_span = span.child(@src(), .parallel_accumulation);
        defer par_span.deinit();

        // Use parallel processing for high-complexity workloads - lock-free implementation
        var task_group = io_executor.createGroup();

        // Pre-allocate results array (lock-free, no hashmap needed)
        const ResultSlot = struct {
            service_id: types.ServiceId,
            result: ?AccumulationResult(params) = null,
        };

        var results_array = try allocator.alloc(ResultSlot, service_ids.count());
        defer allocator.free(results_array);

        // Initialize result slots with service IDs
        for (service_ids.keys(), 0..) |service_id, index| {
            results_array[index] = ResultSlot{ .service_id = service_id };
        }

        // Task context - no hashmap, direct array access
        const TaskContext = struct {
            allocator: std.mem.Allocator,
            context: *const AccumulationContext(params),
            service_operands: *ServiceAccumulationOperandsMap,
            pending_transfers: []const pvm_accumulate.TransferOperand,
            results_array: []ResultSlot,

            fn processServiceAtIndex(self: @This(), index: usize) !void {
                const service_id = self.results_array[index].service_id;
                const maybe_operands = self.service_operands.getOperands(service_id);

                var context_snapshot = try self.context.deepClone();
                defer context_snapshot.deinit();

                const result = try singleServiceAccumulation(
                    params,
                    self.allocator,
                    context_snapshot,
                    service_id,
                    maybe_operands,
                    self.pending_transfers,
                );

                // Direct array access - no mutex, no hashmap
                self.results_array[index].result = result;
            }
        };

        const task_context = TaskContext{
            .allocator = allocator,
            .context = context,
            .service_operands = &service_operands,
            .pending_transfers = pending_transfers,
            .results_array = results_array,
        };

        // Spawn tasks with direct array indices
        for (0..service_ids.count()) |index| {
            try task_group.spawn(TaskContext.processServiceAtIndex, .{ task_context, index });
        }

        // Wait for all parallel tasks to complete
        task_group.wait();

        // Collect results into final map (only at the end)
        for (results_array) |slot| {
            if (slot.result) |result| {
                try service_results.put(slot.service_id, result);
            }
        }
    }

    // Return collected results
    return .{
        .service_results = service_results,
    };
}

/// 12.19 Single service accumulation function Δ1
/// Transforms an initial state context, work operands, and service ID
/// into an updated state context, sequence of transfers,
/// possible accumulation output, and gas used
pub fn singleServiceAccumulation(
    comptime params: jam_params.Params,
    allocator: std.mem.Allocator,
    context: AccumulationContext(params),
    service_id: types.ServiceId,
    service_operands: ?ServiceAccumulationOperandsMap.Operands,
    incoming_transfers: []const pvm_accumulate.TransferOperand,
) !AccumulationResult(params) {
    const span = trace.span(@src(), .single_service_accumulation);
    defer span.deinit();

    // Make context mutable for balance crediting
    var mutable_context = context;

    // Get service account upfront - exit early if service doesn't exist (may have been ejected)
    const dest_account = mutable_context.service_accounts.getMutable(service_id) catch {
        return try pvm_accumulate.AccumulationResult(params).createEmpty(allocator, mutable_context, service_id);
    } orelse {
        return try pvm_accumulate.AccumulationResult(params).createEmpty(allocator, mutable_context, service_id);
    };

    // Count transfers and sum gas/amount for this service
    var transfers_for_service_count: usize = 0;
    var transfers_gas: types.Gas = 0;
    var total_transfer_amount: u64 = 0;

    for (incoming_transfers) |transfer| {
        if (transfer.destination == service_id) {
            transfers_for_service_count += 1;
            transfers_gas += transfer.gas_limit;
            total_transfer_amount += transfer.amount;
        }
    }

    // Credit all transfers at once (per graypaper: balance credited before PVM invocation)
    if (total_transfer_amount > 0) {
        dest_account.balance += total_transfer_amount;
        span.trace("Credited {d} to service {d} balance", .{ total_transfer_amount, service_id });
    }

    span.debug("Starting accumulation for service {d} with {d} operands, {d} transfers", .{
        service_id, if (service_operands) |so| so.count() else 0, transfers_for_service_count,
    });

    // Calculate gas limit: from operands OR from transfers
    const operands_gas = if (service_operands) |so| so.calcGasLimit() else 0;

    // Either privileged service OR has operands OR has incoming transfers
    const gas_limit = mutable_context.privileges.getReadOnly().always_accumulate.get(service_id) orelse
        (operands_gas + transfers_gas);

    // Exit early if gas_limit is 0 (no PVM execution needed)
    // Balance crediting already happened above before this check
    if (gas_limit == 0) {
        return try pvm_accumulate.AccumulationResult(params).createEmpty(allocator, mutable_context, service_id);
    }

    return try pvm_accumulate.invoke(
        params,
        allocator,
        mutable_context,
        service_id,
        gas_limit,
        if (service_operands) |so| so.accumulationOperandSlice() else &[_]AccumulationOperand{},
        incoming_transfers,
    );
}

/// Main execution entry point for accumulation
/// This coordinates the execution of work reports through the PVM
pub fn executeAccumulation(
    comptime IOExecutor: type,
    io_executor: *IOExecutor,
    comptime params: jam_params.Params,
    allocator: std.mem.Allocator,
    stx: *state_delta.StateTransition(params),
    accumulatable: []const types.WorkReport,
    gas_limit: u64,
) !OuterAccumulationResult {
    const span = trace.span(@src(), .execute_accumulation);
    defer span.deinit();

    // Capture original chi values from input state BEFORE any accumulation
    // Per graypaper §12.17: chi fields use R() function to select between
    // manager's and privileged services' changes. See chi_merger.zig.
    const original_chi = try stx.ensure(.chi);
    span.debug("Original chi - manager={d}, delegator={d}, registrar={d}", .{
        original_chi.manager,
        original_chi.designate,
        original_chi.registrar,
    });

    // Build accumulation context
    var accumulation_context = pvm_accumulate.AccumulationContext(params).build(
        allocator,
        .{
            .service_accounts = try stx.ensure(.delta_prime),
            .validator_keys = try stx.ensure(.iota_prime),
            .authorizer_queue = try stx.ensure(.phi_prime),
            .privileges = try stx.ensure(.chi_prime),
            .time = &stx.time,
            .entropy = (try stx.ensure(.eta_prime))[0],
            .original_manager = original_chi.manager,
            .original_assigners = original_chi.assign,
            .original_delegator = original_chi.designate,
            .original_registrar = original_chi.registrar,
        },
    );
    defer accumulation_context.deinit();

    span.debug("Executing outer accumulation with {d} reports and gas limit {d}", .{ accumulatable.len, gas_limit });

    // Execute work reports scheduled for accumulation
    return try outerAccumulation(
        IOExecutor,
        io_executor,
        params,
        allocator,
        &accumulation_context,
        accumulatable,
        gas_limit,
    );
}

/// Calculate how many reports can be processed within gas limit
fn calculateBatchSize(
    reports: []const types.WorkReport,
    gas_limit: types.Gas,
) BatchCalculation {
    var reports_to_process: usize = 0;
    var cumulative_gas: types.Gas = 0;

    for (reports, 0..) |report, i| {
        const report_gas = report.totalAccumulateGas();

        if (cumulative_gas + report_gas <= gas_limit) {
            cumulative_gas += report_gas;
            reports_to_process = i + 1;
        } else {
            break;
        }
    }

    return .{
        .reports_to_process = reports_to_process,
        .gas_to_use = cumulative_gas,
    };
}

/// Collect all unique service IDs from privileged services and work reports
fn collectServiceIds(
    allocator: std.mem.Allocator,
    context: anytype, // *const AccumulationContext(params)
    work_reports: []const types.WorkReport,
    pending_transfers: []const pvm_accumulate.TransferOperand,
    include_privileged: bool,
) !std.AutoArrayHashMap(types.ServiceId, void) {
    const span = trace.span(@src(), .collect_service_ids);
    defer span.deinit();

    var service_ids = std.AutoArrayHashMap(types.ServiceId, void).init(allocator);
    errdefer service_ids.deinit();

    // First the always accumulates (only in first batch)
    if (include_privileged) {
        var it = context.privileges.getReadOnly().always_accumulate.iterator();
        while (it.next()) |entry| {
            try service_ids.put(entry.key_ptr.*, {});
        }
    }

    // Then the work reports
    for (work_reports) |report| {
        for (report.results) |result| {
            try service_ids.put(result.service_id, {});
        }
    }

    // v0.7.1: Transfer destination services (only if they exist)
    // Per graypaper: ejected services are not accumulated
    for (pending_transfers) |transfer| {
        if (context.service_accounts.getReadOnly(transfer.destination) != null) {
            try service_ids.put(transfer.destination, {});
        } else {
            span.debug("Filtered transfer to non-existent service {d}", .{transfer.destination});
        }
    }

    return service_ids;
}

/// Group work items by service ID
fn groupWorkItemsByService(
    allocator: std.mem.Allocator,
    work_reports: []const types.WorkReport,
) !ServiceAccumulationOperandsMap {
    const span = trace.span(@src(), .group_work_items);
    defer span.deinit();

    var service_operands = ServiceAccumulationOperandsMap.init(allocator);
    errdefer service_operands.deinit();

    span.debug("Processing {d} work reports", .{work_reports.len});

    // Process all work reports, and build operands in order of appearance
    for (work_reports, 0..) |report, idx| {
        span.debug("Work report {d}: results.len={d}, core_index={d}", .{ idx, report.results.len, report.core_index.value });

        // Convert work report to accumulation operands
        var operands = try AccumulationOperand.fromWorkReport(allocator, report);
        defer operands.deinit(allocator);

        span.debug("Work report {d}: created {d} operands", .{ idx, operands.items.len });

        // Group by service ID, and store the accumulate_gas per item
        for (report.results, operands.items, 0..) |result, *operand, result_idx| {
            const service_id = result.service_id;
            const accumulate_gas = result.accumulate_gas;
            span.debug("  Operand for service {d}: core={d}, result_idx={d}, payload_hash={s}", .{
                service_id,
                report.core_index.value,
                result_idx,
                std.fmt.fmtSliceHexLower(&result.payload_hash),
            });
            try service_operands.addOperand(service_id, .{
                .operand = try operand.take(),
                .accumulate_gas = accumulate_gas,
            });
        }
    }

    return service_operands;
}
