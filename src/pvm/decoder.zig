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

    pub const MaxInstructionSizeInBytes = @import("instruction.zig").MaxInstructionSizeInBytes;

    pub const Error = error{
        InvalidInstruction,
        OutOfBounds,
        TrapOutOfBounds,
        InvalidImmediateLength,
        MaxInstructionSizeInBytesExceeded,
        InvalidRegisterIndex,
    } || decoder.Error;

    pub fn init(code: []const u8, mask: []const u8) Decoder {
        return Decoder{
            .code = code,
            .mask = mask,
        };
    }

    pub fn decodeInstruction(self: *const Decoder, pc: u32) Error!InstructionWithArgs {
        const inst_length = self.skip_l(pc + 1);
        const bytes_slice = try self.getCodeSliceAt(pc, inst_length + 1);

        return try decoder.decodeInstructionFast(bytes_slice.asSlice());
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
        buffer: [MaxInstructionSizeInBytes]u8 = undefined,
        len: u8,

        pub fn asSlice(self: *const @This()) []const u8 {
            return self.buffer[0..self.len];
        }

        pub inline fn zeroes(len: u8) CodeSlice {
            var self = CodeSlice{ .len = len };

            for (0..len) |idx| {
                self.buffer[idx] = 0x00;
            }
            return self;
        }

        pub inline fn fromSlice(slice: []const u8) Error!CodeSlice {
            std.debug.assert(slice.len <= MaxInstructionSizeInBytes);
            var self = CodeSlice{ .len = @intCast(slice.len) };
            std.mem.copyForwards(u8, self.buffer[0..slice.len], slice);
            return self;
        }

        pub inline fn fromSliceExtended(slice: []const u8, len: u8) CodeSlice {
            std.debug.assert(len > slice.len);
            var self = CodeSlice{ .len = len };
            for (slice, self.buffer[0..slice.len]) |s, *b| {
                b.* = s;
            }
            for (slice.len..len) |idx| {
                self.buffer[idx] = 0x00;
            }
            return self;
        }
    };

    pub fn getCodeSliceAt(self: *const @This(), pc: u32, len: u32) !CodeSlice {
        if (len > MaxInstructionSizeInBytes) {
            return Error.MaxInstructionSizeInBytesExceeded;
        }
        const end = pc + len;
        if (pc <= self.code.len and end > self.code.len) {
            return CodeSlice.fromSliceExtended(self.code[pc..], @intCast(len));
        } else if (pc > self.code.len) {
            return CodeSlice.zeroes(@intCast(len));
        }
        return try CodeSlice.fromSlice(self.code[pc..][0..len]);
    }

    pub fn getMaskAt(self: *const @This(), mask_index: u32) u8 {
        if (mask_index < self.mask.len) {
            if (mask_index == self.mask.len - 1) {
                const remaining_bits = self.code.len % 8;
                if (remaining_bits > 0) {
                    const padding_mask = @as(u8, 0xFF) << @intCast(remaining_bits);
                    return self.mask[mask_index] | padding_mask;
                }
            }
            return self.mask[mask_index];
        }

        return 0xFF;
    }

    pub fn iterator(self: *const @This()) Iterator {
        return .{ .decoder = self };
    }

    inline fn decodeInt(self: *const Decoder, comptime T: type, pc: u32) Error!T {
        var overflow_buffer = std.mem.zeroes([MaxInstructionSizeInBytes]u8);
        const slice: *const [@sizeOf(T)]u8 = (try self.getCodeSliceAt(&overflow_buffer, pc, @sizeOf(T))).asSlice()[0..@sizeOf(T)];
        return std.mem.readInt(T, slice, .little);
    }

    inline fn decodeImmediate(self: *const Decoder, pc: u32, length: u32) Error!u64 {
        var overflow_buffer = std.mem.zeroes([MaxInstructionSizeInBytes]u8);
        const slice = (try self.getCodeSliceAt(&overflow_buffer, pc, length));
        return immediate.decodeUnsigned(slice);
    }

    inline fn decodeImmediateSigned(self: *const Decoder, pc: u32, length: u32) Error!i64 {
        var overflow_buffer = std.mem.zeroes([MaxInstructionSizeInBytes]u8);
        const slice = (try self.getCodeSliceAt(&overflow_buffer, pc, length));
        return immediate.decodeSigned(slice);
    }

    inline fn decodeHighNibble(self: *const Decoder, pc: u32) u4 {
        return nibble.getHighNibble(self.getCodeAt(pc));
    }
    inline fn decodeLowNibble(self: *const Decoder, pc: u32) u4 {
        return nibble.getLowNibble(self.getCodeAt(pc));
    }
};

