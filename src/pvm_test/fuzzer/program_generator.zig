const std = @import("std");
const Allocator = std.mem.Allocator;

const codec = @import("../../codec.zig");
const InstructionWithArgs = @import("../../pvm/instruction.zig").InstructionWithArgs;
const InstructionType = @import("../../pvm/instruction.zig").InstructionType;
const Memory = @import("../../pvm/memory.zig").Memory;
const MaxInstructionSizeInBytes = @import("../../pvm/instruction.zig").MaxInstructionSizeInBytes;

const SeedGenerator = @import("seed.zig").SeedGenerator;
const code_gen = @import("program_generator/code_generator.zig");

const trace = @import("../../tracing.zig").scoped(.pvm);

const JumpAlignmentFactor = 2; // ZA = 2 as per spec

/// Represents the complete encoded PVM program
pub const GeneratedProgram = struct {
    /// Complete raw encoded program bytes
    raw_bytes: ?[]u8 = null,
    /// Component parts for verification/testing
    code: []u8,
    mask: []u8,
    jump_table: []u32,

    pub fn getRawBytes(self: *@This(), allocator: std.mem.Allocator) ![]u8 {
        const span = trace.span(.get_raw_bytes);
        defer span.deinit();
        span.debug("Computing raw bytes for program", .{});

        // If we already have the raw bytes computed, return them
        if (self.raw_bytes) |bytes| {
            span.debug("Returning cached raw bytes, length: {d}", .{bytes.len});
            return bytes;
        }

        // Create an ArrayList to build our output buffer
        var list = std.ArrayList(u8).init(allocator);
        errdefer list.deinit();

        // Get a writer for our list
        const writer = list.writer();

        // 1. Write jump table length using variable-length encoding
        // The length is the number of entries in the jump table
        try codec.writeInteger(self.jump_table.len, writer);

        // 2. Write jump table item length (single byte)
        // Calculate the minimum bytes needed to store the largest jump target
        const max_jump_target = blk: {
            var max: u32 = 0;
            for (self.jump_table) |target| {
                max = @max(max, target);
            }
            break :blk max;
        };
        const item_length = calculateMinimumBytes(max_jump_target);
        try writer.writeByte(item_length);

        // 3. Write code length using variable-length encoding
        try codec.writeInteger(self.code.len, writer);

        // 4. Write jump table entries
        // Each entry is written using the calculated item_length
        for (self.jump_table) |target| {
            var buf: [4]u8 = undefined; // Maximum 4 bytes for u32
            std.mem.writeInt(u32, &buf, target, .little);
            try writer.writeAll(buf[0..item_length]);
        }

        // 5. Write code section
        try writer.writeAll(self.code);

        // 6. Write mask section
        try writer.writeAll(self.mask);

        // Store and return the final byte array
        self.raw_bytes = try list.toOwnedSlice();
        return self.raw_bytes.?;
    }

    pub fn rewriteMemoryAccesses(
        self: *GeneratedProgram,
        seed_gen: *SeedGenerator,
        heap_start: u32,
        heap_len: u32,
    ) !void {
        const span = trace.span(.rewrite_memory);
        defer span.deinit();

        var decoder = @import("../../pvm/decoder.zig").Decoder.init(self.code, self.mask);
        var iter = decoder.iterator();

        span.debug("Rewriting memory accesses - heap base: 0x{X}, size: 0x{X}", .{ heap_start, heap_len });

        while (try iter.next()) |entry| {
            if (entry.inst.getMemoryAccess()) |access| {
                const inst_span = span.child(.rewrite_instruction);
                defer inst_span.deinit();

                // Generate a deterministic offset using the seed generator
                const random_offset = seed_gen.randomIntRange(
                    u32,
                    0,
                    heap_len - access.size - 64 - 1, // 64 is the biggest value which can be read
                );
                const offset = heap_start + random_offset;
                inst_span.debug("Rewriting memory access at pc {d} to address 0x{X}", .{ entry.pc, offset });

                // Encode the modified instruction
                // NOTE: this is a bit of a hack, as if for some reason
                // we get a random match on 0xaaaaaaaa we could get a false hit
                var inst_slice = self.code[entry.pc..entry.next_pc];
                if (std.mem.indexOf(u8, inst_slice, &[_]u8{0xaa} ** 4)) |index| {
                    std.mem.writeInt(u32, inst_slice[index..][0..4], offset, .little);
                }
            }
        }
    }

    /// Calculates the minimum number of bytes needed to store a value
    fn calculateMinimumBytes(value: u32) u8 {
        if (value <= 0xFF) return 1;
        if (value <= 0xFFFF) return 2;
        if (value <= 0xFFFFFF) return 3;
        return 4;
    }

    pub fn deinit(self: *GeneratedProgram, allocator: Allocator) void {
        if (self.raw_bytes) |bytes| {
            allocator.free(bytes);
        }
        allocator.free(self.code);
        allocator.free(self.mask);
        allocator.free(self.jump_table);
        self.* = undefined;
    }
};

