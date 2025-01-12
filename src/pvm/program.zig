const std = @import("std");
const Allocator = std.mem.Allocator;

const codec = @import("../codec.zig");

const Decoder = @import("decoder.zig").Decoder;
const JumpTable = @import("decoder/jumptable.zig").JumpTable;

pub const Program = struct {
    code: []const u8,
    mask: []const u8,
    basic_blocks: []u32,
    jump_table: JumpTable,

    pub const Error = error{
        InvalidJumpTableLength,
        InvalidJumpTableItemLength,
        InvalidCodeLength,
        HeaderSizeMismatch,
        ProgramTooShort,
        InvalidInstruction,
        InvalidJumpDestination,
        InvalidProgramCounter,
        InvalidRegisterIndex,
        InvalidImmediateLength,
    } || JumpError;

    pub const JumpError = error{
        JumpAddressHalt,
        JumpAddressZero,
        JumpAddressOutOfRange,
        JumpAddressNotAligned,
        JumpAddressNotInBasicBlock,
    };

    pub fn decode(allocator: Allocator, raw_program: []const u8) !Program {
        // Validate minimum header size (jump table length + item length + code length)
        if (raw_program.len < 3) {
            return Error.ProgramTooShort;
        }

        var program = Program{
            .code = undefined,
            .mask = undefined,
            .basic_blocks = undefined,
            .jump_table = undefined,
        };

        var index: usize = 0;
        const jump_table_length = try parseIntAndUpdateIndex(raw_program, &index);

        // Validate jump table length isn't absurdly large
        if (jump_table_length > raw_program.len) {
            return Error.InvalidJumpTableLength;
        }

        const jump_table_item_length = raw_program[index];
        // Validate jump table item length (should be 1-4 bytes typically)
        if ((jump_table_length > 0 and jump_table_item_length == 0) or
            jump_table_item_length > 4)
        {
            return Error.InvalidJumpTableItemLength;
        }
        index += 1;

        // Validate we can read code length
        if (index >= raw_program.len) {
            return Error.ProgramTooShort;
        }

        const code_length = try parseIntAndUpdateIndex(raw_program[index..], &index);

        // Calculate required mask length (rounded up to nearest byte)
        const required_mask_bytes = (code_length + 7) / 8;

        // Validate total required size (header + jump table + code + mask)
        const total_required_size = index +
            (jump_table_length * jump_table_item_length) +
            code_length +
            required_mask_bytes;

        if (total_required_size > raw_program.len) {
            return Error.InvalidCodeLength;
        }

        const jump_table_first_byte_index = index;
        const jump_table_length_in_bytes = jump_table_length * jump_table_item_length;

        // Initialize jump table
        program.jump_table = try JumpTable.init(
            allocator,
            jump_table_item_length,
            raw_program[jump_table_first_byte_index..][0..jump_table_length_in_bytes],
        );
        errdefer program.jump_table.deinit(allocator);

        const code_first_index = jump_table_first_byte_index + jump_table_length_in_bytes;
        program.code = try allocator.dupe(u8, raw_program[code_first_index..][0..code_length]);
        errdefer allocator.free(program.code);

        const mask_first_index = code_first_index + code_length;
        const mask_length_in_bytes = @max(
            (code_length + 7) / 8,
            raw_program.len - mask_first_index,
        );
        program.mask = try allocator.dupe(u8, raw_program[mask_first_index..][0..mask_length_in_bytes]);
        errdefer allocator.free(program.mask);

        // Create a safe decoder for validation
        var decoder = Decoder.init(program.code, program.mask);

        // Initialize basic block and always add 0 as first basic block
        var basic_blocks = std.ArrayList(u32).init(allocator);
        errdefer basic_blocks.deinit();
        try basic_blocks.append(0);

        var pc: u32 = 0;
        while (pc < program.code.len) {
            const instruction = try decoder.decodeInstruction(pc);

            // Check if this instruction terminates a basic block
            // const inst_type = instruction.args_type;
            switch (instruction.instruction) {
                .trap,
                .fallthrough,
                .jump,
                .jump_ind,
                .load_imm_jump,
                .load_imm_jump_ind,
                .branch_eq,
                .branch_ne,
                .branch_ge_u,
                .branch_ge_s,
                .branch_lt_u,
                .branch_lt_s,
                .branch_eq_imm,
                .branch_ne_imm,
                .branch_lt_u_imm,
                .branch_lt_s_imm,
                .branch_le_u_imm,
                .branch_le_s_imm,
                .branch_ge_u_imm,
                .branch_ge_s_imm,
                .branch_gt_u_imm,
                .branch_gt_s_imm,
                => |opcode| {
                    // For branches, the next instruction starts a new basic block
                    const next_pc = pc + 1 + instruction.args.skip_l();
                    // Allow 8 byte padding for possible final instruction's immediate value
                    if (next_pc < program.code.len + Decoder.MaxImmediateSizeInByte) {
                        try basic_blocks.append(next_pc);
                    } else {
                        return Error.ProgramTooShort;
                    }
                    switch (opcode) {
                        .jump => {},
                        .jump_ind => {
                            _ = instruction.args.one_register_one_immediate;
                            // Skip validation - jump target is computed at runtime from registers and immediates
                        },
                        .load_imm_jump_ind => {
                            _ = instruction.args.two_registers_two_immediates;
                            // Skip validation - jump target is computed at runtime from registers and immediates

                        },
                        else => {},
                    }
                },
                else => {},
            }

            pc += 1 + instruction.args.skip_l();
        }

        program.basic_blocks = try basic_blocks.toOwnedSlice();
        errdefer allocator.free(program.basic_blocks);

        // Validate that all jump table destinations point to valid basic blocks
        var i: usize = 0;
        while (i < program.jump_table.len()) : (i += 1) {
            const destination = program.jump_table.getDestination(i);

            // Check if destination is within code bounds
            if (destination >= program.code.len) {
                return Error.InvalidJumpDestination;
            }

            // Check if destination is a valid basic block start using binary search
            const valid_destination = std.sort.binarySearch(
                u32,
                program.basic_blocks,
                destination,
                struct {
                    fn orderU32(context: u32, item: u32) std.math.Order {
                        return std.math.order(context, item);
                    }
                }.orderU32,
            ) != null;

            if (!valid_destination) {
                return Error.InvalidJumpDestination;
            }
        }

        return program;
    }

    /// Validates an indirect jump address and returns the computed jump destination.
    /// The function performs various validations including:
    /// - Halt condition check (0xFFFF0000)
    /// - Zero address check
    /// - Range validation
    /// - Alignment check (must be aligned to ZA)
    /// - Basic block validation
    pub fn validateJumpAddress(self: *const Program, address: u32) JumpError!u32 {
        const halt_pc = 0xFFFF0000;
        const ZA = 2; // Alignment requirement

        // Check halt condition
        if (address == halt_pc) {
            return error.JumpAddressHalt;
        }

        // Validate jump address
        if (address == 0) {
            return error.JumpAddressZero;
        }

        if (address > self.jump_table.len() * ZA) {
            return error.JumpAddressOutOfRange;
        }

        if (address % ZA != 0) {
            return error.JumpAddressNotAligned;
        }

        // Compute jump destination
        const index = (address / ZA) - 1;
        const jump_dest = self.jump_table.getDestination(index);

        // Validate jump destination is in a basic block
        if (std.mem.indexOfScalar(u32, self.basic_blocks, jump_dest) == null) {
            return error.JumpAddressNotInBasicBlock;
        }

        return jump_dest;
    }

    pub fn deinit(self: *Program, allocator: Allocator) void {
        allocator.free(self.code);
        allocator.free(self.mask);
        allocator.free(self.basic_blocks);
        self.jump_table.deinit(allocator);
        self.* = undefined;
    }

    pub fn format(
        self: *const Program,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try @import("format.zig").formatProgram(self, writer);
    }
};

fn parseIntAndUpdateIndex(data: []const u8, index: *usize) !usize {
    const result = try codec.decoder.decodeInteger(data);
    index.* += result.bytes_read;

    return @intCast(result.value);
}
