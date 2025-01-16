const std = @import("std");

const SeedGenerator = @import("../seed.zig").SeedGenerator;

const InstructionType = @import("../../../pvm/instruction.zig").InstructionType;
const InstructionRanges = @import("../../../pvm/instruction.zig").InstructionRanges;

const encoder = @import("../../../pvm/instruction/encoder.zig");

pub const MaxInstructionSize = 16;
const MaxRegisterIndex = 12; // Maximum valid register index

pub const Instruction = struct {
    buffer: [MaxInstructionSize]u8,
    len: usize,

    pub fn toSlice(self: *const @This()) []const u8 {
        return self.buffer[0..self.len];
    }
};

pub fn randomInstructionOwned(seed_gen: *SeedGenerator) !Instruction {
    var instruction_buffer: [MaxInstructionSize]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&instruction_buffer);

    const writer = fbs.writer();
    const length = randomInstruction(writer, seed_gen);

    return .{ .len = length, .buffer = instruction_buffer };
}

/// Generate a regular (non-terminator) instruction
pub fn randomInstruction(writer: anytype, seed_gen: *SeedGenerator) !u8 {
    // Select random instruction type (excluding NoArgs which is for terminators)
    const inst_type = @as(InstructionType, @enumFromInt(
        seed_gen.randomIntRange(u8, 1, std.meta.fields(InstructionType).len - 1),
    ));
    const range = InstructionRanges.get(@tagName(inst_type)).?;
    const opcode = seed_gen.randomIntRange(u8, range.start, range.end);

    // Write opcode
    try writer.writeByte(opcode);

    // Write length
    return switch (inst_type) {
        .NoArgs => 0, // Handled by generateTerminator
        .OneImm => blk: {
            const imm = seed_gen.randomImmediate();
            break :blk try encoder.encodeOneImm(writer, imm);
        },
        .OneRegOneExtImm => blk: {
            const reg = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
            const imm = seed_gen.randomImmediate();
            break :blk try encoder.encodeOneRegOneExtImm(writer, reg, imm);
        },
        .TwoImm => blk: {
            const imm1 = seed_gen.randomImmediate();
            const imm2 = seed_gen.randomImmediate();
            break :blk try encoder.encodeTwoImm(writer, imm1, imm2);
        },
        .OneOffset => blk: {
            const offset = @as(i32, @bitCast(seed_gen.randomImmediate()));
            break :blk try encoder.encodeOneOffset(writer, offset);
        },
        .OneRegOneImm => blk: {
            const reg = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
            const imm = seed_gen.randomImmediate();
            break :blk try encoder.encodeOneRegOneImm(writer, reg, imm);
        },
        .OneRegTwoImm => blk: {
            const reg = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
            const imm1 = seed_gen.randomImmediate();
            const imm2 = seed_gen.randomImmediate();
            break :blk try encoder.encodeOneRegTwoImm(writer, reg, imm1, imm2);
        },
        .OneRegOneImmOneOffset => blk: {
            const reg = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
            const imm = seed_gen.randomImmediate();
            const offset = @as(i32, @bitCast(seed_gen.randomImmediate()));
            break :blk try encoder.encodeOneRegOneImmOneOffset(writer, reg, imm, offset);
        },
        .TwoReg => blk: {
            const reg1 = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
            const reg2 = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
            break :blk try encoder.encodeTwoReg(writer, reg1, reg2);
        },
        .TwoRegOneImm => blk: {
            const reg1 = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
            const reg2 = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
            const imm = seed_gen.randomImmediate();
            break :blk try encoder.encodeTwoRegOneImm(writer, reg1, reg2, imm);
        },
        .TwoRegOneOffset => blk: {
            const reg1 = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
            const reg2 = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
            const offset = @as(i32, @bitCast(seed_gen.randomImmediate()));
            break :blk try encoder.encodeTwoRegOneOffset(writer, reg1, reg2, offset);
        },
        .TwoRegTwoImm => blk: {
            const reg1 = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
            const reg2 = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
            const imm1 = seed_gen.randomImmediate();
            const imm2 = seed_gen.randomImmediate();
            break :blk try encoder.encodeTwoRegTwoImm(writer, reg1, reg2, imm1, imm2);
        },
        .ThreeReg => blk: {
            const reg1 = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
            const reg2 = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
            const reg3 = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
            break :blk try encoder.encodeThreeReg(writer, reg1, reg2, reg3);
        },
    };
}
