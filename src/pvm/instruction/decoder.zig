const std = @import("std");

const Instruction = @import("../instruction.zig").Instruction;
const InstructionType = @import("../instruction.zig").InstructionType;
const InstructionArgs = @import("../instruction.zig").InstructionArgs;
const InstructionWithArgs = @import("../instruction.zig").InstructionWithArgs;

const Immediate = @import("immediate.zig");
const Nibble = @import("nibble.zig");

pub const Error = error{
    InvalidInstruction,
    InvalidImmLength,
    InvalidRegIndex,
    SliceTooShort,
};

/// Takes a byte slice containing instruction opcode and arguments. Slice length determines argument size.
pub fn decodeInstruction(bytes: []const u8) Error!InstructionWithArgs {
    const inst = std.meta.intToEnum(Instruction, bytes[0]) catch {
        // std.debug.print("Error decoding instruction at pc {}: code 0x{X:0>2} ({d})\n", .{ pc, self.getCodeAt(pc), self.getCodeAt(pc) });
        return Error.InvalidInstruction;
    };

    const inst_type = InstructionType.lookUp(inst);
    const inst_args = switch (inst_type) {
        .NoArgs => InstructionArgs{ .NoArgs = .{ .no_of_bytes_to_skip = 0 } },
        .OneImm => InstructionArgs{ .OneImm = try decodeOneImm(bytes[1..]) },
        .OneOffset => InstructionArgs{ .OneOffset = try decodeOneOffset(bytes[1..]) },
        .OneRegOneImm => InstructionArgs{ .OneRegOneImm = try decodeOneRegOneImm(bytes[1..]) },
        .OneRegOneImmOneOffset => InstructionArgs{ .OneRegOneImmOneOffset = try decodeOneRegOneImmOneOffset(bytes[1..]) },
        .OneRegOneExtImm => InstructionArgs{ .OneRegOneExtImm = try decodeOneRegOneExtImm(bytes[1..]) },
        .OneRegTwoImm => InstructionArgs{ .OneRegTwoImm = try decodeOneRegTwoImm(bytes[1..]) },
        .ThreeReg => InstructionArgs{ .ThreeReg = try decodeThreeReg(bytes[1..]) },
        .TwoImm => InstructionArgs{ .TwoImm = try decodeTwoImm(bytes[1..]) },
        .TwoReg => InstructionArgs{ .TwoReg = try decodeTwoReg(bytes[1..]) },
        .TwoRegOneImm => InstructionArgs{ .TwoRegOneImm = try decodeTwoRegOneImm(bytes[1..]) },
        .TwoRegOneOffset => InstructionArgs{ .TwoRegOneOffset = try decodeTwoRegOneOffset(bytes[1..]) },
        .TwoRegTwoImm => InstructionArgs{ .TwoRegTwoImm = try decodeTwoRegTwoImm(bytes[1..]) },
    };

    return InstructionWithArgs{
        .instruction = inst,
        .args = inst_args,
    };
}

/// Helper functions that work directly on bytes
inline fn getHighNibble(byte: u8) u4 {
    return Nibble.getHighNibble(byte);
}

inline fn getLowNibble(byte: u8) u4 {
    return Nibble.getLowNibble(byte);
}

pub fn decodeNoArgs(bytes: []const u8) Error!InstructionArgs.NoArgsType {
    if (bytes.len != 0) return Error.SliceTooShort;
    return .{ .no_of_bytes_to_skip = 1 };
}

pub fn decodeOneImm(bytes: []const u8) Error!InstructionArgs.OneImmType {
    if (bytes.len < 1) return Error.SliceTooShort;

    const l_x = @min(4, bytes.len);
    return .{
        .no_of_bytes_to_skip = l_x,
        .immediate = Immediate.decodeUnsigned(bytes[0..l_x]),
    };
}

