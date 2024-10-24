const std = @import("std");
const types = @import("types.zig");
const jamstate = @import("state.zig");
const state_encoder = @import("state_encoding.zig");

/// State constructor function C which generates state keys
pub fn stateKeyConstructor(key_input: anytype) ![32]u8 {
    var result: [32]u8 = [_]u8{0} ** 32;

    switch (@TypeOf(key_input)) {
        // Simple byte input: [i, 0, 0, ...]
        u8 => {
            result[0] = key_input;
        },
        // Byte + service index tuple: [i, n₀, n₁, n₂, n₃, 0, 0, ...]
        struct { u8, u32 } => {
            const i = key_input[0];
            const s = key_input[1];

            result[0] = i;
            std.mem.writeInt(u32, result[1..5], s, .little);
        },
        // Service index + hash tuple: [n₀, h₀, n₁, h₁, n₂, h₂, n₃, h₃, h₄, h₅, ..., h₂₇]
        struct { u32, [32]u8 } => {
            const s = key_input[0];
            const h = key_input[1];

            // Write service index in pieces
            var service_bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &service_bytes, s, .little);

            // Interleave service bytes with hash
            result[0] = service_bytes[0];
            result[1] = h[0];
            result[2] = service_bytes[1];
            result[3] = h[1];
            result[4] = service_bytes[2];
            result[5] = h[2];
            result[6] = service_bytes[3];
            result[7] = h[3];

            // Copy remaining hash bytes
            std.mem.copy(u8, result[8..], h[4..28]);
        },
        else => {
            return error.InvalidInput;
        },
    }

    return result;
}

/// Maps a state component to its encoding using the appropriate state key
pub fn buildStateMerklizationMap(
    allocator: std.mem.Allocator,
    state: *const jamstate.JamState,
) !std.AutoHashMap([32]u8, []const u8) {
    var map = std.AutoHashMap([32]u8, []const u8).init(allocator);
    errdefer map.deinit();

    // Encode the simple state components
    inline for (comptime std.meta.fieldNames(types.JamState)) |field_name| {
        //const field_info = @typeInfo(@TypeOf(@field(state, field_name)));
        const field_num = comptime switch (field_name[0]) {
            'a' => 1, // alpha
            'p' => switch (field_name[1]) {
                'h' => 2, // phi
                'i' => 13, // pi
                's' => 5, // psi
                else => unreachable,
            },
            'b' => 3, // beta
            'g' => 4, // gamma
            'e' => 6, // eta
            'i' => 7, // iota
            'k' => 8, // kappa
            'l' => 9, // lambda
            'r' => 10, // rho
            't' => switch (field_name[1]) {
                'a' => 11, // tau
                'h' => 14, // theta
                else => unreachable,
            },
            'c' => 12, // chi
            // pi is handled above
            'x' => 15, // xi
            'd' => 255, // delta (special case handled below)
            else => unreachable,
        };

        if (field_num < 255) { // Skip delta for special handling
            const key = try stateKeyConstructor(allocator, @as(u8, field_num));
            var value = std.ArrayList(u8).init(allocator);
            defer value.deinit();

            try state_encoder.encode(@field(state, field_name), value.writer());
            try map.put(key, try value.toOwnedSlice());
        }
    }

    // Handle delta component (service accounts) specially
    if (state.delta.accounts.count() > 0) {
        var service_iter = state.delta.accounts.iterator();
        while (service_iter.next()) |service_entry| {
            const service_idx = service_entry.key_ptr.*;
            const account = service_entry.value_ptr;

            // Base account data
            const base_key = try stateKeyConstructor(allocator, .{ @as(u8, 255), service_idx });
            var base_value = std.ArrayList(u8).init(allocator);
            try state_encoder.encodeServiceAccountBase(account, base_value.writer());
            try map.put(base_key, try base_value.toOwnedSlice());

            // Storage entries
            var storage_iter = account.storage.iterator();
            while (storage_iter.next()) |storage_entry| {
                const storage_key = try stateKeyConstructor(allocator, .{ service_idx, storage_entry.key_ptr.* });
                try map.put(storage_key, storage_entry.value_ptr.*);
            }

            // Preimage lookups
            var preimage_iter = account.preimages.iterator();
            while (preimage_iter.next()) |preimage_entry| {
                const preimage_key = try stateKeyConstructor(allocator, .{ service_idx, preimage_entry.key_ptr.* });
                try map.put(preimage_key, preimage_entry.value_ptr.*);
            }

            // Preimage timestamps
            var lookup_iter = account.preimage_lookups.iterator();
            while (lookup_iter.next()) |lookup_entry| {
                const key = lookup_entry.key_ptr.*;
                var modified_hash = key.hash;
                for (modified_hash[4..]) |*byte| {
                    byte.* = ~byte.*;
                }

                var timestamp_key = try stateKeyConstructor(allocator, .{ service_idx, modified_hash });
                var timestamp_value = std.ArrayList(u8).init(allocator);
                try state_encoder.encodePreimageLookup(lookup_entry.value_ptr.*, timestamp_value.writer());
                try map.put(timestamp_key, try timestamp_value.toOwnedSlice());
            }
        }
    }

    return map;
}
