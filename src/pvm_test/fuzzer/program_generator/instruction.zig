const std = @import("std");

const SeedGenerator = @import("../seed.zig").SeedGenerator;

/// Represents a PVM instruction type with its opcode range and operand structure
/// Represents a PVM instruction type with its opcode range and operand structure
pub const InstructionType = enum {
    // Instructions with no arguments (A.5.1)
    NoArgs, // 0-1: trap, fallthrough
    // Instructions with one immediate (A.5.2)
    OneImm, // 10: ecalli
    // Instructions with one register and one extended width immediate (A.5.3)
    OneRegOneExtImm, // 20: load_imm_64
    // Instructions with two immediates (A.5.4)
    TwoImm, // 30-33: store_imm_u8, store_imm_u16, etc.
    // Instructions with one offset (A.5.5)
    OneOffset, // 40: jump
    // Instructions with one register and one immediate (A.5.6)
    OneRegOneImm, // 50-62: jump_ind, load_imm, load_u8, etc.
    // Instructions with one register and two immediates (A.5.7)
    OneRegTwoImm, // 70-73: store_imm_ind_u8, store_imm_ind_u16, etc.
    // Instructions with one register, one immediate and one offset (A.5.8)
    OneRegOneImmOneOffset, // 80-90: load_imm_jump, branch_eq_imm, etc.
    // Instructions with two registers (A.5.9)
    TwoReg, // 100-101: move_reg, sbrk
    // Instructions with two registers and one immediate (A.5.10)
    TwoRegOneImm, // 110-147: store_ind_u8, load_ind_u8, add_imm_32, etc.
    // Instructions with two registers and one offset (A.5.11)
    TwoRegOneOffset, // 150-155: branch_eq, branch_ne, etc.
    // Instructions with two registers and two immediates (A.5.12)
    TwoRegTwoImm, // 160: load_imm_jump_ind
    // Instructions with three registers (A.5.13)
    ThreeReg, // 170-199: add_32, sub_32, mul_32, etc.
};

/// Maps instruction types to their valid opcode ranges
const InstructionRange = struct {
    start: u8,
    end: u8,
};

/// Valid opcode ranges for each instruction type
pub const InstructionRanges = std.StaticStringMap(InstructionRange).initComptime(.{
    .{ "NoArgs", .{ .start = 0, .end = 1 } },
    .{ "OneImm", .{ .start = 10, .end = 10 } },
    .{ "OneRegOneExtImm", .{ .start = 20, .end = 20 } },
    .{ "TwoImm", .{ .start = 30, .end = 33 } },
    .{ "OneOffset", .{ .start = 40, .end = 40 } },
    .{ "OneRegOneImm", .{ .start = 50, .end = 62 } },
    .{ "OneRegTwoImm", .{ .start = 70, .end = 73 } },
    .{ "OneRegOneImmOneOffset", .{ .start = 80, .end = 90 } },
    .{ "TwoReg", .{ .start = 100, .end = 101 } },
    .{ "TwoRegOneImm", .{ .start = 110, .end = 147 } },
    .{ "TwoRegOneOffset", .{ .start = 150, .end = 155 } },
    .{ "TwoRegTwoImm", .{ .start = 160, .end = 160 } },
    .{ "ThreeReg", .{ .start = 170, .end = 199 } },
});

pub const MaxInstructionSize = 16;
const MaxRegisterIndex = 12; // Maximum valid register index

pub const Instruction = struct {
    buffer: [MaxInstructionSize]u8,
    len: usize,

    pub fn toSlice(self: *const @This()) []const u8 {
        return self.buffer[0..self.len];
    }
};

