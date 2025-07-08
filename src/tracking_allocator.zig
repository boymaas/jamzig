const std = @import("std");

/// A simplified tracking allocator that records all allocations for bulk cleanup.
/// Use case: Undo all allocations if an operation fails (all-or-nothing pattern).
pub const TrackingAllocator = struct {
    const Allocation = struct {
        ptr: [*]u8,
        len: usize,
        alignment: std.mem.Alignment,
    };

    base_allocator: std.mem.Allocator,
    allocations: std.ArrayList(Allocation),

    pub fn init(base_allocator: std.mem.Allocator) TrackingAllocator {
        return .{
            .base_allocator = base_allocator,
            .allocations = std.ArrayList(Allocation).init(base_allocator),
        };
    }

    pub fn deinit(self: *TrackingAllocator) void {
        self.freeAllAllocations();
        self.allocations.deinit();
    }

    pub fn allocator(self: *TrackingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
                .remap = remap,
            },
        };
    }

    /// Clear tracking list - call this when operation succeeds
    pub fn commitAllocations(self: *TrackingAllocator) void {
        self.allocations.clearRetainingCapacity();
    }

    /// Free all tracked allocations - call this on error/rollback
    pub fn freeAllAllocations(self: *TrackingAllocator) void {
        // Free in reverse order (LIFO)
        while (self.allocations.pop()) |allocation| {
            self.base_allocator.rawFree(allocation.ptr[0..allocation.len], allocation.alignment, @returnAddress());
        }
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));

        const ptr = self.base_allocator.rawAlloc(len, alignment, return_address) orelse return null;

        // Track this allocation
        self.allocations.append(.{
            .ptr = ptr,
            .len = len,
            .alignment = alignment,
        }) catch {
            self.base_allocator.rawFree(ptr[0..len], alignment, return_address);
            return null;
        };

        return ptr;
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));

        const result = self.base_allocator.rawResize(buf, alignment, new_len, return_address);

        // Update tracked size if resize succeeded
        if (result) {
            for (self.allocations.items) |*allocation| {
                if (allocation.ptr == buf.ptr) {
                    allocation.len = new_len;
                    break;
                }
            }
        }

        return result;
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));

        // Remove from tracking
        for (self.allocations.items, 0..) |allocation, i| {
            if (allocation.ptr == buf.ptr) {
                _ = self.allocations.swapRemove(i);
                break;
            }
        }

        self.base_allocator.rawFree(buf, alignment, return_address);
    }

    fn remap(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        _ = ctx;
        _ = buf;
        _ = buf_align;
        _ = new_len;
        _ = return_address;
        return null; // Let Zig use the fallback (alloc+copy+free)
    }
};

test "TrackingAllocator" {
    const testing = std.testing;
    var tracker = TrackingAllocator.init(testing.allocator);
    defer tracker.deinit();

    const allocator = tracker.allocator();

    // Make some allocations
    _ = try allocator.alloc(u8, 100);
    _ = try allocator.alloc(u32, 50);

    // Simulate error - free all
    tracker.freeAllAllocations();
    try testing.expect(tracker.allocations.items.len == 0);

    // Make new allocations
    const ptr3 = try allocator.alloc(u8, 200);
    defer allocator.free(ptr3);

    // Simulate success - commit
    tracker.commitAllocations();
    try testing.expect(tracker.allocations.items.len == 0);
}

