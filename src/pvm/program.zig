const std = @import("std");
const codec = @import("../codec.zig");
const JumpTable = @import("decoder/jumptable.zig").JumpTable;

const trace = @import("../tracing.zig").scoped(.pvm);

const Allocator = std.mem.Allocator;

pub const Program = struct {
    code: []const u8,
    mask: []const u8,
    basic_blocks: []u32,
    jump_table: JumpTable,

    pub fn decode(allocator: Allocator, raw_program: []const u8) !Program {
        const span = trace.span(.program_decode);
        defer span.deinit();
        span.debug("Starting program decode", .{});
        span.trace("Raw program data ({d} bytes): {any}", .{ raw_program.len, std.fmt.fmtSliceHexLower(raw_program) });

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

        span.debug("Jump table metadata - length: {d}, item length: {d} index @ {d}", .{ jump_table_length, jump_table_item_length, index });

        const code_length = try parseIntAndUpdateIndex(raw_program[index..], &index);
        span.debug("Code section length: {d} bytes", .{code_length});

        const jump_table_first_byte_index = index;
        const jump_table_length_in_bytes = jump_table_length * jump_table_item_length;
        span.debug("Initializing jump table - start index: {d}, total bytes: {d}", .{ jump_table_first_byte_index, jump_table_length_in_bytes });

        const jump_table_bytes = raw_program[jump_table_first_byte_index..][0..jump_table_length_in_bytes];
        span.trace("Jump table raw bytes: {any}", .{std.fmt.fmtSliceHexLower(jump_table_bytes)});

        program.jump_table = try JumpTable.init(
            allocator,
            jump_table_item_length,
            jump_table_bytes,
        );

        const code_first_index = jump_table_first_byte_index + jump_table_length_in_bytes;
        const code_slice = raw_program[code_first_index..][0..code_length];
        span.debug("Code section - start index: {d}, length: {d}", .{ code_first_index, code_slice.len });
        span.trace("Code raw bytes: {any}", .{std.fmt.fmtSliceHexLower(code_slice)});
        program.code = try allocator.dupe(u8, code_slice);

        const mask_first_index = code_first_index + code_length;
        const mask_length_in_bytes = (code_length + 7) / 8;
        const mask_slice = raw_program[mask_first_index..][0..mask_length_in_bytes];
        span.debug("Mask section - start index: {d}, length: {d}", .{ mask_first_index, mask_length_in_bytes });
        span.trace("Mask raw bytes: {any}", .{std.fmt.fmtSliceHexLower(mask_slice)});
        program.mask = try allocator.dupe(u8, mask_slice);

        // Calculate basic blocks from mask
        const blocks_span = span.child(.basic_blocks);
        defer blocks_span.deinit();

        var mask_block_count: usize = 0;
        for (program.mask) |byte| {
            mask_block_count += @popCount(byte);
        }
        blocks_span.debug("Calculated {d} basic blocks from mask", .{mask_block_count});

        program.basic_blocks = try allocator.alloc(u32, mask_block_count);
        blocks_span.debug("Allocated basic blocks array of size {d}", .{mask_block_count});

        var block_index: usize = 0;
        var bit_index: usize = 0;

        for (program.mask) |byte| {
            const byte_span = blocks_span.child(.process_byte);
            defer byte_span.deinit();
            byte_span.trace("Processing mask byte: 0b{b:0>8}", .{byte});

            var mask: u8 = 1;
            for (0..8) |bit_position| {
                if (byte & mask != 0) {
                    program.basic_blocks[block_index] = @intCast(bit_index);
                    byte_span.debug("Found block at bit {d}, absolute position {d}", .{ bit_position, bit_index });
                    block_index += 1;
                }
                mask <<= 1;
                bit_index += 1;
                if (bit_index >= code_length) break;
            }
            if (bit_index >= code_length) break;
        }

        blocks_span.debug("Basic blocks array populated with {d} entries", .{block_index});
        blocks_span.trace("Basic blocks contents: {any}", .{program.basic_blocks});

        span.debug("Program decode completed successfully", .{});
        return program;
    }

    pub fn deinit(self: *Program, allocator: Allocator) void {
        const span = trace.span(.deinit);
        defer span.deinit();
        span.debug("Deallocating program resources", .{});

        span.debug("Freeing code section ({d} bytes)", .{self.code.len});
        allocator.free(self.code);

        span.debug("Freeing mask section ({d} bytes)", .{self.mask.len});
        allocator.free(self.mask);

        span.debug("Freeing basic blocks array ({d} entries)", .{self.basic_blocks.len});
        allocator.free(self.basic_blocks);

        span.debug("Deinitializing jump table", .{});
        self.jump_table.deinit(allocator);
        self.* = undefined;

        span.debug("Program deallocation complete", .{});
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
    const span = trace.span(.parse_int);
    defer span.deinit();
    span.trace("Parsing integer from offset {d}, data: {any}", .{ index.*, std.fmt.fmtSliceHexLower(data) });

    const result = try codec.decoder.decodeInteger(data);
    const old_index = index.*;
    index.* += result.bytes_read;

    span.debug("Parsed integer {d} using {d} bytes, index moved {d}->{d}", .{
        result.value,
        result.bytes_read,
        old_index,
        index.*,
    });

    return @intCast(result.value);
}
