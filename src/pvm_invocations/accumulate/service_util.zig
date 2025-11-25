const std = @import("std");

const types = @import("../../types.zig");
const state = @import("../../state.zig");
const codec = @import("../../codec.zig");

const trace = @import("tracing").scoped(.accumulate);

/// Checks if a service ID is available and finds the next available one if not
/// As defined in B.13 of the graypaper
pub fn check(service_accounts: *const state.Delta.Snapshot, candidate_id: types.ServiceId) types.ServiceId {
    const span = trace.span(@src(), .check_service_id);
    defer span.deinit();
    span.debug("Checking service ID availability: {d}", .{candidate_id});

    // If the ID is not already used, return it
    if (service_accounts.contains(candidate_id) == false) {
        span.debug("Service ID {d} is available", .{candidate_id});
        return candidate_id;
    }

    span.debug("Service ID {d} is already used, calculating next ID", .{candidate_id});

    // Otherwise, calculate the next candidate in the sequence
    // v0.7.1 GP #473: check((i - 2^8 + 1) mod (2^32 - 2^8 - 2^8) + 2^8)
    // Reserved: [0, 256) lower + [2^32-256, 2^32) upper = 512 total
    const next_id: u32 = 0x100 + ((candidate_id - 0x100 + 1) % @as(u32, @intCast(std.math.pow(u64, 2, 32) - 0x200)));
    span.debug("Next candidate ID: {d}", .{next_id});

    // Recursive call to check the next candidate
    return check(service_accounts, next_id);
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

    // v0.7.1 GP #473: take first 4 bytes of hash mod (2^32 - 2^8 - 2^8) + 2^8
    // Available range: [256, 2^32-256) to avoid privileged and top reserved ranges
    const initial_value = std.mem.readInt(u32, hash_output[0..4], .little);
    const candidate_id = 0x100 + (initial_value % @as(u32, @intCast(std.math.pow(u64, 2, 32) - 0x200)));
    span.debug("Initial candidate ID: {d}", .{candidate_id});

    // Check if this ID is available, and find next available if not
    const final_id = check(service_accounts, candidate_id);
    span.debug("Final service ID: {d}", .{final_id});
    return final_id;
}
