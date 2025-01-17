const std = @import("std");
const SeedGenerator = @import("../seed.zig").SeedGenerator;
const igen = @import("instruction_generator.zig");
const InstructionWithArgs = @import("../../../pvm/instruction.zig").InstructionWithArgs;

// Import tracing module and create a scope
const trace = @import("../../../tracing.zig").scoped(.pvm);

/// Generate a sequence of random instructions
pub fn generate(allocator: std.mem.Allocator, seed_gen: *SeedGenerator, instruction_count: usize) ![]InstructionWithArgs {
    const span = trace.span(.generate);
    defer span.deinit();

    span.debug("Starting instruction generation, count: {d}", .{instruction_count});

    var instructions = try std.ArrayList(InstructionWithArgs).initCapacity(
        allocator,
        instruction_count,
    );
    defer instructions.deinit();

    span.trace("Initialized ArrayList with capacity {d}", .{instruction_count});

    // Generate a sequence of valid instructions
    for (0..instruction_count) |i| {
        const gen_span = span.child(.generate_instruction);
        defer gen_span.deinit();

        const instruction = igen.randomInstruction(seed_gen);
        try instructions.append(instruction);

        gen_span.debug("Generated instruction {d}/{d}: {}", .{
            i + 1,
            instruction_count,
            instruction,
        });
    }
    const result = try instructions.toOwnedSlice();

    return result;
}
