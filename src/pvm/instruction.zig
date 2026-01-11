const std = @import("std");

// each instruction's 'length' (defined as the number of contiguous octets
// starting with the opcode which are needed to fully define the instruction's
// semantics) is left implicit though limited to being at most 16.
pub const MaxInstructionSizeInBytes = 16;

pub const Instruction = enum(u8) {
    // A.5.1. Instructions without Arguments
    trap = 0,
    fallthrough = 1,

    // A.5.2. Instructions with Arguments of One Immediate
    ecalli = 10,

    // A.5.3. Instructions with Arguments of One Register and One Extended Width Immediate
    load_imm_64 = 20,

    // A.5.4. Instructions with Arguments of Two Immediates
    store_imm_u8 = 30,
    store_imm_u16 = 31,
    store_imm_u32 = 32,
    store_imm_u64 = 33,

    // A.5.5. Instructions with Arguments of One Offset
    jump = 40,

    // A.5.6. Instructions with Arguments of One Register & One Immediate
    jump_ind = 50,
    load_imm = 51,
    load_u8 = 52,
    load_i8 = 53,
    load_u16 = 54,
    load_i16 = 55,
    load_u32 = 56,
    load_i32 = 57,
    load_u64 = 58,
    store_u8 = 59,
    store_u16 = 60,
    store_u32 = 61,
    store_u64 = 62,

    // A.5.7. Instructions with Arguments of One Register & Two Immediates
    store_imm_ind_u8 = 70,
    store_imm_ind_u16 = 71,
    store_imm_ind_u32 = 72,
    store_imm_ind_u64 = 73,

    // A.5.8. Instructions with Arguments of One Register, One Immediate and One Offset
    load_imm_jump = 80,
    branch_eq_imm = 81,
    branch_ne_imm = 82,
    branch_lt_u_imm = 83,
    branch_le_u_imm = 84,
    branch_ge_u_imm = 85,
    branch_gt_u_imm = 86,
    branch_lt_s_imm = 87,
    branch_le_s_imm = 88,
    branch_ge_s_imm = 89,
    branch_gt_s_imm = 90,

    // A.5.9. Instructions with Arguments of Two Registers
    move_reg = 100,
    sbrk = 101,
    count_set_bits_64 = 102,
    count_set_bits_32 = 103,
    leading_zero_bits_64 = 104,
    leading_zero_bits_32 = 105,
    trailing_zero_bits_64 = 106,
    trailing_zero_bits_32 = 107,
    sign_extend_8 = 108,
    sign_extend_16 = 109,
    zero_extend_16 = 110,
    reverse_bytes = 111,

    // A.5.10. Instructions with Arguments of Two Registers & One Immediate
    store_ind_u8 = 120,
    store_ind_u16 = 121,
    store_ind_u32 = 122,
    store_ind_u64 = 123,
    load_ind_u8 = 124,
    load_ind_i8 = 125,
    load_ind_u16 = 126,
    load_ind_i16 = 127,
    load_ind_u32 = 128,
    load_ind_i32 = 129,
    load_ind_u64 = 130,
    add_imm_32 = 131,
    and_imm = 132,
    xor_imm = 133,
    or_imm = 134,
    mul_imm_32 = 135,
    set_lt_u_imm = 136,
    set_lt_s_imm = 137,
    shlo_l_imm_32 = 138,
    shlo_r_imm_32 = 139,
    shar_r_imm_32 = 140,
    neg_add_imm_32 = 141,
    set_gt_u_imm = 142,
    set_gt_s_imm = 143,
    shlo_l_imm_alt_32 = 144,
    shlo_r_imm_alt_32 = 145,
    shar_r_imm_alt_32 = 146,
    cmov_iz_imm = 147,
    cmov_nz_imm = 148,
    add_imm_64 = 149,
    mul_imm_64 = 150,
    shlo_l_imm_64 = 151,
    shlo_r_imm_64 = 152,
    shar_r_imm_64 = 153,
    neg_add_imm_64 = 154,
    shlo_l_imm_alt_64 = 155,
    shlo_r_imm_alt_64 = 156,
    shar_r_imm_alt_64 = 157,
    rot_r_64_imm = 158,
    rot_r_64_imm_alt = 159,
    rot_r_32_imm = 160,
    rot_r_32_imm_alt = 161,

    // A.5.11. Instructions with Arguments of Two Registers & One Offset
    branch_eq = 170,
    branch_ne = 171,
    branch_lt_u = 172,
    branch_lt_s = 173,
    branch_ge_u = 174,
    branch_ge_s = 175,

    // A.5.12. Instructions with Arguments of Two Registers and Two Immediates
    load_imm_jump_ind = 180,

    // A.5.13. Instructions with Arguments of Three Registers
    add_32 = 190,
    sub_32 = 191,
    mul_32 = 192,
    div_u_32 = 193,
    div_s_32 = 194,
    rem_u_32 = 195,
    rem_s_32 = 196,
    shlo_l_32 = 197,
    shlo_r_32 = 198,
    shar_r_32 = 199,
    add_64 = 200,
    sub_64 = 201,
    mul_64 = 202,
    div_u_64 = 203,
    div_s_64 = 204,
    rem_u_64 = 205,
    rem_s_64 = 206,
    shlo_l_64 = 207,
    shlo_r_64 = 208,
    shar_r_64 = 209,
    @"and" = 210,
    xor = 211,
    @"or" = 212,
    mul_upper_s_s = 213,
    mul_upper_u_u = 214,
    mul_upper_s_u = 215,
    set_lt_u = 216,
    set_lt_s = 217,
    cmov_iz = 218,
    cmov_nz = 219,
    rot_l_64 = 220,
    rot_l_32 = 221,
    rot_r_64 = 222,
    rot_r_32 = 223,
    and_inv = 224,
    or_inv = 225,
    xnor = 226,
    max = 227,
    max_u = 228,
    min = 229,
    min_u = 230,
};

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

    pub fn lookUp(inst: Instruction) InstructionType {
        const opcode = @intFromEnum(inst);
        inline for (std.meta.fields(InstructionType)) |field| {
            if (comptime InstructionRanges.get(field.name)) |range| {
                if (opcode >= range.start and opcode <= range.end) {
                    return @enumFromInt(field.value);
                }
            } else {
                @compileError("Missing range definition in InstructionRanges for instruction type '" ++ field.name ++ "'");
            }
        }
        unreachable;
    }
};

