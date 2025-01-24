const std = @import("std");
const SeedGenerator = @import("../seed.zig").SeedGenerator;
const igen = @import("instruction_generator.zig");
const instlib = @import("../../../pvm/instruction.zig");
const Memory = @import("../../../pvm/memory.zig").Memory;
const InstructionWithArgs = instlib.InstructionWithArgs;

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
    var did_sbrk: usize = 0;
    var i: usize = 0;
    while ((i + did_sbrk) < instruction_count) : (i += 1) {
        const gen_span = span.child(.generate_instruction);
        defer gen_span.deinit();

        var inst = igen.randomInstruction(seed_gen);

        // for fuzzing purposes we do not want to allocate too much memory
        // we one do one
        if (inst.instruction == .sbrk) {
            if (did_sbrk > 5) {
                continue;
            } else {
                // we load some size in a random register for sbrk to allocate
                const reg = seed_gen.randomIntRange(u8, 0, 12);
                const load_imm = InstructionWithArgs{ .instruction = .load_imm, .args = .{
                    .OneRegOneImm = instlib.InstructionArgs.OneRegOneImmType{
                        .no_of_bytes_to_skip = 0,
                        .immediate = seed_gen.randomIntRange(u64, 0, Memory.Z_P * 3),
                        .register_index = reg,
                    },
                } };
                // inject instruction
                try instructions.append(load_imm);
                // instruct sbrk to get the size out of the register
                inst.args.TwoReg.second_register_index = reg;
                did_sbrk += 1;
            }
        }

        try instructions.append(inst);

        gen_span.debug("Generated instruction {d}/{d}: {}", .{
            i + 1,
            instruction_count,
            inst,
        });
        i += 1;
    }
    const result = try instructions.toOwnedSlice();

    return result;
}