/// Generate a regular (non-terminator) instruction
pub fn generateRegularInstruction(seed_gen: *SeedGenerator) !Instruction {
    var instruction_buffer: [MaxInstructionSize]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&instruction_buffer);

    var encoder = @import("instruction_encoder.zig").buildEncoder(fbs.writer());

    // Select random instruction type (excluding NoArgs which is for terminators)
    const inst_type = @as(InstructionType, @enumFromInt(
        seed_gen.randomIntRange(u8, 1, std.meta.fields(InstructionType).len - 1),
    ));
    const range = InstructionRanges.get(@tagName(inst_type)).?;
    const opcode = seed_gen.randomIntRange(u8, range.start, range.end);

    const length = switch (inst_type) {
        .NoArgs => unreachable, // Handled by generateTerminator
        .OneImm => blk: {
            const imm = seed_gen.randomImmediate();
            break :blk try encoder.encodeOneImm(opcode, imm);
        },
        .OneRegOneExtImm => blk: {
            const reg = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
            const imm = seed_gen.randomImmediate();
            break :blk try encoder.encodeOneRegOneExtImm(opcode, reg, imm);
        },
        .TwoImm => blk: {
            const imm1 = seed_gen.randomImmediate();
            const imm2 = seed_gen.randomImmediate();
            break :blk try encoder.encodeTwoImm(opcode, imm1, imm2);
        },
        .OneOffset => blk: {
            const offset = @as(i32, @bitCast(seed_gen.randomImmediate()));
            break :blk try encoder.encodeOneOffset(opcode, offset);
        },
        .OneRegOneImm => blk: {
            const reg = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
            const imm = seed_gen.randomImmediate();
            break :blk try encoder.encodeOneRegOneImm(opcode, reg, imm);
        },
        .OneRegTwoImm => blk: {
            const reg = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
            const imm1 = seed_gen.randomImmediate();
            const imm2 = seed_gen.randomImmediate();
            break :blk try encoder.encodeOneRegTwoImm(opcode, reg, imm1, imm2);
        },
        .OneRegOneImmOneOffset => blk: {
            const reg = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
            const imm = seed_gen.randomImmediate();
            const offset = @as(i32, @bitCast(seed_gen.randomImmediate()));
            break :blk try encoder.encodeOneRegOneImmOneOffset(opcode, reg, imm, offset);
        },
        .TwoReg => blk: {
            const reg1 = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
            const reg2 = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
            break :blk try encoder.encodeTwoReg(opcode, reg1, reg2);
        },
        .TwoRegOneImm => blk: {
            const reg1 = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
            const reg2 = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
            const imm = seed_gen.randomImmediate();
            break :blk try encoder.encodeTwoRegOneImm(opcode, reg1, reg2, imm);
        },
        .TwoRegOneOffset => blk: {
            const reg1 = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
            const reg2 = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
            const offset = @as(i32, @bitCast(seed_gen.randomImmediate()));
            break :blk try encoder.encodeTwoRegOneOffset(opcode, reg1, reg2, offset);
        },
        .TwoRegTwoImm => blk: {
            const reg1 = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
            const reg2 = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
            const imm1 = seed_gen.randomImmediate();
            const imm2 = seed_gen.randomImmediate();
            break :blk try encoder.encodeTwoRegTwoImm(opcode, reg1, reg2, imm1, imm2);
        },
        .ThreeReg => blk: {
            const reg1 = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
            const reg2 = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
            const reg3 = seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
            break :blk try encoder.encodeThreeReg(opcode, reg1, reg2, reg3);
        },
    };

    return .{ .len = length, .buffer = instruction_buffer };
}

/// Generate a terminator instruction (trap, fallthrough, or jump)
pub fn generateTerminator(seed_gen: *SeedGenerator) !Instruction {
    var instruction_buffer: [MaxInstructionSize]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&instruction_buffer);

    var encoder = @import("instruction_encoder.zig").buildEncoder(fbs.writer());

    const terminator_type = seed_gen.randomIntRange(u8, 0, 2);
    const length = switch (terminator_type) {
        0 => try encoder.encodeNoArgs(0), // trap
        1 => try encoder.encodeNoArgs(1), // fallthrough
        2 => try encoder.encodeNoArgs(1), // FIXME: try encoder.encodeJump(0), // Jump target will be filled in later during block linking
        else => unreachable,
    };

    return .{ .len = length, .buffer = instruction_buffer };
}
