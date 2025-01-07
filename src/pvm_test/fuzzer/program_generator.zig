const std = @import("std");
const codec = @import("../../codec.zig");
const Allocator = std.mem.Allocator;
const SeedGenerator = @import("seed.zig").SeedGenerator;

pub const BasicBlock = struct {
    address: u32,
    size: u32,
    instructions: std.ArrayList(u8),
};

/// Represents a complete PVM program in its raw encoded format
pub const GeneratedProgram = struct {
    /// The complete raw encoded program bytes
    raw_bytes: []u8,
    /// For debugging/testing: the component parts
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

    const Self = @This();

    pub fn init(allocator: Allocator, seed_gen: *SeedGenerator) Self {
        return .{
            .allocator = allocator,
            .seed_gen = seed_gen,
            .basic_blocks = std.ArrayList(BasicBlock).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.basic_blocks.items) |*block| {
            block.instructions.deinit();
        }
        self.basic_blocks.deinit();
    }

    /// Generate a complete PVM program with the specified number of basic blocks
    /// The generated program will be in the exact format expected by PVM.decode()
    pub fn generate(self: *Self, num_blocks: u32) !GeneratedProgram {
        // Clear any existing blocks
        self.deinit();
        self.basic_blocks = std.ArrayList(BasicBlock).init(self.allocator);

        // Generate basic blocks
        var current_address: u32 = 0;
        var i: u32 = 0;
        while (i < num_blocks) : (i += 1) {
            const block = try self.generateBasicBlock(current_address);
            try self.basic_blocks.append(block);
            current_address += block.size;
        }

        // Build the component parts
        const code = try self.buildCode();
        errdefer self.allocator.free(code);

        const mask = try self.buildMask(code.len);
        errdefer self.allocator.free(mask);

        const jump_table = try self.buildJumpTable();
        errdefer self.allocator.free(jump_table);

        // Now build the complete raw program
        const program = try self.buildRawProgram(code, mask, jump_table);

        return GeneratedProgram{
            .raw_bytes = program,
            .code = code,
            .mask = mask,
            .jump_table = jump_table,
        };
    }

    fn generateBasicBlock(self: *Self, address: u32) !BasicBlock {
        var block = BasicBlock{
            .address = address,
            .size = self.seed_gen.randomIntRange(u32, 4, 32), // Random block size
            .instructions = std.ArrayList(u8).init(self.allocator),
        };

        // Generate random instructions for the block
        const num_instructions = self.seed_gen.randomIntRange(u32, 1, 8);
        var i: u32 = 0;
        while (i < num_instructions) : (i += 1) {
            try self.generateInstruction(&block);
        }

        // End block with a control flow instruction
        try self.generateBlockTerminator(&block);

        return block;
    }

    fn generateInstruction(self: *Self, block: *BasicBlock) !void {
        // For now, generate simple arithmetic or load immediate instructions
        const opcode = self.seed_gen.randomIntRange(u8, 0, 255);
        try block.instructions.append(opcode);

        // Add random operands
        const num_operands = self.seed_gen.randomIntRange(u8, 0, 3);
        var i: u8 = 0;
        while (i < num_operands) : (i += 1) {
            try block.instructions.append(self.seed_gen.randomByte());
        }
    }

    fn generateBlockTerminator(self: *Self, block: *BasicBlock) !void {
        // End block with jump, trap, or fallthrough
        const terminator_type = self.seed_gen.randomIntRange(u8, 0, 2);
        switch (terminator_type) {
            0 => try block.instructions.append(0), // trap
            1 => try block.instructions.append(1), // fallthrough
            2 => { // jump
                try block.instructions.append(40); // jump opcode
                // Add random jump target - we'll fix this up later
                try block.instructions.append(self.seed_gen.randomByte());
            },
            else => unreachable,
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
        // Find the highest block address to determine mask size
        var max_address: usize = 0;
        for (self.basic_blocks.items) |block| {
            max_address = @max(max_address, block.address + block.size);
        }
        // Ensure mask covers both the code length and all block addresses
        const mask_size = (@max(code_length, max_address) + 7) / 8;
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
        var jump_table = try self.allocator.alloc(u32, self.basic_blocks.items.len);
        for (self.basic_blocks.items, 0..) |block, i| {
            jump_table[i] = block.address;
        }
        return jump_table;
    }

    fn buildRawProgram(self: *Self, code: []const u8, mask: []const u8, jump_table: []const u32) ![]u8 {
        var program = std.ArrayList(u8).init(self.allocator);
        defer program.deinit();

        // 1. Jump table length (encoded integer)
        try codec.writeInteger(jump_table.len, program.writer());

        // 2. Jump table item length (single byte)
        // Calculate minimum bytes needed to store largest jump target
        var max_jump_target: u32 = 0;
        for (jump_table) |target| {
            max_jump_target = @max(max_jump_target, target);
        }
        const item_length: u8 = switch (max_jump_target) {
            0...0xFF => 1,
            0x100...0xFFFF => 2,
            0x10000...0xFFFFFF => 3,
            else => 4,
        };
        try program.append(item_length);

        // 3. Code length (encoded integer)
        try codec.writeInteger(code.len, program.writer());

        // 4. Jump table bytes
        // Write each jump target using the calculated item_length
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

test "ProgramGenerator - generates valid format" {
    const allocator = std.testing.allocator;
    var seed_gen = SeedGenerator.init(42);
    var generator = ProgramGenerator.init(allocator, &seed_gen);
    defer generator.deinit();

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var program = try generator.generate(3);
        defer program.deinit(allocator);

        // Verify we can decode the generated program
        var decoded = try @import("../../pvm/program.zig").Program.decode(allocator, program.raw_bytes);
        defer decoded.deinit(allocator);

        // Basic sanity checks
        try std.testing.expect(decoded.code.len > 0);
        try std.testing.expect(decoded.mask.len > 0);
        try std.testing.expect(decoded.jump_table.indices.len > 0);
    }
}
