// Shared memory types for all PVM memory implementations

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Memory slice with optional ownership management
pub const MemorySlice = struct {
    buffer: []const u8,
    allocator: ?Allocator = null,

    // If buffer points to internal memory, dupe it for caller safety.
    // Otherwise transfer ownership by clearing allocator reference.
    pub fn takeBufferOwnership(self: *MemorySlice, allocator: Allocator) ![]const u8 {
        if (self.allocator) |_| {
            self.allocator = null;
            return self.buffer;
        } else {
            const owned_copy = try allocator.dupe(u8, self.buffer);
            return owned_copy;
        }
    }

    pub fn deinit(self: *MemorySlice) void {
        if (self.allocator) |alloc| {
            alloc.free(self.buffer);
            self.allocator = null;
        }
        self.* = undefined;
    }
};

/// Memory access violation information
pub const ViolationInfo = struct {
    violation_type: ViolationType,
    address: u32, // aligned to page
    attempted_size: usize,
};

/// Types of memory access violations
pub const ViolationType = enum {
    WriteProtection,
    AccessViolation,
    NonAllocated,
};

/// Page access flags
pub const PageFlags = enum {
    ReadOnly,
    ReadWrite,
};

/// Result of memory access pointer lookup
pub const MemoryAccessResult = union(enum) {
    success: [*]u8,
    violation: ViolationInfo,
};

pub const MemorySnapShot = struct {
    regions: []MemoryRegion,

    pub fn deinit(self: *MemorySnapShot, allocator: Allocator) void {
        for (self.regions) |*region| {
            region.deinit(allocator);
        }
        allocator.free(self.regions);
        self.* = undefined;
    }
};

/// Represents a region of memory with address, data, and writability
pub const MemoryRegion = struct {
    address: u32,
    data: []const u8,
    writable: bool,

    pub fn deinit(self: *MemoryRegion, allocator: Allocator) void {
        allocator.free(self.data);
        self.* = undefined;
    }
};
