const std = @import("std");

pub const Instruction = @import("instruction.zig").Instruction;
pub const InstructionType = @import("instruction.zig").InstructionType;
pub const InstructionArgs = @import("instruction.zig").InstructionArgs;
pub const InstructionWithArgs = @import("instruction.zig").InstructionWithArgs;

const immediate = @import("./instruction/immediate.zig");
const nibble = @import("./instruction/nibble.zig");
const decoder = @import("./instruction/decoder.zig");

const updatePc = @import("./utils.zig").updatePc;

pub const Decoder = struct {
    code: []const u8,
    mask: []const u8,

    pub const MaxImmediateSizeInBytes = 8;

    pub const Error = error{
        InvalidInstruction,
        OutOfBounds,
        InvalidImmediateLength,
        InvalidRegisterIndex,
    } || decoder.Error;

    pub fn init(code: []const u8, mask: []const u8) Decoder {
        return Decoder{
            .code = code,
            .mask = mask,
        };
    }

    pub fn decodeInstruction(self: *const Decoder, pc: u32) Error!InstructionWithArgs {
        const inst = std.meta.intToEnum(Instruction, self.getCodeAt(pc)) catch {
            // std.debug.print("Error decoding instruction at pc {}: code 0x{X:0>2} ({d})\n", .{ pc, self.getCodeAt(pc), self.getCodeAt(pc) });
            return Error.InvalidInstruction;
        };

        const args_type = InstructionType.lookUp(inst);
        const args = switch (args_type) {
            .NoArgs => InstructionArgs{ .NoArgs = .{ .no_of_bytes_to_skip = 0 } },
            .OneImm => InstructionArgs{ .OneImm = try self.decodeOneImm(pc + 1) },
            .OneOffset => InstructionArgs{ .OneOffset = try self.decodeOneOffset(pc + 1) },
            .OneRegOneImm => InstructionArgs{ .OneRegOneImm = try self.decodeOneRegOneImm(pc + 1) },
            .OneRegOneImmOneOffset => InstructionArgs{ .OneRegOneImmOneOffset = try self.decodeOneRegOneImmOneOffset(pc + 1) },
            .OneRegOneExtImm => InstructionArgs{ .OneRegOneExtImm = try self.decodeOneRegOneExtImm(pc + 1) },
            .OneRegTwoImm => InstructionArgs{ .OneRegTwoImm = try self.decodeOneRegTwoImm(pc + 1) },
            .ThreeReg => InstructionArgs{ .ThreeReg = try self.decodeThreeReg(pc + 1) },
            .TwoImm => InstructionArgs{ .TwoImm = try self.decodeTwoImm(pc + 1) },
            .TwoReg => InstructionArgs{ .TwoReg = try self.decodeTwoReg(pc + 1) },
            .TwoRegOneImm => InstructionArgs{ .TwoRegOneImm = try self.decodeTwoRegOneImm(pc + 1) },
            .TwoRegOneOffset => InstructionArgs{ .TwoRegOneOffset = try self.decodeTwoRegOneOffset(pc + 1) },
            .TwoRegTwoImm => InstructionArgs{ .TwoRegTwoImm = try self.decodeTwoRegTwoImm(pc + 1) },
        };

        return InstructionWithArgs{
            .instruction = inst,
            .args_type = args_type,
            .args = args,
        };
    }

    fn decodeOneImm(self: *const Decoder, pc: u32) Error!InstructionArgs.OneImmType {
        const l = @min(4, self.skip_l(pc + 1));
        return try decoder.decodeOneImm(
            self.getCodeSliceAt(
                pc,
                l,
            ).asSlice(),
        );
    }

    fn decodeTwoImm(self: *const Decoder, pc: u32) Error!InstructionArgs.TwoImmType {
        const bytes = self.getCodeSliceAt(pc, self.skip_l(pc)).asSlice();
        return try decoder.decodeTwoImm(bytes);
    }

    fn decodeOneOffset(self: *const Decoder, pc: u32) Error!InstructionArgs.OneOffsetType {
        const bytes = self.getCodeSliceAt(pc, self.skip_l(pc)).asSlice();
        return try decoder.decodeOneOffset(bytes);
    }

    fn decodeOneRegOneImm(self: *const Decoder, pc: u32) Error!InstructionArgs.OneRegOneImmType {
        const bytes = self.getCodeSliceAt(pc, self.skip_l(pc)).asSlice();
        return try decoder.decodeOneRegOneImm(bytes);
    }

    fn decodeOneRegTwoImm(self: *const Decoder, pc: u32) Error!InstructionArgs.OneRegTwoImmType {
        const bytes = self.getCodeSliceAt(pc, self.skip_l(pc)).asSlice();
        return try decoder.decodeOneRegTwoImm(bytes);
    }

    fn decodeOneRegOneImmOneOffset(self: *const Decoder, pc: u32) Error!InstructionArgs.OneRegOneImmOneOffsetType {
        const bytes = self.getCodeSliceAt(pc, self.skip_l(pc)).asSlice();
        return try decoder.decodeOneRegOneImmOneOffset(bytes);
    }

    fn decodeOneRegOneExtImm(self: *const Decoder, pc: u32) Error!InstructionArgs.OneRegOneExtImmType {
        const bytes = self.getCodeSliceAt(pc, 10).asSlice(); // 1 byte opcode + 1 byte reg + 8 bytes immediate
        return try decoder.decodeOneRegOneExtImm(bytes);
    }

    fn decodeTwoReg(self: *const Decoder, pc: u32) Error!InstructionArgs.TwoRegType {
        const bytes = self.getCodeSliceAt(pc, self.skip_l(pc)).asSlice();
        return try decoder.decodeTwoReg(bytes);
    }

    fn decodeTwoRegOneImm(self: *const Decoder, pc: u32) Error!InstructionArgs.TwoRegOneImmType {
        const bytes = self.getCodeSliceAt(pc, self.skip_l(pc)).asSlice();
        return try decoder.decodeTwoRegOneImm(bytes);
    }

    fn decodeTwoRegOneOffset(self: *const Decoder, pc: u32) Error!InstructionArgs.TwoRegOneOffsetType {
        const bytes = self.getCodeSliceAt(pc, self.skip_l(pc)).asSlice();
        return try decoder.decodeTwoRegOneOffset(bytes);
    }

    fn decodeTwoRegTwoImm(self: *const Decoder, pc: u32) Error!InstructionArgs.TwoRegTwoImmType {
        const bytes = self.getCodeSliceAt(pc, self.skip_l(pc)).asSlice();
        return try decoder.decodeTwoRegTwoImm(bytes);
    }

    fn decodeThreeReg(self: *const Decoder, pc: u32) Error!InstructionArgs.ThreeRegType {
        const bytes = self.getCodeSliceAt(pc, self.skip_l(pc)).asSlice();
        return try decoder.decodeThreeReg(bytes);
    }

    /// (215)@0.3.8 Skip function
    fn skip_l(self: *const Decoder, pc: u32) u32 {
        var count: u32 = 0;
        var mask_index = pc / 8;
        const bit_offset: u3 = @intCast(pc % 8);
        var mask_byte = self.getMaskAt(mask_index) >> bit_offset;

        while (mask_byte & 1 == 0) {
            count += 1;
            mask_byte >>= 1;
            if ((bit_offset + count) % 8 == 0) {
                mask_index += 1;
                mask_byte = self.getMaskAt(mask_index);
            }
        }

        return count;
    }

    /// (216) ζ ≡ c ⌢[0, 0, . . .]
    pub fn getCodeAt(self: *const @This(), pc: u32) u8 {
        if (pc < self.code.len) {
            return self.code[pc];
        }

        return 0;
    }

    const CodeSlice = struct {
        buffer: [MaxImmediateSizeInBytes]u8 = undefined,
        len: u8,

        pub fn asSlice(self: *const @This()) []const u8 {
            return self.buffer[0..self.len];
        }

        pub inline fn zeroes(len: u8) CodeSlice {
            var self = CodeSlice{ .len = len };

            // fill the length with 0
            for (0..len) |idx| {
                self.buffer[idx] = 0x00;
            }
            return self;
        }

        // Initialize from slice
        pub inline fn fromSlice(slice: []const u8) CodeSlice {
            std.debug.assert(slice.len < MaxImmediateSizeInBytes);
            var self = CodeSlice{ .len = @intCast(slice.len) };
            std.mem.copyForwards(u8, self.buffer[0..slice.len], slice);
            return self;
        }

        // Initialize from slice, when len extends code slice
        pub inline fn fromSliceExtended(slice: []const u8, len: u8) CodeSlice {
            std.debug.assert(len > slice.len);
            var self = CodeSlice{ .len = len };
            // copy slice into buffer
            for (slice, self.buffer[0..slice.len]) |s, *b| {
                b.* = s;
            }
            // fill the extended length with 0
            for (slice.len..len) |idx| {
                self.buffer[idx] = 0x00;
            }
            return self;
        }
    };

    pub fn getCodeSliceAt(self: *const @This(), pc: u32, len: u32) CodeSlice {
        std.debug.assert(len <= MaxImmediateSizeInBytes);
        const end = pc + len;
        if (pc <= self.code.len and end > self.code.len) {
            // we are extending the code, return 0 buffer
            return CodeSlice.fromSliceExtended(self.code[pc..], @intCast(len));
        } else if (pc > self.code.len) {
            // if pc is outside of code.len
            return CodeSlice.zeroes(@intCast(len));
        }
        // just return the code slice
        return CodeSlice.fromSlice(self.code[pc..][0..len]);
    }

    pub fn getMaskAt(self: *const @This(), mask_index: u32) u8 {
        if (mask_index < self.mask.len) {
            return self.mask[mask_index];
        }

        return 0xFF;
    }

    inline fn decodeInt(self: *const Decoder, comptime T: type, pc: u32) Error!T {
        var overflow_buffer = std.mem.zeroes([MaxImmediateSizeInBytes]u8);
        const slice: *const [@sizeOf(T)]u8 = self.getCodeSliceAt(&overflow_buffer, pc, @sizeOf(T)).asSlice()[0..@sizeOf(T)];
        return std.mem.readInt(T, slice, .little);
    }

    inline fn decodeImmediate(self: *const Decoder, pc: u32, length: u32) Error!u64 {
        var overflow_buffer = std.mem.zeroes([MaxImmediateSizeInBytes]u8);
        const slice = self.getCodeSliceAt(&overflow_buffer, pc, length);
        return immediate.decodeUnsigned(slice);
    }

    inline fn decodeImmediateSigned(self: *const Decoder, pc: u32, length: u32) Error!i64 {
        var overflow_buffer = std.mem.zeroes([MaxImmediateSizeInBytes]u8);
        const slice = self.getCodeSliceAt(&overflow_buffer, pc, length);
        return immediate.decodeSigned(slice);
    }

    inline fn decodeHighNibble(self: *const Decoder, pc: u32) u4 {
        return nibble.getHighNibble(self.getCodeAt(pc));
    }
    inline fn decodeLowNibble(self: *const Decoder, pc: u32) u4 {
        return nibble.getLowNibble(self.getCodeAt(pc));
    }
};

inline fn safeSubstract(comptime T: type, initial: T, values: anytype) !T {
    // This function body will be evaluated at comptime for each unique set of values
    if (values.len == 0) {
        return initial;
    } else {
        var result: T = initial;
        inline for (values) |value| {
            if (result >= value) {
                result = result - value;
            } else {
                return Decoder.Error.invalid_immediate_length;
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
    try std.testing.expectError(Decoder.Error.invalid_immediate_length, safeSubstract(u32, 5, .{ 3, 3 }));
}

test "safeSubstract - different types" {
    try std.testing.expectEqual(@as(u8, 2), try safeSubstract(u8, 5, .{ 2, 1 }));
    try std.testing.expectEqual(@as(i32, 2), try safeSubstract(i32, 10, .{ 5, 3 }));
}

test "safeSubstract - zero result" {
    try std.testing.expectEqual(@as(u32, 0), try safeSubstract(u32, 10, .{ 5, 5 }));
}
