const std = @import("std");

pub const SeedGenerator = struct {
    random: std.Random.DefaultPrng,
    seed: u64,

    /// Initialize with a specific seed value
    pub fn init(seed: u64) SeedGenerator {
        return .{
            .seed = seed,
            .random = std.Random.DefaultPrng.init(seed),
        };
    }

    /// Generate a random seed using system entropy
    pub fn randomSeed(self: *SeedGenerator) u64 {
        return self.random.random().int(u64);
    }

    /// Generate a random integer within a range [min, max]
    pub fn randomIntRange(self: *SeedGenerator, comptime T: type, min: T, max: T) T {
        return self.random.random().intRangeAtMost(T, min, max);
    }

    /// Generate a random boolean
    pub fn randomBool(self: *SeedGenerator) bool {
        return self.random.random().boolean();
    }

    /// Generate a random u8
    pub fn randomByte(self: *SeedGenerator) u8 {
        return self.randomIntRange(u8, 0, 255);
    }

    /// Generate a slice of random bytes
    pub fn randomBytes(self: *SeedGenerator, buffer: []u8) void {
        self.random.random().bytes(buffer);
    }

    /// Generate a random register index (0-12)
    pub fn randomRegisterIndex(self: *SeedGenerator) u8 {
        return self.randomIntRange(u8, 0, 12);
    }

    /// Generate a random u64 immediate value
    /// Uses a weighted distribution to favor smaller values
    pub fn randomImmediate(self: *SeedGenerator) u32 {
        // 70% chance of small value (0-255)
        // 20% chance of medium value (256-65535)
        // 10% chance of large value (65536-u32.max)
        const roll = self.randomIntRange(u8, 0, 99);
        return switch (roll) {
            0...69 => self.randomIntRange(u32, 0, 255),
            70...89 => self.randomIntRange(u32, 256, 65535),
            else => self.randomIntRange(u32, 65536, std.math.maxInt(u32)),
        };
    }

    /// Generate a random memory size
    /// Returns sizes that are reasonable for test programs
    pub fn randomMemorySize(self: *SeedGenerator) u32 {
        return self.randomIntRange(u32, 32, 4096);
    }

    /// Generate a random memory address
    /// Returns addresses aligned to 8 bytes
    pub fn randomMemoryAddress(self: *SeedGenerator) u32 {
        const addr = self.randomIntRange(u32, 0, 0xFFFFFFFF);
        return addr & ~@as(u32, 7); // Align to 8 bytes
    }

    /// Generate a random program size
    /// Returns sizes appropriate for test programs
    pub fn randomProgramSize(self: *SeedGenerator) u32 {
        // 70% chance of small program (16-256 bytes)
        // 20% chance of medium program (257-1024 bytes)
        // 10% chance of large program (1025-4096 bytes)
        const roll = self.randomIntRange(u8, 0, 99);
        return switch (roll) {
            0...69 => self.randomIntRange(u32, 16, 256),
            70...89 => self.randomIntRange(u32, 257, 1024),
            else => self.randomIntRange(u32, 1025, 4096),
        };
    }
};
