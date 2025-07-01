const std = @import("std");

/// Information about a tracked allocation
const AllocationInfo = struct {
    ptr: [*]u8,
    size: usize,
    alignment: std.mem.Alignment,
};

/// A wrapper allocator that tracks all allocations and can free them all at once.
/// This is useful for scenarios where partial allocation failure should result in
/// complete cleanup of all previously allocated memory.
pub const TrackingAllocator = struct {
    base_allocator: std.mem.Allocator,
    allocations: std.ArrayList(AllocationInfo),
    is_tracking: bool,

    /// Initialize a new tracking allocator
    pub fn init(base_allocator: std.mem.Allocator) TrackingAllocator {
        return TrackingAllocator{
            .base_allocator = base_allocator,
            .allocations = std.ArrayList(AllocationInfo).init(base_allocator),
            .is_tracking = true,
        };
    }

    /// Deinitialize the tracking allocator. This will free the tracking list
    /// but not the tracked allocations themselves.
    pub fn deinit(self: *TrackingAllocator) void {
        self.allocations.deinit();
    }

    /// Get the allocator interface for this tracking allocator
    pub fn allocator(self: *TrackingAllocator) std.mem.Allocator {
        return std.mem.Allocator{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
                .remap = remap,
            },
        };
    }

    /// Stop tracking allocations. After calling this, allocations will go
    /// directly to the base allocator and won't be tracked for cleanup.
    /// This should be called when the operation succeeds and you want to
    /// commit all allocations.
    pub fn commitAllocations(self: *TrackingAllocator) void {
        self.is_tracking = false;
        self.allocations.clearRetainingCapacity();
    }

    /// Free all tracked allocations. This should be called when an error
    /// occurs and you want to clean up all previously allocated memory.
    pub fn freeAllAllocations(self: *TrackingAllocator) void {
        // Free in reverse order (LIFO) to handle potential dependencies
        var i = self.allocations.items.len;
        while (i > 0) {
            i -= 1;
            const allocation = self.allocations.items[i];
            self.base_allocator.rawFree(allocation.ptr[0..allocation.size], allocation.alignment, @returnAddress());
        }
        self.allocations.clearRetainingCapacity();
    }

    /// Allocator vtable function for allocation
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        
        const ptr = self.base_allocator.rawAlloc(len, alignment, return_address) orelse return null;
        
        // Only track if we're still in tracking mode
        if (self.is_tracking) {
            const allocation_info = AllocationInfo{
                .ptr = ptr,
                .size = len,
                .alignment = alignment,
            };
            
            self.allocations.append(allocation_info) catch {
                // If we can't track the allocation, free it immediately and return null
                self.base_allocator.rawFree(ptr[0..len], alignment, return_address);
                return null;
            };
        }
        
        return ptr;
    }

    /// Allocator vtable function for resize
    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        
        const result = self.base_allocator.rawResize(buf, alignment, new_len, return_address);
        
        // Update tracking info if resize succeeded and we're tracking
        if (result and self.is_tracking) {
            // Find and update the allocation info
            for (self.allocations.items) |*allocation| {
                if (allocation.ptr == buf.ptr) {
                    allocation.size = new_len;
                    break;
                }
            }
        }
        
        return result;
    }

    /// Allocator vtable function for free
    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        
        // Remove from tracking if we're still tracking
        if (self.is_tracking) {
            for (self.allocations.items, 0..) |allocation, i| {
                if (allocation.ptr == buf.ptr) {
                    _ = self.allocations.swapRemove(i);
                    break;
                }
            }
        }
        
        self.base_allocator.rawFree(buf, alignment, return_address);
    }

    /// Allocator vtable function for remap (no-op implementation)
    fn remap(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        _ = ctx;
        _ = buf;
        _ = buf_align;
        _ = new_len;
        _ = return_address;
        return null; // No-op remap, always fails
    }
};

// Tests
test "TrackingAllocator basic functionality" {
    const testing = std.testing;
    var tracking_allocator = TrackingAllocator.init(testing.allocator);
    defer tracking_allocator.deinit();
    
    const allocator = tracking_allocator.allocator();
    
    // Allocate some memory
    const ptr1 = try allocator.alloc(u8, 100);
    const ptr2 = try allocator.alloc(u32, 50);
    
    // Should have 2 tracked allocations
    try testing.expect(tracking_allocator.allocations.items.len == 2);
    
    // Free one manually
    allocator.free(ptr1);
    
    // Should have 1 tracked allocation
    try testing.expect(tracking_allocator.allocations.items.len == 1);
    
    // Commit allocations - should stop tracking
    tracking_allocator.commitAllocations();
    try testing.expect(tracking_allocator.allocations.items.len == 0);
    try testing.expect(!tracking_allocator.is_tracking);
    
    // Clean up remaining allocation
    allocator.free(ptr2);
}

test "TrackingAllocator freeAllAllocations" {
    const testing = std.testing;
    var tracking_allocator = TrackingAllocator.init(testing.allocator);
    defer tracking_allocator.deinit();
    
    const allocator = tracking_allocator.allocator();
    
    // Allocate some memory
    _ = try allocator.alloc(u8, 100);
    _ = try allocator.alloc(u32, 50);
    _ = try allocator.alloc(u64, 25);
    
    // Should have 3 tracked allocations
    try testing.expect(tracking_allocator.allocations.items.len == 3);
    
    // Free all allocations
    tracking_allocator.freeAllAllocations();
    
    // Should have no tracked allocations
    try testing.expect(tracking_allocator.allocations.items.len == 0);
}

test "TrackingAllocator after commit doesn't track" {
    const testing = std.testing;
    var tracking_allocator = TrackingAllocator.init(testing.allocator);
    defer tracking_allocator.deinit();
    
    const allocator = tracking_allocator.allocator();
    
    // Allocate and commit
    const ptr1 = try allocator.alloc(u8, 100);
    tracking_allocator.commitAllocations();
    
    // New allocations shouldn't be tracked
    const ptr2 = try allocator.alloc(u8, 100);
    try testing.expect(tracking_allocator.allocations.items.len == 0);
    
    // Clean up manually since they're not tracked
    allocator.free(ptr1);
    allocator.free(ptr2);
}