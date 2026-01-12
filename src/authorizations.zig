const std = @import("std");
const trace = @import("tracing").scoped(.authorizations);
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

pub fn processAuthorizations(
    comptime params: Params,
    stx: *state_delta.StateTransition(params),
    authorizers: []const CoreAuthorizer,
) !void {
    std.debug.assert(authorizers.len <= params.core_count);
    comptime {
        std.debug.assert(params.core_count > 0);
        std.debug.assert(params.max_authorizations_pool_items > 0);
        std.debug.assert(params.max_authorizations_queue_items > 0);
    }

    const span = trace.span(@src(), .process_authorizations);
    defer span.deinit();

    span.debug("Processing authorizations for slot {d}", .{stx.time.current_slot});
    span.debug("Number of core authorizers: {d}", .{authorizers.len});

    const alpha_prime: *state.Alpha(params.core_count, params.max_authorizations_pool_items) =
        try stx.ensure(.alpha_prime);

    const phi_prime: *state.Phi(params.core_count, params.max_authorizations_queue_items) =
        try stx.ensure(.phi_prime);

    try processInputAuthorizers(params, alpha_prime, authorizers, span);

    try processAuthorizationRotation(params, alpha_prime, phi_prime, stx.time.current_slot, span);

    span.debug("Authorization processing complete for slot {d}", .{stx.time.current_slot});
}

fn processInputAuthorizers(
    comptime params: Params,
    alpha_prime: anytype,
    authorizers: []const CoreAuthorizer,
    parent_span: anytype,
) !void {
    std.debug.assert(authorizers.len <= params.core_count);

    const process_span = parent_span.child(@src(), .process_authorizers);
    defer process_span.deinit();
    process_span.debug("Processing {d} input authorizers", .{authorizers.len});

    for (authorizers, 0..) |authorizer, i| {
        const auth_span = process_span.child(@src(), .authorizer);
        defer auth_span.deinit();

        const core = authorizer.core;
        const auth_hash = authorizer.auth_hash;

        auth_span.debug("Processing authorizer {d}/{d} for core {d}", .{ i + 1, authorizers.len, core });
        auth_span.trace("Auth hash: {s}", .{std.fmt.fmtSliceHexLower(&auth_hash)});

        if (core >= params.core_count) {
            auth_span.warn("Invalid core: {d} (max: {d})", .{ core, params.core_count - 1 });
            return error.InvalidCore;
        }

        const is_authorized = alpha_prime.isAuthorized(core, auth_hash);
        auth_span.trace("Auth in pool check result: {}", .{is_authorized});

        if (is_authorized) {
            auth_span.debug("Auth already in pool for core {d}, removing", .{core});

            const remove_span = auth_span.child(@src(), .remove_authorizer);
            defer remove_span.deinit();
            alpha_prime.removeAuthorizer(core, auth_hash);
            remove_span.debug("Successfully removed authorizer from pool", .{});
        } else {
            auth_span.debug("Auth not in pool for core {d}, nothing to remove", .{core});
        }
    }

    std.debug.assert(true);
}

