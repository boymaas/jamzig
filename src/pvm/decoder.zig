const std = @import("std");
pub const Instruction = @import("instruction.zig").Instruction;

pub const ArgumentType = @import("./decoder/types.zig").ArgumentType;

const Immediate = @import("./decoder/immediate.zig");
const Nibble = @import("./decoder/nibble.zig");

const updatePc = @import("./utils.zig").updatePc;

pub const InstructionWithArgs = struct {
    instruction: Instruction,
    args_type: ArgumentType,
    args: InstructionArgs,

    pub fn skip_l(self: *const @This()) u32 {
        return self.args.skip_l();
    }

    pub fn format(
        self: *const @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try @import("./decoder/format.zig").formatInstructionWithArgs(self, fmt, options, writer);
    }
};

pub const Decoder = struct {
    code: []const u8,
    mask: []const u8,

    pub const Error = error{
        invalid_instruction,
        out_of_bounds,
        invalid_immediate_length,
        invalid_register_index,
    };

    pub fn init(code: []const u8, mask: []const u8) Decoder {
        return Decoder{
            .code = code,
            .mask = mask,
        };
    }

    pub fn decodeInstruction(self: *const Decoder, pc: u32) Error!InstructionWithArgs {
        const instruction = std.meta.intToEnum(Instruction, self.getCodeAt(pc)) catch {
            std.debug.print("Error decoding instruction at pc {}: code 0x{X:0>2} ({d})\n", .{ pc, self.getCodeAt(pc), self.getCodeAt(pc) });
            return Error.invalid_instruction;
        };
        const args_type = ArgumentType.lookup(instruction);

        const args = switch (args_type) {
            .no_arguments => InstructionArgs{ .no_arguments = .{ .no_of_bytes_to_skip = 0 } },
            .one_immediate => try self.decodeOneImmediate(pc),
            .one_offset => try self.decodeOneOffset(pc),
            .one_register_one_immediate => try self.decodeOneRegisterOneImmediate(pc),
            .one_register_one_immediate_one_offset => try self.decodeOneRegisterOneImmediateOneOffset(pc),
            .one_register_one_extended_immediate => try self.decodeOneRegisterOneExtendedImmediate(pc),
            .one_register_two_immediates => try self.decodeOneRegisterTwoImmediates(pc),
            .three_registers => try self.decodeThreeRegisters(pc),
            .two_immediates => try self.decodeTwoImmediates(pc),
            .two_registers => try self.decodeTwoRegisters(pc),
            .two_registers_one_immediate => try self.decodeTwoRegistersOneImmediate(pc),
            .two_registers_one_offset => try self.decodeTwoRegistersOneOffset(pc),
            .two_registers_two_immediates => try self.decodeTwoRegistersTwoImmediates(pc),
        };

        return InstructionWithArgs{
            .instruction = instruction,
            .args_type = args_type,
            .args = args,
        };
    }

    fn decodeOneImmediate(self: *const Decoder, pc: u32) Error!InstructionArgs {
        const l = @min(4, self.skip_l(pc + 1));
        return .{
            .one_immediate = .{
                .no_of_bytes_to_skip = l,
                .immediate = try self.decodeImmediate(pc + 1, l),
            },
        };
    }

    fn decodeTwoImmediates(self: *const Decoder, pc: u32) Error!InstructionArgs {
        const l = self.skip_l(pc + 1);
        const l_x = self.decodeLowNibble(pc + 1) % 8;
        const l_y = @min(4, l - l_x - 1);
        return .{
            .two_immediates = .{
                .no_of_bytes_to_skip = 1 + l_x + l_y,
                .first_immediate = try self.decodeImmediate(pc + 2, l_x),
                .second_immediate = try self.decodeImmediate(pc + 2 + l_x, l_y),
            },
        };
    }

    fn decodeOneOffset(self: *const Decoder, pc: u32) Error!InstructionArgs {
        const l_x = @min(4, self.skip_l(pc + 1));
        const offset = @as(
            i32,
            @intCast(try self.decodeImmediateSigned(pc + 1, l_x)),
        );
        return .{
            .one_offset = .{
                .no_of_bytes_to_skip = l_x,
                .offset = offset,
            },
        };
    }

    fn decodeOneRegisterOneImmediate(self: *const Decoder, pc: u32) Error!InstructionArgs {
        const l = self.skip_l(pc + 1);
        const r_a = @min(12, self.decodeLowNibble(pc + 1));
        const l_x = @min(4, l -| 1);
        return .{
            .one_register_one_immediate = .{
                .no_of_bytes_to_skip = l,
                .register_index = r_a,
                .immediate = try self.decodeImmediate(pc + 2, l_x),
            },
        };
    }

    fn decodeOneRegisterTwoImmediates(self: *const Decoder, pc: u32) Error!InstructionArgs {
        const l = self.skip_l(pc + 1);
        const r_a = @min(12, self.decodeLowNibble(pc + 1));
        const l_x = @min(4, self.decodeHighNibble(pc + 1) % 8);
        const l_y = @min(4, @max(0, l - l_x - 1));
        return .{
            .one_register_two_immediates = .{
                .no_of_bytes_to_skip = l,
                .register_index = r_a,
                .first_immediate = try self.decodeImmediate(pc + 2, l_x),
                .second_immediate = try self.decodeImmediate(pc + 2 + l_x, l_y),
            },
        };
    }

    fn decodeOneRegisterOneImmediateOneOffset(self: *const Decoder, pc: u32) Error!InstructionArgs {
        const l = self.skip_l(pc + 1);
        const r_a = @min(12, self.decodeLowNibble(pc + 1));
        const l_x = @min(4, self.decodeHighNibble(pc + 1) % 8);
        const l_y = @min(4, @max(0, l - l_x - 1));
        const offset = @as(i32, @intCast(try self.decodeImmediateSigned(pc + 2 + l_x, l_y)));
        return .{
            .one_register_one_immediate_one_offset = .{
                .no_of_bytes_to_skip = l,
                .register_index = r_a,
                .immediate = try self.decodeImmediate(pc + 2, l_x),
                .offset = offset,
            },
        };
    }

    fn decodeOneRegisterOneExtendedImmediate(self: *const Decoder, pc: u32) Error!InstructionArgs {
        const r_a = @min(12, self.decodeLowNibble(pc + 1));
        return .{
            .one_register_one_extended_immediate = .{
                .no_of_bytes_to_skip = 9, // 1 byte opcode + 8 bytes immediate
                .register_index = r_a,
                .immediate = try self.decodeInt(u64, pc + 2),
            },
        };
    }

    fn decodeTwoRegisters(self: *const Decoder, pc: u32) Error!InstructionArgs {
        const l = self.skip_l(pc + 1);
        const r_d = @min(12, self.decodeLowNibble(pc + 1));
        const r_a = @min(12, self.decodeHighNibble(pc + 1));
        return .{
            .two_registers = .{
                .no_of_bytes_to_skip = l,
                .first_register_index = r_d,
                .second_register_index = r_a,
            },
        };
    }

    fn decodeTwoRegistersOneImmediate(self: *const Decoder, pc: u32) Error!InstructionArgs {
        const l = self.skip_l(pc + 1);
        const r_a = @min(12, self.decodeLowNibble(pc + 1));
        const r_b = @min(12, self.decodeHighNibble(pc + 1));
        const l_x = @min(4, l - 1);
        return .{
            .two_registers_one_immediate = .{
                .no_of_bytes_to_skip = l,
                .first_register_index = r_a,
                .second_register_index = r_b,
                .immediate = try self.decodeImmediate(pc + 2, l_x),
            },
        };
    }

    fn decodeTwoRegistersOneOffset(self: *const Decoder, pc: u32) Error!InstructionArgs {
        const l_prev = self.skip_l(pc + 1);
        _ = l_prev;
        const l = self.skip_l(pc + 1);
        const r_a = @min(12, self.decodeLowNibble(pc + 1));
        const r_b = @min(12, self.decodeHighNibble(pc + 1));
        const l_x = @min(4, l - 1);
        const offset = @as(i32, @intCast(try self.decodeImmediateSigned(pc + 2, l_x)));
        return .{
            .two_registers_one_offset = .{
                .no_of_bytes_to_skip = l,
                .first_register_index = r_a,
                .second_register_index = r_b,
                .offset = offset,
            },
        };
    }

    fn decodeTwoRegistersTwoImmediates(self: *const Decoder, pc: u32) Error!InstructionArgs {
        const l = self.skip_l(pc + 1);
        const r_a = @min(12, self.decodeLowNibble(pc + 1));
        const r_b = @min(12, self.decodeHighNibble(pc + 1));
        const l_x = @min(4, self.decodeLowNibble(pc + 2) % 8);
        const l_y = @min(4, @max(0, l - l_x - 2));
        return .{
            .two_registers_two_immediates = .{
                .no_of_bytes_to_skip = l,
                .first_register_index = r_a,
                .second_register_index = r_b,
                .first_immediate = try self.decodeImmediate(pc + 2, l_x),
                .second_immediate = try self.decodeImmediate(pc + 2 + l_x, l_y),
            },
        };
    }

    fn decodeThreeRegisters(self: *const Decoder, pc: u32) Error!InstructionArgs {
        const l = self.skip_l(pc + 1);
        const r_a = @min(12, self.decodeLowNibble(pc + 1));
        const r_b = @min(12, self.decodeHighNibble(pc + 1));
        const r_d = @min(12, self.getCodeAt(pc + 2));
        return .{
            .three_registers = .{
                .no_of_bytes_to_skip = l,
                .first_register_index = r_a,
                .second_register_index = r_b,
                .third_register_index = r_d,
            },
        };
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

    pub fn getCodeSliceAt(self: *const @This(), pc: u32, len: u32) ![]const u8 {
        const end = pc + len;
        if (end > self.code.len) {
            return Error.out_of_bounds;
        }
        return self.code[pc..end];
    }

    pub fn getCodeSliceAtFixed(self: *const @This(), pc: u32, comptime len: u32) Error!*const [len]u8 {
        const end = pc + len;
        if (end > self.code.len) {
            return Error.out_of_bounds;
        }
        return self.code[pc..end][0..len];
    }

    pub fn getMaskAt(self: *const @This(), mask_index: u32) u8 {
        if (mask_index < self.mask.len) {
            return self.mask[mask_index];
        }

        return 0xFF;
    }

    inline fn decodeInt(self: *const Decoder, comptime T: type, pc: u32) Error!T {
        const slice = try self.getCodeSliceAtFixed(pc, @sizeOf(T));
        return std.mem.readInt(T, slice, .little);
    }

    inline fn decodeImmediate(self: *const Decoder, pc: u32, length: u32) Error!u64 {
        const slice = try self.getCodeSliceAt(pc, length);
        return Immediate.decodeUnsigned(slice);
    }

    inline fn decodeImmediateSigned(self: *const Decoder, pc: u32, length: u32) Error!i64 {
        const slice = try self.getCodeSliceAt(pc, length);
        return Immediate.decodeSigned(slice);
    }

    inline fn decodeHighNibble(self: *const Decoder, pc: u32) u4 {
        return Nibble.getHighNibble(self.getCodeAt(pc));
    }
    inline fn decodeLowNibble(self: *const Decoder, pc: u32) u4 {
        return Nibble.getLowNibble(self.getCodeAt(pc));
    }
};

pub const InstructionArgs = union(ArgumentType) {
    no_arguments: struct { no_of_bytes_to_skip: u32 },
    one_immediate: struct { no_of_bytes_to_skip: u32, immediate: u64 },
    one_offset: struct {
        no_of_bytes_to_skip: u32,
        offset: i32,
    },
    one_register_one_immediate: struct {
        no_of_bytes_to_skip: u32,
        register_index: u8,
        immediate: u64,
    },
    one_register_one_immediate_one_offset: struct {
        no_of_bytes_to_skip: u32,
        register_index: u8,
        immediate: u64,
        offset: i32,
    },
    one_register_one_extended_immediate: struct {
        no_of_bytes_to_skip: u32,
        register_index: u8,
        immediate: u64,
    },
    one_register_two_immediates: struct {
        no_of_bytes_to_skip: u32,
        register_index: u8,
        first_immediate: u64,
        second_immediate: u64,
    },
    three_registers: struct {
        no_of_bytes_to_skip: u32,
        first_register_index: u8,
        second_register_index: u8,
        third_register_index: u8,
    },
    two_immediates: struct {
        no_of_bytes_to_skip: u32,
        first_immediate: u64,
        second_immediate: u64,
    },
    two_registers: struct {
        no_of_bytes_to_skip: u32,
        first_register_index: u8,
        second_register_index: u8,
    },
    two_registers_one_immediate: struct {
        no_of_bytes_to_skip: u32,
        first_register_index: u8,
        second_register_index: u8,
        immediate: u64,
    },
    two_registers_one_offset: struct {
        no_of_bytes_to_skip: u32,
        first_register_index: u8,
        second_register_index: u8,
        offset: i32,
    },
    two_registers_two_immediates: struct {
        no_of_bytes_to_skip: u32,
        first_register_index: u8,
        second_register_index: u8,
        first_immediate: u64,
        second_immediate: u64,
    },

    pub fn skip_l(self: *const @This()) u32 {
        return switch (self.*) {
            .no_arguments => |v| v.no_of_bytes_to_skip,
            .one_immediate => |v| v.no_of_bytes_to_skip,
            .one_offset => |v| v.no_of_bytes_to_skip,
            .one_register_one_immediate => |v| v.no_of_bytes_to_skip,
            .one_register_one_immediate_one_offset => |v| v.no_of_bytes_to_skip,
            .one_register_two_immediates => |v| v.no_of_bytes_to_skip,
            .one_register_one_extended_immediate => |v| v.no_of_bytes_to_skip,
            .three_registers => |v| v.no_of_bytes_to_skip,
            .two_immediates => |v| v.no_of_bytes_to_skip,
            .two_registers => |v| v.no_of_bytes_to_skip,
            .two_registers_one_immediate => |v| v.no_of_bytes_to_skip,
            .two_registers_one_offset => |v| v.no_of_bytes_to_skip,
            .two_registers_two_immediates => |v| v.no_of_bytes_to_skip,
        };
    }
};