const Iterator = struct {
    decoder: *const Decoder,
    pc: u32 = 0,

    const Entry = struct {
        pc: u32,
        next_pc: u32,
        inst: InstructionWithArgs,
        raw: []const u8,
    };

    pub fn next(self: *@This()) !?Entry {
        if (self.pc >= self.decoder.code.len) return null;

        const current_pc = self.pc;
        const inst = try self.decoder.decodeInstruction(current_pc);
        // TODO: the +1 is becuse the skip_l is from the args. This should be in the skip_l
        self.pc += inst.skip_l() + 1;
        return .{
            .pc = current_pc,
            .next_pc = self.pc,
            .inst = inst,
            // Since in some cases the pc can extend code.len
            .raw = self.decoder.code[current_pc..@min(self.pc, self.decoder.code.len)],
        };
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
                return Decoder.Error.InvalidImmediateLength;
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
    try std.testing.expectError(Decoder.Error.InvalidImmediateLength, safeSubstract(u32, 5, .{ 3, 4 }));
}

test "safeSubstract - different types" {
    try std.testing.expectEqual(@as(u8, 2), try safeSubstract(u8, 5, .{ 2, 1 }));
    try std.testing.expectEqual(@as(i32, 2), try safeSubstract(i32, 10, .{ 5, 3 }));
}

test "safeSubstract - zero result" {
    try std.testing.expectEqual(@as(u32, 0), try safeSubstract(u32, 10, .{ 5, 5 }));
}

test "skip_l - no skip when mask bit is 1" {
    const code = &[_]u8{0} ** 16;
    const mask = &[_]u8{0xFF} ** 2;
    const d = Decoder.init(code, mask);
    try std.testing.expectEqual(@as(u32, 0), d.skip_l(0));
}

test "skip_l - skip until first 1 bit" {
    const code = &[_]u8{0} ** 16;
    const mask = &[_]u8{ 0b00001000, 0xFF };
    const d = Decoder.init(code, mask);
    try std.testing.expectEqual(@as(u32, 3), d.skip_l(0));
}

test "skip_l - skip across byte boundary" {
    const code = &[_]u8{0} ** 16;
    const mask = &[_]u8{ 0b00000000, 0b00000001 };
    const d = Decoder.init(code, mask);
    try std.testing.expectEqual(@as(u32, 8), d.skip_l(0));
}

test "skip_l - skip across byte boundary from middle" {
    const code = &[_]u8{0} ** 16;
    const mask = &[_]u8{ 0b00000000, 0b00000001 };
    const d = Decoder.init(code, mask);
    try std.testing.expectEqual(@as(u32, 4), d.skip_l(4));
}

test "skip_l - start from middle of byte" {
    const code = &[_]u8{0} ** 16;
    const mask = &[_]u8{ 0b11110000, 0xFF };
    const d = Decoder.init(code, mask);
    try std.testing.expectEqual(@as(u32, 0), d.skip_l(5));
}

test "skip_l - skip with non-zero pc" {
    const code = &[_]u8{0} ** 16;
    const mask = &[_]u8{ 0xFF, 0b00001000 };
    const d = Decoder.init(code, mask);
    try std.testing.expectEqual(@as(u32, 3), d.skip_l(8));
}

test "skip_l - skip at end of mask" {
    const code = &[_]u8{0} ** 16;
    const mask = &[_]u8{0xFF};
    const d = Decoder.init(code, mask);
    // When we're beyond mask length, getMaskAt returns 0xFF, so no skip
    try std.testing.expectEqual(@as(u32, 0), d.skip_l(8));
}

test "skip_l - skip at end of mask with zeroes" {
    const code = &[_]u8{0} ** 16;
    const mask = &[_]u8{0x00};
    const d = Decoder.init(code, mask);
    // When we have no 1's will skip
    try std.testing.expectEqual(@as(u32, 8), d.skip_l(0));
}