/// Maps instruction types to their valid opcode ranges
const InstructionRange = struct {
    start: u8,
    end: u8,
};

const IKV = struct { []const u8, InstructionRange };

pub const InstructionRanges = std.StaticStringMap(InstructionRange)
    .initComptime(.{
    // A.5.1 - No arguments instructions (trap, fallthrough)
    IKV{ "NoArgs", .{ .start = 0, .end = 1 } },

    // A.5.2 - Instructions with one immediate (ecalli)
    IKV{ "OneImm", .{ .start = 10, .end = 10 } },

    // A.5.3 - Instructions with one register and one extended immediate (load_imm_64)
    IKV{ "OneRegOneExtImm", .{ .start = 20, .end = 20 } },

    // A.5.4 - Instructions with two immediates (store_imm_* family)
    IKV{ "TwoImm", .{ .start = 30, .end = 33 } },

    // A.5.5 - Instructions with one offset (jump)
    IKV{ "OneOffset", .{ .start = 40, .end = 40 } },

    // A.5.6 - Instructions with one register and one immediate (jump_ind through store_u64)
    IKV{ "OneRegOneImm", .{ .start = 50, .end = 62 } },

    // A.5.7 - Instructions with one register and two immediates (store_imm_ind_* family)
    IKV{ "OneRegTwoImm", .{ .start = 70, .end = 73 } },

    // A.5.8 - Instructions with one register, one immediate and one offset (load_imm_jump through branch_gt_s_imm)
    IKV{ "OneRegOneImmOneOffset", .{ .start = 80, .end = 90 } },

    // A.5.9 - Instructions with two registers (move_reg through reverse_bytes)
    IKV{ "TwoReg", .{ .start = 100, .end = 111 } }, // Updated end to include new instructions

    // A.5.10 - Instructions with two registers and one immediate (store_ind_* through rot_r_32_imm_alt)
    IKV{ "TwoRegOneImm", .{ .start = 120, .end = 161 } }, // Updated range to reflect new IDs and instructions

    // A.5.11 - Instructions with two registers and one offset (branch_* family)
    IKV{ "TwoRegOneOffset", .{ .start = 170, .end = 175 } }, // Updated range to match new IDs

    // A.5.12 - Instructions with two registers and two immediates (load_imm_jump_ind)
    IKV{ "TwoRegTwoImm", .{ .start = 180, .end = 180 } }, // Updated start to match new ID

    // A.5.13 - Instructions with three registers (add_32 through min_u)
    IKV{ "ThreeReg", .{ .start = 190, .end = 230 } }, // Updated range to include new instructions
});

