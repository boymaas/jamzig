const std = @import("std");

const pvm_accumulate = @import("../pvm_invocations/accumulate.zig");
const types = @import("../types.zig");
const state = @import("../state.zig");
const jam_params = @import("../jam_params.zig");
const meta = @import("../meta.zig");

const trace = @import("../tracing.zig").scoped(.accumulate);

const AccumulationContext = pvm_accumulate.AccumulationContext;
const AccumulationOperand = pvm_accumulate.AccumulationOperand;
const AccumulationResult = pvm_accumulate.AccumulationResult;
const DeferredTransfer = pvm_accumulate.DeferredTransfer;

const ServiceAccumulationOperandsMap = @import("service_operands_map.zig").ServiceAccumulationOperandsMap;

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

    pub fn takeTransfers(self: *@This()) []DeferredTransfer {
        const result = self.transfers;
        self.transfers = &[_]DeferredTransfer{};
        return result;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.transfers);
        self.accumulation_outputs.deinit();
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
    gas_limit: types.Gas,
    work_reports: []const types.WorkReport,
    context: *const AccumulationContext(params),
    privileged_services: *const std.AutoHashMap(types.ServiceId, types.Gas),
    tau: types.TimeSlot,
    entropy: types.Entropy,
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

    // If no work reports, return early
    if (work_reports.len == 0) {
        span.debug("No work reports to process", .{});
        return .{
            .accumulated_count = 0,
            .transfers = &[_]DeferredTransfer{},
            .accumulation_outputs = accumulation_outputs,
        };
    }

    // Empty HashMap, as we need to clear current_privileged_services after the first iteration
    var empty_privileged_services = std.AutoHashMap(types.ServiceId, types.Gas).init(allocator);
    defer empty_privileged_services.deinit();

    // Initialize loop variables
    var current_gas_limit = gas_limit;
    var current_reports = work_reports;
    var current_privileged_services = privileged_services;
    var total_accumulated_count: usize = 0;

    // Process reports in batches until we've processed all or run out of gas
    while (current_reports.len > 0 and current_gas_limit > 0) {
        // Calculate total gas needed for all remaining work items
        var reports_to_process: usize = 0;
        var gas_to_use: types.Gas = 0;

        // Find max number of reports that fit within gas limit
        var cumulative_gas: types.Gas = 0;
        for (current_reports, 0..) |report, i| {
            const report_gas: types.Gas = report.totalAccumulateGas();

            if (cumulative_gas + report_gas <= current_gas_limit) {
                cumulative_gas += report_gas;
                reports_to_process = i + 1;
            } else {
                break;
            }
        }
        gas_to_use = cumulative_gas;

        span.debug("Will process {d}/{d} reports using {d}/{d} gas", .{
            reports_to_process, current_reports.len, gas_to_use, current_gas_limit,
        });

        // If no reports can be processed within the gas limit, break the loop
        if (reports_to_process == 0) {
            span.debug("No more reports can be processed within gas limit", .{});
            break;
        }

        // Process reports in parallel
        var parallelized_result = try parallelizedAccumulation(
            params,
            allocator,
            context,
            current_reports[0..reports_to_process],
            current_privileged_services,
            tau,
            entropy,
        );
        defer parallelized_result.deinit(allocator);

        // Gather all transfers
        try transfers.appendSlice(parallelized_result.transfers);

        // Add all accumulation outputs to the map
        {
            var it = parallelized_result.service_results.iterator();
            while (it.next()) |entry| {
                const service_id = entry.key_ptr.*;
                const result = entry.value_ptr.*;

                if (result.accumulation_output) |output| {
                    try accumulation_outputs.put(service_id, output);
                }
            }
        }

        // Update loop variables for next iteration
        total_accumulated_count += reports_to_process;
        // Deduct actual gas used, smash into zero
        current_gas_limit = current_gas_limit -| parallelized_result.gas_used;
        // We only execute our privileged_services once
        current_privileged_services = &empty_privileged_services;

        // If all reports processed, break early
        if (current_reports.len == reports_to_process) {
            span.debug("Processed all work reports", .{});
            break;
        }

        current_reports = current_reports[reports_to_process..];

        span.debug("Continuing with remaining {d} reports and {d} gas", .{
            current_reports.len, current_gas_limit,
        });
    }

    return .{
        .accumulated_count = total_accumulated_count,
        .transfers = try transfers.toOwnedSlice(),
        .accumulation_outputs = accumulation_outputs,
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
/// Transforms an initial state context, sequence of work reports,
/// and dictionary of privileged always-accumulate services into a tuple containing:
/// - Total gas utilized in PVM execution
/// - Posterior state context
/// - Resultant deferred transfers
/// - Accumulation output pairings
pub fn parallelizedAccumulation(
    comptime params: jam_params.Params,
    allocator: std.mem.Allocator,
    context: *const AccumulationContext(params),
    work_reports: []const types.WorkReport,
    privileged_services: *const std.AutoHashMap(types.ServiceId, types.Gas),
    tau: types.TimeSlot,
    entropy: types.Entropy,
) !ParallelizedAccumulationResult {
    const span = trace.span(.parallelized_accumulation);
    defer span.deinit();
    span.debug("Starting parallelized accumulation for {d} work reports", .{work_reports.len});

    // Build up our list of service ids
    var service_ids = std.AutoArrayHashMap(types.ServiceId, void).init(allocator);
    defer service_ids.deinit();

    // First the always accumulates
    {
        var it = privileged_services.iterator();
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

    span.debug("Found {d} unique services to accumulate", .{service_ids.count()});

    // Group work items by service using our container type
    var service_operands = ServiceAccumulationOperandsMap.init(allocator);
    defer service_operands.deinit();

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
        var result = try singleServiceAccumulation(
            params,
            allocator,
            context,
            tau,
            entropy,
            service_id,
            privileged_services,
            maybe_operands,
        );
        defer result.deinit(allocator);

        // Store results
        try service_results.put(service_id, .{
            .gas_used = result.gas_used,
            .transfers = try allocator.dupe(DeferredTransfer, result.transfers),
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
    tau: types.TimeSlot,
    entropy: types.Entropy,
    service_id: types.ServiceId,
    privileged_services: *const std.AutoHashMap(types.ServiceId, types.Gas),
    service_operands: ?ServiceAccumulationOperandsMap.Operands,
) !AccumulationResult {
    const span = trace.span(.single_service_accumulation);
    defer span.deinit();
    span.debug("Starting accumulation for service {d} with {d} operands", .{
        service_id, if (service_operands) |so| so.count() else 0,
    });

    // Either this is a priviledges service and it has a gas limit set, or we have some operands
    // and have a gas_limit
    const gas_limit = privileged_services.get(service_id) orelse
        if (service_operands) |so| so.calcGasLimit() else return AccumulationResult.Empty;

    // Exit early if we have a gas_limit of 0
    if (gas_limit == 0) {
        return AccumulationResult.Empty;
    }

    return try pvm_accumulate.invoke(
        params,
        allocator,
        context,
        tau,
        entropy,
        service_id,
        gas_limit,
        if (service_operands) |so| so.accumulationOperandSlice() else &[_]AccumulationOperand{},
    );
}
