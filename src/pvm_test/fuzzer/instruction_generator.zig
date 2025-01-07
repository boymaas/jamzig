const std = @import("std");
const Instruction = @import("../../pvm/instruction.zig").Instruction;
const ArgumentType = @import("../../pvm/decoder/types.zig").ArgumentType;
const SeedGenerator = @import("seed.zig").SeedGenerator;

pub const InstructionGenerator = struct {
    seed_gen: *SeedGenerator,

    const Self = @This();

    pub fn init(seed_gen: *SeedGenerator) Self {
        return .{
            .seed_gen = seed_gen,
        };
    }

    /// Generate a random valid instruction sequence
    pub fn generateInstruction(self: *Self) []const u8 {
        // Pick a random instruction type
        const instruction = self.randomInstruction();
        const args_type = ArgumentType.lookup(instruction);

        return switch (args_type) {
            .no_arguments => self.generateNoArgs(instruction),
            .one_immediate => self.generateOneImmediate(instruction),
            .one_offset => self.generateOneOffset(instruction),
            .one_register_one_immediate => self.generateOneRegOneImm(instruction),
            .one_register_one_immediate_one_offset => self.generateOneRegOneImmOneOffset(instruction),
            .one_register_one_extended_immediate => self.generateOneRegOneExtImm(instruction),
            .one_register_two_immediates => self.generateOneRegTwoImm(instruction),
            .three_registers => self.generateThreeReg(instruction),
            .two_immediates => self.generateTwoImm(instruction),
            .two_registers => self.generateTwoReg(instruction),
            .two_registers_one_immediate => self.generateTwoRegOneImm(instruction),
            .two_registers_one_offset => self.generateTwoRegOneOffset(instruction),
            .two_registers_two_immediates => self.generateTwoRegTwoImm(instruction),
        };
    }

    /// Pick a random instruction from the instruction set
    fn randomInstruction(self: *Self) Instruction {
        const tag_type = @typeInfo(Instruction).Enum;
        const random_value = self.seed_gen.randomIntRange(u8, 0, tag_type.fields.len - 1);
        return @enumFromInt(random_value);
    }

    fn generateNoArgs(self: *Self, instruction: Instruction) []const u8 {
        _ = self;
        return &[_]u8{@intFromEnum(instruction)};
    }

    fn generateOneImmediate(self: *Self, instruction: Instruction) []const u8 {
        var result: [5]u8 = undefined;
        result[0] = @intFromEnum(instruction);

        // Generate immediate length (1-4 bytes)
        const imm_len = self.seed_gen.randomIntRange(u8, 1, 4);
        result[1] = imm_len;

        // Generate immediate value
        var i: u8 = 0;
        while (i < imm_len) : (i += 1) {
            result[2 + i] = self.seed_gen.randomByte();
        }

        return result[0 .. 2 + imm_len];
    }

    fn generateOneRegOneImm(self: *Self, instruction: Instruction) []const u8 {
        var result: [6]u8 = undefined;
        result[0] = @intFromEnum(instruction);

        // Register in low nibble, length in high nibble
        const reg = self.seed_gen.randomRegisterIndex();
        const len = self.seed_gen.randomIntRange(u8, 1, 4);
        result[1] = (len << 4) | reg;

        // Generate immediate value
        var i: u8 = 0;
        while (i < len) : (i += 1) {
            result[2 + i] = self.seed_gen.randomByte();
        }

        return result[0 .. 2 + len];
    }

    // Add more specific instruction generation methods...
    fn generateOneOffset(self: *Self, instruction: Instruction) []const u8 {
        var result: [5]u8 = undefined;
        result[0] = @intFromEnum(instruction);

        // Generate offset length (1-4 bytes)
        const offset_len = self.seed_gen.randomIntRange(u8, 1, 4);
        result[1] = offset_len;

        // Generate offset value
        var i: u8 = 0;
        while (i < offset_len) : (i += 1) {
            result[2 + i] = self.seed_gen.randomByte();
        }

        return result[0 .. 2 + offset_len];
    }

    fn generateOneRegOneExtImm(self: *Self, instruction: Instruction) []const u8 {
        var result: [10]u8 = undefined;
        result[0] = @intFromEnum(instruction);

        // Register in low nibble
        const reg = self.seed_gen.randomRegisterIndex();
        result[1] = reg;

        // Generate 8-byte immediate value
        var i: u8 = 0;
        while (i < 8) : (i += 1) {
            result[2 + i] = self.seed_gen.randomByte();
        }

        return &result;
    }

    fn generateThreeReg(self: *Self, instruction: Instruction) []const u8 {
        var result: [3]u8 = undefined;
        result[0] = @intFromEnum(instruction);

        // First two registers packed in one byte
        const reg1 = self.seed_gen.randomRegisterIndex();
        const reg2 = self.seed_gen.randomRegisterIndex();
        result[1] = (reg2 << 4) | reg1;

        // Third register in its own byte
        result[2] = self.seed_gen.randomRegisterIndex();

        return &result;
    }

    // Common helper functions
    fn packRegisters(self: *Self) u8 {
        const reg1 = self.seed_gen.randomRegisterIndex();
        const reg2 = self.seed_gen.randomRegisterIndex();
        return (reg2 << 4) | reg1;
    }

    fn generateImmediate(self: *Self, len: u8) []u8 {
        var result = self.allocator.alloc(u8, len) catch unreachable;
        var i: u8 = 0;
        while (i < len) : (i += 1) {
            result[i] = self.seed_gen.randomByte();
        }
        return result;
    }
};
