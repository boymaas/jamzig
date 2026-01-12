const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");

pub fn Queued(T: type) type {
    return std.ArrayList(T);
}

pub fn Accumulatable(T: type) type {
    return std.ArrayList(T);
}

pub fn Resolved(T: type) type {
    return std.ArrayList(T);
}

pub const PreparedReports = struct {
    accumulatable_buffer: Accumulatable(types.WorkReport),
    queued: Queued(state.reports_ready.WorkReportAndDeps),
    map_buffer: std.ArrayList(types.WorkReportHash),
};

pub const TimeInfo = struct {
    current_slot: types.TimeSlot,
    prior_slot: types.TimeSlot,
    current_slot_in_epoch: u32,
};

pub const FilterResult = struct {
    filtered_out: usize,
    resolved_deps: usize,
};

pub const PartitionResult = struct {
    immediate_count: usize,
    queued_count: usize,
};

pub const AccumulationError = error{
    ServiceNotFound,
    InsufficientGas,
    InvalidWorkReport,
    StorageLimitExceeded,
    AccumulationFailed,
    OutOfMemory,
};