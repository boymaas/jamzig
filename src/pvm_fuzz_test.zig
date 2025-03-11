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

    // Create custom config
    const config = FuzzerConfig{
        .seed = 42,
        .num_cases = 1_000_000_000_000,
        .verbose = true,
    };

    var fzzr = InstructionFuzzer.initWithConfig(allocator, config);

    var iter = fzzr.iterator(config.num_cases);
    var counter: usize = 0;
    while (iter.next()) |instruction| {
        if (counter % 10_000 == 0) {
            std.debug.print("\nCase: {d}", .{counter});
        }
        counter += 1;
        // std.debug.print("Instruction: {}\r", .{instruction});

        // Not yet implemented
        if (instruction.instruction == .sbrk) {
            continue;
        }

        // Ignore for now
        if (instruction.isTerminationInstruction()) {
            continue;
        }

        // Ignore for now
        if (instruction.getMemoryAccess()) |access| {
            _ = access;
            continue;
        }

        var ccheck = try crosscheck.CrossCheck.init(allocator);
        defer ccheck.deinit();

        // Load up with large register values so
        // we will wrap around
        for (&ccheck.initial_registers) |*reg_value| {
            reg_value.* = fzzr.seed_gen.randomRegisterValue();
        }

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
