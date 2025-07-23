const std = @import("std");
const trace = @import("tracing.zig").scoped(.authorizations);
const types = @import("types.zig");

const Params = @import("jam_params.zig").Params;

const state = @import("state.zig");
const state_delta = @import("state_delta.zig");

const auth_pool = @import("authorizer_pool.zig");
const auth_queue = @import("authorizer_queue.zig");

pub const CoreAuthorizer = struct {
    core: types.CoreIndex,
    auth_hash: types.OpaqueHash,
};

// Process authorizations for a block
// Since α′ is dependent on φ′, practically speaking, this step must be
// computed after accumulation, the stage in which φ′ is defined.
pub fn processAuthorizations(
    comptime params: Params,
    stx: *state_delta.StateTransition(params),
    authorizers: []const CoreAuthorizer,
) !void {
    // Preconditions
    std.debug.assert(authorizers.len <= params.core_count);
    comptime {
        std.debug.assert(params.core_count > 0);
        std.debug.assert(params.max_authorizations_pool_items > 0);
        std.debug.assert(params.max_authorizations_queue_items > 0);
    }

    const span = trace.span(.process_authorizations);
    defer span.deinit();

    span.debug("Processing authorizations for slot {d}", .{stx.time.current_slot});
    span.debug("Number of core authorizers: {d}", .{authorizers.len});

    const alpha_prime: *state.Alpha(params.core_count, params.max_authorizations_pool_items) =
        try stx.ensure(.alpha_prime);

    const phi_prime: *state.Phi(params.core_count, params.max_authorizations_queue_items) =
        try stx.ensure(.phi_prime);

    // Process input authorizers (removals)
    try processInputAuthorizers(params, alpha_prime, authorizers, span);

    // Process authorization rotation for all cores
    try processAuthorizationRotation(params, alpha_prime, phi_prime, stx.time.current_slot, span);

    span.debug("Authorization processing complete for slot {d}", .{stx.time.current_slot});
}

// Process input authorizers by removing them from pools if they exist
fn processInputAuthorizers(
    comptime params: Params,
    alpha_prime: anytype,
    authorizers: []const CoreAuthorizer,
    // REFACTOR: could we have a more specific type for parent_span?
    parent_span: anytype,
) !void {
    // Preconditions
    std.debug.assert(authorizers.len <= params.core_count);

    const process_span = parent_span.child(.process_authorizers);
    defer process_span.deinit();
    process_span.debug("Processing {d} input authorizers", .{authorizers.len});

    for (authorizers, 0..) |authorizer, i| {
        const auth_span = process_span.child(.authorizer);
        defer auth_span.deinit();

        const core = authorizer.core;
        const auth_hash = authorizer.auth_hash;

        auth_span.debug("Processing authorizer {d}/{d} for core {d}", .{ i + 1, authorizers.len, core });
        auth_span.trace("Auth hash: {s}", .{std.fmt.fmtSliceHexLower(&auth_hash)});

        // Validate core index
        if (core >= params.core_count) {
            auth_span.warn("Invalid core: {d} (max: {d})", .{ core, params.core_count - 1 });
            return error.InvalidCore;
        }

        // Check if the auth is already in the pool
        const is_authorized = alpha_prime.isAuthorized(core, auth_hash);
        auth_span.trace("Auth in pool check result: {}", .{is_authorized});

        if (is_authorized) {
            auth_span.debug("Auth already in pool for core {d}, removing", .{core});

            const remove_span = auth_span.child(.remove_authorizer);
            defer remove_span.deinit();
            alpha_prime.removeAuthorizer(core, auth_hash);
            remove_span.debug("Successfully removed authorizer from pool", .{});
        } else {
            auth_span.debug("Auth not in pool for core {d}, nothing to remove", .{core});
        }
    }

    // Postcondition: all valid authorizers have been processed
    std.debug.assert(true); // Placeholder for more specific postcondition
}

// Process authorization rotation for all cores
fn processAuthorizationRotation(
    comptime params: Params,
    alpha_prime: anytype,
    phi_prime: anytype,
    current_slot: types.TimeSlot,
    parent_span: anytype,
) !void {
    // Preconditions
    comptime {
        std.debug.assert(params.core_count > 0);
    }

    const authorization_rotation_span = parent_span.child(.rotation);
    defer authorization_rotation_span.deinit();
    authorization_rotation_span.debug("Processing authorization rotation across {d} cores", .{params.core_count});

    for (0..params.core_count) |core_index| {
        try rotateAuthorizationForCore(
            params,
            alpha_prime,
            phi_prime,
            @intCast(core_index),
            current_slot,
            authorization_rotation_span,
        );
    }
}