pub fn decodeTwoImm(bytes: []const u8) Error!InstructionArgs.TwoImmType {
    if (bytes.len < 1) return Error.SliceTooShort;

    const l_x: u4 = @min(4, bytes[0] % 8);
    const l_y = @min(
        4,
        try safeSubstract(u8, @intCast(bytes.len), .{ 1, l_x }),
    );

    return .{
        .no_of_bytes_to_skip = 1 + l_x + l_y,
        .first_immediate = Immediate.decodeUnsigned(bytes[1..][0..l_x]),
        .second_immediate = Immediate.decodeUnsigned(bytes[1..][l_x..][0..l_y]),
    };
}

pub fn decodeOneOffset(bytes: []const u8) Error!InstructionArgs.OneOffsetType {
    const l_x = @min(4, bytes.len);
    const offset = @as(i32, @intCast(Immediate.decodeSigned(bytes[0..l_x])));

    return .{
        .no_of_bytes_to_skip = l_x,
        .offset = offset,
    };
}

pub fn decodeOneRegOneImm(bytes: []const u8) Error!InstructionArgs.OneRegOneImmType {
    if (bytes.len < 1) return Error.SliceTooShort;

    const r_a = @min(12, getLowNibble(bytes[0]));
    const l_x = @min(4, bytes.len - 1);

    return .{
        .no_of_bytes_to_skip = l_x + 1,
        .register_index = r_a,
        .immediate = Immediate.decodeUnsigned(bytes[1..][0..l_x]),
    };
}

pub fn decodeOneRegTwoImm(bytes: []const u8) Error!InstructionArgs.OneRegTwoImmType {
    if (bytes.len < 1) return Error.SliceTooShort;

    const r_a = @min(12, getLowNibble(bytes[0]));
    const l_x: u4 = @min(4, getHighNibble(bytes[0]) % 8);
    const l_y = @min(
        4,
        try safeSubstract(u8, @intCast(bytes.len), .{ 1, l_x }),
    );

    return .{
        .no_of_bytes_to_skip = 1 + l_x + l_y,
        .register_index = r_a,
        .first_immediate = Immediate.decodeUnsigned(bytes[1..][0..l_x]),
        .second_immediate = Immediate.decodeUnsigned(bytes[1..][l_x..][0..l_y]),
    };
}

pub fn decodeOneRegOneImmOneOffset(bytes: []const u8) Error!InstructionArgs.OneRegOneImmOneOffsetType {
    if (bytes.len < 1) return Error.SliceTooShort;

    const r_a = @min(12, getLowNibble(bytes[0]));
    const l_x: u4 = @min(4, getHighNibble(bytes[0]) % 8);

    const l_y = @min(
        4,
        try safeSubstract(u8, @intCast(bytes.len), .{ 1, l_x }),
    );

    return .{
        .no_of_bytes_to_skip = 1 + l_x + l_y,
        .register_index = r_a,
        .immediate = Immediate.decodeUnsigned(bytes[1..][0..l_x]),
        .offset = @intCast(Immediate.decodeOffset(bytes[1..][l_x..][0..l_y])),
    };
}

pub fn decodeOneRegOneExtImm(bytes: []const u8) Error!InstructionArgs.OneRegOneExtImmType {
    if (bytes.len < 9) return Error.SliceTooShort; // 1 byte opcode + 1 byte register + 8 bytes immediate

    const r_a = @min(12, bytes[0] & 0x0F);
    return .{
        .no_of_bytes_to_skip = 9,
        .register_index = r_a,
        .immediate = std.mem.readInt(u64, bytes[1..9], .little),
    };
}

pub fn decodeTwoReg(bytes: []const u8) Error!InstructionArgs.TwoRegType {
    if (bytes.len < 1) return Error.SliceTooShort;

    const r_d = @min(12, getLowNibble(bytes[0]));
    const r_a = @min(12, getHighNibble(bytes[0]));

    return .{
        .no_of_bytes_to_skip = 1,
        .first_register_index = r_d,
        .second_register_index = r_a,
    };
}

