const std = @import("std");
const pvmlib = @import("pvm.zig");

const polkavm_env = @import("pvm_fuzz_test/polkavm.zig");
const pvm_env = @import("pvm_fuzz_test/pvm.zig");
const crosscheck = @import("pvm_fuzz_test/crosscheck.zig");

const fuzzer = @import("pvm_test/fuzzer/fuzzer.zig");

const instruction_generator = @import("pvm_test/fuzzer/program_generator/instruction_generator.zig");

const PVM = @import("pvm.zig").PVM;
const SeedGenerator = @import("pvm_test/fuzzer/seed.zig").SeedGenerator;
const InstructionWithArgs = PVM.InstructionWithArgs;
const Instruction = PVM.Instruction;

/// Configuration for the fuzzer
pub const FuzzerConfig = struct {
    seed: u64 = 42,
    num_cases: usize = 100,
    verbose: bool = false,

    const Self = @This();

    pub fn default() Self {
        return .{};
    }

    /// Create configuration with specified seed
    pub fn withSeed(seed: u64) Self {
        var config = Self.default();
        config.seed = seed;
        return config;
    }

    /// Create configuration with specified number of test cases
    pub fn withCases(num_cases: usize) Self {
        var config = Self.default();
        config.num_cases = num_cases;
        return config;
    }
};

pub const InstructionFuzzer = struct {
    allocator: std.mem.Allocator,
    seed_gen: SeedGenerator,
    config: FuzzerConfig,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, seed_gen: SeedGenerator) Self {
        return .{
            .allocator = allocator,
            .seed_gen = seed_gen,
            .config = FuzzerConfig.default(),
        };
    }

    pub fn initWithConfig(allocator: std.mem.Allocator, config: FuzzerConfig) Self {
        const seed_gen = SeedGenerator.init(config.seed);
        return .{
            .allocator = allocator,
            .seed_gen = seed_gen,
            .config = config,
        };
    }

    pub const InstructionIterator = struct {
        seed_gen: *SeedGenerator,
        count: usize,

        /// Initialize a new instruction iterator with the given seed generator
        pub fn init(seed_gen: *SeedGenerator, count: usize) InstructionIterator {
            return .{ .seed_gen = seed_gen, .count = count };
        }

        /// Generate the next random instruction
        pub fn next(self: *InstructionIterator) ?InstructionWithArgs {
            if (self.count == 0) {
                return null;
            }
            self.count -= 1;
            return instruction_generator.randomInstruction(self.seed_gen);
        }
    };

    pub fn iterator(self: *Self, count: usize) InstructionIterator {
        return InstructionIterator.init(&self.seed_gen, count);
    }
};

test "instruction_fuzzer_with_config" {
    const allocator = std.testing.allocator;

    var rand = std.Random.DefaultPrng.init(42);
    var rng = rand.random();

    // Create custom config
    const config = FuzzerConfig{
        .seed = rng.int(u64),
        .num_cases = 50_000,
        .verbose = true,
    };

    var fzzr = InstructionFuzzer.initWithConfig(allocator, config);

    var iter = fzzr.iterator(config.num_cases);
    var counter: usize = 0;
    while (iter.next()) |inst| {
        var instruction = inst;

        if (counter % 10_000 == 0) {
            std.debug.print("\nCase: {d}", .{counter});
        }
        counter += 1;

        var ccheck = try crosscheck.CrossCheck.init(allocator);
        defer ccheck.deinit();

        // Load up with large register values so
        // we will wrap around
        for (&ccheck.initial_registers) |*reg_value| {
            reg_value.* = fzzr.seed_gen.randomRegisterValue();
        }

        // Load the initial memory with random values
        fzzr.seed_gen.randomBytes(ccheck.initial_memory);

        // Not yet implemented
        if (instruction.instruction == .sbrk) {
            continue;
        }

        // Ignore for now
        if (instruction.isTerminationInstruction()) {
            continue;
        }

        // Handle memory access instructions
        if (instruction.getMemoryAccess()) |access| {
            // easy solution is to set all registers to a low value
            if (access.isIndirect) {
                const ind_access = try instruction.getMemoryAccessInd(&ccheck.initial_registers);
                if (ind_access.address > ccheck.memory_base_address and
                    ind_access.address < ccheck.memory_base_address + ccheck.memory_size)
                {
                    // all good nothing to do

                } else {
                    // choose a target address
                    const target = ccheck.memory_base_address;
                    const register_part = ccheck.memory_base_address / 2;
                    const immediate_part = target - register_part;

                    switch (instruction.instruction) {

                        // Indirect load operations
                        .load_ind_u8,
                        .load_ind_i8,
                        .load_ind_u16,
                        .load_ind_i16,
                        .load_ind_u32,
                        .load_ind_i32,
                        .load_ind_u64,
                        => {
                            instruction.args.TwoRegOneImm.immediate = immediate_part;
                            ccheck.initial_registers[instruction.args.TwoRegOneImm.second_register_index] = register_part;
                        },

                        // Indirect store operations
                        .store_ind_u8,
                        .store_ind_u16,
                        .store_ind_u32,
                        .store_ind_u64,
                        => {
                            instruction.args.TwoRegOneImm.immediate = immediate_part;
                            ccheck.initial_registers[instruction.args.TwoRegOneImm.second_register_index] = register_part;
                        },

                        // Indirect immediate store operations
                        .store_imm_ind_u8,
                        .store_imm_ind_u16,
                        .store_imm_ind_u32,
                        .store_imm_ind_u64,
                        => {
                            instruction.args.OneRegTwoImm.first_immediate = immediate_part;
                            ccheck.initial_registers[instruction.args.OneRegTwoImm.register_index] = register_part;
                        },

                        else => return error.NotInMemoryAccess,
                    }
                }
            } else {
                // Just set te immediate part
                try instruction.setMemoryAddress(ccheck.memory_base_address);
            }
        }

        // std.debug.print("\nInstruction: {}\n", .{instruction});

        var result = try ccheck.compareInstruction(instruction);
        defer result.deinit(allocator);
        if (!result.matchesExactly()) {
            std.debug.print("\n\n", .{});
            try result.getDifferenceReport(std.io.getStdErr().writer());
            break;
        }
    }
}

// Reference tests
comptime {
    _ = @import("pvm_fuzz_test/polkavm.zig");
    _ = @import("pvm_fuzz_test/pvm.zig");
    _ = @import("pvm_fuzz_test/crosscheck.zig");
}
