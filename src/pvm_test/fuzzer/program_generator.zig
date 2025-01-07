const std = @import("std");
const codec = @import("../../codec.zig");
const Allocator = std.mem.Allocator;
const SeedGenerator = @import("seed.zig").SeedGenerator;

/// Represents a PVM instruction type with its opcode range and operand structure
const InstructionType = enum {
    NoArgs, // Instructions like trap (0), fallthrough (1)
    OneImm, // Instructions like ecalli (10)
    OneRegOneImm, // Instructions like jump_ind (50), load_imm (51)
    TwoRegOneImm, // Instructions like store_imm_ind_u8 (110)
    TwoRegTwoImm, // Instructions like load_imm_jump_ind (160)
    ThreeReg, // Instructions like add_32 (170), sub_32 (171)
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
    .{ "OneRegOneImm", .{ .start = 50, .end = 62 } },
    .{ "TwoRegOneImm", .{ .start = 110, .end = 139 } },
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

    /// Generate a valid PVM instruction
    fn generateValidInstruction(self: *Self, block: *BasicBlock, is_terminator: bool) !void {
        if (is_terminator) {
            // Generate terminator instruction (trap, fallthrough, or jump)
            const terminator_type = self.seed_gen.randomIntRange(u8, 0, 2);
            switch (terminator_type) {
                0 => try block.instructions.append(0), // trap
                1 => try block.instructions.append(1), // fallthrough
                2 => { // jump
                    try block.instructions.append(40); // jump opcode
                    // Jump target will be filled in during linkBlocks()
                    try block.instructions.append(0); // Placeholder
                },
                else => unreachable,
            }
        } else {
            // Generate regular instruction
            const inst_type = @as(InstructionType, @enumFromInt(
                self.seed_gen.randomIntRange(u8, 2, 5),
            ));
            const range = instruction_ranges.get(@tagName(inst_type)).?;
            const opcode = self.seed_gen.randomIntRange(u8, range.start, range.end);
            try block.instructions.append(opcode);

            // Add appropriate operands based on instruction type
            switch (inst_type) {
                .NoArgs => {}, // No operands needed
                .OneImm => {
                    const imm = self.seed_gen.randomByte();
                    try block.instructions.append(imm);
                },
                .OneRegOneImm => {
                    const reg = self.seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
                    const imm = self.seed_gen.randomByte();
                    try block.instructions.append(reg);
                    try block.instructions.append(imm);
                },
                .TwoRegOneImm => {
                    const reg1 = self.seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
                    const reg2 = self.seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
                    const imm = self.seed_gen.randomByte();
                    try block.instructions.append(reg1);
                    try block.instructions.append(reg2);
                    try block.instructions.append(imm);
                },
                .TwoRegTwoImm => {
                    const reg1 = self.seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
                    const reg2 = self.seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
                    const imm1 = self.seed_gen.randomByte();
                    const imm2 = self.seed_gen.randomByte();
                    try block.instructions.append(reg1);
                    try block.instructions.append(reg2);
                    try block.instructions.append(imm1);
                    try block.instructions.append(imm2);
                },
                .ThreeReg => {
                    const reg1 = self.seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
                    const reg2 = self.seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
                    const reg3 = self.seed_gen.randomIntRange(u8, 0, MaxRegisterIndex);
                    try block.instructions.append(reg1);
                    try block.instructions.append(reg2);
                    try block.instructions.append(reg3);
                },
            }
        }
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

    fn buildMask(self: *Self, code_length: usize) ![]u8 {
        const mask_size = (code_length + 7) / 8;
        var mask = try self.allocator.alloc(u8, mask_size);
        @memset(mask, 0);

        // Set mask bits for each basic block start
        for (self.basic_blocks.items) |block| {
            const byte_index = block.address / 8;
            const bit_index = @as(u3, @truncate(block.address % 8));
            mask[byte_index] |= @as(u8, 1) << bit_index;
        }

        return mask;
    }

    fn buildJumpTable(self: *Self) ![]u32 {
        // Collect all unique jump targets
        var targets = std.ArrayList(u32).init(self.allocator);
        defer targets.deinit();

        for (self.basic_blocks.items) |block| {
            for (block.jump_targets.items) |target| {
                // Check if target already exists
                var found = false;
                for (targets.items) |existing| {
                    if (existing == target) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try targets.append(target);
                }
            }
        }

        // Sort targets for deterministic output
        std.sort.insertion(u32, targets.items, {}, std.sort.asc(u32));

        return try targets.toOwnedSlice();
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
    var block_count: u32 = 1;
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
        if (byte_index >= program.mask.len) return error.InvalidJumpTarget;
        if ((program.mask[byte_index] & (@as(u8, 1) << bit_index)) == 0) {
            return error.InvalidJumpTarget;
        }
    }

    // 2. Verify code section ends with valid instructions
    var i: usize = 0;
    while (i < program.code.len) {
        const opcode = program.code[i];
        i += 1;

        // Skip operands based on instruction type
        switch (opcode) {
            0, 1 => {}, // No operands (trap, fallthrough)
            10 => i += 1, // OneImm
            40 => i += 1, // jump (special case)
            50...62 => i += 2, // OneRegOneImm
            110...139 => i += 3, // TwoRegOneImm
            160 => i += 4, // TwoRegTwoImm
            170...199 => i += 3, // ThreeReg
            else => return error.InvalidOpcode,
        }

        if (i > program.code.len) return error.IncompleteFinalInstruction;
    }

    // 3. Verify mask size matches code length
    const expected_mask_size = (program.code.len + 7) / 8;
    if (program.mask.len != expected_mask_size) {
        return error.InvalidMaskSize;
    }

    // // 4. Verify jump table format
    // if (program.jump_table.len == 0) {
    //     return error.EmptyJumpTable;
    // }

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
