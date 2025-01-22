const std = @import("std");

const InstructionWithArgs = @import("../instruction.zig").InstructionWithArgs;

// Immediates: encoded as 32-bit, sign-extended to 64-bit on decode
const ImmediateSizeInBytes: usize = 4;

pub fn sizeOfInstruction(iwa: *const InstructionWithArgs) !u8 {
    return try encodeInstruction(NullWriter, iwa);
}

pub fn encodeInstruction(writer: anytype, iwa: *const InstructionWithArgs) !u8 {
    // First encode the instruction opcode
    try writer.writeByte(@intFromEnum(iwa.instruction));

    // Then encode the arguments based on instruction type
    const arg_length = switch (iwa.args) {
        .NoArgs => |_| try encodeNoArgs(writer),
        .OneImm => |args| try encodeOneImm(writer, @truncate(args.immediate)),
        .OneRegOneExtImm => |args| try encodeOneRegOneExtImm(writer, args.register_index, args.immediate),
        .TwoImm => |args| try encodeTwoImm(writer, @truncate(args.first_immediate), @truncate(args.second_immediate)),
        .OneOffset => |args| try encodeOneOffset(writer, args.offset),
        .OneRegOneImm => |args| try encodeOneRegOneImm(writer, args.register_index, @truncate(args.immediate)),
        .OneRegTwoImm => |args| try encodeOneRegTwoImm(writer, args.register_index, @truncate(args.first_immediate), @truncate(args.second_immediate)),
        .OneRegOneImmOneOffset => |args| try encodeOneRegOneImmOneOffset(writer, args.register_index, @truncate(args.immediate), args.offset),
        .TwoReg => |args| try encodeTwoReg(writer, args.first_register_index, args.second_register_index),
        .TwoRegOneImm => |args| try encodeTwoRegOneImm(writer, args.first_register_index, args.second_register_index, @truncate(args.immediate)),
        .TwoRegOneOffset => |args| try encodeTwoRegOneOffset(writer, args.first_register_index, args.second_register_index, args.offset),
        .TwoRegTwoImm => |args| try encodeTwoRegTwoImm(writer, args.first_register_index, args.second_register_index, @truncate(args.first_immediate), @truncate(args.second_immediate)),
        .ThreeReg => |args| try encodeThreeReg(writer, args.first_register_index, args.second_register_index, args.third_register_index),
    };

    return 1 + arg_length;
}

pub const MaxInstructionSizeInBytes = @import("../instruction.zig").MaxInstructionSizeInBytes;
pub const EncodedInstruction = struct {
    buffer: [MaxInstructionSizeInBytes]u8,
    len: u8,

    pub fn asSlice(self: *const EncodedInstruction) []const u8 {
        return self.buffer[0..self.len];
    }
};

pub fn encodeInstructionOwned(iwa: *const InstructionWithArgs) !EncodedInstruction {
    var result = EncodedInstruction{
        .buffer = undefined,
        .len = 0,
    };

    // Create a fixed buffer writer
    var fbs = std.io.fixedBufferStream(&result.buffer);
    const writer = fbs.writer();

    // Encode the instruction into the buffer
    result.len = try encodeInstruction(writer, iwa);

    return result;
}

const NullWriter = struct {};

pub fn encodeNoArgs(writer: anytype) !u8 {
    _ = writer;
    return 0;
}

pub fn encodeOneImm(writer: anytype, imm: u32) !u8 {
    const l_x = calcLengthNeeded(imm);
    try writeImm(writer, imm, l_x);
    return l_x;
}

pub fn encodeOneRegOneExtImm(writer: anytype, reg_a: u8, imm: u64) !u8 {
    try writer.writeByte(reg_a & 0x0F);
    try writer.writeInt(u64, imm, .little);
    return 1 + 8;
}

pub fn encodeTwoImm(writer: anytype, imm1: u32, imm2: u32) !u8 {
    const l_x = calcLengthNeeded(imm1);
    const l_y = calcLengthNeeded(imm2);
    try writer.writeByte(l_x);
    try writeImm(writer, imm1, l_x);
    try writeImm(writer, imm2, l_y);
    return l_x + l_y + 1;
}

pub fn encodeOneOffset(writer: anytype, offset: i32) !u8 {
    const l_x = calcLengthNeeded(@bitCast(offset));
    try writeImm(writer, @bitCast(offset), l_x);
    return l_x;
}

pub fn encodeOneRegTwoImm(writer: anytype, reg_a: u8, imm1: u32, imm2: u32) !u8 {
    const l_x = calcLengthNeeded(imm1);
    const l_y = calcLengthNeeded(imm2);
    try writer.writeByte((reg_a & 0x0F) | (l_x << 4));
    try writeImm(writer, imm1, l_x);
    try writeImm(writer, imm2, l_y);
    return l_x + l_y + 1;
}

