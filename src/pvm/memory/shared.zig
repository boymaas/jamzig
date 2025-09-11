// Shared memory constants for all PVM memory implementations

/// Page size in bytes (4KB)
pub const Z_P: u32 = 0x1000; // 2^12 = 4,096

/// Major zone size in bytes (64KB)
pub const Z_Z: u32 = 0x10000; // 2^16 = 65,536

/// Standard input data size in bytes (16MB)
pub const Z_I: u32 = 0x1000000; // 2^24

// Fixed section base addresses
pub const READ_ONLY_BASE_ADDRESS: u32 = Z_Z;
pub const INPUT_ADDRESS: u32 = 0xFFFFFFFF - Z_Z - Z_I + 1;
pub const STACK_BASE_ADDRESS: u32 = 0xFFFFFFFF - (2 * Z_Z) - Z_I + 1;

/// Calculate heap base address based on read-only section size
pub fn HEAP_BASE_ADDRESS(read_only_size_in_bytes: usize) !u32 {
    return 2 * Z_Z + @as(u32, @intCast(try alignToSectionSize(read_only_size_in_bytes)));
}

/// Calculate stack bottom address based on stack size
pub fn STACK_BOTTOM_ADDRESS(stack_size_in_pages: u32) !u32 {
    return STACK_BASE_ADDRESS - (@as(u32, @intCast(stack_size_in_pages)) * Z_P);
}

/// Aligns size to the next section boundary (Z_Z = 65536)
pub fn alignToSectionSize(size_in_bytes: usize) !usize {
    if (size_in_bytes > std.math.maxInt(u32)) {
        return error.SizeTooLarge;
    }
    const sections = @as(u32, @intCast(try std.math.divCeil(@TypeOf(size_in_bytes), size_in_bytes, Z_Z)));
    const aligned_size = sections * Z_Z;
    return aligned_size;
}

/// Aligns size to the next page boundary (Z_P = 4096)
pub fn alignToPageSize(size_in_bytes: usize) !u32 {
    const pages = try sizeInBytesToPages(size_in_bytes);
    const aligned_size = pages * Z_P;
    return aligned_size;
}

pub fn sizeInBytesToPages(size: usize) !u32 {
    const pages: u32 = @intCast(try std.math.divCeil(@TypeOf(size), size, Z_P));
    return pages;
}

const std = @import("std");
