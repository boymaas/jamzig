const std = @import("std");
const types = @import("types.zig");
const state = @import("state.zig");
const state_delta = @import("state_delta.zig");
const state_keys = @import("state_keys.zig");

const Params = @import("jam_params.zig").Params;

const trace = @import("tracing").scoped(.preimages);

fn comparePreimages(lhs: types.Preimage, rhs: types.Preimage) bool {
    if (lhs.requester != rhs.requester) {
        return lhs.requester < rhs.requester;
    }

    const min_len = @min(lhs.blob.len, rhs.blob.len);

    for (0..min_len) |i| {
        if (lhs.blob[i] != rhs.blob[i]) {
            return lhs.blob[i] < rhs.blob[i];
        }
    }

    return lhs.blob.len < rhs.blob.len;
}

pub fn processPreimagesExtrinsic(
    comptime params: Params,
    stx: *state_delta.StateTransition(params),
    preimages: types.PreimagesExtrinsic,
) !void {
    const span = trace.span(@src(), .process_preimages_extrinsic);
    defer span.deinit();

    span.debug("Starting preimages extrinsic processing with {d} preimages", .{preimages.data.len});

    if (preimages.data.len > 1) {
        for (preimages.data[0 .. preimages.data.len - 1], preimages.data[1..]) |prev, curr| {
            if (!comparePreimages(prev, curr)) {
                if (prev.requester == curr.requester) {
                    const prev_hash = try calculatePreimageHash(prev.blob);
                    const curr_hash = try calculatePreimageHash(curr.blob);

                    if (std.mem.eql(u8, &prev_hash, &curr_hash)) {
                        span.err("Duplicate preimage found for requester {d}", .{prev.requester});
                        return error.DuplicatePreimage;
                    }

                    span.err("Preimages are not correctly ordered for requester {d}", .{prev.requester});
                } else {
                    span.err("Preimages are not ordered by requester: {d} > {d}", .{ prev.requester, curr.requester });
                }
                return error.PreimagesNotOrdered;
            }
        }
    }

    const base_delta: *const state.Delta = &stx.base.delta.?;

    const delta_prime: *state.Delta = try stx.ensure(.delta_prime);

    for (preimages.data, 0..) |preimage, i| {
        const preimage_span = span.child(@src(), .process_preimage);
        defer preimage_span.deinit();

        preimage_span.debug("Processing preimage {d} for service {d}", .{ i, preimage.requester });

        const preimage_hash = try calculatePreimageHash(preimage.blob);
        preimage_span.debug("Calculated hash: {s}", .{std.fmt.fmtSliceHexLower(&preimage_hash)});

        const service_id = preimage.requester;
        const preimage_len: u32 = @intCast(preimage.blob.len);

        const base_account = base_delta.getAccount(service_id) orelse {
            preimage_span.err("Service account {d} not found in base state", .{service_id});
            return error.UnknownServiceAccount;
        };

        if (!base_account.needsPreImage(service_id, preimage_hash, preimage_len, stx.time.current_slot)) {
            preimage_span.err("Preimage not needed in base state for service {d}, hash: {s}", .{ service_id, std.fmt.fmtSliceHexLower(&preimage_hash) });
            return error.PreimageUnneeded;
        }

        const prime_account = delta_prime.getAccount(service_id) orelse {
            preimage_span.debug("Service {d} no longer exists in prime state, skipping integration", .{service_id});
            continue;
        };

        if (!prime_account.needsPreImage(service_id, preimage_hash, preimage_len, stx.time.current_slot)) {
            preimage_span.debug("Preimage no longer needed in prime state (forgotten during accumulation), skipping", .{});
            continue;
        }

        const preimage_key = state_keys.constructServicePreimageKey(service_id, preimage_hash);
        try prime_account.dupeAndAddPreimage(preimage_key, preimage.blob);
        preimage_span.debug("Added preimage to service {d}", .{service_id});

        try prime_account.registerPreimageAvailable(
            service_id,
            preimage_hash,
            preimage_len,
            stx.time.current_slot,
        );
        preimage_span.debug("Updated lookup metadata for service {d}", .{service_id});
    }

    span.debug("Completed preimages extrinsic processing", .{});
}

fn calculatePreimageHash(blob: []const u8) !types.OpaqueHash {
    var hash: types.OpaqueHash = undefined;
    std.crypto.hash.blake2.Blake2b256.hash(blob, &hash, .{});
    return hash;
}
