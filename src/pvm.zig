const std = @import("std");
const Allocator = std.mem.Allocator;
const Instruction = @import("./pvm/instruction.zig").Instruction;
const Program = @import("./pvm/program.zig").Program;
const Decoder = @import("./pvm/decoder.zig").Decoder;
const InstructionWithArgs = @import("./pvm/decoder.zig").InstructionWithArgs;

const updatePc = @import("./pvm/utils.zig").updatePc;

pub const PVM = struct {
    allocator: Allocator,
    program: Program,
    registers: [13]u32,
    pc: u32,
    memory: []MemoryChunk,
    page_map: []PageMap,
    gas: i64,

    pub const PageMap = struct {
        address: u32,
        length: u32,
        is_writable: bool,
    };

    pub const MemoryChunk = struct {
        address: u32,
        contents: []u8,
    };

    pub const Status = enum {
        trap,
        halt,
    };

    pub fn init(allocator: Allocator, raw_program: []const u8, initial_gas: i64) !PVM {
        const program = try Program.decode(allocator, raw_program);

        return PVM{
            .allocator = allocator,
            .program = program,
            .registers = [_]u32{0} ** 13,
            .pc = 0,
            .page_map = &[_]PageMap{},
            .memory = &[_]MemoryChunk{},
            .gas = initial_gas,
        };
    }

    pub fn deinit(self: *PVM) void {
        self.program.deinit(self.allocator);
        self.allocator.free(self.page_map);
        for (self.memory) |chunk| {
            self.allocator.free(chunk.contents);
        }
        self.allocator.free(self.memory);
    }

    pub fn pushMemory(self: *PVM, address: u32, contents: []const u8) !void {
        const new_chunk = MemoryChunk{
            .address = address,
            .contents = try self.allocator.dupe(u8, contents),
        };
        const new_memory = try self.allocator.realloc(self.memory, self.memory.len + 1);
        new_memory[self.memory.len] = new_chunk;
        self.memory = new_memory;
    }

    pub fn setPageMap(self: *PVM, new_page_map: []const PageMap) !void {
        self.allocator.free(self.page_map);
        self.page_map = try self.allocator.dupe(PageMap, new_page_map);
    }

    const MAX_ITERATIONS = 1024;
    pub fn run(self: *PVM) !void {
        const decoder = Decoder.init(self.program.code, self.program.mask);
        var n: usize = 0;
        while (self.pc < self.program.code.len and n < MAX_ITERATIONS) : (n += 1) {
            const i = try decoder.decodeInstruction(self.pc);

            std.debug.print("{d:0>4}: {any}\n", .{ self.pc, i });
            self.pc = try updatePc(self.pc, try self.executeInstruction(i));

            if (self.gas <= 0) {
                return error.OUT_OF_GAS;
            }
        }

        if (n == MAX_ITERATIONS) {
            return error.MAX_ITERATIONS_REACHED;
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
            .move_reg => {
                const args = i.args.two_registers;
                self.registers[args.first_register_index] = self.registers[args.second_register_index];
            },
            .fallthrough => {
                // Do nothing, just move to the next instruction
            },
            .add => {
                const args = i.args.three_registers;
                self.registers[args.third_register_index] = @addWithOverflow(
                    self.registers[args.first_register_index],
                    self.registers[args.second_register_index],
                )[0];
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
