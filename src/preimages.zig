const std = @import("std");
const types = @import("types.zig");
const state = @import("state.zig");
const state_delta = @import("state_delta.zig");

const Params = @import("jam_params.zig").Params;

// Add tracing import
const trace = @import("tracing.zig").scoped(.preimages);

/// Compares two preimages for ordering
fn comparePreimages(lhs: types.Preimage, rhs: types.Preimage) bool {
    // First compare by requester
    if (lhs.requester != rhs.requester) {
        return lhs.requester < rhs.requester;
    }

    // If requesters are equal, compare the blobs lexicographically
    const min_len = @min(lhs.blob.len, rhs.blob.len);

    // Compare byte by byte
    for (0..min_len) |i| {
        if (lhs.blob[i] != rhs.blob[i]) {
            return lhs.blob[i] < rhs.blob[i];
        }
    }

    // If all bytes compared so far are equal, shorter blob comes first
    return lhs.blob.len < rhs.blob.len;
}

/// Processes preimage extrinsics
pub fn processPreimagesExtrinsic(
    comptime params: Params,
    stx: *state_delta.StateTransition(params),
    preimages: types.PreimagesExtrinsic,
) !void {
    const span = trace.span(.process_preimages_extrinsic);
    defer span.deinit();

    span.debug("Starting preimages extrinsic processing with {d} preimages", .{preimages.data.len});

    // Validate uniqueness and ordering of preimages
    if (preimages.data.len > 1) {
        // Check that preimages are ordered by requester and then by blob content
        for (preimages.data[0 .. preimages.data.len - 1], preimages.data[1..]) |prev, curr| {
            // Compare using our ordering function
            if (!comparePreimages(prev, curr)) {
                // If not in ascending order, check if they're equal (which would be a duplicate)
                if (prev.requester == curr.requester) {
                    // Check if blobs are identical
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

    // Ensure the delta prime state is available
    var delta_prime: *state.Delta = try stx.ensure(.delta_prime);

    // Process each preimage
    for (preimages.data, 0..) |preimage, i| {
        const preimage_span = span.child(.process_preimage);
        defer preimage_span.deinit();

        preimage_span.debug("Processing preimage {d} for service {d}", .{ i, preimage.requester });

        // Calculate the preimage hash
        const preimage_hash = try calculatePreimageHash(preimage.blob);
        preimage_span.debug("Calculated hash: {s}", .{std.fmt.fmtSliceHexLower(&preimage_hash)});

        // Check if service exists
        const service_id = preimage.requester;
        var service_account = delta_prime.getAccount(service_id) orelse {
            preimage_span.err("Service account {d} not found", .{service_id});
            return error.UnknownServiceAccount;
        };

        // Check if preimage hash is already recorded
        if (!service_account.needsPreImage(preimage_hash, @intCast(preimage.blob.len), stx.time.current_slot)) {
            preimage_span.err("Preimage not needed for service {d}, hash: {s}", .{ service_id, std.fmt.fmtSliceHexLower(&preimage_hash) });
            return error.PreimageUnneeded;
        }

        // Add the preimage to the service account
        try service_account.addPreimage(preimage_hash, preimage.blob);
        preimage_span.debug("Added preimage to service {d}", .{service_id});

        // Update the lookup metadata
        try service_account.registerPreimageAvailable(
            preimage_hash,
            @intCast(preimage.blob.len),
            stx.time.current_slot,
        );
        preimage_span.debug("Updated lookup metadata for service {d}", .{service_id});
    }

    span.debug("Completed preimages extrinsic processing", .{});
}

/// Calculate hash of a preimage blob
fn calculatePreimageHash(blob: []const u8) !types.OpaqueHash {
    var hash: types.OpaqueHash = undefined;
    std.crypto.hash.blake2.Blake2b256.hash(blob, &hash, .{});
    return hash;
}
