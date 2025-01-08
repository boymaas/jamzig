const std = @import("std");
const codec = @import("../../codec.zig");
const Allocator = std.mem.Allocator;
const SeedGenerator = @import("seed.zig").SeedGenerator;

/// Represents a PVM instruction type with its opcode range and operand structure
/// Represents a PVM instruction type with its opcode range and operand structure
const InstructionType = enum {
    // Instructions with no arguments (A.5.1)
    NoArgs, // 0-1: trap, fallthrough
    // Instructions with one immediate (A.5.2)
    OneImm, // 10: ecalli
    // Instructions with one register and one extended width immediate (A.5.3)
    OneRegExtImm, // 20: load_imm_64
    // Instructions with two immediates (A.5.4)
    TwoImm, // 30-33: store_imm_u8, store_imm_u16, etc.
    // Instructions with one offset (A.5.5)
    OneOffset, // 40: jump
    // Instructions with one register and one immediate (A.5.6)
    OneRegOneImm, // 50-62: jump_ind, load_imm, load_u8, etc.
    // Instructions with one register and two immediates (A.5.7)
    OneRegTwoImm, // 70-73: store_imm_ind_u8, store_imm_ind_u16, etc.
    // Instructions with one register, one immediate and one offset (A.5.8)
    OneRegOneImmOneOffset, // 80-90: load_imm_jump, branch_eq_imm, etc.
    // Instructions with two registers (A.5.9)
    TwoReg, // 100-101: move_reg, sbrk
    // Instructions with two registers and one immediate (A.5.10)
    TwoRegOneImm, // 110-147: store_ind_u8, load_ind_u8, add_imm_32, etc.
    // Instructions with two registers and one offset (A.5.11)
    TwoRegOneOffset, // 150-155: branch_eq, branch_ne, etc.
    // Instructions with two registers and two immediates (A.5.12)
    TwoRegTwoImm, // 160: load_imm_jump_ind
    // Instructions with three registers (A.5.13)
    ThreeReg, // 170-199: add_32, sub_32, mul_32, etc.
};

/// Maps instruction types to their valid opcode ranges
const InstructionRange = struct {
    start: u8,
    end: u8,
};

/// Valid opcode ranges for each instruction type
const instruction_ranges = std.StaticStringMap(InstructionRange).initComptime(.{
    .{ "NoArgs", .{ .start = 0, .end = 1 } },
    .{ "OneImm", .{ .start = 10, .end = 10 } },
    .{ "OneRegExtImm", .{ .start = 20, .end = 20 } },
    .{ "TwoImm", .{ .start = 30, .end = 33 } },
    .{ "OneOffset", .{ .start = 40, .end = 40 } },
    .{ "OneRegOneImm", .{ .start = 50, .end = 62 } },
    .{ "OneRegTwoImm", .{ .start = 70, .end = 73 } },
    .{ "OneRegOneImmOneOffset", .{ .start = 80, .end = 90 } },
    .{ "TwoReg", .{ .start = 100, .end = 101 } },
    .{ "TwoRegOneImm", .{ .start = 110, .end = 147 } },
    .{ "TwoRegOneOffset", .{ .start = 150, .end = 155 } },
    .{ "TwoRegTwoImm", .{ .start = 160, .end = 160 } },
    .{ "ThreeReg", .{ .start = 170, .end = 199 } },
});

/// Definition of a basic block for improved tracking
pub const BasicBlock = struct {
    /// Starting address of the block
    address: u32,
    /// Instructions in the block
    instructions: std.ArrayList(u8),
    /// List of valid jump targets from this block
    jump_targets: std.ArrayList(u32),
    /// Mask bits for the block's instructions
    mask_bits: std.ArrayList(bool),

    /// Add an instruction with its length to the block
    pub fn addInstruction(self: *BasicBlock, bytes: []const u8, length: u8) !void {
        try self.instructions.appendSlice(bytes);

        // Set mask bit for instruction start
        try self.mask_bits.append(true);

        // Add false bits for the rest of the instruction
        var i: usize = 1;
        while (i < length) : (i += 1) {
            try self.mask_bits.append(false);
        }
    }

    pub fn deinit(self: *BasicBlock) void {
        self.instructions.deinit();
        self.jump_targets.deinit();
    }
};