fn processAuthorizationRotation(
    comptime params: Params,
    alpha_prime: anytype,
    phi_prime: anytype,
    current_slot: types.TimeSlot,
    parent_span: anytype,
) !void {
    comptime {
        std.debug.assert(params.core_count > 0);
    }

    const authorization_rotation_span = parent_span.child(@src(), .rotation);
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

fn rotateAuthorizationForCore(
    comptime params: Params,
    alpha_prime: anytype,
    phi_prime: anytype,
    core_index: types.CoreIndex,
    current_slot: types.TimeSlot,
    parent_span: anytype,
) !void {
    std.debug.assert(core_index < params.core_count);

    const core_span = parent_span.child(@src(), .core);
    defer core_span.deinit();
    core_span.debug("Processing core {d}", .{core_index});

    const queue_items = try phi_prime.getQueue(core_index);
    core_span.trace("Queue items for core {d}: {d} available", .{ core_index, queue_items.len });

    std.debug.assert(queue_items.len == params.max_authorizations_queue_items);

    const auth_index = @mod(current_slot, params.max_authorizations_queue_items);
    core_span.trace("Selected auth index {d} for slot {d}", .{ auth_index, current_slot });

    const selected_auth = queue_items[auth_index];
    core_span.debug("Adding auth from queue to pool: {s}", .{std.fmt.fmtSliceHexLower(&selected_auth)});

    const add_span = core_span.child(@src(), .add_authorizer);
    defer add_span.deinit();

    try addAuthorizerToPool(params, alpha_prime, core_index, selected_auth);

    add_span.debug("Successfully added authorizer to pool", .{});
}

fn addAuthorizerToPool(
    comptime params: Params,
    alpha_prime: anytype,
    core_index: types.CoreIndex,
    auth_hash: types.OpaqueHash,
) !void {
    std.debug.assert(core_index < params.core_count);
    std.debug.assert(auth_hash.len == @sizeOf(types.OpaqueHash));

    var authorization_pool = &alpha_prime.pools[core_index];
    const initial_pool_size = authorization_pool.len;

    if (authorization_pool.len >= params.max_authorizations_pool_items) {
        const pool_slice = authorization_pool.slice();
        std.debug.assert(pool_slice.len > 0);

        for (0..pool_slice.len - 1) |i| {
            pool_slice[i] = pool_slice[i + 1];
        }

        pool_slice[pool_slice.len - 1] = auth_hash;

        std.debug.assert(authorization_pool.len == initial_pool_size);
    } else {
        try authorization_pool.append(auth_hash);

        std.debug.assert(authorization_pool.len == initial_pool_size + 1);
    }
}

pub fn verifyAuthorizationsExtrinsicPre(
    comptime params: anytype,
    authorizers: []const CoreAuthorizer,
    slot: types.TimeSlot,
) !void {
    std.debug.assert(authorizers.len <= params.core_count);

    const span = trace.span(@src(), .verify_pre);
    defer span.deinit();

    span.debug("Pre-verification of authorizations for slot {d}", .{slot});
    span.trace("Number of authorizers: {d}", .{authorizers.len});
    span.trace("Parameters: core_count={d}", .{params.core_count});

    for (authorizers) |authorizer| {
        if (authorizer.core >= params.core_count) {
            span.err("Invalid core index: {d} >= {d}", .{ authorizer.core, params.core_count });
            return error.InvalidCore;
        }
    }

    span.debug("Pre-verification passed", .{});

    std.debug.assert(true);
}

pub fn verifyAuthorizationsExtrinsicPost(
    comptime params: anytype,
    alpha_prime: anytype,
    phi_prime: anytype,
    authorizers: []const CoreAuthorizer,
) !void {
    std.debug.assert(authorizers.len <= params.core_count);
    std.debug.assert(alpha_prime.pools.len == params.core_count);
    std.debug.assert(phi_prime.queue.len == params.core_count);

    const span = trace.span(@src(), .verify_post);
    defer span.deinit();

    span.debug("Post-verification of authorizations", .{});
    span.trace("Number of authorizers: {d}", .{authorizers.len});
    span.trace("Parameters: core_count={d}", .{params.core_count});

    span.trace("Alpha prime pool size by core:", .{});
    for (0..params.core_count) |core_index| {
        const pool_size = alpha_prime.pools[core_index].len;
        span.trace("  Core {d}: {d} authorizers", .{ core_index, pool_size });

        std.debug.assert(pool_size <= params.max_authorizations_pool_items);
    }

    span.trace("Phi prime queue size by core:", .{});
    for (0..params.core_count) |core_index| {
        const queue_size = phi_prime.getQueueLength(core_index);
        span.trace("  Core {d}: {d} authorizers", .{ core_index, queue_size });

        std.debug.assert(queue_size <= params.max_authorizations_queue_items);
    }

    span.debug("Post-verification passed", .{});
}
