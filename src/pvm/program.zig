const std = @import("std");
const codec = @import("../codec.zig");

const Allocator = std.mem.Allocator;

pub const Program = struct {
    code: []const u8,
    mask: []const u8,
    jump_table: []const u8,
    jump_table_item_length: u8,

    pub fn decode(allocator: Allocator, raw_program: []const u8) !Program {
        var program = Program{
            .code = undefined,
            .mask = undefined,
            .jump_table = undefined,
            .jump_table_item_length = undefined,
        };

        var index: usize = 0;
        const jump_table_length = try parseIntAndUpdateIndex(raw_program, &index);
        program.jump_table_item_length = raw_program[index];
        index += 1;

        const code_length = try parseIntAndUpdateIndex(raw_program[index..], &index);

        const jump_table_first_byte_index = index;
        const jump_table_length_in_bytes = jump_table_length * program.jump_table_item_length;
        program.jump_table = try allocator.dupe(u8, raw_program[jump_table_first_byte_index..][0..jump_table_length_in_bytes]);

        const code_first_index = jump_table_first_byte_index + jump_table_length_in_bytes;
        program.code = try allocator.dupe(u8, raw_program[code_first_index..][0..code_length]);

        const mask_first_index = code_first_index + code_length;
        const mask_length_in_bytes = (code_length + 7) / 8;
        program.mask = try allocator.dupe(u8, raw_program[mask_first_index..][0..mask_length_in_bytes]);

        return program;
    }

    pub fn deinit(self: *Program, allocator: Allocator) void {
        allocator.free(self.code);
        allocator.free(self.mask);
        allocator.free(self.jump_table);
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