//  ___           _                   _   _                _
// |_ _|_ __  ___| |_ _ __ _   _  ___| |_(_) ___  _ __    / \   _ __ __ _ ___
//  | || '_ \/ __| __| '__| | | |/ __| __| |/ _ \| '_ \  / _ \ | '__/ _` / __|
//  | || | | \__ \ |_| |  | |_| | (__| |_| | (_) | | | |/ ___ \| | | (_| \__ \
// |___|_| |_|___/\__|_|   \__,_|\___|\__|_|\___/|_| |_/_/   \_\_|  \__, |___/
//                                                                  |___/

pub const InstructionArgs = union(InstructionType) {

    // Instruction argument types
    // TODO: rename ..Type to ..Args
    pub const NoArgsType = struct { no_of_bytes_to_skip: u32 };
    pub const OneImmType = struct { no_of_bytes_to_skip: u32, immediate: u64 };
    pub const OneRegOneExtImmType = struct {
        no_of_bytes_to_skip: u32,
        register_index: u8,
        immediate: u64,
    };
    pub const TwoImmType = struct {
        no_of_bytes_to_skip: u32,
        first_immediate: u64,
        second_immediate: u64,
    };
    pub const OneOffsetType = struct {
        no_of_bytes_to_skip: u32,
        offset: i32,
    };
    pub const OneRegOneImmType = struct {
        no_of_bytes_to_skip: u32,
        register_index: u8,
        immediate: u64,
    };
    pub const OneRegTwoImmType = struct {
        no_of_bytes_to_skip: u32,
        register_index: u8,
        first_immediate: u64,
        second_immediate: u64,
    };
    pub const OneRegOneImmOneOffsetType = struct {
        no_of_bytes_to_skip: u32,
        register_index: u8,
        immediate: u64,
        offset: i32,
    };
    pub const TwoRegType = struct {
        no_of_bytes_to_skip: u32,
        first_register_index: u8,
        second_register_index: u8,
    };
    pub const TwoRegOneImmType = struct {
        no_of_bytes_to_skip: u32,
        first_register_index: u8,
        second_register_index: u8,
        immediate: u64,
    };
    pub const TwoRegOneOffsetType = struct {
        no_of_bytes_to_skip: u32,
        first_register_index: u8,
        second_register_index: u8,
        offset: i32,
    };
    pub const TwoRegTwoImmType = struct {
        no_of_bytes_to_skip: u32,
        first_register_index: u8,
        second_register_index: u8,
        first_immediate: u64,
        second_immediate: u64,
    };
    pub const ThreeRegType = struct {
        no_of_bytes_to_skip: u32,
        first_register_index: u8,
        second_register_index: u8,
        third_register_index: u8,
    };

    // A.5.1
    NoArgs: NoArgsType,
    // A.5.2
    OneImm: OneImmType,
    // A.5.3
    OneRegOneExtImm: OneRegOneExtImmType,
    // A.5.4
    TwoImm: TwoImmType,
    // A.5.5
    OneOffset: OneOffsetType,
    // A.5.6
    OneRegOneImm: OneRegOneImmType,
    // A.5.7
    OneRegTwoImm: OneRegTwoImmType,
    // A.5.8
    OneRegOneImmOneOffset: OneRegOneImmOneOffsetType,
    // A.5.9
    TwoReg: TwoRegType,
    // A.5.10
    TwoRegOneImm: TwoRegOneImmType,
    // A.5.11
    TwoRegOneOffset: TwoRegOneOffsetType,
    // A.5.12
    TwoRegTwoImm: TwoRegTwoImmType,
    // A.5.13
    ThreeReg: ThreeRegType,

    pub fn skip_l(self: *const @This()) u32 {
        return switch (self.*) {
            .NoArgs => |v| v.no_of_bytes_to_skip,
            .OneImm => |v| v.no_of_bytes_to_skip,
            .OneOffset => |v| v.no_of_bytes_to_skip,
            .OneRegOneImm => |v| v.no_of_bytes_to_skip,
            .OneRegOneImmOneOffset => |v| v.no_of_bytes_to_skip,
            .OneRegTwoImm => |v| v.no_of_bytes_to_skip,
            .OneRegOneExtImm => |v| v.no_of_bytes_to_skip,
            .ThreeReg => |v| v.no_of_bytes_to_skip,
            .TwoImm => |v| v.no_of_bytes_to_skip,
            .TwoReg => |v| v.no_of_bytes_to_skip,
            .TwoRegOneImm => |v| v.no_of_bytes_to_skip,
            .TwoRegOneOffset => |v| v.no_of_bytes_to_skip,
            .TwoRegTwoImm => |v| v.no_of_bytes_to_skip,
        };
    }
};

