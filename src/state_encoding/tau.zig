const std = @import("std");
const types = @import("../types.zig");

const trace = @import("../tracing.zig").scoped(.codec);

pub fn encode(tau: types.TimeSlot, writer: anytype) !void {
    const span = trace.span(.encode);
    defer span.deinit();
    span.debug("Encoding timeslot", .{});
    span.trace("Timeslot value: {d}", .{tau});

    try writer.writeInt(u32, tau, .little);
    span.debug("Successfully encoded timeslot", .{});
}