/// Represents the complete encoded PVM program
pub const GeneratedProgram = struct {
    /// Complete raw encoded program bytes
    raw_bytes: []u8,
    /// Component parts for verification/testing
    code: []u8,
    mask: []u8,
    jump_table: []u32,

    pub fn deinit(self: *GeneratedProgram, allocator: Allocator) void {
        allocator.free(self.raw_bytes);
        allocator.free(self.code);
        allocator.free(self.mask);
        allocator.free(self.jump_table);
        self.* = undefined;
    }
};

pub const ProgramGenerator = struct {
    allocator: Allocator,
    seed_gen: *SeedGenerator,
    basic_blocks: std.ArrayList(BasicBlock),
    next_address: u32,

    const Self = @This();
    const MaxBlockSize = 32; // Maximum instructions in a block
    const MinBlockSize = 4; // Minimum instructions in a block
    const MaxRegisterIndex = 12; // Maximum valid register index

    pub fn init(allocator: Allocator, seed_gen: *SeedGenerator) Self {
        return .{
            .allocator = allocator,
            .seed_gen = seed_gen,
            .basic_blocks = std.ArrayList(BasicBlock).init(allocator),
            .next_address = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.basic_blocks.items) |*block| {
            block.deinit();
        }
        self.basic_blocks.deinit();
    }

    /// Generate a valid PVM program with the specified number of basic blocks
    pub fn generate(self: *Self, num_blocks: u32) !GeneratedProgram {
        // Clear any existing state
        self.deinit();
        self.basic_blocks = std.ArrayList(BasicBlock).init(self.allocator);
        self.next_address = 0;

        // Generate basic blocks
        var i: u32 = 0;
        while (i < num_blocks) : (i += 1) {
            const block = try self.generateBasicBlock();
            try self.basic_blocks.append(block);
        }

        // Add valid jump targets to each block
        try self.linkBlocks();

        // Build the component parts
        const code = try self.buildCode();
        errdefer self.allocator.free(code);

        const mask = try self.buildMask(code.len);
        errdefer self.allocator.free(mask);

        const jump_table = try self.buildJumpTable();
        errdefer self.allocator.free(jump_table);

        // Build the complete raw program
        const program = try self.buildRawProgram(code, mask, jump_table);

        return GeneratedProgram{
            .raw_bytes = program,
            .code = code,
            .mask = mask,
            .jump_table = jump_table,
        };
    }

    /// Generate a single valid basic block
    fn generateBasicBlock(self: *Self) !BasicBlock {
        var block = BasicBlock{
            .address = self.next_address,
            .instructions = std.ArrayList(u8).init(self.allocator),
            .jump_targets = std.ArrayList(u32).init(self.allocator),
            .mask_bits = std.ArrayList(bool).init(self.allocator),
        };

        // Generate a sequence of valid instructions
        const num_instructions = self.seed_gen.randomIntRange(u32, MinBlockSize, MaxBlockSize);
        var i: u32 = 0;
        while (i < num_instructions - 1) : (i += 1) {
            try self.generateValidInstruction(&block, false);
        }

        // End with a valid terminator
        try self.generateValidInstruction(&block, true);

        // Update next block address
        self.next_address += @intCast(block.instructions.items.len);

        return block;
    }

    /// Generate a valid PVM instruction with correctly encoded arguments
    /// Following graypaper sections A.5.1 through A.5.13, using variable-length
    /// immediate encoding as per section 3.7.2
    fn generateValidInstruction(self: *Self, block: *BasicBlock, is_terminator: bool) !void {
        if (is_terminator) {
            try self.generateTerminator(block);
        } else {
            try self.generateRegularInstruction(block);
        }
    }

    /// Generate a terminator instruction (trap, fallthrough, or jump)
    fn generateTerminator(self: *Self, block: *BasicBlock) !void {
        var instruction_buffer = std.ArrayList(u8).init(self.allocator);
        defer instruction_buffer.deinit();

        var encoder = @import("instruction.zig").encoder(instruction_buffer.writer());

        const terminator_type = self.seed_gen.randomIntRange(u8, 0, 2);
        const length = switch (terminator_type) {
            0 => try encoder.encodeNoArgs(0), // trap
            1 => try encoder.encodeNoArgs(1), // fallthrough
            2 => try encoder.encodeJump(0), // Jump target will be filled in later during block linking
            else => unreachable,
        };

        try block.addInstruction(instruction_buffer.items, length);
    }

    /// Generate a regular (non-terminator) instruction
    fn generateRegularInstruction(self: *Self, block: *BasicBlock) !void {
        var instruction_buffer = std.ArrayList(u8).init(self.allocator);
        defer instruction_buffer.deinit();

        var encoder = @import("instruction.zig").encoder(instruction_buffer.writer());

        // Select random instruction type (excluding NoArgs which is for terminators)
        const inst_type = @as(InstructionType, @enumFromInt(
            self.seed_gen.randomIntRange(u8, 3, std.meta.fields(InstructionType).len - 1),
        ));
        const range = instruction_ranges.get(@tagName(inst_type)).?;
        const opcode = self.seed_gen.randomIntRange(u8, range.start, range.end);

        const length = switch (inst_type) {
            .NoArgs => unreachable, // Handled by generateTerminator
            .OneImm => blk: {
                const imm = self.seed_gen.randomImmediate();
                break :blk try encoder.encodeOneImm(opcode, imm);
            },
            .OneRegExtImm => blk: {
                const reg = self.seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
                const imm = self.seed_gen.randomImmediate();
                break :blk try encoder.encodeOneRegOneExtImm(opcode, reg, imm);
            },
            .TwoImm => blk: {
                const imm1 = self.seed_gen.randomImmediate();
                const imm2 = self.seed_gen.randomImmediate();
                break :blk try encoder.encodeTwoImm(opcode, imm1, imm2);
            },
            .OneOffset => blk: {
                const offset = @as(i32, @bitCast(self.seed_gen.randomImmediate()));
                break :blk try encoder.encodeOneOffset(opcode, offset);
            },
            .OneRegOneImm => blk: {
                const reg = self.seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
                const imm = self.seed_gen.randomImmediate();
                break :blk try encoder.encodeOneRegOneImm(opcode, reg, imm);
            },
            .OneRegTwoImm => blk: {
                const reg = self.seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
                const imm1 = self.seed_gen.randomImmediate();
                const imm2 = self.seed_gen.randomImmediate();
                break :blk try encoder.encodeOneRegTwoImm(opcode, reg, imm1, imm2);
            },
            .OneRegOneImmOneOffset => blk: {
                const reg = self.seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
                const imm = self.seed_gen.randomImmediate();
                const offset = @as(i32, @bitCast(self.seed_gen.randomImmediate()));
                break :blk try encoder.encodeOneRegOneImmOneOffset(opcode, reg, imm, offset);
            },
            .TwoReg => blk: {
                const reg1 = self.seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
                const reg2 = self.seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
                break :blk try encoder.encodeTwoReg(opcode, reg1, reg2);
            },
            .TwoRegOneImm => blk: {
                const reg1 = self.seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
                const reg2 = self.seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
                const imm = self.seed_gen.randomImmediate();
                break :blk try encoder.encodeTwoRegOneImm(opcode, reg1, reg2, imm);
            },
            .TwoRegOneOffset => blk: {
                const reg1 = self.seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
                const reg2 = self.seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
                const offset = @as(i32, @bitCast(self.seed_gen.randomImmediate()));
                break :blk try encoder.encodeTwoRegOneOffset(opcode, reg1, reg2, offset);
            },
            .TwoRegTwoImm => blk: {
                const reg1 = self.seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
                const reg2 = self.seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
                const imm1 = self.seed_gen.randomImmediate();
                const imm2 = self.seed_gen.randomImmediate();
                break :blk try encoder.encodeTwoRegTwoImm(opcode, reg1, reg2, imm1, imm2);
            },
            .ThreeReg => blk: {
                const reg1 = self.seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
                const reg2 = self.seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
                const reg3 = self.seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
                break :blk try encoder.encodeThreeReg(opcode, reg1, reg2, reg3);
            },
        };

        try block.addInstruction(instruction_buffer.items, length);
    }

    /// Create valid jump targets between blocks
    fn linkBlocks(self: *Self) !void {
        for (self.basic_blocks.items) |*block| {
            // Find any jump instructions in the block
            var i: usize = 0;
            while (i < block.instructions.items.len) {
                if (block.instructions.items[i] == 40) { // jump opcode
                    // Select a valid target block
                    const target_idx = self.seed_gen.randomIntRange(
                        usize,
                        0,
                        self.basic_blocks.items.len - 1,
                    );
                    const target = self.basic_blocks.items[target_idx].address;
                    try block.jump_targets.append(target);

                    // Update the jump instruction's target
                    if (i + 1 < block.instructions.items.len) {
                        block.instructions.items[i + 1] = @truncate(target);
                    }
                }
                i += 1;
            }
        }
    }

    fn buildCode(self: *Self) ![]u8 {
        var code = std.ArrayList(u8).init(self.allocator);
        defer code.deinit();

        for (self.basic_blocks.items) |block| {
            try code.appendSlice(block.instructions.items);
        }

        return code.toOwnedSlice();
    }

    /// Build final mask from block mask bits
    fn buildMask(self: *Self, code_length: usize) ![]u8 {
        const mask_size = (code_length + 7) / 8;
        var mask = try self.allocator.alloc(u8, mask_size);
        @memset(mask, 0);

        var bit_pos: usize = 0;

        // Convert each block's mask bits to packed bytes
        for (self.basic_blocks.items) |block| {
            for (block.mask_bits.items) |is_start| {
                if (is_start) {
                    const byte_index = bit_pos / 8;
                    const bit_index = @as(u3, @truncate(bit_pos % 8));
                    mask[byte_index] |= @as(u8, 1) << bit_index;
                }
                bit_pos += 1;
            }
        }

        // Add padding bits if needed for final instructions
        while (bit_pos < code_length) {
            const byte_index = bit_pos / 8;
            const bit_index = @as(u3, @truncate(bit_pos % 8));
            mask[byte_index] |= @as(u8, 1) << bit_index;
            bit_pos += 1;
        }

        return mask;
    }

    const JumpAlignmentFactor = 2;

    fn buildJumpTable(self: *Self) ![]u32 {
        // Collect all unique jump targets and convert to table indices
        var targets = std.ArrayList(u32).init(self.allocator);
        defer targets.deinit();

        for (self.basic_blocks.items) |block| {
            for (block.jump_targets.items) |target| {
                // Convert target address to jump table index
                // Add 1 and multiply by alignment factor as per graypaper A.4
                const table_index = (target + 1) * JumpAlignmentFactor;

                // Check if target is aligned properly
                if (table_index % JumpAlignmentFactor != 0) {
                    return error.UnalignedJumpTarget;
                }

                // Check if target index already exists
                var found = false;
                for (targets.items) |existing| {
                    if (existing == table_index) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try targets.append(table_index);
                }
            }
        }

        // Sort targets for deterministic output
        std.sort.insertion(u32, targets.items, {}, std.sort.asc(u32));

        // Validate jump table constraints
        if (targets.items.len > 0) {
            // Verify no entry is 0 (would cause panic per graypaper)
            if (targets.items[0] == 0) {
                return error.InvalidJumpTableEntry;
            }

            // Verify all entries are properly aligned
            for (targets.items) |entry| {
                if (entry % JumpAlignmentFactor != 0) {
                    return error.UnalignedJumpTableEntry;
                }
            }
        }

        return try targets.toOwnedSlice();
    }

    // Update the jump instruction encoding to use table indices
    fn updateJumpTarget(instructions: []u8, offset: usize, target: u32) !void {
        // Convert target address to jump table index
        const table_index = (target + 1) * JumpAlignmentFactor;

        var fbs = std.io.fixedBufferStream(instructions[offset..]);
        try codec.writeInteger(table_index, fbs.writer());
    }

    fn buildRawProgram(self: *Self, code: []const u8, mask: []const u8, jump_table: []const u32) ![]u8 {
        var program = std.ArrayList(u8).init(self.allocator);
        defer program.deinit();

        // 1. Jump table length
        try codec.writeInteger(jump_table.len, program.writer());

        // 2. Jump table item length
        var max_target: u32 = 0;
        for (jump_table) |target| {
            max_target = @max(max_target, target);
        }
        const item_length: u8 = if (max_target <= 0xFF)
            1
        else if (max_target <= 0xFFFF)
            2
        else if (max_target <= 0xFFFFFF)
            3
        else
            4;
        try program.append(item_length);

        // 3. Code length
        try codec.writeInteger(code.len, program.writer());

        // 4. Jump table
        for (jump_table) |target| {
            var buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &buf, target, .little);
            try program.appendSlice(buf[0..item_length]);
        }

        // 5. Code section
        try program.appendSlice(code);

        // 6. Mask section
        try program.appendSlice(mask);

        return program.toOwnedSlice();
    }
};

