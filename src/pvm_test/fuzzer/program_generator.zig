const std = @import("std");
const Allocator = std.mem.Allocator;

const SeedGenerator = @import("seed.zig").SeedGenerator;
const BasicBlock = @import("program_generator/basic_block.zig").BasicBlock;

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
    basic_blocks: std.ArrayListUnmanaged(BasicBlock),

    const Self = @This();
    const MaxBlockSize = 32; // Maximum instructions in a block
    const MinBlockSize = 4; // Minimum instructions in a block
    const MaxRegisterIndex = 12; // Maximum valid register index

    pub fn init(allocator: Allocator, seed_gen: *SeedGenerator) !Self {
        return .{
            .allocator = allocator,
            .basic_blocks = try std.ArrayListUnmanaged(BasicBlock).initCapacity(allocator, 64),
            .seed_gen = seed_gen,
        };
    }

    pub fn deinit_basic_blocks(self: *Self) void {
        for (self.basic_blocks.items) |*block| {
            block.deinit();
        }
        self.basic_blocks.deinit(self.allocator);
    }

    pub fn deinit(self: *Self) void {
        self.deinit_basic_blocks();
        self.* = undefined;
    }

    /// Generate a valid PVM program with the specified number of basic blocks
    pub fn generate(self: *Self, num_blocks: u32) !GeneratedProgram {
        // Generate basic blocks
        errdefer self.deinit_basic_blocks();
        var i: u32 = 0;
        while (i < num_blocks) : (i += 1) {
            const block = try self.generateBasicBlock();
            try self.basic_blocks.append(self.allocator, block);
        }

        // Build the component parts
        const code = try self.buildCode();
        errdefer self.allocator.free(code);

        const mask = try self.buildMask(code.len);
        errdefer self.allocator.free(mask);

        const jump_table = try self.buildJumpTable();
        errdefer self.allocator.free(jump_table);

        // Build the complete raw program
        // const program = try self.buildRawProgram(code, mask, jump_table);

        return GeneratedProgram{
            .raw_bytes = &[_]u8{},
            .code = code,
            .mask = mask,
            .jump_table = jump_table,
        };
    }

    /// Generate a single valid basic block
    fn generateBasicBlock(self: *Self) !BasicBlock {
        var block = try BasicBlock.init(self.allocator, self.seed_gen.randomIntRange(usize, 8, 64));
        try block.generate(self.seed_gen);

        return block;
    }

    fn buildCode(self: *Self) ![]u8 {
        // FIXME: initCapacity
        var code = std.ArrayList(u8).init(self.allocator);
        defer code.deinit();

        for (self.basic_blocks.items) |block| {
            try code.appendSlice(block.instructions.items);
        }

        return code.toOwnedSlice();
    }

    /// Build final mask from block mask bits
    fn buildMask(self: *Self, code_length: usize) ![]u8 {
        const mask = try self.allocator.alloc(u8, code_length);
        @memset(mask, 0);

        var block_mask = mask[0..];
        var total_offset: usize = 0;
        for (self.basic_blocks.items, 0..) |block, block_idx| {
            std.debug.print("\nProcessing Block {d} at offset {d}\n", .{ block_idx, total_offset });
            var set_bits = block.mask_bits.iterator(.{});
            while (set_bits.next()) |set_bit_idx| {
                std.debug.print("  Setting mask bit {d} (byte: {d}, bit: {d})\n", .{ set_bit_idx + total_offset, set_bit_idx / 8, set_bit_idx % 8 });
                const mask_idx = set_bit_idx / 8;
                const mask_byte_bit_idx: u3 = @truncate(set_bit_idx % 8);
                const mask_byte_mask = @as(u8, 0x01) << mask_byte_bit_idx;
                block_mask[mask_idx] |= mask_byte_mask;
            }
            total_offset += block.instructions.items.len;
            block_mask = block_mask[block.instructions.items.len..];
        }

        return mask;
    }

    const JumpAlignmentFactor = 2;

    fn buildJumpTable(self: *Self) ![]u32 {
        _ = self;
        return &[_]u32{};
    }
};

test "simple" {
    const allocator = std.testing.allocator;
    var seed_gen = SeedGenerator.init(42);
    var generator = try ProgramGenerator.init(allocator, &seed_gen);
    defer generator.deinit();

    // Generate multiple programs of varying sizes
    var program = try generator.generate(2);
    defer program.deinit(allocator);

    const Decoder = @import("../../pvm/decoder.zig").Decoder;
    const decoder = Decoder.init(program.code, program.mask);

    std.debug.print("\n\nCode.len: {d}\n", .{program.code.len});
    std.debug.print("Mask.len: {d}\n\n\n", .{program.mask.len});

    var pc: u32 = 0;
    while (pc < program.code.len) {
        const i = try decoder.decodeInstruction(pc);
        std.debug.print("{d:0>4}: {any} len: {d}\n", .{ pc, i, i.skip_l() });
        pc += i.skip_l() + 1;
    }
}
