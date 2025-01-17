const std = @import("std");

const SeedGenerator = @import("../seed.zig").SeedGenerator;

const InstructionType = @import("../../../pvm/instruction.zig").InstructionType;
const InstructionWithArgs = @import("../../../pvm/instruction.zig").InstructionWithArgs;
const InstructionRanges = @import("../../../pvm/instruction.zig").InstructionRanges;
const InstructionArgs = @import("../../../pvm/instruction.zig").InstructionArgs;

const MaxRegisterIndex = 12; // Maximum valid register index

/// Generate a random instruction with its arguments
pub fn randomInstruction(seed_gen: *SeedGenerator) InstructionWithArgs {
    // Select random instruction type (excluding NoArgs which is for terminators)
    const inst_type = @as(InstructionType, @enumFromInt(
        seed_gen.randomIntRange(u8, 1, std.meta.fields(InstructionType).len - 1),
    ));
    const range = InstructionRanges.get(@tagName(inst_type)).?;
    const opcode = seed_gen.randomIntRange(u8, range.start, range.end);

    return .{
        .instruction = @enumFromInt(opcode),
        .args = switch (inst_type) {
            .NoArgs => .{ .NoArgs = .{ .no_of_bytes_to_skip = 0 } },
            .OneImm => .{
                .OneImm = .{
                    .no_of_bytes_to_skip = 0,
                    .immediate = seed_gen.randomImmediate(),
                },
            },
            .OneRegOneExtImm => .{
                .OneRegOneExtImm = .{
                    .no_of_bytes_to_skip = 0,
                    .register_index = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex),
                    .immediate = seed_gen.randomImmediate(),
                },
            },
            .TwoImm => .{
                .TwoImm = .{
                    .no_of_bytes_to_skip = 0,
                    .first_immediate = seed_gen.randomImmediate(),
                    .second_immediate = seed_gen.randomImmediate(),
                },
            },
            .OneOffset => .{
                .OneOffset = .{
                    .no_of_bytes_to_skip = 0,
                    .offset = @as(i32, @bitCast(seed_gen.randomImmediate())),
                },
            },
            .OneRegOneImm => .{
                .OneRegOneImm = .{
                    .no_of_bytes_to_skip = 0,
                    .register_index = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex),
                    .immediate = seed_gen.randomImmediate(),
                },
            },
            .OneRegTwoImm => .{
                .OneRegTwoImm = .{
                    .no_of_bytes_to_skip = 0,
                    .register_index = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex),
                    .first_immediate = seed_gen.randomImmediate(),
                    .second_immediate = seed_gen.randomImmediate(),
                },
            },
            .OneRegOneImmOneOffset => .{
                .OneRegOneImmOneOffset = .{
                    .no_of_bytes_to_skip = 0,
                    .register_index = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex),
                    .immediate = seed_gen.randomImmediate(),
                    .offset = @as(i32, @bitCast(seed_gen.randomImmediate())),
                },
            },
            .TwoReg => .{
                .TwoReg = .{
                    .no_of_bytes_to_skip = 0,
                    .first_register_index = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex),
                    .second_register_index = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex),
                },
            },
            .TwoRegOneImm => .{
                .TwoRegOneImm = .{
                    .no_of_bytes_to_skip = 0,
                    .first_register_index = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex),
                    .second_register_index = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex),
                    .immediate = seed_gen.randomImmediate(),
                },
            },
            .TwoRegOneOffset => .{
                .TwoRegOneOffset = .{
                    .no_of_bytes_to_skip = 0,
                    .first_register_index = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex),
                    .second_register_index = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex),
                    .offset = @as(i32, @bitCast(seed_gen.randomImmediate())),
                },
            },
            .TwoRegTwoImm => .{
                .TwoRegTwoImm = .{
                    .no_of_bytes_to_skip = 0,
                    .first_register_index = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex),
                    .second_register_index = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex),
                    .first_immediate = seed_gen.randomImmediate(),
                    .second_immediate = seed_gen.randomImmediate(),
                },
            },
            .ThreeReg => .{
                .ThreeReg = .{
                    .no_of_bytes_to_skip = 0,
                    .first_register_index = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex),
                    .second_register_index = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex),
                    .third_register_index = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex),
                },
            },
        },
    };
}
