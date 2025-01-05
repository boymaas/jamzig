const std = @import("std");
const codec = @import("../codec.zig");
const JumpTable = @import("decoder/jumptable.zig").JumpTable;

const Allocator = std.mem.Allocator;

pub const Program = struct {
    code: []const u8,
    mask: []const u8,
    basic_blocks: []u32,
    jump_table: JumpTable,

    pub fn decode(allocator: Allocator, raw_program: []const u8) !Program {
        var program = Program{
            .code = undefined,
            .mask = undefined,
            .basic_blocks = undefined,
            .jump_table = undefined,
        };

        var index: usize = 0;
        const jump_table_length = try parseIntAndUpdateIndex(raw_program, &index);
        const jump_table_item_length = raw_program[index];
        index += 1;

        const code_length = try parseIntAndUpdateIndex(raw_program[index..], &index);

        const jump_table_first_byte_index = index;
        const jump_table_length_in_bytes = jump_table_length * jump_table_item_length;
        program.jump_table = try JumpTable.init(
            allocator,
            jump_table_item_length,
            raw_program[jump_table_first_byte_index..][0..jump_table_length_in_bytes],
        );

        const code_first_index = jump_table_first_byte_index + jump_table_length_in_bytes;
        program.code = try allocator.dupe(u8, raw_program[code_first_index..][0..code_length]);

        const mask_first_index = code_first_index + code_length;
        const mask_length_in_bytes = (code_length + 7) / 8;
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
