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
        if (jump_table_item_length == 0 or jump_table_item_length > 4) {
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

        const code_first_index = jump_table_first_byte_index + jump_table_length_in_bytes;
        program.code = try allocator.dupe(u8, raw_program[code_first_index..][0..code_length]);

        const mask_first_index = code_first_index + code_length;
        const mask_length_in_bytes = @max(
            (code_length + 7) / 8,
            raw_program.len - mask_first_index,
        );
        program.mask = try allocator.dupe(u8, raw_program[mask_first_index..][0..mask_length_in_bytes]);

        // fill the mask_block_starts
        var mask_block_count: usize = 0;
        for (program.mask) |byte| {
            mask_block_count += @popCount(byte);
        }

        program.basic_blocks = try allocator.alloc(u32, mask_block_count);

        var block_index: usize = 0;
        var bit_index: usize = 0;
        for (program.mask) |byte| {
            var mask: u8 = 1;
            for (0..8) |_| {
                if (byte & mask != 0) {
                    program.basic_blocks[block_index] = @intCast(bit_index);
                    block_index += 1;
                }
                mask <<= 1;
                bit_index += 1;
                if (bit_index >= code_length) break;
            }
            if (bit_index >= code_length) break;
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
