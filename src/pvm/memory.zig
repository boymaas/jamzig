pub const shared = @import("memory/shared.zig");
pub const types = @import("memory/types.zig");

pub const PageTableMemory = @import("memory/paged.zig").Memory;
pub const FlatMemory = @import("memory/flat.zig").FlatMemory;

pub const MemorySlice = types.MemorySlice;

pub const Memory = FlatMemory;
