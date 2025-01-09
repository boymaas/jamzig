const std = @import("std");
const igen = @import("instruction.zig");

const SeedGenerator = @import("../seed.zig").SeedGenerator;

/// Definition of a basic block for improved tracking
pub const BasicBlock = struct {
    /// Instructions in the block
    instructions: std.ArrayListUnmanaged(u8),
    /// Configured instructions count
    instruction_count: usize,
    /// Mask bits for the block's instructions
    mask_bits: std.DynamicBitSetUnmanaged,
    /// Reference to allocator
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, instruction_count: usize) !@This() {
        const max_code_size = instruction_count * igen.MaxInstructionSize;
        return .{
            .instructions = try std.ArrayListUnmanaged(u8).initCapacity(allocator, max_code_size),
            .instruction_count = instruction_count,
            .mask_bits = try std.DynamicBitSetUnmanaged.initEmpty(allocator, max_code_size),
            .allocator = allocator,
        };
    }

    /// Generate the block's contents with a sequence of instructions
    pub fn generate(self: *Self, seed_gen: *SeedGenerator) !void {
        // Generate a sequence of valid instructions
        var i: u32 = 0;
        var pc: u32 = 0;

        while (i < self.instruction_count - 1) : (i += 1) {
            const inst = try igen.generateRegularInstruction(seed_gen);
            try self.instructions.appendSlice(self.allocator, inst.toSlice());
            self.mask_bits.set(pc + inst.len);
            pc += @intCast(inst.len);
        }

        // End with a valid terminator
        const inst = try igen.generateTerminator(seed_gen);
        try self.instructions.appendSlice(self.allocator, inst.toSlice());
        self.mask_bits.set(pc + inst.len);
    }

    pub fn deinit(self: *Self) void {
        self.instructions.deinit(self.allocator);
        self.mask_bits.deinit(self.allocator);
    }
};