// Rotate authorization for a single core
fn rotateAuthorizationForCore(
    comptime params: Params,
    alpha_prime: anytype,
    phi_prime: anytype,
    core_index: types.CoreIndex,
    current_slot: types.TimeSlot,
    parent_span: anytype,
) !void {
    // Preconditions
    std.debug.assert(core_index < params.core_count);

    const core_span = parent_span.child(.core);
    defer core_span.deinit();
    core_span.debug("Processing core {d}", .{core_index});

    const queue_items = try phi_prime.getQueue(core_index);
    core_span.trace("Queue items for core {d}: {d} available", .{ core_index, queue_items.len });

    std.debug.assert(queue_items.len == params.max_authorizations_queue_items);

    const auth_index = @mod(current_slot, params.max_authorizations_queue_items);
    core_span.trace("Selected auth index {d} for slot {d}", .{ auth_index, current_slot });

    const selected_auth = queue_items[auth_index];
    core_span.debug("Adding auth from queue to pool: {s}", .{std.fmt.fmtSliceHexLower(&selected_auth)});

    const add_span = core_span.child(.add_authorizer);
    defer add_span.deinit();

    try addAuthorizerToPool(params, alpha_prime, core_index, selected_auth);

    add_span.debug("Successfully added authorizer to pool", .{});
}

// Add an authorizer to a core's pool, managing capacity
fn addAuthorizerToPool(
    comptime params: Params,
    alpha_prime: anytype,
    core_index: types.CoreIndex,
    auth_hash: types.OpaqueHash,
) !void {
    // Preconditions
    std.debug.assert(core_index < params.core_count);
    std.debug.assert(auth_hash.len == @sizeOf(types.OpaqueHash));

    var authorization_pool = &alpha_prime.pools[core_index];
    const initial_pool_size = authorization_pool.len;

    // Check if the pool is already at maximum capacity
    if (authorization_pool.len >= params.max_authorizations_pool_items) {
        // Pool is full, shift everything down by one position (removing the oldest)
        const pool_slice = authorization_pool.slice();
        std.debug.assert(pool_slice.len > 0);

        for (0..pool_slice.len - 1) |i| {
            pool_slice[i] = pool_slice[i + 1];
        }

        // Set the new auth at the last position
        pool_slice[pool_slice.len - 1] = auth_hash;

        // Postcondition: pool size unchanged
        std.debug.assert(authorization_pool.len == initial_pool_size);
    } else {
        // Pool has space, simply append the new auth
        try authorization_pool.append(auth_hash);

        // Postcondition: pool size increased by 1
        std.debug.assert(authorization_pool.len == initial_pool_size + 1);
    }
}

pub fn verifyAuthorizationsExtrinsicPre(
    comptime params: anytype,
    authorizers: []const CoreAuthorizer,
    slot: types.TimeSlot,
) !void {
    // Preconditions
    std.debug.assert(authorizers.len <= params.core_count);

    const span = trace.span(.verify_pre);
    defer span.deinit();

    span.debug("Pre-verification of authorizations for slot {d}", .{slot});
    span.trace("Number of authorizers: {d}", .{authorizers.len});
    span.trace("Parameters: core_count={d}", .{params.core_count});

    // Validate all core indices are within bounds
    for (authorizers) |authorizer| {
        if (authorizer.core >= params.core_count) {
            span.err("Invalid core index: {d} >= {d}", .{ authorizer.core, params.core_count });
            return error.InvalidCore;
        }
    }

    span.debug("Pre-verification passed", .{});

    // Postcondition: all authorizers have valid core indices
    std.debug.assert(true);
}

pub fn verifyAuthorizationsExtrinsicPost(
    comptime params: anytype,
    alpha_prime: anytype,
    phi_prime: anytype,
    authorizers: []const CoreAuthorizer,
) !void {
    // Preconditions
    std.debug.assert(authorizers.len <= params.core_count);
    std.debug.assert(alpha_prime.pools.len == params.core_count);
    std.debug.assert(phi_prime.queue.len == params.core_count);

    const span = trace.span(.verify_post);
    defer span.deinit();

    span.debug("Post-verification of authorizations", .{});
    span.trace("Number of authorizers: {d}", .{authorizers.len});
    span.trace("Parameters: core_count={d}", .{params.core_count});

    // Report alpha_prime and phi_prime state (debugging purposes)
    span.trace("Alpha prime pool size by core:", .{});
    for (0..params.core_count) |core_index| {
        const pool_size = alpha_prime.pools[core_index].len;
        span.trace("  Core {d}: {d} authorizers", .{ core_index, pool_size });

        // Verify pool size is within bounds
        std.debug.assert(pool_size <= params.max_authorizations_pool_items);
    }

    span.trace("Phi prime queue size by core:", .{});
    for (0..params.core_count) |core_index| {
        const queue_size = phi_prime.getQueueLength(core_index);
        span.trace("  Core {d}: {d} authorizers", .{ core_index, queue_size });

        // Verify queue size is within bounds
        std.debug.assert(queue_size <= params.max_authorizations_queue_items);
    }

    span.debug("Post-verification passed", .{});
}
