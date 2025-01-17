const std = @import("std");
const Allocator = std.mem.Allocator;

const codec = @import("../../codec.zig");
const InstructionWithArgs = @import("../../pvm/instruction.zig").InstructionWithArgs;
const InstructionType = @import("../../pvm/instruction.zig").InstructionType;
const MaxInstructionSizeInBytes = @import("../../pvm/instruction.zig").MaxInstructionSizeInBytes;

const SeedGenerator = @import("seed.zig").SeedGenerator;
const code_gen = @import("program_generator/code_generator.zig");

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
        // Generate a random program
        const instructions = try code_gen.generate(self.allocator, self.seed_gen, instruction_count);
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
        for (instructions) |inst| {
            pc += try inst.encode(code_writer);
            if (inst.isTerminationInstruction()) {
                try basic_blocks.append(pc);
                try jump_table.append(pc);
            }
            mask_bitset.set(pc);
        }

        // generate the mask, we allocate ceil + 1 as the mask could possible end
        const mask = try self.allocator.alloc(u8, try std.math.divCeil(usize, pc, 8) + 1);
        @memset(mask, 0);
        var mask_iter = mask_bitset.iterator(.{});
        while (mask_iter.next()) |bidx| {
            mask[bidx / 8] |= @as(u8, 1) << @intCast(bidx % 8);
        }

        // On the second pass of our program we need to find the dynamic jumps
        // and let them jump to any of the elements in our jump table to make
        // these jumps valid

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
