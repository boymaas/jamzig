const std = @import("std");

const types = @import("../types.zig");
const WorkReport = types.WorkReport;

const jam_params = @import("../jam_params.zig");

const encoder = @import("../codec/encoder.zig");
const codec = @import("../codec.zig");

const pending_reports = @import("../pending_reports.zig");
const Rho = pending_reports.Rho;

pub fn encode(
    comptime params: jam_params.Params,
    rho: *const Rho(params.core_count),
    writer: anytype,
) !void {
    // The number of cores (C) is not encoded as it is a constant

    // Encode each report entry
    for (rho.reports) |maybe_entry| {
        if (maybe_entry) |entry| {
            // Entry exists
            try writer.writeByte(1);

            // Encode work report
            try codec.serialize(types.AvailabilityAssignment, .{}, writer, entry.assignment);
        } else {
            // No entry
            try writer.writeByte(0);
        }
    }
}
