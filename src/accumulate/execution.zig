const std = @import("std");

const pvm_accumulate = @import("../pvm_invocations/accumulate.zig");
const types = @import("../types.zig");
const state = @import("../state.zig");
const state_delta = @import("../state_delta.zig");
const jam_params = @import("../jam_params.zig");
const meta = @import("../meta.zig");

const trace = @import("../tracing.zig").scoped(.accumulate);

const AccumulationContext = pvm_accumulate.AccumulationContext;
const AccumulationOperand = pvm_accumulate.AccumulationOperand;
const AccumulationResult = pvm_accumulate.AccumulationResult;
const DeferredTransfer = pvm_accumulate.DeferredTransfer;

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

/// Statistics for transfers targeting a single service within a block (Part of 'X' stats).
pub const TransferServiceStats = struct {
    transfer_count: u32 = 0,
    gas_used: u64 = 0,
};

/// Helper struct to hold service accumulation results
pub const ServiceAccumulationResult = struct {
    gas_used: types.Gas,
    transfers: []DeferredTransfer,
    accumulation_output: ?types.AccumulateRoot,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.transfers);
        self.* = undefined;
    }
};

/// Result of the outer accumulation function
pub const OuterAccumulationResult = struct {
    accumulated_count: usize,
    transfers: []DeferredTransfer,
    accumulation_outputs: std.AutoHashMap(types.ServiceId, types.AccumulateOutput),
    service_gas_used: std.AutoHashMap(types.ServiceId, types.Gas), // Gas used per service ID

    pub fn takeTransfers(self: *@This()) []DeferredTransfer {
        const result = self.transfers;
        self.transfers = &[_]DeferredTransfer{};
        return result;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.transfers);
        self.accumulation_outputs.deinit();
        self.service_gas_used.deinit(); // Deinit the new map
        self.* = undefined;
    }
};

