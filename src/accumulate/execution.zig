const std = @import("std");

const pvm_accumulate = @import("../pvm_invocations/accumulate.zig");
const types = @import("../types.zig");
const state = @import("../state.zig");
const state_delta = @import("../state_delta.zig");
const jam_params = @import("../jam_params.zig");
const meta = @import("../meta.zig");

const HashSet = @import("../datastruct/hash_set.zig").HashSet;

const trace = @import("../tracing.zig").scoped(.accumulate);

const AccumulationContext = pvm_accumulate.AccumulationContext;
const AccumulationOperand = pvm_accumulate.AccumulationOperand;
const AccumulationResult = pvm_accumulate.AccumulationResult;
const DeferredTransfer = pvm_accumulate.DeferredTransfer;

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

/// Statistics for transfers targeting a single service within a block (Part of 'X' stats).
pub const TransferServiceStats = struct {
    transfer_count: u32 = 0,
    gas_used: u64 = 0,
};

/// Result of the outer accumulation function
pub const OuterAccumulationResult = struct {
    accumulated_count: usize,
    transfers: []DeferredTransfer,
    accumulation_outputs: HashSet(ServiceAccumulationOutput),
    service_gas_used: std.AutoHashMap(types.ServiceId, types.Gas), // Gas used per service ID

    pub fn takeTransfers(self: *@This()) []DeferredTransfer {
        const result = self.transfers;
        self.transfers = &[_]DeferredTransfer{};
        return result;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.transfers);
        self.accumulation_outputs.deinit(allocator);
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

    var accumulation_outputs = HashSet(ServiceAccumulationOutput).init();
    errdefer accumulation_outputs.deinit(allocator);

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

        // Apply context changes from all service dimensions
        try parallelized_result.applyContextChanges();

        // Process all service results in a single loop:
        // - Apply provided preimages
        // - Collect transfers
        // - Aggregate gas usage
        // - Collect accumulation outputs
        var batch_gas_used: types.Gas = 0;
        var result_it = parallelized_result.iterator();
        while (result_it.next()) |entry| {
            // Apply provided preimages
            try entry.dimension().applyProvidedPreimages(context.time.current_slot);

            // Append transfers directly
            try transfers.appendSlice(entry.transfers());

            // Add accumulation output if present
            if (entry.output()) |output| {
                try accumulation_outputs.add(allocator, .{ .service_id = entry.service_id, .output = output });
            }

            // Aggregate gas used for this service
            const current_gas = total_service_gas_used.get(entry.service_id) orelse 0;
            try total_service_gas_used.put(entry.service_id, current_gas + entry.gasUsed());

            // Track total gas for this batch
            batch_gas_used += entry.gasUsed();
        }

        span.debug("Applied state changes for all services", .{});

        // Update loop variables for next iteration
        total_accumulated_count += batch.reports_to_process;
        // Deduct actual total gas used in this batch, avoid underflow
        current_gas_limit = current_gas_limit -| batch_gas_used;
        span.debug("Batch finished. Accumulated: {d}, Batch Gas Used: {d}, Remaining Gas Limit: {d}", .{ batch.reports_to_process, batch_gas_used, current_gas_limit });
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

pub fn ParallelizedAccumulationResult(params: jam_params.Params) type {
    return struct {
        service_results: std.AutoHashMap(types.ServiceId, AccumulationResult(params)),

        /// Custom iterator with clean accessors for service results
        pub const ServiceResultIterator = struct {
            inner: std.AutoHashMap(types.ServiceId, AccumulationResult(params)).Iterator,
            current: ?Entry = null,

            pub const Entry = struct {
                service_id: types.ServiceId,
                result: *AccumulationResult(params),

                // Inline accessors
                pub inline fn transfers(self: Entry) []DeferredTransfer {
                    return self.result.transfers;
                }

                pub inline fn gasUsed(self: Entry) types.Gas {
                    return self.result.gas_used;
                }

                pub inline fn output(self: Entry) ?types.AccumulateOutput {
                    return self.result.accumulation_output;
                }

                pub inline fn dimension(self: Entry) @TypeOf(self.result.collapsed_dimension) {
                    return self.result.collapsed_dimension;
                }
            };

            pub fn next(self: *@This()) ?Entry {
                if (self.inner.next()) |entry| {
                    self.current = Entry{
                        .service_id = entry.key_ptr.*,
                        .result = entry.value_ptr,
                    };
                    return self.current;
                }
                return null;
            }
        };

        /// Returns a custom iterator over the service results
        pub fn iterator(self: *@This()) ServiceResultIterator {
            return ServiceResultIterator{
                .inner = self.service_results.iterator(),
            };
        }

        // Note: collectTransfers and totalGasUsed methods removed
        // These operations are now performed inline during iteration in outerAccumulation

        /// Apply context changes from all service dimensions
        pub fn applyContextChanges(self: *@This()) !void {
            var it = self.iterator();
            while (it.next()) |entry| {
                try entry.dimension().commit();
            }
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            // Clean up service results
            var it = self.iterator();
            while (it.next()) |entry| {
                entry.result.deinit(allocator);
            }
            self.service_results.deinit();

            // Mark as undefined to prevent use-after-free
            self.* = undefined;
        }
    };
}

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
) !ParallelizedAccumulationResult(params) {
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
    var service_results = std.AutoHashMap(types.ServiceId, AccumulationResult(params)).init(allocator);
    errdefer meta.deinit.deinitHashMapValuesAndMap(allocator, service_results);

    // Process each service in parallel (in a real implementation)
    // Here we process them sequentially but could be parallelized
    //
    // Process each service, in order of insertion
    for (service_ids.keys()) |service_id| {
        // Get operands if we have them, privileged_services do not have them
        const maybe_operands = service_operands.getOperands(service_id);

        // Process this service
        // TODO: https://github.com/zig-gamedev/zjobs maybe of interest
        // NOTE: Each service needs its own context copy for parallelization
        const result = try singleServiceAccumulation(
            params,
            allocator,
            context,
            service_id,
            maybe_operands,
        );
        // Don't defer deinit since we're moving ownership to service_results

        try service_results.put(service_id, result);
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
    context: *const AccumulationContext(params),
    service_id: types.ServiceId,
    service_operands: ?ServiceAccumulationOperandsMap.Operands,
) !AccumulationResult(params) {
    const span = trace.span(.single_service_accumulation);
    defer span.deinit();

    // Assertions - function parameters are guaranteed to be valid

    span.debug("Starting accumulation for service {d} with {d} operands", .{
        service_id, if (service_operands) |so| so.count() else 0,
    });

    // Either this is a privileged service and it has a gas limit set, or we have some operands
    // and have a gas_limit
    const gas_limit = context.privileges.getReadOnly().always_accumulate.get(service_id) orelse
        if (service_operands) |so| so.calcGasLimit() else 0;

    // Exit early if we have a gas_limit of 0
    if (gas_limit == 0) {
        return try pvm_accumulate.AccumulationResult(params).createEmpty(allocator, context, service_id);
    }

    return try pvm_accumulate.invoke(
        params,
        allocator,
        context,
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
