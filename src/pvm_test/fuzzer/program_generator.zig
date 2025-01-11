const std = @import("std");
const Allocator = std.mem.Allocator;

const codec = @import("../../codec.zig");

const SeedGenerator = @import("seed.zig").SeedGenerator;
const BasicBlock = @import("program_generator/basic_block.zig").BasicBlock;

/// Represents the complete encoded PVM program
pub const GeneratedProgram = struct {
    /// Complete raw encoded program bytes
    raw_bytes: ?[]u8 = null,
    /// Component parts for verification/testing
    code: []u8,
    mask: []u8,
    jump_table: []u32,

    pub fn getRawBytes(self: *@This(), allocator: std.mem.Allocator) ![]u8 {
        // If we already have the raw bytes computed, return them
        if (self.raw_bytes) |bytes| {
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
    const MaxBlockSize = 32; // Maximum instructions in a block
    const MinBlockSize = 4; // Minimum instructions in a block
    const MaxRegisterIndex = 12; // Maximum valid register index

    const BasicBlocks = std.ArrayList(BasicBlock);

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
    pub fn generate(self: *Self, num_blocks: u32) !GeneratedProgram {
        // Generate basic blocks
        var basic_blocks = try BasicBlocks.initCapacity(self.allocator, num_blocks);
        defer {
            for (basic_blocks.items) |*block| {
                block.deinit();
            }
            basic_blocks.deinit();
        }

        var i: u32 = 0;
        while (i < num_blocks) : (i += 1) {
            const block = try self.generateBasicBlock();
            try basic_blocks.append(block);
        }

        // Build the component parts
        const code = try self.buildCode(basic_blocks);
        errdefer self.allocator.free(code);

        const mask = try self.buildMask(basic_blocks, code.len);
        errdefer self.allocator.free(mask);

        const jump_table = try self.buildJumpTable(basic_blocks);
        errdefer self.allocator.free(jump_table);

        // Build the complete raw program
        // const program = try self.buildRawProgram(code, mask, jump_table);

        return GeneratedProgram{
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

    fn buildCode(self: *Self, basic_blocks: BasicBlocks) ![]u8 {
        // FIXME: initCapacity
        var code = std.ArrayList(u8).init(self.allocator);
        defer code.deinit();

        for (basic_blocks.items) |block| {
            try code.appendSlice(block.instructions.items);
        }

        return code.toOwnedSlice();
    }

    /// Build final mask from block mask bits
    fn buildMask(self: *Self, basic_blocks: BasicBlocks, code_length: usize) ![]u8 {
        const mask = try self.allocator.alloc(u8, try std.math.divCeil(usize, code_length, 8) + 1);
        @memset(mask, 0);

        var block_mask = mask[0..];
        for (basic_blocks.items) |block| {
            var set_bits = block.mask_bits.iterator(.{});
            while (set_bits.next()) |set_bit_idx| {
                const mask_idx = set_bit_idx / 8;
                const mask_byte_bit_idx: u3 = @truncate(set_bit_idx % 8);
                const mask_byte_mask = @as(u8, 0x01) << mask_byte_bit_idx;
                block_mask[mask_idx] |= mask_byte_mask;
            }
            block_mask = block_mask[block.instructions.items.len / 8 ..];
        }

        return mask;
    }

    const JumpAlignmentFactor = 2;

    fn buildJumpTable(self: *Self, basic_blocks: BasicBlocks) ![]u32 {
        // calculate the starting addressses by taking all the starts of the basic blocks
        // determine the length of the jump table
        // and determine the size of the entries of the jump table

        // 1. codec.encodeInteger the length of the jump table
        // 2. byte encode the size of the items
        // 3. encode the items with that size.
        const block_addrs = try self.allocator.alloc(u32, basic_blocks.items.len);
        var offset: u32 = 0;
        for (basic_blocks.items, 0..) |basic_block, i| {
            block_addrs[i] = offset + @as(u32, @intCast(basic_block.instructions.items.len));
            offset = block_addrs[i];
        }

        return block_addrs;
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

test "getRawBytes" {
    // Create test data
    const allocator = std.testing.allocator;

    var program = GeneratedProgram{
        .code = try allocator.dupe(u8, &[_]u8{ 0x01, 0x02, 0x03 }),
        .mask = try allocator.dupe(u8, &[_]u8{ 0xFF, 0x0F }),
        .jump_table = try allocator.dupe(u32, &[_]u32{ 10, 20, 30 }),
        .raw_bytes = null,
    };
    defer program.deinit(allocator);

    // Get raw bytes
    const raw = try program.getRawBytes(allocator);

    // Verify the encoded data can be decoded back
    var decoded = try @import("../../pvm/program.zig").Program.decode(allocator, raw);
    defer decoded.deinit(allocator);

    // Verify contents match
    try std.testing.expectEqualSlices(u8, program.code, decoded.code);
    try std.testing.expectEqualSlices(u8, program.mask, decoded.mask);
    for (program.jump_table, 0..) |target, i| {
        try std.testing.expectEqual(target, decoded.jump_table.getDestination(i));
    }
}