/// Aggregated result after processing reports, including the AccumulateRoot and statistics.
pub const ProcessAccumulationResult = struct {
    accumulate_root: types.AccumulateRoot,
    accumulation_stats: std.AutoHashMap(types.ServiceId, AccumulationServiceStats),
    transfer_stats: std.AutoHashMap(types.ServiceId, TransferServiceStats),

    pub fn deinit(self: *@This(), _: std.mem.Allocator) void {
        // Deinit maps
        self.accumulation_stats.deinit();
        self.transfer_stats.deinit();
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
    comptime params: @import("../jam_params.zig").Params,
    allocator: std.mem.Allocator,
    context: *const AccumulationContext(params),
    work_reports: []const types.WorkReport,
    gas_limit: types.Gas,
) !OuterAccumulationResult {
    const span = trace.span(.outer_accumulation);
    defer span.deinit();

    span.debug("Starting outer accumulation with gas limit: {d}", .{gas_limit});

    span.trace("Processing following work_reports: {}", .{types.fmt.format(work_reports)});

    // Initialize output containers
    var transfers = std.ArrayList(DeferredTransfer).init(allocator);
    defer transfers.deinit();

    var accumulation_outputs = std.AutoHashMap(types.ServiceId, types.AccumulateRoot).init(allocator);
    errdefer accumulation_outputs.deinit();

    // Map to store gas used per service ID across all batches
    var total_service_gas_used = std.AutoHashMap(types.ServiceId, types.Gas).init(allocator);
    errdefer total_service_gas_used.deinit();

    // If no work reports, return early
    if (work_reports.len == 0) {
        span.debug("No work reports to process", .{});
        return .{
            .accumulated_count = 0,
            .transfers = &[_]DeferredTransfer{},
            .accumulation_outputs = accumulation_outputs,
            .service_gas_used = total_service_gas_used,
        };
    }

    // Initialize loop variables
    var current_gas_limit = gas_limit;
    var current_reports = work_reports;
    var total_accumulated_count: usize = 0;
    var first_batch = true;

    // Process reports in batches until we've processed all or run out of gas
    while (current_reports.len > 0 and current_gas_limit > 0) {
        // Calculate how many reports fit within gas limit
        const batch = calculateBatchSize(current_reports, current_gas_limit);

        span.debug("Will process {d}/{d} reports using {d}/{d} gas", .{
            batch.reports_to_process, current_reports.len, batch.gas_to_use, current_gas_limit,
        });

        // If no reports can be processed within the gas limit, break the loop
        if (batch.reports_to_process == 0) {
            span.debug("No more reports can be processed within gas limit", .{});
            break;
        }

        // Process reports in parallel
        var parallelized_result = try parallelizedAccumulation(
            params,
            allocator,
            context,
            current_reports[0..batch.reports_to_process],
            first_batch,
        );
        defer parallelized_result.deinit(allocator);

        // Aggregate batch results
        try aggregateBatchResults(
            &transfers,
            &accumulation_outputs,
            &total_service_gas_used,
            &parallelized_result,
            span,
        );

        // Update loop variables for next iteration
        total_accumulated_count += batch.reports_to_process;
        // Deduct actual total gas used in this batch, avoid underflow
        current_gas_limit = current_gas_limit -| parallelized_result.gas_used;
        span.debug("Batch finished. Accumulated: {d}, Batch Gas Used: {d}, Remaining Gas Limit: {d}", .{ batch.reports_to_process, parallelized_result.gas_used, current_gas_limit });
        // We only execute our privileged_services once
        first_batch = false;

        // If all reports processed, break early
        if (current_reports.len == batch.reports_to_process) {
            span.debug("Processed all work reports", .{});
            break;
        }

        current_reports = current_reports[batch.reports_to_process..];

        span.debug("Continuing with remaining {d} reports and {d} gas", .{
            current_reports.len, current_gas_limit,
        });
    }

    return .{
        .accumulated_count = total_accumulated_count,
        .transfers = try transfers.toOwnedSlice(),
        .accumulation_outputs = accumulation_outputs,
        .service_gas_used = total_service_gas_used,
    };
}

pub const ParallelizedAccumulationResult = struct {
    gas_used: types.Gas,
    transfers: []DeferredTransfer,
    service_results: std.AutoHashMap(types.ServiceId, ServiceAccumulationResult),

    /// Takes ownership of the transfers slice, setting internal transfers to empty
    pub fn takeTransfers(self: *@This()) []DeferredTransfer {
        const result = self.transfers;
        self.transfers = &[_]DeferredTransfer{};
        return result;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        // Free the transfers array
        allocator.free(self.transfers);

        // Clean up service results
        var it = self.service_results.iterator();
        while (it.next()) |entry| {
            // _ = entry;
            entry.value_ptr.deinit(allocator);
        }
        self.service_results.deinit();

        // Mark as undefined to prevent use-after-free
        self.* = undefined;
    }
};

/// 12.17 Parallelized accumulation function Δ*
/// Transforms an initial state context and sequence of work reports
/// into a tuple containing:
/// - Total gas utilized in PVM execution
/// - Posterior state context
/// - Resultant deferred transfers
/// - Accumulation output pairings
pub fn parallelizedAccumulation(
    comptime params: jam_params.Params,
    allocator: std.mem.Allocator,
    context: *const AccumulationContext(params),
    work_reports: []const types.WorkReport,
    include_privileged: bool, // Whether to include privileged services (first batch only)
) !ParallelizedAccumulationResult {
    const span = trace.span(.parallelized_accumulation);
    defer span.deinit();

    // Assertions - function parameters are guaranteed to be valid

    span.debug("Starting parallelized accumulation for {d} work reports", .{work_reports.len});

    // Collect all unique service IDs
    var service_ids = try collectServiceIds(allocator, context, work_reports, include_privileged);
    defer service_ids.deinit();

    span.debug("Found {d} unique services to accumulate", .{service_ids.count()});

    // Group work items by service
    var service_operands = try groupWorkItemsByService(allocator, work_reports);
    defer service_operands.deinit();

    // Store results for each service
    var service_results = std.AutoHashMap(types.ServiceId, ServiceAccumulationResult).init(allocator);
    errdefer meta.deinit.deinitHashMapValuesAndMap(allocator, service_results);

    // Process each service in parallel (in a real implementation)
    // Here we process them sequentially but could be parallelized
    var total_gas_used: types.Gas = 0;
    var all_transfers = std.ArrayList(DeferredTransfer).init(allocator);
    defer all_transfers.deinit();

    // Process each service, in order of insertion
    for (service_ids.keys()) |service_id| {
        // Get operands if we have them, privileged_services do not have them
        const maybe_operands = service_operands.getOperands(service_id);

        // Process this service
        // TODO: https://github.com/zig-gamedev/zjobs maybe of interest
        // TODO: When implementing parallel execution, each service should get an isolated
        // copy of the context that can be modified without affecting others.
        var result = try singleServiceAccumulation(
            params,
            allocator,
            context,
            service_id,
            maybe_operands,
        );
        defer result.deinit(allocator);

        // Store results - take ownership of transfers
        const transfers = result.takeTransfers();
        try service_results.put(service_id, .{
            .gas_used = result.gas_used,
            .transfers = transfers,
            .accumulation_output = result.accumulation_output,
        });

        // Update total gas used
        total_gas_used += result.gas_used;

        // Collect all transfers
        try all_transfers.appendSlice(result.transfers);
    }

    // Return collected results
    return .{
        .gas_used = total_gas_used,
        .transfers = try all_transfers.toOwnedSlice(),
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
    context: *const AccumulationContext(params),
    service_id: types.ServiceId,
    service_operands: ?ServiceAccumulationOperandsMap.Operands,
) !AccumulationResult {
    const span = trace.span(.single_service_accumulation);
    defer span.deinit();

    // Assertions - function parameters are guaranteed to be valid

    span.debug("Starting accumulation for service {d} with {d} operands", .{
        service_id, if (service_operands) |so| so.count() else 0,
    });

    // Either this is a privileged service and it has a gas limit set, or we have some operands
    // and have a gas_limit
    const gas_limit = @constCast(&context.privileges).getReadOnly().always_accumulate.get(service_id) orelse
        if (service_operands) |so| so.calcGasLimit() else return AccumulationResult.Empty;

    // Exit early if we have a gas_limit of 0
    if (gas_limit == 0) {
        return AccumulationResult.Empty;
    }

    return try pvm_accumulate.invoke(
        params,
        allocator,
        context,
        context.time.current_slot,
        context.entropy,
        service_id,
        gas_limit,
        if (service_operands) |so| so.accumulationOperandSlice() else &[_]AccumulationOperand{},
    );
}

/// Main execution entry point for accumulation
/// This coordinates the execution of work reports through the PVM
pub fn executeAccumulation(
    comptime params: jam_params.Params,
    allocator: std.mem.Allocator,
    stx: *state_delta.StateTransition(params),
    _: *state.Chi,
    accumulatable: []const types.WorkReport,
    gas_limit: u64,
) !OuterAccumulationResult {
    const span = trace.span(.execute_accumulation);
    defer span.deinit();

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
        },
    );
    defer accumulation_context.deinit();

    span.debug("Executing outer accumulation with {d} reports and gas limit {d}", .{ accumulatable.len, gas_limit });

    // Execute work reports scheduled for accumulation
    return try outerAccumulation(
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

/// Aggregate results from a batch of parallel accumulations
fn aggregateBatchResults(
    transfers: *std.ArrayList(DeferredTransfer),
    accumulation_outputs: *std.AutoHashMap(types.ServiceId, types.AccumulateRoot),
    total_service_gas_used: *std.AutoHashMap(types.ServiceId, types.Gas),
    parallelized_result: *ParallelizedAccumulationResult,
    span: anytype,
) !void {
    // Gather all transfers
    try transfers.appendSlice(parallelized_result.transfers);

    // Add all accumulation outputs and aggregate per-service gas usage
    var it = parallelized_result.service_results.iterator();
    while (it.next()) |entry| {
        const service_id = entry.key_ptr.*;
        const service_result = entry.value_ptr.*;

        // Add accumulation output if present
        if (service_result.accumulation_output) |output| {
            try accumulation_outputs.put(service_id, output);
        }

        // Aggregate gas used for this service
        const current_gas = total_service_gas_used.get(service_id) orelse 0;
        try total_service_gas_used.put(service_id, current_gas + service_result.gas_used);
        span.trace("Aggregated gas for service {d}: {d} (batch) + {d} (prev) = {d} (total)", .{ service_id, service_result.gas_used, current_gas, current_gas + service_result.gas_used });
    }
}

/// Collect all unique service IDs from privileged services and work reports
fn collectServiceIds(
    allocator: std.mem.Allocator,
    context: anytype, // *const AccumulationContext(params)
    work_reports: []const types.WorkReport,
    include_privileged: bool,
) !std.AutoArrayHashMap(types.ServiceId, void) {
    var service_ids = std.AutoArrayHashMap(types.ServiceId, void).init(allocator);
    errdefer service_ids.deinit();

    // First the always accumulates (only in first batch)
    if (include_privileged) {
        var it = &context.privileges.getReadOnly().always_accumulate.iterator();
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

    return service_ids;
}

/// Group work items by service ID
fn groupWorkItemsByService(
    allocator: std.mem.Allocator,
    work_reports: []const types.WorkReport,
) !ServiceAccumulationOperandsMap {
    var service_operands = ServiceAccumulationOperandsMap.init(allocator);
    errdefer service_operands.deinit();

    // Process all work reports, and build operands in order of appearance
    for (work_reports) |report| {
        // Convert work report to accumulation operands
        var operands = try AccumulationOperand.fromWorkReport(allocator, report);
        defer operands.deinit(allocator);

        // Group by service ID, and store the accumulate_gas per item
        for (report.results, operands.items) |result, *operand| {
            const service_id = result.service_id;
            const accumulate_gas = result.accumulate_gas;
            try service_operands.addOperand(service_id, .{
                .operand = try operand.take(),
                .accumulate_gas = accumulate_gas,
            });
        }
    }

    return service_operands;
}