pub fn encodeOneRegOneImm(writer: anytype, reg_a: u8, imm: u32) !u8 {
    const l_x = calcLengthNeeded(imm);
    try writer.writeByte(reg_a & 0x0F);
    try writeImm(writer, imm, l_x);
    return l_x + 1;
}

pub fn encodeOneRegOneImmOneOffset(writer: anytype, reg_a: u8, imm: u32, offset: i32) !u8 {
    const l_x = calcLengthNeeded(imm);
    const l_y = calcLengthNeeded(@bitCast(offset));
    try writer.writeByte((reg_a & 0x0F) | (l_x << 4));
    try writeImm(writer, imm, l_x);
    try writeImm(writer, @bitCast(offset), l_y);
    return l_x + l_y + 1;
}

pub fn encodeTwoReg(writer: anytype, reg_a: u8, reg_b: u8) !u8 {
    try writer.writeByte((reg_a & 0x0F) | (reg_b << 4));
    return 1;
}

pub fn encodeTwoRegOneImm(writer: anytype, reg_a: u8, reg_b: u8, imm: u32) !u8 {
    const l_x = calcLengthNeeded(imm);
    try writer.writeByte((reg_a & 0x0F) | (reg_b << 4));
    try writeImm(writer, imm, l_x);
    return l_x + 1;
}

pub fn encodeTwoRegOneOffset(writer: anytype, reg_a: u8, reg_b: u8, offset: i32) !u8 {
    const l_x = calcLengthNeeded(@bitCast(offset));
    try writer.writeByte((reg_a & 0x0F) | (reg_b << 4));
    try writeImm(writer, @bitCast(offset), l_x);
    return l_x + 1;
}

pub fn encodeTwoRegTwoImm(writer: anytype, reg_a: u8, reg_b: u8, imm1: u32, imm2: u32) !u8 {
    const l_x = calcLengthNeeded(imm1);
    const l_y = calcLengthNeeded(imm2);
    try writer.writeByte((reg_a & 0x0F) | (reg_b << 4));
    try writer.writeByte(l_x);
    try writeImm(writer, imm1, l_x);
    try writeImm(writer, imm2, l_y);
    return l_x + l_y + 2;
}

pub fn encodeThreeReg(writer: anytype, reg_a: u8, reg_b: u8, reg_d: u8) !u8 {
    try writer.writeByte((reg_a & 0x0F) | (reg_b << 4));
    try writer.writeByte(reg_d & 0x0F);
    return 2;
}

pub fn encodeJump(writer: anytype, target: u32) !u8 {
    const l_x = calcLengthNeeded(target);
    try writer.writeByte(40);
    try writeImm(writer, writer, target, l_x);
    return l_x;
}

fn calcLengthNeeded(value: u32) u8 {
    if (value == 0) return 1;

    var buffer: [ImmediateSizeInBytes]u8 = undefined;
    std.mem.writeInt(u32, &buffer, value, .little);

    var cursor: u8 = ImmediateSizeInBytes - 1;
    if (buffer[cursor] & 0x80 != 0) { // Signed
        while (cursor > 0 and
            buffer[cursor] == 0xFF and
            buffer[cursor - 1] & 0x80 != 0) : (cursor -= 1)
        {}
    } else { // Unsigned
        while (cursor > 0 and
            buffer[cursor] == 0x00 and
            buffer[cursor - 1] & 0x80 == 0) : (cursor -= 1)
        {}
    }

    return cursor + 1;
}

test calcLengthNeeded {
    try std.testing.expectEqual(1, calcLengthNeeded(0xFFFFFFF4));
    try std.testing.expectEqual(1, calcLengthNeeded(0x00000004));
    try std.testing.expectEqual(1, calcLengthNeeded(0x00000000));
    try std.testing.expectEqual(1, calcLengthNeeded(0xFFFFFFFF));
    try std.testing.expectEqual(3, calcLengthNeeded(0xFFFF0000));
    try std.testing.expectEqual(3, calcLengthNeeded(0x0000FFFF)); // 3 since we have a signed bit
    try std.testing.expectEqual(3, calcLengthNeeded(0xFFF40000));
    try std.testing.expectEqual(4, calcLengthNeeded(0x8FF40000));
    try std.testing.expectEqual(4, calcLengthNeeded(0x7FF40000));
}

fn writeImm(writer: anytype, value: u32, len: u8) !void {
    if (@TypeOf(writer) == NullWriter) return;

    var buffer: [ImmediateSizeInBytes]u8 = undefined;
    std.mem.writeInt(u32, &buffer, value, .little);

    if (len > 0) {
        for (buffer[0..len]) |byte| {
            try writer.writeByte(byte);
        }
    } else {
        try writer.writeByte(0);
    }
}
