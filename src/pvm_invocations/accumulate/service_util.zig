const std = @import("std");

const types = @import("../../types.zig");
const state = @import("../../state.zig");
const codec = @import("../../codec.zig");

const trace = @import("tracing").scoped(.accumulate);

/// C_minpublicindex = 2^16 - minimum public service index
/// Services below this can only be created by the Registrar (graypaper definitions.tex)
const C_MIN_PUBLIC_INDEX: u32 = 0x10000; // 65536 = 2^16

// (graypaper eq. newserviceindex)
pub fn check(service_accounts: *const state.Delta.Snapshot, candidate_id: types.ServiceId) types.ServiceId {
    const span = trace.span(@src(), .check_service_id);
    defer span.deinit();

    // Available range: [C_minpublicindex, 2^32-256)
    const modulo: u32 = @intCast(std.math.pow(u64, 2, 32) - 0x100 - C_MIN_PUBLIC_INDEX);

    var current_id = candidate_id;
    var iterations: u32 = 0;

    while (iterations < modulo) : (iterations += 1) {
        if (!service_accounts.contains(current_id)) {
            span.debug("Service ID {d} available after {d} iterations", .{ current_id, iterations });
            return current_id;
        }
        current_id = C_MIN_PUBLIC_INDEX + ((current_id - C_MIN_PUBLIC_INDEX + 1) % modulo);
    }

    // Should never reach here - would mean all ~4B service IDs are taken
    unreachable;
}

/// Generates a deterministic service ID based on creator service, entropy, and timeslot
/// As defined in B.9 of the graypaper
pub fn generateServiceId(service_accounts: *const state.Delta.Snapshot, creator_id: types.ServiceId, entropy: [32]u8, timeslot: u32) types.ServiceId {
    const span = trace.span(@src(), .generate_service_id);
    defer span.deinit();
    span.debug("Generating service ID - creator: {d}, timeslot: {d}", .{ creator_id, timeslot });
    span.trace("Entropy: {s}", .{std.fmt.fmtSliceHexLower(&entropy)});

    // Create input for hash: service ID + entropy + timeslot
    // According to graypaper B.9: encode(s, η'_0, H_t)
    // Use varint encoding for integers as per JAM codec specification
    var hash_input_buf: [9 + 32 + 9]u8 = undefined; // Max size for two varint-encoded u32s + entropy
    var offset: usize = 0;

    // Encode service ID using varint encoding FIRST
    const service_id_encoded = codec.encoder.encodeInteger(creator_id);
    std.mem.copyForwards(u8, hash_input_buf[offset..], service_id_encoded.as_slice());
    offset += service_id_encoded.len;

    // Copy entropy (32 bytes) SECOND
    std.mem.copyForwards(u8, hash_input_buf[offset..offset + 32], &entropy);
    offset += 32;

    // Encode timeslot using varint encoding THIRD
    const timeslot_encoded = codec.encoder.encodeInteger(timeslot);
    std.mem.copyForwards(u8, hash_input_buf[offset..], timeslot_encoded.as_slice());
    offset += timeslot_encoded.len;

    const hash_input = hash_input_buf[0..offset];
    span.trace("Hash input: {s}", .{std.fmt.fmtSliceHexLower(hash_input)});

    // Hash the input using Blake2b-256
    var hash_output: [32]u8 = undefined;
    std.crypto.hash.blake2.Blake2b256.hash(hash_input, &hash_output, .{});
    span.trace("Hash output: {s}", .{std.fmt.fmtSliceHexLower(&hash_output)});

    // Graypaper: (decode[4]{hash} mod (2^32 - C_minpublicindex - 2^8)) + C_minpublicindex
    // Available range: [C_minpublicindex, 2^32-256) = [65536, 2^32-256)
    const initial_value = std.mem.readInt(u32, hash_output[0..4], .little);
    const modulo: u32 = @intCast(std.math.pow(u64, 2, 32) - C_MIN_PUBLIC_INDEX - 0x100);
    const candidate_id = C_MIN_PUBLIC_INDEX + (initial_value % modulo);
    span.debug("Initial candidate ID: {d}", .{candidate_id});

    // Check if this ID is available, and find next available if not
    const final_id = check(service_accounts, candidate_id);
    span.debug("Final service ID: {d}", .{final_id});
    return final_id;
}