pub const ProgramGenerator = struct {
    allocator: Allocator,
    seed_gen: *SeedGenerator,

    const Self = @This();
    const MaxRegisterIndex = 12; // Maximum valid register index

    pub fn init(allocator: Allocator, seed_gen: *SeedGenerator) !Self {
        return .{
            .allocator = allocator,
            .seed_gen = seed_gen,
        };
    }

    pub fn deinit(self: *Self) void {
        self.* = undefined;
    }

    /// Generate a valid PVM program with the specified number of basic blocks
    pub fn generate(self: *Self, instruction_count: u32) !GeneratedProgram {
        const span = trace.span(.generate);
        defer span.deinit();
        span.debug("Generating program with {d} instructions", .{instruction_count});

        // Generate a random program
        const instructions = try code_gen.generate(self.allocator, self.seed_gen, instruction_count);
        span.debug("Generated {d} random instructions", .{instructions.len});
        defer self.allocator.free(instructions);

        var code = try std.ArrayList(u8).initCapacity(self.allocator, instruction_count * MaxInstructionSizeInBytes);
        defer code.deinit();
        var mask_bitset = try std.DynamicBitSet.initEmpty(self.allocator, instruction_count * MaxInstructionSizeInBytes);
        defer mask_bitset.deinit();
        var basic_blocks = std.ArrayList(u32).init(self.allocator);
        defer basic_blocks.deinit();

        var jump_table = std.ArrayList(u32).init(self.allocator);
        errdefer jump_table.deinit();

        // always start with pos0
        try basic_blocks.append(0);
        try jump_table.append(0);

        var pc: u32 = 0;
        const code_writer = code.writer();
        const encode_span = span.child(.encode_instructions);
        defer encode_span.deinit();

        // We have the instructions and sizes. We can find the indexes to the
        // instructions of the basic blocks by looping.
        mask_bitset.set(0); // We always start with an instruction so first bit is always set
        for (instructions, 0..) |*inst, i| {
            const inst_span = encode_span.child(.encode_instruction);
            defer inst_span.deinit();

            // Pre-encode jumps with 0xaaaaaaaa to ensure max immediate size, allowing safe rewrites later
            inst.setBranchOrJumpTargetTo(0xaaaaaaaa) catch {};
            // Pre-encode memory accesses with the 0xaaaaaaaa to ensure max immediate size, allowing safe rewrites later
            inst.setMemoryAddress(0xaaaaaaaa) catch {};

            // if the instruction is a host call, set it to 0 so we can always provide a valid host
            // call
            if (inst.instruction == .ecalli) {
                inst.args.OneImm.immediate = 0x00;
            }

            inst_span.debug("Encoding instruction {d}/{d} at pc: {d}", .{ i + 1, instructions.len, pc });
            inst_span.trace("Instruction: {any}", .{inst});
            const bytes_written = try inst.encode(code_writer);
            pc += bytes_written;

            if (inst.isTerminationInstruction() and
                i != instructions.len - 1) // After last instruction we do not add a block or jump_table
            {
                try basic_blocks.append(pc);
                try jump_table.append(pc);
                inst_span.debug("Added termination block at pc {d}", .{pc});
            }

            // do not set a bit on last instruction, this could save
            // a byte, and the graypaper defined k + [1,1,1,1]
            if (i < instructions.len - 1) {
                mask_bitset.set(pc);
            }
            inst_span.trace("Wrote {d} bytes, new pc: {d}", .{ bytes_written, pc });
        }

        // generate the mask, we allocate ceil + 1 as the mask could possible end
        const mask_span = span.child(.generate_mask);
        defer mask_span.deinit();

        const mask_size = try std.math.divCeil(usize, pc, 8);
        mask_span.debug("Allocating mask of size {d} bytes", .{mask_size});

        const mask = try self.allocator.alloc(u8, mask_size);
        errdefer self.allocator.free(mask);
        @memset(mask, 0);

        var mask_iter = mask_bitset.iterator(.{});
        while (mask_iter.next()) |bidx| {
            mask_span.trace("Mask bit {d} set", .{bidx});
            mask[bidx / 8] |= @as(u8, 1) << @intCast(bidx % 8);
        }
        span.debug("Generated mask with {d} bytes", .{mask.len});

        var expected_bitmask_length = code.items.len / 8;
        const is_bitmask_padded = code.items.len % 8 != 0;
        expected_bitmask_length += if (is_bitmask_padded) 1 else 0;

        if (is_bitmask_padded) {
            const last_byte = mask[mask.len - 1];
            const padding_bits: u3 = @intCast(mask.len * 8 - code.items.len);
            const padding_mask = @as(i8, @bitCast(@as(u8, 0b10000000))) >> (padding_bits - 1);
            // std.debug.print("Last byte of mask:  0b{b:0>8}\n", .{last_byte});
            // std.debug.print("Padding mask:      0b{b:0>8}\n", .{@as(u8, @bitCast(padding_mask))});
            if (last_byte & @as(u8, @bitCast(padding_mask)) != 0) {
                @panic("BitmaskPaddedWithNonZeroes");
            }
        }

        // On the second pass of our program we need to find the branches
        // and let them jump to any of the elements in our jump table to make
        // these jumps valid
        var prgdec = @import("../../pvm/decoder.zig").Decoder.init(code.items, mask);
        var iter = prgdec.iterator();

        {
            const rewrite_span = span.child(.rewrite_jumps);
            rewrite_span.debug("Rewriting jumps", .{});
            while (try iter.next()) |entry| {
                if (entry.inst.isBranch() or entry.inst.isBranchWithImm() or entry.inst.instruction == .jump) {
                    const branch_span = rewrite_span.child(.rewrite_branch);
                    defer branch_span.deinit();
                    branch_span.debug("Rewriting branch/jump at pc {d}: {}", .{ entry.pc, entry.inst });

                    // Select a random jump target from our jump table
                    var target_idx = self.seed_gen.randomIntRange(usize, 0, basic_blocks.items.len - 1);
                    var target_pc = basic_blocks.items[target_idx];

                    // If we're jumping to our own position and there's a next target available,
                    // use the next target instead
                    if (target_pc == entry.pc and basic_blocks.items.len > 1) {
                        target_idx = (target_idx + 1) % basic_blocks.items.len;
                        target_pc = basic_blocks.items[target_idx];
                    }

                    // Calculate the relative offset from current position
                    // Need to account for instruction size in offset calculation
                    const current_pos = entry.pc;
                    const offset: i32 = @intCast(@as(i64, target_pc) - @as(i64, current_pos));
                    branch_span.trace("Jump calculation - from: {d}, to: {d}, offset: {d} ({d})", .{ current_pos, target_pc, offset, @as(u32, @bitCast(offset)) });

                    // Update the branch instruction with the new target
                    // the offset are always the last 4 bytes of te instruction
                    // which we maximized in the first pass
                    var buffer: [4]u8 = undefined;
                    const code_slice = code.items[entry.next_pc - 4 ..][0..4];
                    std.mem.writeInt(i32, &buffer, offset, .little);
                    branch_span.trace("Rewriting bytes at offset {X}: {X} => {X}", .{
                        entry.next_pc - 4,
                        code_slice,
                        &buffer,
                    });

                    // Update the code buffer with the modified instruction
                    @memcpy(code_slice, &buffer);
                }

                // Handle the indirect jumps here
                if (entry.inst.instruction == .jump_ind or
                    entry.inst.instruction == .load_imm_jump_ind)
                {
                    // Select a random jump target index
                    var target_idx = self.seed_gen.randomIntRange(usize, 0, jump_table.items.len - 1);

                    // If the target is the same as our position and there's a next target available,
                    // use the next target instead
                    if (jump_table.items[target_idx] == entry.pc and jump_table.items.len > 1) {
                        target_idx = (target_idx + 1) % jump_table.items.len;
                    }

                    // Update the instruction's immediate value with the jump table index
                    var buffer: [4]u8 = undefined;
                    std.mem.writeInt(u32, &buffer, @as(u32, @intCast((target_idx + 1) * 2)), .little);

                    // Update the code buffer at the immediate position
                    const imm_offset = entry.next_pc - 4; // Last 4 bytes contain the immediate
                    @memcpy(code.items[imm_offset..][0..4], &buffer);
                }
            }
        }

        return GeneratedProgram{
            .code = try code.toOwnedSlice(),
            .mask = mask,
            .jump_table = try jump_table.toOwnedSlice(),
        };
    }
};

test "simple" {
    const allocator = std.testing.allocator;
    var seed_gen = SeedGenerator.init(42);
    var generator = try ProgramGenerator.init(allocator, &seed_gen);
    defer generator.deinit();

    // Generate multiple programs of varying sizes
    var program = try generator.generate(128);
    defer program.deinit(allocator);

    const Decoder = @import("../../pvm/decoder.zig").Decoder;
    const decoder = Decoder.init(program.code, program.mask);

    std.debug.print("\n\nCode.len: {d}\n", .{program.code.len});
    std.debug.print("Mask.len: {d}\n", .{program.mask.len});

    var pc: u32 = 0;
    while (pc < program.code.len) {
        const i = try decoder.decodeInstruction(pc);
        std.debug.print("{d:0>4}: {any} len: {d}\n", .{ pc, i, i.skip_l() });
        pc += i.skip_l() + 1;
    }
}
