const std = @import("std");
const types = @import("../types.zig");
const codec = @import("../codec.zig");

const trace = @import("../tracing.zig").scoped(.codec);

pub fn encode(set: *const types.ValidatorSet, writer: anytype) !void {
    const span = trace.span(.encode);
    defer span.deinit();
    span.debug("Starting validator set encoding", .{});
    span.trace("Validator set length: {d}", .{set.items().len});

    try codec.serializeSliceAsArray(types.ValidatorData, writer, set.items());

    span.debug("Successfully encoded validator set", .{});
}
