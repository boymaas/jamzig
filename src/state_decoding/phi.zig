const std = @import("std");
const testing = std.testing;
const authorization_queue = @import("../authorizer_queue.zig");
const Phi = authorization_queue.Phi;
const state_decoding = @import("../state_decoding.zig");
const DecodingError = state_decoding.DecodingError;
const DecodingContext = state_decoding.DecodingContext;

const H = 32; // Hash size (32)

const trace = @import("../tracing.zig").scoped(.state_decoding);

pub const DecoderParams = struct {
    core_count: u16,
    max_authorizations_queue_items: u8,

    pub fn fromJamParams(comptime params: anytype) DecoderParams {
        return .{
            .core_count = params.core_count,
            .max_authorizations_queue_items = params.max_authorizations_queue_items,
        };
    }
};

pub fn decode(
    comptime params: DecoderParams,
    allocator: std.mem.Allocator,
    context: *DecodingContext,
    reader: anytype,
) !Phi(params.core_count, params.max_authorizations_queue_items) {
    const span = trace.span(.decode);
    defer span.deinit();

    span.debug("starting phi state decoding for {d} cores with queue length {d}", .{ params.core_count, params.max_authorizations_queue_items });

    var phi = try Phi(params.core_count, params.max_authorizations_queue_items).init(allocator);
    errdefer phi.deinit();

    span.debug("initialized phi state with {d} total slots", .{phi.queue_data.len});

    // Read all authorization data directly into queue_data
    for (phi.queue_data) |*slot| {
        try reader.readNoEof(slot);
    }
    context.pop(); // queues

    return phi;
}
