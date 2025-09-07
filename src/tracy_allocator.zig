/// TracyAllocator - Memory tracking allocator wrapper for Tracy profiler
/// This allows selective memory tracking per subsystem while maintaining
/// zero overhead when Tracy is disabled.

const std = @import("std");
const tracy = @import("tracy");

/// Creates a Tracy-aware allocator wrapper that tracks allocations/deallocations
/// for the specified subsystem. When Tracy is disabled, this has zero overhead.
pub fn TracyAllocator(comptime name: []const u8) type {
    return struct {
        child: std.mem.Allocator,

        const Self = @This();

        pub fn init(child: std.mem.Allocator) Self {
            return .{ .child = child };
        }

        pub fn allocator(self: *Self) std.mem.Allocator {
            return .{
                .ptr = self,
                .vtable = &.{
                    .alloc = alloc,
                    .resize = resize,
                    .free = free,
                },
            };
        }

        fn alloc(ctx: *anyopaque, len: usize, log2_ptr_align: u8, ret_addr: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const result = self.child.rawAlloc(len, log2_ptr_align, ret_addr);
            
            if (result) |ptr| {
                // Track allocation in Tracy with subsystem name
                tracy.AllocN(ptr, len, name);
            }
            
            return result;
        }

        fn resize(ctx: *anyopaque, buf: []u8, log2_buf_align: u8, new_len: usize, ret_addr: usize) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            
            if (self.child.rawResize(buf, log2_buf_align, new_len, ret_addr)) {
                // Track reallocation: free old, alloc new
                tracy.FreeN(buf.ptr, name);
                tracy.AllocN(buf.ptr, new_len, name);
                return true;
            }
            
            return false;
        }

        fn free(ctx: *anyopaque, buf: []u8, log2_buf_align: u8, ret_addr: usize) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            
            // Track deallocation in Tracy with subsystem name
            tracy.FreeN(buf.ptr, name);
            
            self.child.rawFree(buf, log2_buf_align, ret_addr);
        }
    };
}

/// Convenience function to create a TracyAllocator for a subsystem
pub fn tracyAllocator(comptime name: []const u8, child: std.mem.Allocator) TracyAllocator(name) {
    return TracyAllocator(name).init(child);
}

// Pre-defined allocators for common subsystems
pub fn accumulate(child: std.mem.Allocator) TracyAllocator("accumulate") {
    return TracyAllocator("accumulate").init(child);
}

pub fn stf(child: std.mem.Allocator) TracyAllocator("stf") {
    return TracyAllocator("stf").init(child);
}

pub fn safrole(child: std.mem.Allocator) TracyAllocator("safrole") {
    return TracyAllocator("safrole").init(child);
}

pub fn services(child: std.mem.Allocator) TracyAllocator("services") {
    return TracyAllocator("services").init(child);
}

pub fn pvm(child: std.mem.Allocator) TracyAllocator("pvm") {
    return TracyAllocator("pvm").init(child);
}

pub fn reports(child: std.mem.Allocator) TracyAllocator("reports") {
    return TracyAllocator("reports").init(child);
}

pub fn disputes(child: std.mem.Allocator) TracyAllocator("disputes") {
    return TracyAllocator("disputes").init(child);
}

pub fn assurances(child: std.mem.Allocator) TracyAllocator("assurances") {
    return TracyAllocator("assurances").init(child);
}