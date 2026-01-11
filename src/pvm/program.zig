const std = @import("std");
const Allocator = std.mem.Allocator;

const codec = @import("../codec.zig");

const Decoder = @import("decoder.zig").Decoder;
const JumpTable = @import("decoder/jumptable.zig").JumpTable;

const trace = @import("tracing").scoped(.pvm);

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
        const span = trace.span(@src(), .decode);
        defer span.deinit();
        span.debug("Starting program decoding, raw size: {d} bytes", .{raw_program.len});
        if (raw_program.len < 3) {
            span.err("Program too short: {d} bytes, minimum required: 3", .{raw_program.len});
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
        span.debug("Jump table length: {d}, index after parsing: {d}", .{ jump_table_length, index });

        // Validate jump table length isn't absurdly large
        if (jump_table_length > raw_program.len) {
            span.err("Invalid jump table length: {d} exceeds program size: {d}", .{ jump_table_length, raw_program.len });
            return Error.InvalidJumpTableLength;
        }

        const jump_table_item_length = raw_program[index];
        span.debug("Jump table item length: {d}", .{jump_table_item_length});

        // Validate jump table item length (should be 1-4 bytes typically)
        if ((jump_table_length > 0 and jump_table_item_length == 0) or
            jump_table_item_length > 4)
        {
            span.err("Invalid jump table item length: {d}", .{jump_table_item_length});
            return Error.InvalidJumpTableItemLength;
        }

        index += 1;

        if (index >= raw_program.len) {
            return Error.ProgramTooShort;
        }

        const code_length = try parseIntAndUpdateIndex(raw_program[index..], &index);
        span.debug("Code length: {d} bytes", .{code_length});

        const required_mask_bytes = (code_length + 7) / 8;
        span.debug("Required mask bytes: {d}", .{required_mask_bytes});
        const total_required_size = index +
            (jump_table_length * jump_table_item_length) +
            code_length +
            required_mask_bytes;

        if (total_required_size > raw_program.len) {
            return Error.InvalidCodeLength;
        }

        const jump_table_first_byte_index = index;
        const jump_table_length_in_bytes = jump_table_length * jump_table_item_length;

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

        const remaining_bits = (program.code.len) % 8;
        if (remaining_bits != 0) {
            const mask = ~((@as(u8, 1) << @intCast(remaining_bits)) - 1);
            @constCast(program.mask)[program.mask.len - 1] |= mask;
        }

        const mask_span = span.child(@src(), .mask);
        defer mask_span.deinit();
        mask_span.debug("Mask length: {d} bytes", .{mask_length_in_bytes});

        for (program.mask) |byte| {
            var bit_str: [8]u8 = undefined;
            for (0..8) |bit| {
                bit_str[bit] = if ((byte >> @intCast(7 - bit)) & 1 == 1) '1' else '0';
            }
            // mask_span.debug("Mask[{d:0>2}]: 0b{s} (0x{x:0>2})", .{ i, bit_str, byte });
        }

        var decoder = Decoder.init(program.code, program.mask);

        var basic_blocks = std.ArrayList(u32).init(allocator);
        errdefer basic_blocks.deinit();
        try basic_blocks.append(0);

        var pc: u32 = 0;
        const basic_span = span.child(@src(), .basic_blocks);
        defer basic_span.deinit();
        basic_span.debug("Starting basic block analysis", .{});

        while (pc < program.code.len) {
            const instruction = decoder.decodeInstruction(pc) catch |err| {
                basic_span.err("PC {d:0>4}: error decoding instruction {d}: {any}", .{ pc, decoder.getCodeAt(pc), err });
                return err;
            };
            basic_span.trace("PC {d:0>4}: Instruction: {}", .{ pc, instruction });

            if (instruction.isTerminationInstruction()) {
                const next_pc = pc + 1 + instruction.args.skip_l();
                if (next_pc < program.code.len + Decoder.MaxInstructionSizeInBytes) {
                    try basic_blocks.append(next_pc);
                } else {
                    return Error.ProgramTooShort;
                }
            }

            pc += 1 + instruction.args.skip_l();
        }

        program.basic_blocks = try basic_blocks.toOwnedSlice();
        errdefer allocator.free(program.basic_blocks);

        const jump_span = span.child(@src(), .jump_validation);
        defer jump_span.deinit();
        jump_span.debug("Validating jump table destinations", .{});

        var i: usize = 0;
        while (i < program.jump_table.len()) : (i += 1) {
            const destination = program.jump_table.getDestination(i);
            jump_span.trace("Jump table entry {d}: destination = {d:0>4}", .{ i, destination });

            if (destination >= program.code.len) {
                return Error.InvalidJumpDestination;
            }

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

    pub fn validateJumpAddress(self: *const Program, address: u32) JumpError!u32 {
        const span = trace.span(@src(), .validate_jump);
        defer span.deinit();
        span.debug("Validating jump address: {d:0>8} (0x{x:0>8})", .{ address, address });

        const halt_pc = 0xFFFF0000;
        const ZA = 2;

        span.trace("Jump table length: {d}, ZA: {d}, max valid address: {d}", .{ self.jump_table.len(), ZA, self.jump_table.len() * ZA });

        if (address == halt_pc) {
            span.trace("Detected halt address (0x{x:0>8})", .{halt_pc});
            return error.JumpAddressHalt;
        }

        if (address == 0) {
            span.trace("Invalid zero address", .{});
            return error.JumpAddressZero;
        }

        if (address > self.jump_table.len() * ZA) {
            span.err("Address {d} exceeds maximum valid address {d}", .{ address, self.jump_table.len() * ZA });
            return error.JumpAddressOutOfRange;
        }

        if (address % ZA != 0) {
            span.err("Address {d} is not aligned to ZA={d} (remainder: {d})", .{ address, ZA, address % ZA });
            return error.JumpAddressNotAligned;
        }

        const index = (address / ZA) - 1;
        const jump_dest = self.jump_table.getDestination(index);
        span.trace("Computed index: {d} from address {d}/ZA-1, jump destination: {d}", .{ index, address, jump_dest });

        if (std.sort.binarySearch(u32, self.basic_blocks, jump_dest, struct {
            fn orderU32(ctx: u32, item: u32) std.math.Order {
                return std.math.order(ctx, item);
            }
        }.orderU32) == null) {
            span.trace("Jump destination {d} not found in basic blocks: {any}", .{ jump_dest, self.basic_blocks });
            return error.JumpAddressNotInBasicBlock;
        }

        span.trace("Jump validated successfully: address {d} -> destination {d}", .{ address, jump_dest });
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