pub const InstructionWithArgs = struct {
    instruction: Instruction,
    args: InstructionArgs,

    pub fn encode(self: *const @This(), writer: anytype) !u8 {
        return try @import("instruction/encoder.zig").encodeInstruction(writer, self);
    }

    pub fn encodeOwned(self: *const @This()) !@import("instruction/encoder.zig").EncodedInstruction {
        return try @import("instruction/encoder.zig").encodeInstructionOwned(self);
    }

    pub fn size(self: *const @This()) !u8 {
        return try @import("instruction/encoder.zig").sizeOfInstruction(self);
    }

    pub fn isTerminationInstruction(self: *const @This()) bool {
        return self.isTrap() or self.isFallthrough() or
            self.isJump() or
            self.isLoadAndJump() or
            self.isBranch() or
            self.isBranchWithImm();
    }

    pub fn isTrap(self: *const @This()) bool {
        return self.instruction == .trap;
    }

    pub fn isFallthrough(self: *const @This()) bool {
        return self.instruction == .fallthrough;
    }

    pub fn isJump(self: *const @This()) bool {
        return switch (self.instruction) {
            .jump,
            .jump_ind,
            => true,
            else => false,
        };
    }

    pub fn isLoadAndJump(self: *const @This()) bool {
        return switch (self.instruction) {
            .load_imm_jump,
            .load_imm_jump_ind,
            => true,
            else => false,
        };
    }

    pub fn isBranch(self: *const @This()) bool {
        return switch (self.instruction) {
            .branch_eq,
            .branch_ne,
            .branch_ge_u,
            .branch_ge_s,
            .branch_lt_u,
            .branch_lt_s,
            .branch_eq_imm,
            .branch_ne_imm,
            => true,
            else => false,
        };
    }

    pub fn isBranchWithImm(self: *const @This()) bool {
        return switch (self.instruction) {
            .branch_lt_u_imm,
            .branch_lt_s_imm,
            .branch_le_u_imm,
            .branch_le_s_imm,
            .branch_ge_u_imm,
            .branch_ge_s_imm,
            .branch_gt_u_imm,
            .branch_gt_s_imm,
            => true,
            else => false,
        };
    }

    pub const MemoryAccess = struct {
        address: u64,
        size: u8,
        isWrite: bool,
        isIndirect: bool,
    };

    pub fn getMemoryAccessInd(self: *const InstructionWithArgs, registers: *[13]u64) !MemoryAccess {
        return switch (self.instruction) {

            // Indirect load operations
            .load_ind_u8, .load_ind_i8 => .{
                .address = self.args.TwoRegOneImm.immediate + registers[self.args.TwoRegOneImm.second_register_index],
                .size = 1,
                .isWrite = false,
                .isIndirect = true,
            },
            .load_ind_u16, .load_ind_i16 => .{
                .address = self.args.TwoRegOneImm.immediate + registers[self.args.TwoRegOneImm.second_register_index],
                .size = 2,
                .isWrite = false,
                .isIndirect = true,
            },
            .load_ind_u32, .load_ind_i32 => .{
                .address = self.args.TwoRegOneImm.immediate + registers[self.args.TwoRegOneImm.second_register_index],
                .size = 4,
                .isWrite = false,
                .isIndirect = true,
            },
            .load_ind_u64 => .{
                .address = self.args.TwoRegOneImm.immediate + registers[self.args.TwoRegOneImm.second_register_index],
                .size = 8,
                .isWrite = false,
                .isIndirect = true,
            },

            // Indirect store operations
            .store_ind_u8 => .{
                .address = self.args.TwoRegOneImm.immediate + registers[self.args.TwoRegOneImm.second_register_index],
                .size = 1,
                .isWrite = true,
                .isIndirect = true,
            },
            .store_ind_u16 => .{
                .address = self.args.TwoRegOneImm.immediate + registers[self.args.TwoRegOneImm.second_register_index],
                .size = 2,
                .isWrite = true,
                .isIndirect = true,
            },
            .store_ind_u32 => .{
                .address = self.args.TwoRegOneImm.immediate + registers[self.args.TwoRegOneImm.second_register_index],
                .size = 4,
                .isWrite = true,
                .isIndirect = true,
            },
            .store_ind_u64 => .{
                .address = self.args.TwoRegOneImm.immediate + registers[self.args.TwoRegOneImm.second_register_index],
                .size = 8,
                .isWrite = true,
                .isIndirect = true,
            },

            // Indirect immediate store operations
            .store_imm_ind_u8 => .{
                .address = self.args.OneRegTwoImm.first_immediate + registers[self.args.OneRegTwoImm.register_index],
                .size = 1,
                .isWrite = true,
                .isIndirect = true,
            },
            .store_imm_ind_u16 => .{
                .address = self.args.OneRegTwoImm.first_immediate + registers[self.args.OneRegTwoImm.register_index],
                .size = 2,
                .isWrite = true,
                .isIndirect = true,
            },
            .store_imm_ind_u32 => .{
                .address = self.args.OneRegTwoImm.first_immediate + registers[self.args.OneRegTwoImm.register_index],
                .size = 4,
                .isWrite = true,
                .isIndirect = true,
            },
            .store_imm_ind_u64 => .{
                .address = self.args.OneRegTwoImm.first_immediate + registers[self.args.OneRegTwoImm.register_index],
                .size = 8,
                .isWrite = true,
                .isIndirect = true,
            },

            // Non-memory instructions
            else => return error.NotInAccess,
        };
    }

    pub fn getMemoryAccess(self: *const InstructionWithArgs) ?MemoryAccess {
        return switch (self.instruction) {
            // Load operations
            .load_u8, .load_i8 => .{ .address = self.args.OneRegOneImm.immediate, .size = 1, .isWrite = false, .isIndirect = false },
            .load_u16, .load_i16 => .{ .address = self.args.OneRegOneImm.immediate, .size = 2, .isWrite = false, .isIndirect = false },
            .load_u32, .load_i32 => .{ .address = self.args.OneRegOneImm.immediate, .size = 4, .isWrite = false, .isIndirect = false },
            .load_u64 => .{ .address = self.args.OneRegOneImm.immediate, .size = 8, .isWrite = false, .isIndirect = false },

            // Indirect load operations
            .load_ind_u8, .load_ind_i8 => .{ .address = self.args.TwoRegOneImm.immediate, .size = 1, .isWrite = false, .isIndirect = true },
            .load_ind_u16, .load_ind_i16 => .{ .address = self.args.TwoRegOneImm.immediate, .size = 2, .isWrite = false, .isIndirect = true },
            .load_ind_u32, .load_ind_i32 => .{ .address = self.args.TwoRegOneImm.immediate, .size = 4, .isWrite = false, .isIndirect = true },
            .load_ind_u64 => .{ .address = self.args.TwoRegOneImm.immediate, .size = 8, .isWrite = false, .isIndirect = true },

            // Store operations
            .store_u8 => .{ .address = self.args.OneRegOneImm.immediate, .size = 1, .isWrite = true, .isIndirect = false },
            .store_u16 => .{ .address = self.args.OneRegOneImm.immediate, .size = 2, .isWrite = true, .isIndirect = false },
            .store_u32 => .{ .address = self.args.OneRegOneImm.immediate, .size = 4, .isWrite = true, .isIndirect = false },
            .store_u64 => .{ .address = self.args.OneRegOneImm.immediate, .size = 8, .isWrite = true, .isIndirect = false },

            // Immediate store operations
            .store_imm_u8 => .{ .address = self.args.TwoImm.first_immediate, .size = 1, .isWrite = true, .isIndirect = false },
            .store_imm_u16 => .{ .address = self.args.TwoImm.first_immediate, .size = 2, .isWrite = true, .isIndirect = false },
            .store_imm_u32 => .{ .address = self.args.TwoImm.first_immediate, .size = 4, .isWrite = true, .isIndirect = false },
            .store_imm_u64 => .{ .address = self.args.TwoImm.first_immediate, .size = 8, .isWrite = true, .isIndirect = false },

            // Indirect store operations
            .store_ind_u8 => .{ .address = self.args.TwoRegOneImm.immediate, .size = 1, .isWrite = true, .isIndirect = true },
            .store_ind_u16 => .{ .address = self.args.TwoRegOneImm.immediate, .size = 2, .isWrite = true, .isIndirect = true },
            .store_ind_u32 => .{ .address = self.args.TwoRegOneImm.immediate, .size = 4, .isWrite = true, .isIndirect = true },
            .store_ind_u64 => .{ .address = self.args.TwoRegOneImm.immediate, .size = 8, .isWrite = true, .isIndirect = true },

            // Indirect immediate store operations
            .store_imm_ind_u8 => .{ .address = self.args.OneRegTwoImm.first_immediate, .size = 1, .isWrite = true, .isIndirect = true },
            .store_imm_ind_u16 => .{ .address = self.args.OneRegTwoImm.first_immediate, .size = 2, .isWrite = true, .isIndirect = true },
            .store_imm_ind_u32 => .{ .address = self.args.OneRegTwoImm.first_immediate, .size = 4, .isWrite = true, .isIndirect = true },
            .store_imm_ind_u64 => .{ .address = self.args.OneRegTwoImm.first_immediate, .size = 8, .isWrite = true, .isIndirect = true },

            // Non-memory instructions
            else => null,
        };
    }

    pub fn setMemoryAddress(self: *InstructionWithArgs, new_address: u64) !void {
        switch (self.instruction) {
            // Load operations
            .load_u8,
            .load_i8,
            .load_u16,
            .load_i16,
            .load_u32,
            .load_i32,
            .load_u64,
            => self.args.OneRegOneImm.immediate = new_address,

            // Indirect load operations
            .load_ind_u8,
            .load_ind_i8,
            .load_ind_u16,
            .load_ind_i16,
            .load_ind_u32,
            .load_ind_i32,
            .load_ind_u64,
            => self.args.TwoRegOneImm.immediate = new_address,

            // Store operations
            .store_u8,
            .store_u16,
            .store_u32,
            .store_u64,
            => self.args.OneRegOneImm.immediate = new_address,

            // Immediate store operations
            .store_imm_u8,
            .store_imm_u16,
            .store_imm_u32,
            .store_imm_u64,
            => self.args.TwoImm.first_immediate = new_address,

            // Indirect store operations
            .store_ind_u8,
            .store_ind_u16,
            .store_ind_u32,
            .store_ind_u64,
            => self.args.TwoRegOneImm.immediate = new_address,

            // Indirect immediate store operations
            .store_imm_ind_u8,
            .store_imm_ind_u16,
            .store_imm_ind_u32,
            .store_imm_ind_u64,
            => self.args.OneRegTwoImm.first_immediate = new_address,

            // Non-memory instructions
            else => return error.NotAMemoryInstruction,
        }
    }

    pub fn instructionType(self: *@This()) InstructionType {
        return @as(InstructionType, self.args);
    }

    pub fn setSkipBytes(self: *@This(), skip_bytes: u32) void {
        switch (self.args) {
            .NoArgs => |*args| args.no_of_bytes_to_skip = skip_bytes,
            .OneImm => |*args| args.no_of_bytes_to_skip = skip_bytes,
            .OneOffset => |*args| args.no_of_bytes_to_skip = skip_bytes,
            .OneRegOneImm => |*args| args.no_of_bytes_to_skip = skip_bytes,
            .OneRegOneImmOneOffset => |*args| args.no_of_bytes_to_skip = skip_bytes,
            .OneRegTwoImm => |*args| args.no_of_bytes_to_skip = skip_bytes,
            .OneRegOneExtImm => |*args| args.no_of_bytes_to_skip = skip_bytes,
            .ThreeReg => |*args| args.no_of_bytes_to_skip = skip_bytes,
            .TwoImm => |*args| args.no_of_bytes_to_skip = skip_bytes,
            .TwoReg => |*args| args.no_of_bytes_to_skip = skip_bytes,
            .TwoRegOneImm => |*args| args.no_of_bytes_to_skip = skip_bytes,
            .TwoRegOneOffset => |*args| args.no_of_bytes_to_skip = skip_bytes,
            .TwoRegTwoImm => |*args| args.no_of_bytes_to_skip = skip_bytes,
        }
    }

    pub fn skip_l(self: *const @This()) u32 {
        return self.args.skip_l();
    }

    pub fn setOffset(self: *@This(), offset: i32) !void {
        switch (self.args) {
            .OneOffset => |*args| args.offset = offset,
            .OneRegOneImmOneOffset => |*args| args.offset = offset,
            .TwoRegOneOffset => |*args| args.offset = offset,
            else => {
                std.debug.print("Instruction '{s}' does not have an offset field\n", .{@tagName(self.instruction)});
                return error.InstructionDoesNotHaveOffset;
            },
        }
    }

    pub fn setBranchOrJumpTargetTo(self: *@This(), value: u32) !void {
        // As these all work with an offset
        if (self.isBranch() or self.isBranchWithImm()) {
            // ensure offset is not compressed
            try self.setOffset(@bitCast(@as(u32, value)));
        } else {
            switch (self.instruction) {
                .load_imm_jump => {
                    //
                    try self.setOffset(@bitCast(@as(u32, value)));
                },
                .load_imm_jump_ind => {
                    //
                    self.args.TwoRegTwoImm.second_immediate = value;
                },
                .jump => {
                    try self.setOffset(@bitCast(@as(u32, value)));
                },
                .jump_ind => {
                    self.args.OneRegOneImm.immediate = value;
                },
                else => return error.InstructionDoesNotHaveOffset,
            }
        }
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

pub fn lookupInstructionType(instruction: Instruction) InstructionType {
    return switch (instruction) {
        // No argument instructions
        .trap, .fallthrough => .NoArgs,

        // One immediate instructions
        .ecalli => .OneImm,

        // One register and extended width immediate instructions
        .load_imm_64 => .OneRegOneExtImm,

        // Two immediate instructions
        .store_imm_u8,
        .store_imm_u16,
        .store_imm_u32,
        .store_imm_u64,
        => .TwoImm,

        // One offset instructions
        .jump => .OneOffset,

        // One register and one immediate instructions
        .jump_ind,
        .load_imm,
        .load_u8,
        .load_i8,
        .load_u16,
        .load_i16,
        .load_u32,
        .load_i32,
        .load_u64,
        .store_u8,
        .store_u16,
        .store_u32,
        .store_u64,
        => .OneRegOneImm,

        // One register and two immediates instructions
        .store_imm_ind_u8,
        .store_imm_ind_u16,
        .store_imm_ind_u32,
        .store_imm_ind_u64,
        => .OneRegTwoImm,

        // One register, one immediate and one offset instructions
        .load_imm_jump,
        .branch_eq_imm,
        .branch_ne_imm,
        .branch_lt_u_imm,
        .branch_le_u_imm,
        .branch_ge_u_imm,
        .branch_gt_u_imm,
        .branch_lt_s_imm,
        .branch_le_s_imm,
        .branch_ge_s_imm,
        .branch_gt_s_imm,
        => .OneRegOneImmOneOffset,

        // Two registers instructions
        .move_reg, .sbrk => .TwoReg,

        // Two registers and one immediate instructions
        .store_ind_u8,
        .store_ind_u16,
        .store_ind_u32,
        .store_ind_u64,
        .load_ind_u8,
        .load_ind_u16,
        .load_ind_u32,
        .load_ind_u64,
        .load_ind_i8,
        .load_ind_i16,
        .load_ind_i32,
        .and_imm,
        .xor_imm,
        .or_imm,
        .set_lt_u_imm,
        .set_lt_s_imm,
        .set_gt_u_imm,
        .set_gt_s_imm,
        .shlo_l_imm_32,
        .shlo_l_imm_64,
        .shlo_l_imm_alt_32,
        .shlo_l_imm_alt_64,
        .shlo_r_imm_32,
        .shlo_r_imm_64,
        .shlo_r_imm_alt_32,
        .shlo_r_imm_alt_64,
        .shar_r_imm_32,
        .shar_r_imm_64,
        .shar_r_imm_alt_32,
        .shar_r_imm_alt_64,
        .cmov_iz_imm,
        .cmov_nz_imm,
        .neg_add_imm_32,
        .neg_add_imm_64,
        .add_imm_32,
        .mul_imm_32,
        .add_imm_64,
        .mul_imm_64,
        => .TwoRegOneImm,

        // Two registers and one offset instructions
        .branch_eq,
        .branch_ne,
        .branch_lt_u,
        .branch_lt_s,
        .branch_ge_u,
        .branch_ge_s,
        => .TwoRegOneOffset,

        // Two registers and two immediates instructions
        .load_imm_jump_ind => .TwoRegTwoImm,

        // Three registers instructions
        .add_32,
        .sub_32,
        .mul_32,
        .div_u_32,
        .div_s_32,
        .rem_u_32,
        .rem_s_32,
        .shlo_l_32,
        .shlo_r_32,
        .shar_r_32,
        .add_64,
        .sub_64,
        .mul_64,
        .div_u_64,
        .div_s_64,
        .rem_u_64,
        .rem_s_64,
        .shlo_l_64,
        .shlo_r_64,
        .shar_r_64,
        .@"and",
        .xor,
        .@"or",
        .mul_upper_s_s,
        .mul_upper_u_u,
        .mul_upper_s_u,
        .set_lt_u,
        .set_lt_s,
        .cmov_iz,
        .cmov_nz,
        => .ThreeReg,
    };
}
