const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");

/// Type alias for queued work reports with dependencies
pub fn Queued(T: type) type {
    return std.ArrayList(T);
}

/// Type alias for work reports ready for accumulation
pub fn Accumulatable(T: type) type {
    return std.ArrayList(T);
}

/// Type alias for resolved work package hashes
pub fn Resolved(T: type) type {
    return std.ArrayList(T);
}

/// Result of preparing reports for accumulation
pub const PreparedReports = struct {
    accumulatable_buffer: Accumulatable(types.WorkReport),
    queued: Queued(state.reports_ready.WorkReportAndDeps),
    map_buffer: std.ArrayList(types.WorkReportHash),
};

/// Time information for state updates
pub const TimeInfo = struct {
    current_slot: types.TimeSlot,
    prior_slot: types.TimeSlot,
    current_slot_in_epoch: u32,
};

/// Result of dependency filtering
pub const FilterResult = struct {
    filtered_out: usize,
    resolved_deps: usize,
};

/// Result of report partitioning
pub const PartitionResult = struct {
    immediate_count: usize,
    queued_count: usize,
};

/// Error types for accumulation operations
pub const AccumulationError = error{
    ServiceNotFound,
    InsufficientGas,
    InvalidWorkReport,
    StorageLimitExceeded,
    AccumulationFailed,
    OutOfMemory,
};