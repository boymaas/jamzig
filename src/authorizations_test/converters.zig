const std = @import("std");
const state = @import("../state.zig");
const types = @import("../types.zig");

const auth_pool = @import("../authorizer_pool.zig");
const auth_queue = @import("../authorizer_queue.zig");

const jamtestvectors = @import("../jamtestvectors/authorizations.zig");
const trace = @import("../tracing.zig").scoped(.converters);

const Params = @import("../jam_params.zig").Params;

/// Converts from a test vector's pre-state or post-state to an Alpha state object
/// This is useful for comparing the expected state with the actual state after processing authorizations
pub fn convertToAlpha(
    comptime params: Params,
    _: std.mem.Allocator,
    test_state: jamtestvectors.State(params),
) !state.Alpha(params.core_count, params.max_authorizations_pool_items) {
    const span = trace.span(.convert_to_alpha);
    defer span.deinit();
    span.debug("Converting test state to Alpha instance", .{});

    var alpha = auth_pool.Alpha(params.core_count, params.max_authorizations_pool_items).init();

    // For each core in the test state, add authorizers to the Alpha pools
    for (test_state.auth_pools, 0..) |pool, core_idx| {
        span.debug("Processing core {d} with {d} authorizers", .{ core_idx, pool.items.len });

        // Add each hash in the pool to the Alpha instance
        for (pool.items) |hash| {
            // Skip empty hashes (all zeros)
            if (isEmptyHash(&hash)) continue;

            try alpha.addAuthorizer(core_idx, hash);
            span.trace("Added authorizer hash to core {d}: {s}", .{
                core_idx,
                std.fmt.fmtSliceHexLower(&hash),
            });
        }
    }

    return alpha;
}

/// Converts from a test vector's pre-state or post-state to a Phi state object
pub fn convertToPhi(
    comptime params: Params,
    allocator: std.mem.Allocator,
    test_state: jamtestvectors.State(params),
) !state.Phi(params.core_count, params.max_authorizations_queue_items) {
    const span = trace.span(.convert_to_phi);
    defer span.deinit();
    span.debug("Converting test state to Phi instance", .{});

    var phi = try auth_queue.Phi(params.core_count, params.max_authorizations_queue_items).init(allocator);
    errdefer phi.deinit();

    // For each core in the test state, add authorizers to the Phi queues
    for (test_state.auth_queues, 0..) |queue, core_idx| {
        span.debug("Processing core {d} queue with {d} items", .{ core_idx, queue.items.len });

        // Add each hash in the queue to the Phi instance
        for (queue.items) |hash| {
            // Skip empty hashes (all zeros)
            if (isEmptyHash(&hash)) continue;

            try phi.addAuthorization(core_idx, hash);
            span.trace("Added authorizor hash to core {d} queue: {s}", .{
                core_idx,
                std.fmt.fmtSliceHexLower(&hash),
            });
        }
    }

    return phi;
}

/// Creates a CoreAuthorizer list from test vector input
pub fn convertToAuthorizerList(
    allocator: std.mem.Allocator,
    input: jamtestvectors.Input,
) ![]@import("../authorizations.zig").CoreAuthorizer {
    const span = trace.span(.convert_to_authorizers);
    defer span.deinit();
    span.debug("Converting input to authorizer list ({d} items)", .{input.auths.len});

    var result = std.ArrayList(@import("../authorizations.zig").CoreAuthorizer).init(allocator);
    errdefer result.deinit();

    try result.ensureTotalCapacity(input.auths.len);

    for (input.auths) |auth| {
        try result.append(.{
            .core = auth.core,
            .auth_hash = auth.auth_hash,
        });
        span.trace("Added authorizer for core {d}: {s}", .{
            auth.core,
            std.fmt.fmtSliceHexLower(&auth.auth_hash),
        });
    }

    return result.toOwnedSlice();
}

/// Helper function to check if a hash is empty (all zeros)
fn isEmptyHash(hash: *const [32]u8) bool {
    for (hash) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

/// Builds a complete transient JamState with both Alpha and Phi initialized from test data
pub fn buildTransientFromTestState(
    comptime params: Params,
    allocator: std.mem.Allocator,
    test_state: jamtestvectors.State(params),
) !state.JamState(params) {
    const span = trace.span(.build_transient);
    defer span.deinit();
    span.debug("Building complete transient state from test data", .{});

    var jam_state = try state.JamState(params).init(allocator);
    errdefer jam_state.deinit(allocator);

    // Convert and initialize Alpha component
    jam_state.alpha = try convertToAlpha(
        params,
        allocator,
        test_state,
    );

    // Convert and initialize Phi component
    jam_state.phi = try convertToPhi(
        params,
        allocator,
        test_state,
    );

    return jam_state;
}
