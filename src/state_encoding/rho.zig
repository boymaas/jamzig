const std = @import("std");

const types = @import("../types.zig");
const WorkReport = types.WorkReport;

const jam_params = @import("../jam_params.zig");

const encoder = @import("../codec/encoder.zig");
const codec = @import("../codec.zig");

const pending_reports = @import("../reports_pending.zig");
const Rho = pending_reports.Rho;

const trace = @import("tracing").scoped(.codec);

pub fn encode(
    comptime params: jam_params.Params,
    rho: *const Rho(params.core_count),
    writer: anytype,
) !void {
    const span = trace.span(@src(), .encode);
    defer span.deinit();
    span.debug("Starting Rho state encoding with {d} cores", .{params.core_count});

    for (rho.reports, 0..) |maybe_entry, core_idx| {
        const entry_span = span.child(@src(), .entry);
        defer entry_span.deinit();
        entry_span.debug("Processing core {d}", .{core_idx});

        if (maybe_entry) |entry| {
            entry_span.debug("Encoding entry for core {d}", .{core_idx});
            try writer.writeByte(1);
            entry_span.trace("Wrote presence byte: 1", .{});

            entry_span.debug("Serializing availability assignment", .{});
            try codec.serialize(types.AvailabilityAssignment, .{}, writer, entry.assignment);
        } else {
            entry_span.debug("No entry for core {d}", .{core_idx});
            try writer.writeByte(0);
            entry_span.trace("Wrote presence byte: 0", .{});
        }
    }

    span.debug("Successfully encoded Rho state", .{});
}