pub fn decodeTwoRegOneImm(bytes: []const u8) Error!InstructionArgs.TwoRegOneImmType {
    if (bytes.len < 1) return Error.SliceTooShort;

    const r_a = @min(12, getLowNibble(bytes[0]));
    const r_b = @min(12, getHighNibble(bytes[0]));
    const l_x = @min(4, bytes.len - 1);

    if (bytes.len < l_x + 1) return Error.SliceTooShort;

    return .{
        .no_of_bytes_to_skip = l_x + 1,
        .first_register_index = r_a,
        .second_register_index = r_b,
        .immediate = Immediate.decodeUnsigned(bytes[1..][0..l_x]),
    };
}

pub fn decodeTwoRegOneOffset(bytes: []const u8) Error!InstructionArgs.TwoRegOneOffsetType {
    if (bytes.len < 1) return Error.SliceTooShort;

    const r_a = @min(12, getLowNibble(bytes[0]));
    const r_b = @min(12, getHighNibble(bytes[0]));
    const l_x = @min(4, bytes.len - 1);

    if (bytes.len < l_x + 1) return Error.SliceTooShort;

    return .{
        .no_of_bytes_to_skip = l_x + 1,
        .first_register_index = r_a,
        .second_register_index = r_b,
        .offset = @intCast(Immediate.decodeSigned(bytes[1..][0..l_x])),
    };
}

pub fn decodeTwoRegTwoImm(bytes: []const u8) Error!InstructionArgs.TwoRegTwoImmType {
    if (bytes.len < 2) return Error.SliceTooShort;

    const r_a = @min(12, getLowNibble(bytes[0]));
    const r_b = @min(12, getHighNibble(bytes[0]));
    const l_x: u4 = @min(4, bytes[1] % 8);

    const l_y = @min(
        4,
        try safeSubstract(u8, @intCast(bytes.len), .{ 2, l_x }),
    );

    if (bytes.len < 2 + l_x + l_y) return Error.SliceTooShort;

    return .{
        .no_of_bytes_to_skip = 2 + l_x + l_y,
        .first_register_index = r_a,
        .second_register_index = r_b,
        .first_immediate = Immediate.decodeUnsigned(bytes[2..][0..l_x]),
        .second_immediate = Immediate.decodeUnsigned(bytes[2..][l_x..][0..l_y]),
    };
}

pub fn decodeThreeReg(bytes: []const u8) Error!InstructionArgs.ThreeRegType {
    if (bytes.len < 2) return Error.SliceTooShort;

    const r_a = @min(12, getLowNibble(bytes[0]));
    const r_b = @min(12, getHighNibble(bytes[0]));
    const r_d = @min(12, bytes[1]);

    return .{
        .no_of_bytes_to_skip = 2,
        .first_register_index = r_a,
        .second_register_index = r_b,
        .third_register_index = r_d,
    };
}

inline fn safeSubstract(comptime T: type, initial: T, values: anytype) Error!T {
    // This function body will be evaluated at comptime for each unique set of values
    if (values.len == 0) {
        return initial;
    } else {
        var result: T = initial;
        inline for (values) |value| {
            if (result >= value) {
                result = result - value;
            } else {
                return Error.InvalidImmLength;
            }
        }
        return result;
    }
}

test "safeSubstract - basic subtraction" {
    try std.testing.expectEqual(@as(u32, 5), try safeSubstract(u32, 10, .{ 3, 2 }));
}

test "safeSubstract - empty values returns initial" {
    try std.testing.expectEqual(@as(u32, 10), try safeSubstract(u32, 10, .{}));
}

test "safeSubstract - single value" {
    try std.testing.expectEqual(@as(u32, 7), try safeSubstract(u32, 10, .{3}));
}

test "safeSubstract - error on underflow" {
    try std.testing.expectError(Error.InvalidImmLength, safeSubstract(u32, 5, .{ 3, 3 }));
}

test "safeSubstract - different types" {
    try std.testing.expectEqual(@as(u8, 2), try safeSubstract(u8, 5, .{ 2, 1 }));
    try std.testing.expectEqual(@as(i32, 2), try safeSubstract(i32, 10, .{ 5, 3 }));
}

test "safeSubstract - zero result" {
    try std.testing.expectEqual(@as(u32, 0), try safeSubstract(u32, 10, .{ 5, 5 }));
}
