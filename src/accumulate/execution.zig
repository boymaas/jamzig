const std = @import("std");

const pvm_accumulate = @import("../pvm_invocations/accumulate.zig");
const types = @import("../types.zig");
const state = @import("../state.zig");
const jam_params = @import("../jam_params.zig");

const trace = @import("../tracing.zig").scoped(.accumulate_execution);

const AccumulationContext = pvm_accumulate.AccumulationContext;
const AccumulationOperand = pvm_accumulate.AccumulationOperand;
const AccumulationResult = pvm_accumulate.AccumulationResult;
const DeferredTransfer = @import("../pvm_invocations/accumulate/types.zig").DeferredTransfer;

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
pub fn OuterAccumulationResult(comptime params: @import("../jam_params.zig").Params) type {
    return struct {
        accumulated_count: usize,
        context: AccumulationContext(params),
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
}

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
    context: AccumulationContext(params),
    free_accumulation_services: std.AutoHashMap(types.ServiceId, types.Gas),
    tau: types.TimeSlot,
    entropy: types.Entropy,
) !OuterAccumulationResult(params) {
    const span = trace.span(.outer_accumulation);
    defer span.deinit();
    span.debug("Starting outer accumulation with gas limit: {d}", .{gas_limit});

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
            .context = context,
            .transfers = &[_]DeferredTransfer{},
            .accumulation_outputs = accumulation_outputs,
        };
    }

    // Calculate total gas needed for all work items
    var total_gas_needed: types.Gas = 0;
    for (work_reports) |report| {
        for (report.results) |result| {
            total_gas_needed += result.accumulate_gas;
        }
    }

    // Determine how many work reports we can process with the given gas limit
    const can_process_all = total_gas_needed <= gas_limit;
    var reports_to_process: usize = 0;
    var gas_to_use: types.Gas = 0;

    if (can_process_all) {
        reports_to_process = work_reports.len;
        gas_to_use = total_gas_needed;
    } else {
        // Find max number of reports that fit within gas limit
        var cumulative_gas: types.Gas = 0;
        for (work_reports, 0..) |report, i| {
            var report_gas: types.Gas = 0;
            for (report.results) |result| {
                report_gas += result.accumulate_gas;
            }

            if (cumulative_gas + report_gas <= gas_limit) {
                cumulative_gas += report_gas;
                reports_to_process = i + 1;
            } else {
                break;
            }
        }
        gas_to_use = cumulative_gas;
    }

    span.debug("Will process {d}/{d} reports using {d}/{d} gas", .{
        reports_to_process, work_reports.len, gas_to_use, gas_limit,
    });

    // If no reports can be processed within the gas limit, return early
    if (reports_to_process == 0) {
        span.debug("No reports can be processed within gas limit", .{});
        return .{
            .accumulated_count = 0,
            .context = context,
            .transfers = &[_]DeferredTransfer{},
            .accumulation_outputs = accumulation_outputs,
        };
    }

    // Process reports in parallel using parallelizedAccumulation
    var parallelized_result = try parallelizedAccumulation(
        params,
        allocator,
        context,
        work_reports[0..reports_to_process],
        free_accumulation_services,
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

    // If we've processed all reports or have no gas left, return results
    if (reports_to_process == work_reports.len) {
        span.debug("Processed all work reports", .{});
        return .{
            .accumulated_count = reports_to_process,
            .context = parallelized_result.context,
            .transfers = try transfers.toOwnedSlice(),
            .accumulation_outputs = accumulation_outputs,
        };
    }

    // Otherwise, recursively process the remaining reports with remaining gas
    const remaining_gas = gas_limit - gas_to_use;
    span.debug("Recursively processing remaining {d} reports with {d} gas", .{
        work_reports.len - reports_to_process, remaining_gas,
    });

    var recursive_result = try outerAccumulation(
        params,
        allocator,
        remaining_gas,
        work_reports[reports_to_process..],
        parallelized_result.context,
        free_accumulation_services,
        tau,
        entropy,
    );
    defer recursive_result.deinit(allocator);

    // Combine results from recursive call
    try transfers.appendSlice(recursive_result.transfers);

    {
        var it = recursive_result.accumulation_outputs.iterator();
        while (it.next()) |entry| {
            try accumulation_outputs.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    return .{
        .accumulated_count = reports_to_process + recursive_result.accumulated_count,
        .context = recursive_result.context,
        .transfers = try transfers.toOwnedSlice(),
        .accumulation_outputs = accumulation_outputs,
    };
}

pub fn ParallelizedAccumulationResult(comptime params: jam_params.Params) type {
    return struct {
        context: AccumulationContext(params),
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
}

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
    context: AccumulationContext(params),
    work_reports: []const types.WorkReport,
    privileged_services: std.AutoHashMap(types.ServiceId, types.Gas),
    tau: types.TimeSlot,
    entropy: types.Entropy,
) !ParallelizedAccumulationResult(params) {
    const span = trace.span(.parallelized_accumulation);
    defer span.deinit();
    span.debug("Starting parallelized accumulation for {d} work reports", .{work_reports.len});

    // Extract all unique service IDs from work reports and privileged services
    var service_ids = std.AutoHashMap(types.ServiceId, void).init(allocator);
    defer service_ids.deinit();

    // Add services from work reports
    for (work_reports) |report| {
        for (report.results) |result| {
            try service_ids.put(result.service_id, {});
        }
    }

    // Add privileged services
    {
        var it = privileged_services.iterator();
        while (it.next()) |entry| {
            try service_ids.put(entry.key_ptr.*, {});
        }
    }

    span.debug("Found {d} unique services to accumulate", .{service_ids.count()});

    // Group work items by service
    var service_work_items = std.AutoHashMap(
        types.ServiceId,
        std.ArrayList(AccumulationOperand),
    ).init(allocator);
    defer {
        var it = service_work_items.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |*operand| {
                operand.deinit(allocator);
            }
            entry.value_ptr.deinit();
        }
        service_work_items.deinit();
    }

    // Process all work reports
    for (work_reports) |report| {
        // Convert work report to accumulation operands
        var operands = try AccumulationOperand.fromWorkReport(allocator, report);
        defer operands.deinit(allocator);

        // Group by service ID
        for (report.results, operands.items) |result, *operand| {
            const service_id = result.service_id;

            if (!service_work_items.contains(service_id)) {
                try service_work_items.put(service_id, std.ArrayList(AccumulationOperand).init(allocator));
            }

            var service_operands = service_work_items.getPtr(service_id).?;

            try service_operands.append(try operand.take());
        }
    }

    // Store results for each service
    var service_results = std.AutoHashMap(types.ServiceId, ServiceAccumulationResult).init(allocator);
    errdefer {
        var it = service_results.valueIterator();
        while (it.next()) |entry| {
            entry.deinit(allocator);
        }
    }

    // Process each service in parallel (in a real implementation)
    // Here we process them sequentially but could be parallelized
    var total_gas_used: types.Gas = 0;
    var all_transfers = std.ArrayList(DeferredTransfer).init(allocator);
    defer all_transfers.deinit();

    var service_ids_slice = try allocator.alloc(types.ServiceId, service_ids.count());
    defer allocator.free(service_ids_slice);

    {
        var i: usize = 0;
        var it = service_ids.iterator();
        while (it.next()) |entry| {
            service_ids_slice[i] = entry.key_ptr.*;
            i += 1;
        }
    }

    // Process each service
    for (service_ids_slice) |service_id| {
        const operands_opt = service_work_items.get(service_id);
        const gas_limit_opt = privileged_services.get(service_id);

        var gas_limit: types.Gas = 0;

        // Determine gas limit for this service
        if (gas_limit_opt) |gas| {
            // Service has privileged gas allocation
            gas_limit = gas;
        }

        // Add gas from work items if available
        if (operands_opt) |operands| {
            for (operands.items) |operand| {
                switch (operand.output) {
                    .success => |_| {
                        // Find the result with matching payload hash
                        for (work_reports) |report| {
                            for (report.results) |result| {
                                if (std.mem.eql(u8, &result.payload_hash, &operand.payload_hash) and
                                    result.service_id == service_id)
                                {
                                    gas_limit += result.accumulate_gas;
                                    break;
                                }
                            }
                        }
                    },
                    .err => {}, // No gas for error cases
                }
            }
        }

        // Skip services with no gas allocation
        if (gas_limit == 0) {
            span.debug("Skipping service {d} with no gas allocation", .{service_id});
            continue;
        }

        // Process this service
        var result = try singleServiceAccumulation(
            params,
            allocator,
            context,
            tau,
            entropy,
            service_id,
            gas_limit,
            if (operands_opt) |operands| operands.items.ptr[0..operands.items.len] else &[_]AccumulationOperand{},
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
        .context = context,
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
    comptime params: @import("../jam_params.zig").Params,
    allocator: std.mem.Allocator,
    context: AccumulationContext(params),
    tau: types.TimeSlot,
    entropy: types.Entropy,
    service_id: types.ServiceId,
    gas_limit: types.Gas,
    operands: []const AccumulationOperand,
) !AccumulationResult(params) {
    const span = trace.span(.single_service_accumulation);
    defer span.deinit();
    span.debug("Starting accumulation for service {d} with {d} operands", .{
        service_id, operands.len,
    });

    // This is essentially a wrapper around the pvm_accumulate function
    return try pvm_accumulate.invoke(
        params,
        allocator,
        context,
        tau,
        entropy,
        service_id,
        gas_limit,
        operands,
    );
}
