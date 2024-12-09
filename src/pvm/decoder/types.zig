const Instruction = @import("../instruction.zig").Instruction;

pub const ArgumentType = enum {
    no_arguments,
    one_immediate,
    one_offset,
    one_register_one_immediate,
    one_register_one_immediate_one_offset,
    one_register_one_extended_immediate,
    one_register_two_immediates,
    three_registers,
    two_immediates,
    two_registers,
    two_registers_one_immediate,
    two_registers_one_offset,
    two_registers_two_immediates,

    pub fn lookup(instruction: Instruction) ArgumentType {
        return lookupArgumentType(instruction);
    }
};

pub fn lookupArgumentType(instruction: Instruction) ArgumentType {
    return switch (instruction) {
        // No argument instructions
        .trap, .fallthrough => .no_arguments,

        // One immediate instructions
        .ecalli => .one_immediate,

        // One register and extended width immediate instructions
        .load_imm_64 => .one_register_one_extended_immediate,

        // Two immediate instructions
        .store_imm_u8,
        .store_imm_u16,
        .store_imm_u32,
        .store_imm_u64,
        => .two_immediates,

        // One offset instructions
        .jump => .one_offset,

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
        => .one_register_one_immediate,

        // One register and two immediates instructions
        .store_imm_ind_u8,
        .store_imm_ind_u16,
        .store_imm_ind_u32,
        .store_imm_ind_u64,
        => .one_register_two_immediates,

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
        => .one_register_one_immediate_one_offset,

        // Two registers instructions
        .move_reg, .sbrk => .two_registers,

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
        => .two_registers_one_immediate,

        // Two registers and one offset instructions
        .branch_eq,
        .branch_ne,
        .branch_lt_u,
        .branch_lt_s,
        .branch_ge_u,
        .branch_ge_s,
        => .two_registers_one_offset,

        // Two registers and two immediates instructions
        .load_imm_jump_ind => .two_registers_two_immediates,

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
        => .three_registers,
    };
}
