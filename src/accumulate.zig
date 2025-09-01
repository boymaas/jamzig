//! Accumulation module - processes work reports through dependency resolution,
//! execution, and state updates according to JAM specification §12
//!
//! This module provides the main public API for the accumulation process,
//! coordinating the various subsystems involved in processing work reports.

const std = @import("std");
const types = @import("types.zig");
const state_delta = @import("state_delta.zig");
const Params = @import("jam_params.zig").Params;

// Re-export key types from execution module
pub const ProcessAccumulationResult = @import("accumulate/execution.zig").ProcessAccumulationResult;
pub const DeferredTransfer = @import("pvm_invocations/accumulate.zig").DeferredTransfer;

// Also re-export execution module for components that depend on it
pub const execution = @import("accumulate/execution.zig");

// Import internal modules
const DependencyResolver = @import("accumulate/dependency_resolver.zig").DependencyResolver;
const StatisticsCalculator = @import("accumulate/statistics_calculator.zig").StatisticsCalculator;
const StateUpdater = @import("accumulate/state_updater.zig").StateUpdater;
const GasCalculator = @import("accumulate/gas_calculator.zig").GasCalculator;
const TransferExecutor = @import("accumulate/transfer_executor.zig").TransferExecutor;
const HistoryTracker = @import("accumulate/history_tracker.zig").HistoryTracker;
const QueueProcessor = @import("accumulate/queue_processor.zig").QueueProcessor;

const trace = @import("tracing.zig").scoped(.accumulate);

/// Main entry point for processing work reports according to JAM §12.1
/// Coordinates the full accumulation pipeline through specialized modules
pub fn processAccumulationReports(
    comptime IOExecutor: type,
    io_executor: *IOExecutor,
    comptime params: Params,
    allocator: std.mem.Allocator,
    stx: *state_delta.StateTransition(params),
    reports: []types.WorkReport,
) !ProcessAccumulationResult {
    const span = trace.span(.process_accumulate_reports);
    defer span.deinit();

    span.debug("Starting accumulation process with {d} reports", .{reports.len});

    // Initialize state components
    const xi = try stx.ensure(.xi_prime);
    const vartheta = try stx.ensure(.vartheta_prime);
    const chi = try stx.ensure(.chi_prime);

    // Step 1: Resolve dependencies and prepare reports
    const resolver = DependencyResolver(params).init(allocator);
    var prepared = try resolver.prepareReportsForAccumulation(
        xi,
        vartheta,
        reports,
        stx.time.current_slot_in_epoch,
    );
    defer {
        @import("meta.zig").deinit.deinitEntriesAndAggregate(allocator, prepared.accumulatable_buffer);
        @import("meta.zig").deinit.deinitEntriesAndAggregate(allocator, prepared.queued);
        prepared.map_buffer.deinit();
    }

    // Step 2: Calculate gas limits
    const gas_calculator = GasCalculator(params){};
    const gas_limit = gas_calculator.calculateGasLimit(chi);

    // Step 3: Execute accumulation
    const accumulatable = prepared.accumulatable_buffer.items;
    var execution_result = try @import("accumulate/execution.zig").executeAccumulation(
        IOExecutor,
        io_executor,
        params,
        allocator,
        stx,
        accumulatable,
        gas_limit,
    );
    defer execution_result.deinit(allocator);

    const accumulated = accumulatable[0..execution_result.accumulated_count];

    // Step 4: Apply deferred transfers
    const transfer_executor = TransferExecutor(params).init(allocator);
    const transfer_stats = try transfer_executor.applyDeferredTransfers(
        stx,
        execution_result.deferred_transfers,
    );

    // Step 5: Update history
    const history_tracker = HistoryTracker(params){};
    try history_tracker.updateAccumulationHistory(xi, accumulated);

    // Step 6: Update state
    const state_updater = StateUpdater(params).init(allocator);
    try state_updater.updateThetaState(
        vartheta,
        &prepared.queued,
        accumulated,
        &prepared.map_buffer,
        .{
            .current_slot = stx.time.current_slot,
            .prior_slot = stx.time.prior_slot,
            .current_slot_in_epoch = stx.time.current_slot_in_epoch,
        },
    );

    // Step 7: Update theta with accumulation outputs
    const theta = try stx.ensure(.theta_prime);
    try state_updater.updateAccumulationOutputs(
        theta,
        execution_result.accumulation_outputs,
    );

    // Step 8: Calculate statistics
    const stats_calculator = StatisticsCalculator(params).init(allocator);
    return try stats_calculator.computeAllStatistics(
        accumulated,
        &execution_result,
        transfer_stats,
    );
}
