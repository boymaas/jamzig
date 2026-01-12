const std = @import("std");
const testing = std.testing;
const guarantor = @import("guarantor_assignments.zig");
const jam_params = @import("jam_params.zig");
const types = @import("types.zig");

test "rotateAssignments" {
    const allocator = std.testing.allocator;

    const cores = [_]u32{ 0, 1, 2, 3 };

    var result = try allocator.dupe(u32, &cores);
    guarantor.rotateAssignments(4, result, 0);
    try testing.expectEqualSlices(u32, &cores, result);
    allocator.free(result);

    result = try allocator.dupe(u32, &cores);
    guarantor.rotateAssignments(4, result, 1);
    try testing.expectEqual(result[0], cores[1]);
    try testing.expectEqual(result[1], cores[2]);
    try testing.expectEqual(result[2], cores[3]);
    try testing.expectEqual(result[3], cores[0]);
    allocator.free(result);

    result = try allocator.dupe(u32, &cores);
    guarantor.rotateAssignments(4, result, 4);
    try testing.expectEqualSlices(u32, &cores, result);
    allocator.free(result);
}

test "permuteAssignments" {
    var allocator = testing.allocator;

    const PARAMS = jam_params.FULL_PARAMS;

    var entropy: [32]u8 = undefined;
    for (&entropy, 0..) |*byte, i| {
        byte.* = @truncate(i);
    }

    const result = try guarantor.permuteAssignments(PARAMS, allocator, entropy, 0);
    defer allocator.free(result);

    try testing.expectEqual(PARAMS.validators_count, result.len);

    var found = [_]u8{0} ** PARAMS.core_count;
    for (result) |core| {
        try testing.expect(core < PARAMS.core_count);
        found[core] += 1;
    }

    const validators_per_core = PARAMS.validators_count / PARAMS.core_count;
    for (found) |was_found| {
        try testing.expectEqual(was_found, validators_per_core);
    }
}

test "buildForTimeSlot" {
    const allocator = testing.allocator;

    const PARAMS = jam_params.FULL_PARAMS;

    var entropy: [32]u8 = undefined;
    for (&entropy, 0..) |*byte, i| {
        byte.* = @truncate(i);
    }

    var validators = [_]types.ValidatorData{undefined} ** PARAMS.validators_count;
    for (&validators, 0..) |*validator, i| {
        @memset(&validator.ed25519, @truncate(i + 1));
    }

    var result = try guarantor.buildForTimeSlot(
        PARAMS,
        allocator,
        entropy,
        0,
    );
    defer result.deinit(allocator);

    try testing.expectEqual(PARAMS.validators_count, result.assignments.len);

    var found = [_]u8{0} ** PARAMS.core_count;
    for (result.assignments) |core| {
        try testing.expect(core < PARAMS.core_count);
        found[core] += 1;
    }

    const validators_per_core = PARAMS.validators_count / PARAMS.core_count;
    for (found) |was_found| {
        try testing.expectEqual(was_found, validators_per_core);
    }
}