test "ProgramGenerator - Verify generated program structure" {
    const allocator = std.testing.allocator;
    var seed_gen = SeedGenerator.init(42);
    var generator = ProgramGenerator.init(allocator, &seed_gen);
    defer generator.deinit();

    // Generate multiple programs of varying sizes
    var block_count: u32 = 2;
    while (block_count < 32) : (block_count *= 2) {
        var program = try generator.generate(block_count);
        defer program.deinit(allocator);

        try verifyProgramStructure(program);
    }
}

fn verifyProgramStructure(program: GeneratedProgram) !void {
    // 1. Verify all jump targets point to valid block starts
    for (program.jump_table) |target| {
        const byte_index = target / 8;
        const bit_index = @as(u3, @truncate(target % 8));
        std.debug.print("Validating jump target: {d} (byte: {d}, bit: {d})\n", .{ target, byte_index, bit_index });

        if (byte_index >= program.mask.len) {
            std.debug.print("ERROR: Jump target {d} exceeds mask length {d}\n", .{ target, program.mask.len });
            return error.InvalidJumpTarget;
        }

        const mask_byte = program.mask[byte_index];
        const bit_mask = @as(u8, 1) << bit_index;
        if ((mask_byte & bit_mask) == 1) {
            std.debug.print("ERROR: Invalid jump target {d} - mask byte 0x{x:0>2} doesn't have bit {d} set\n", .{ target, mask_byte, bit_index });
            return error.InvalidJumpTarget;
        }
        std.debug.print("  -> Valid jump target (mask byte: 0x{x:0>2})\n", .{mask_byte});
    }

    // 3. Verify mask size matches code length
    const expected_mask_size = (program.code.len + 7) / 8;
    if (program.mask.len != expected_mask_size) {
        return error.InvalidMaskSize;
    }

    // 4. Verify jump table format
    if (program.jump_table.len == 0) {
        return error.EmptyJumpTable;
    }

    // 5. Verify all jump targets are within code bounds
    for (program.jump_table) |target| {
        if (target >= program.code.len) {
            return error.JumpTargetOutOfBounds;
        }
    }
}

