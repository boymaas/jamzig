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

const BatchCalculation = struct {
    reports_to_process: usize,
    gas_to_use: types.Gas,
};

pub const AccumulationServiceStats = struct {
    gas_used: u64,
    accumulated_count: u32,
};

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

pub fn outerAccumulation(
    comptime IOExecutor: type,
    io_executor: *IOExecutor,
    comptime params: @import("../jam_params.zig").Params,
    allocator: std.mem.Allocator,
    context: *AccumulationContext(params),
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

    var pending_transfers = std.ArrayList(pvm_accumulate.TransferOperand).init(allocator);
    defer pending_transfers.deinit();

    while ((current_reports.len > 0 or pending_transfers.items.len > 0) and current_gas_limit > 0) {
        const batch = calculateBatchSize(current_reports, current_gas_limit);

        span.debug("Will process {d}/{d} reports using {d}/{d} gas", .{
            batch.reports_to_process, current_reports.len, batch.gas_to_use, current_gas_limit,
        });

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
            &invoked_services,
        );
        defer parallelized_result.deinit(allocator);

        try applyChiRResolution(params, allocator, context, &parallelized_result);

        var batch_gas_used: types.Gas = 0;

        var new_transfers = std.ArrayList(pvm_accumulate.TransferOperand).init(allocator);
        defer new_transfers.deinit();

        var ordered_it = try parallelized_result.iteratorByServiceId(allocator);
        defer allocator.free(ordered_it.service_ids_sorted);

        while (ordered_it.next()) |entry| {
            const service_id = entry.service_id;
            const result = entry.result;

            try result.collapsed_dimension.applyProvidedPreimages(context.time.current_slot);

            try new_transfers.appendSlice(result.generated_transfers);
            if (result.generated_transfers.len > 0) {
                span.debug("Service {d} generated {d} transfers for next batch", .{ service_id, result.generated_transfers.len });
            }

            if (result.accumulation_output) |output| {
                try accumulation_outputs.add(allocator, .{ .service_id = service_id, .output = output });
            }

            const current_gas = gas_used_per_service.get(service_id) orelse 0;
            try gas_used_per_service.put(service_id, current_gas + result.gas_used);

            batch_gas_used += result.gas_used;
        }

        try parallelized_result.applyContextChanges();

        span.debug("Applied state changes for all services", .{});

        var gas_refund: types.Gas = 0;
        for (pending_transfers.items) |transfer| {
            gas_refund += transfer.gas_limit;
        }

        total_accumulated_count += batch.reports_to_process;

        current_gas_limit = (current_gas_limit -| batch_gas_used) + gas_refund;

        span.debug("Batch finished. Accumulated: {d}, Gas Used: {d}, Gas Refund: {d}, Remaining: {d}", .{
            batch.reports_to_process, batch_gas_used, gas_refund, current_gas_limit,
        });

        pending_transfers.clearRetainingCapacity();
        try pending_transfers.appendSlice(new_transfers.items);
        first_batch = false;

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

        pub fn iterator(self: *@This()) std.AutoHashMap(types.ServiceId, AccumulationResult(params)).Iterator {
            return self.service_results.iterator();
        }

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

        /// Apply context changes following graypaper ordering:
        /// accounts' = (accounts ∪ modifications) \ deletions
        pub fn applyContextChanges(self: *@This()) !void {
            const span = trace.span(@src(), .apply_context_changes);
            defer span.deinit();

            // Phase 1: Apply all modifications
            {
                var it = self.service_results.iterator();
                while (it.next()) |entry| {
                    try entry.value_ptr.collapsed_dimension.context.service_accounts.applyModifications();
                }
            }

            // Phase 2: Apply all deletions
            {
                var it = self.service_results.iterator();
                while (it.next()) |entry| {
                    entry.value_ptr.collapsed_dimension.context.service_accounts.applyDeletions();
                }
            }

            // Phase 3: Commit non-service-account state (validator_keys, authorizer_queue)
            {
                var it = self.service_results.iterator();
                while (it.next()) |entry| {
                    try entry.value_ptr.collapsed_dimension.commit();
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

fn applyChiRResolution(
    comptime params: jam_params.Params,
    allocator: std.mem.Allocator,
    context: *AccumulationContext(params),
    parallelized_result: *ParallelizedAccumulationResult(params),
) !void {
    const span = trace.span(@src(), .apply_chi_r_resolution);
    defer span.deinit();

    const original_chi = try context.privileges.getMutable();

    var service_chi_map = std.AutoHashMap(types.ServiceId, *const state.Chi(params.core_count)).init(allocator);
    defer service_chi_map.deinit();

    var it = parallelized_result.service_results.iterator();
    while (it.next()) |entry| {
        const service_id = entry.key_ptr.*;
        const chi_ptr = entry.value_ptr.collapsed_dimension.context.privileges.getReadOnly();
        try service_chi_map.put(service_id, chi_ptr);
    }

    span.debug("Built service chi map with {d} entries", .{service_chi_map.count()});

    const any_privileged_accumulated = service_chi_map.contains(original_chi.manager) or
        service_chi_map.contains(original_chi.designate) or
        service_chi_map.contains(original_chi.registrar) or
        blk: {
            for (original_chi.assign) |assigner| {
                if (service_chi_map.contains(assigner)) break :blk true;
            }
            break :blk false;
        };

    if (!any_privileged_accumulated) {
        span.debug("No privileged services accumulated, skipping R() resolution", .{});
        return;
    }

    // Capture original privileged services BEFORE R() resolution
    var original_assigners: [params.core_count]types.ServiceId = undefined;
    for (0..params.core_count) |c| {
        original_assigners[c] = original_chi.assign[c];
    }
    const original_delegator = original_chi.designate;

    try ChiMerger(params).merge(original_chi, &service_chi_map);
    context.privileges.commit();

    span.debug("Chi R() resolution complete", .{});

    // Apply authorizer queue from original assigners per graypaper
    const original_authqueue = try context.authorizer_queue.getMutable();
    for (0..params.core_count) |c| {
        const original_assigner = original_assigners[c];
        if (parallelized_result.service_results.get(original_assigner)) |assigner_result| {
            const assigner_authqueue = assigner_result.collapsed_dimension.context.authorizer_queue.getReadOnly();
            // Copy all authorizations for this core from the original assigner's result
            for (0..params.max_authorizations_queue_items) |i| {
                const auth_hash = assigner_authqueue.getAuthorization(c, i);
                try original_authqueue.setAuthorization(c, i, auth_hash);
            }
            span.debug("Applied authqueue[{d}] from original assigner {d}", .{ c, original_assigner });
        }
    }
    context.authorizer_queue.commit();

    span.debug("Authorizer queue finalization complete", .{});

    // Apply validator keys from original delegator per graypaper
    if (parallelized_result.service_results.get(original_delegator)) |delegator_result| {
        const delegator_validator_keys = delegator_result.collapsed_dimension.context.validator_keys.getReadOnly();
        const original_validator_keys = try context.validator_keys.getMutable();

        // std.debug.assert(delegator_validator_keys.validators.len == params.validators_count);
        // std.debug.assert(original_validator_keys.validators.len == params.validators_count);

        for (delegator_validator_keys.validators, 0..) |key, i| {
            original_validator_keys.validators[i] = key;
        }
        span.debug("Applied validator_keys from original delegator {d}", .{original_delegator});
    }
    context.validator_keys.commit();

    span.debug("Validator keys finalization complete", .{});
}

pub fn parallelizedAccumulation(
    comptime IOExecutor: type,
    io_executor: *IOExecutor,
    comptime params: jam_params.Params,
    allocator: std.mem.Allocator,
    context: *const AccumulationContext(params),
    work_reports: []const types.WorkReport,
    pending_transfers: []const pvm_accumulate.TransferOperand,
    include_privileged: bool,
    invoked_services: *std.AutoArrayHashMap(types.ServiceId, void),
) !ParallelizedAccumulationResult(params) {
    const span = trace.span(@src(), .parallelized_accumulation);
    defer span.deinit();

    span.debug("Starting parallelized accumulation for {d} work reports, {d} pending transfers", .{
        work_reports.len, pending_transfers.len,
    });

    var service_ids = try collectServiceIds(allocator, context, work_reports, pending_transfers, include_privileged);
    defer service_ids.deinit();

    for (service_ids.keys()) |service_id| {
        try invoked_services.put(service_id, {});
    }

    span.debug("Found {d} unique services to accumulate", .{service_ids.count()});

    var service_operands = try groupWorkItemsByService(allocator, work_reports);
    defer service_operands.deinit();

    var service_results = std.AutoHashMap(types.ServiceId, AccumulationResult(params)).init(allocator);
    errdefer meta.deinit.deinitHashMapValuesAndMap(allocator, service_results);

    const PARALLEL_SERVICE_THRESHOLD = 2;

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

    if (service_ids.count() > 0) {
        if (!use_parallel) {
            const seq_span = span.child(@src(), .sequential_accumulation);
            defer seq_span.deinit();

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

            var task_group = io_executor.createGroup();

            const ResultSlot = struct {
                service_id: types.ServiceId,
                result: ?AccumulationResult(params) = null,
            };

            var results_array = try allocator.alloc(ResultSlot, service_ids.count());
            defer allocator.free(results_array);

            for (service_ids.keys(), 0..) |service_id, index| {
                results_array[index] = ResultSlot{ .service_id = service_id };
            }

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

            for (0..service_ids.count()) |index| {
                try task_group.spawn(TaskContext.processServiceAtIndex, .{ task_context, index });
            }

            task_group.wait();

            for (results_array) |slot| {
                if (slot.result) |result| {
                    try service_results.put(slot.service_id, result);
                }
            }
        }
    }

    return .{
        .service_results = service_results,
    };
}

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

    var mutable_context = context;

    const dest_account = mutable_context.service_accounts.getMutable(service_id) catch {
        return try pvm_accumulate.AccumulationResult(params).createEmpty(allocator, mutable_context, service_id);
    } orelse {
        return try pvm_accumulate.AccumulationResult(params).createEmpty(allocator, mutable_context, service_id);
    };

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

    if (total_transfer_amount > 0) {
        dest_account.balance += total_transfer_amount;
        span.trace("Credited {d} to service {d} balance", .{ total_transfer_amount, service_id });
    }

    span.debug("Starting accumulation for service {d} with {d} operands, {d} transfers", .{
        service_id, if (service_operands) |so| so.count() else 0, transfers_for_service_count,
    });

    const operands_gas = if (service_operands) |so| so.calcGasLimit() else 0;

    const gas_limit = mutable_context.privileges.getReadOnly().always_accumulate.get(service_id) orelse
        (operands_gas + transfers_gas);

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

    const delta_prime = try stx.ensure(.delta_prime);

    var accumulation_context = pvm_accumulate.AccumulationContext(params).build(
        allocator,
        .{
            .service_accounts = delta_prime,
            .validator_keys = try stx.ensure(.iota_prime),
            .authorizer_queue = try stx.ensure(.phi_prime),
            .privileges = try stx.ensure(.chi_prime),
            .time = &stx.time,
            .entropy = (try stx.ensure(.eta_prime))[0],
        },
    );
    defer accumulation_context.deinit();

    span.debug("Executing outer accumulation with {d} reports and gas limit {d}", .{ accumulatable.len, gas_limit });

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

    if (include_privileged) {
        var it = context.privileges.getReadOnly().always_accumulate.iterator();
        while (it.next()) |entry| {
            try service_ids.put(entry.key_ptr.*, {});
        }
    }

    for (work_reports) |report| {
        for (report.results) |result| {
            try service_ids.put(result.service_id, {});
        }
    }

    for (pending_transfers) |transfer| {
        if (context.service_accounts.getReadOnly(transfer.destination) != null) {
            try service_ids.put(transfer.destination, {});
        } else {
            span.debug("Filtered transfer to non-existent service {d}", .{transfer.destination});
        }
    }

    return service_ids;
}

fn groupWorkItemsByService(
    allocator: std.mem.Allocator,
    work_reports: []const types.WorkReport,
) !ServiceAccumulationOperandsMap {
    const span = trace.span(@src(), .group_work_items);
    defer span.deinit();

    var service_operands = ServiceAccumulationOperandsMap.init(allocator);
    errdefer service_operands.deinit();

    span.debug("Processing {d} work reports", .{work_reports.len});

    for (work_reports, 0..) |report, idx| {
        span.debug("Work report {d}: results.len={d}, core_index={d}", .{ idx, report.results.len, report.core_index.value });

        var operands = try AccumulationOperand.fromWorkReport(allocator, report);
        defer operands.deinit(allocator);

        span.debug("Work report {d}: created {d} operands", .{ idx, operands.items.len });

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
