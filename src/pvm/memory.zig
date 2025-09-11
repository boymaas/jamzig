// Main memory export file - provides unified interface to all memory implementations

pub const shared = @import("memory/shared.zig");
pub const types = @import("memory/types.zig");

// Memory implementations
pub const PageTableMemory = @import("memory/paged.zig").Memory;
pub const FlatMemory = @import("memory/flat.zig").FlatMemory;

// Re-export commonly used types and constants for convenience
pub const MemorySlice = types.MemorySlice;

// Default Memory type for backward compatibility
pub const Memory = FlatMemory;
