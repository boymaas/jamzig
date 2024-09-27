const std = @import("std");
const Allocator = std.mem.Allocator;
const Instruction = @import("./pvm/instruction.zig").Instruction;
const Program = @import("./pvm/program.zig").Program;
const Decoder = @import("./pvm/decoder.zig").Decoder;
const InstructionWithArgs = @import("./pvm/decoder.zig").InstructionWithArgs;

const updatePc = @import("./pvm/utils.zig").updatePc;

pub const PVM = struct {
    allocator: *Allocator,
    program: Program,
    registers: [13]u32,
    pc: u32,
    memory: []u8,

    pub fn init(allocator: *Allocator, raw_program: []const u8) !PVM {
        const program = try Program.decode(allocator, raw_program);

        return PVM{
            .allocator = allocator,
            .program = program,
            .registers = [_]u32{0} ** 13,
            .pc = 0,
            .memory = try allocator.alloc(u8, 1024 * 1024), // Allocate 1MB of memory
        };
    }

    pub fn deinit(self: *PVM) void {
        self.program.deinit(self.allocator);
        self.allocator.free(self.memory);
    }

    pub fn run(self: *PVM) !void {
        const decoder = Decoder.init(self.program.code, self.program.mask);
        var n: usize = 0;
        while (self.pc < self.program.code.len and n < 32) : (n += 1) {
            const i = try decoder.decodeInstruction(self.pc);

            std.debug.print("{d:0>4}: {any}\n", .{ self.pc, i });
            self.pc = try updatePc(self.pc, try self.executeInstruction(i));
        }
    }

    /// Offset to add to the program counter
    const PcOffset = i32;
    /// executes the instruction and returns the offset to add to the program counter
    fn executeInstruction(self: *PVM, i: InstructionWithArgs) !PcOffset {
        switch (i.instruction) {
            .trap => {
                // Halt the program
                return error.PANIC;
            },
            .load_imm => {
                // Load immediate value into register
                const args = i.args.one_register_one_immediate;
                self.registers[args.register_index] = @bitCast(args.immediate);
            },
            .jump => {
                // Jump to offset
                const args = i.args.one_offset;
                return args.offset;
            },
            .add_imm => {
                // Add immediate value to register
                const args = i.args.two_registers_one_immediate;
                self.registers[args.first_register_index] = @addWithOverflow(
                    self.registers[args.second_register_index],
                    @as(u32, @bitCast(args.immediate)),
                )[0];
            },
            .branch_eq_imm => {
                const args = i.args.one_register_one_immediate_one_offset;
                if (self.registers[args.register_index] == @as(u32, @bitCast(args.immediate))) {
                    return args.offset;
                }
            },
            .fallthrough => {
                // Do nothing, just move to the next instruction
            },
            else => {
                // For now, we'll just print a message for unimplemented instructions
                std.debug.print("Instruction not implemented: {any}\n", .{i});
                unreachable;
            },
        }

        // default offset
        return @intCast(i.skip_l() + 1);
    }
};