test "ProgramGenerator - Basic block termination" {
    const allocator = std.testing.allocator;
    var seed_gen = SeedGenerator.init(42);
    var generator = ProgramGenerator.init(allocator, &seed_gen);
    defer generator.deinit();

    var program = try generator.generate(4);
    defer program.deinit(allocator);

    // Every basic block should end with a valid terminator
    var current_block_start: usize = 0;
    var i: usize = 0;
    while (i < program.code.len) {
        // const opcode = program.code[i];
        const byte_index = i / 8;
        const bit_index = @as(u3, @truncate(i % 8));

        // Check if this is a block start
        if ((program.mask[byte_index] & (@as(u8, 1) << bit_index)) != 0) {
            // If not the first block, verify previous block terminator
            if (i > 0) {
                const prev_terminator = program.code[i - 1];
                try std.testing.expect(prev_terminator == 0 or // trap
                    prev_terminator == 1 or // fallthrough
                    prev_terminator == 40); // jump
            }
            current_block_start = i;
        }
        i += 1;
    }
}

test "ProgramGenerator - Jump table validity" {
    const allocator = std.testing.allocator;
    var seed_gen = SeedGenerator.init(42);
    var generator = ProgramGenerator.init(allocator, &seed_gen);
    defer generator.deinit();

    var program = try generator.generate(4);
    defer program.deinit(allocator);

    // Every jump target should point to a block start
    for (program.jump_table) |target| {
        const byte_index = target / 8;
        const bit_index = @as(u3, @truncate(target % 8));
        try std.testing.expect((program.mask[byte_index] & (@as(u8, 1) << bit_index)) != 0);
    }
}
