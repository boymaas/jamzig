const std = @import("std");
const codec = @import("../codec.zig");
const JumpTable = @import("decoder/jumptable.zig").JumpTable;

const trace = @import("../tracing.zig").scoped(.pvm);

const Allocator = std.mem.Allocator;

// Custom error set for Program decoding
pub const ProgramError = error{
    InvalidProgramLength,
    InvalidJumpTableLength,
    InvalidJumpTableItemLength,
    InvalidCodeLength,
    InvalidMaskLength,
    OutOfBoundsJumpTarget,
    IncompleteProgram,
    AllocationTooLarge,
    UnalignedJumpTarget,
    UnalignedJumpTableEntry,
    InvalidJumpTableEntry,
};

pub const Program = struct {
    code: []const u8,
    mask: []const u8,
    basic_blocks: []u32,
    jump_table: JumpTable,

    const MaxProgramSize = 4_000_000; // 4MB to match W_C
    const MaxCodeLength = 4_000_000; // 4MB to match W_C
    const MaxJumpTableLength = 500_000; // 500K entries (unofficial range)

    pub fn decode(allocator: Allocator, raw_program: []const u8) (ProgramError || Allocator.Error)!Program {
        const span = trace.span(.program_decode);
        defer span.deinit();
        span.debug("Starting program decode", .{});

        // Validate total program size
        if (raw_program.len > MaxProgramSize) {
            span.err("Program exceeds maximum size of {d} bytes", .{MaxProgramSize});
            return ProgramError.InvalidProgramLength;
        }

        if (raw_program.len < 2) { // Minimum size for header
            span.err("Program too short - needs at least 2 bytes", .{});
            return ProgramError.InvalidProgramLength;
        }

        var program = Program{
            .code = undefined,
            .mask = undefined,
            .basic_blocks = undefined,
            .jump_table = undefined,
        };

        // Parse header information
        var index: usize = 0;
        const jump_table_length = parseIntAndUpdateIndex(raw_program, &index) catch |err| switch (err) {
            error.EndOfStream => return ProgramError.IncompleteProgram,
            else => return ProgramError.InvalidJumpTableLength,
        };

        // Validate jump table length
        if (jump_table_length > MaxJumpTableLength) {
            span.err("Jump table length {d} exceeds maximum of {d}", .{ jump_table_length, MaxJumpTableLength });
            return ProgramError.InvalidJumpTableLength;
        }

        // Ensure we can read the item length byte
        if (index >= raw_program.len) {
            span.err("Unexpected end of program data at index {d}", .{index});
            return ProgramError.IncompleteProgram;
        }

        const jump_table_item_length = raw_program[index];
        index += 1;

        // Validate jump table item length
        if (jump_table_item_length == 0 or jump_table_item_length > 4) {
            span.err("Invalid jump table item length: {d}", .{jump_table_item_length});
            return ProgramError.InvalidJumpTableItemLength;
        }

        span.debug("Jump table metadata - length: {d}, item length: {d} index @ {d}", .{
            jump_table_length,
            jump_table_item_length,
            index,
        });

        // Parse code length
        const code_length = parseIntAndUpdateIndex(raw_program[index..], &index) catch |err| switch (err) {
            error.EndOfStream => return ProgramError.IncompleteProgram,
            else => return ProgramError.InvalidCodeLength,
        };

        // Validate code length
        if (code_length > MaxCodeLength) {
            span.err("Code length {d} exceeds maximum of {d}", .{ code_length, MaxCodeLength });
            return ProgramError.InvalidCodeLength;
        }

        span.debug("Code section length: {d} bytes", .{code_length});

        // Calculate and validate section offsets
        const jump_table_size = jump_table_length * jump_table_item_length;
        const jump_table_end = index + jump_table_size;
        const code_start = jump_table_end;
        const code_end = code_start + code_length;
        const mask_size = (code_length + 7) / 8;
        const mask_start = code_end;
        const mask_end = mask_start + mask_size;

        // Validate total size
        if (mask_end > raw_program.len) {
            span.err("Program data too short - need {d} bytes, have {d}", .{
                mask_end,
                raw_program.len,
            });
            return ProgramError.IncompleteProgram;
        }

        // Initialize jump table
        const jump_table_bytes = raw_program[index..jump_table_end];
        program.jump_table = try JumpTable.init(
            allocator,
            jump_table_item_length,
            jump_table_bytes,
        );

        // Validate jump table targets
        for (0..program.jump_table.len()) |i| {
            const target = program.jump_table.getDestination(i);
            if (target >= code_length) {
                span.err("Jump table entry {d} has invalid target {d} >= code length {d}", .{
                    i, target, code_length,
                });
                return ProgramError.OutOfBoundsJumpTarget;
            }
        }

        // Copy code section
        const code_slice = raw_program[code_start..code_end];
        program.code = try allocator.dupe(u8, code_slice);
        errdefer allocator.free(program.code);

        // Copy and validate mask section
        const mask_slice = raw_program[mask_start..mask_end];
        program.mask = try allocator.dupe(u8, mask_slice);
        errdefer allocator.free(program.mask);

        // Calculate basic blocks from mask
        var mask_block_count: usize = 0;
        for (program.mask) |byte| {
            mask_block_count += @popCount(byte);
        }

        // Validate allocation size
        if (mask_block_count > MaxJumpTableLength) {
            span.err("Too many basic blocks: {d}", .{mask_block_count});
            return ProgramError.AllocationTooLarge;
        }

        program.basic_blocks = try allocator.alloc(u32, mask_block_count);
        errdefer allocator.free(program.basic_blocks);

        var block_index: usize = 0;
        var bit_index: usize = 0;

        // Process mask bits
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

    if (index.* >= data.len) {
        span.err("Attempt to read integer past end of data at index {d}", .{index.*});
        return error.EndOfStream;
    }

    const result = try codec.decoder.decodeInteger(data[index.*..]);
    index.* += result.bytes_read;

    return @intCast(result.value);
}
