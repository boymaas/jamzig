const std = @import("std");

const types = @import("../../types.zig");
const state = @import("../../state.zig");

const trace = @import("../../tracing.zig").scoped(.accumulate);

/// Checks if a service ID is available and finds the next available one if not
/// As defined in B.13 of the graypaper
pub fn check(service_accounts: *state.Delta, candidate_id: types.ServiceId) types.ServiceId {
    const span = trace.span(.check_service_id);
    defer span.deinit();
    span.debug("Checking service ID availability: {d}", .{candidate_id});

    // If the ID is not already used, return it
    if (service_accounts.getAccount(candidate_id) == null) {
        span.debug("Service ID {d} is available", .{candidate_id});
        return candidate_id;
    }

    span.debug("Service ID {d} is already used, calculating next ID", .{candidate_id});

    // Otherwise, calculate the next candidate in the sequence
    // The formula is: check((i - 2^8 + 1) mod (2^32 - 2^9) + 2^8)
    const next_id = 0x100 + ((candidate_id - 0x100 + 1) % (std.math.maxInt(u32) - 0x200));
    span.debug("Next candidate ID: {d}", .{next_id});

    // Recursive call to check the next candidate
    return check(service_accounts, next_id);
}

/// Generates a deterministic service ID based on creator service, entropy, and timeslot
/// As defined in B.9 of the graypaper
pub fn generateServiceId(service_accounts: *state.Delta, creator_id: types.ServiceId, entropy: [32]u8, timeslot: u32) types.ServiceId {
    const span = trace.span(.generate_service_id);
    defer span.deinit();
    span.debug("Generating service ID - creator: {d}, timeslot: {d}", .{ creator_id, timeslot });
    span.trace("Entropy: {s}", .{std.fmt.fmtSliceHexLower(&entropy)});

    // Create input for hash: service ID + entropy + timeslot
    var hash_input: [32 + 4 + 4]u8 = undefined;

    // Copy service ID as bytes (4 bytes in little-endian format)
    std.mem.writeInt(u32, hash_input[0..4], creator_id, .little);

    // Copy entropy (32 bytes)
    std.mem.copyForwards(u8, hash_input[4..36], &entropy);

    // Copy timeslot (4 bytes in little-endian format)
    std.mem.writeInt(u32, hash_input[36..40], timeslot, .little);
    span.trace("Hash input: {s}", .{std.fmt.fmtSliceHexLower(&hash_input)});

    // Hash the input using Blake2b-256
    var hash_output: [32]u8 = undefined;
    std.crypto.hash.blake2.Blake2b256.hash(&hash_input, &hash_output, .{});
    span.trace("Hash output: {s}", .{std.fmt.fmtSliceHexLower(&hash_output)});

    // Generate initial ID: take first 4 bytes of hash mod (2^32 - 2^9) + 2^8
    const initial_value = std.mem.readInt(u32, hash_output[0..4], .little);
    const candidate_id = 0x100 + (initial_value % (std.math.maxInt(u32) - 0x200));
    span.debug("Initial candidate ID: {d}", .{candidate_id});

    // Check if this ID is available, and find next available if not
    const final_id = check(service_accounts, candidate_id);
    span.debug("Final service ID: {d}", .{final_id});
    return final_id;
}
