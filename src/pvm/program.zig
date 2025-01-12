const std = @import("std");
const codec = @import("../codec.zig");
const JumpTable = @import("decoder/jumptable.zig").JumpTable;

const Allocator = std.mem.Allocator;

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
        var decoder = @import("decoder.zig").Decoder.init(program.code, program.mask);

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
                => {
                    // For jumps, validate the destination
                    switch (instruction.instruction) {
                        .jump => {
                            const args = instruction.args.one_offset;
                            const target_pc = @as(i64, pc) + 1 + @as(i64, args.no_of_bytes_to_skip) + @as(i64, args.offset);
                            if (target_pc < 0 or target_pc >= program.code.len) {
                                return Error.InvalidJumpDestination;
                            }
                            try basic_blocks.append(@intCast(target_pc));
                        },
                        .jump_ind => {
                            const args = instruction.args.one_register_one_immediate;
                            const idx = args.immediate / 2;
                            if (idx >= program.jump_table.len()) {
                                return Error.InvalidJumpDestination;
                            }
                            const target_pc = program.jump_table.getDestination(@intCast(idx));
                            if (target_pc >= program.code.len) {
                                return Error.InvalidJumpDestination;
                            }
                            try basic_blocks.append(target_pc);
                        },
                        .load_imm_jump => {
                            const args = instruction.args.one_register_one_immediate_one_offset;
                            const target_pc = @as(i64, pc) + 1 + @as(i64, args.no_of_bytes_to_skip) + @as(i64, args.offset);
                            if (target_pc < 0 or target_pc >= program.code.len) {
                                return Error.InvalidJumpDestination;
                            }
                            try basic_blocks.append(@intCast(target_pc));
                        },
                        .load_imm_jump_ind => {
                            const args = instruction.args.two_registers_two_immediates;
                            const target_pc = program.jump_table.getDestination(@intCast(args.second_immediate / 2));
                            if (target_pc >= program.code.len) {
                                return Error.InvalidJumpDestination;
                            }
                            try basic_blocks.append(target_pc);
                        },
                        else => {
                            // For branches, the next instruction starts a new basic block
                            const next_pc = pc + 1 + instruction.args.skip_l();
                            if (next_pc < program.code.len) {
                                try basic_blocks.append(next_pc);
                            }
                        },
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
