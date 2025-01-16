const std = @import("std");

const SeedGenerator = @import("../seed.zig").SeedGenerator;
const igen = @import("instruction_generator.zig");

/// Generate a sequence of random instructions
pub fn generate(allocator: std.mem.Allocator, seed_gen: *SeedGenerator, instruction_count: usize) ![]u8 {
    var instructions = try std.ArrayList(u8).initCapacity(
        allocator,
        instruction_count * igen.MaxInstructionSize,
    );
    defer instructions.deinit();

    const writer = instructions.writer();

    // Generate a sequence of valid instructions
    for (0..instruction_count) |_| {
        _ = try igen.randomInstruction(writer, seed_gen);
    }

    return try instructions.toOwnedSlice();
}
