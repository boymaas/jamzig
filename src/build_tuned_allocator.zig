const std = @import("std");
const builtin = @import("builtin");

/// Allocator that is tuned for different build modes:
/// - ReleaseFast: Uses std.heap.smp_allocator for maximum performance
/// - Other modes: Uses GeneralPurposeAllocator for safety and debugging
pub const BuildTunedAllocator = struct {
    allocator_impl: std.mem.Allocator,
    gpa: if (builtin.mode == .ReleaseFast) void else *std.heap.GeneralPurposeAllocator(.{}),

    /// Initialize the build-tuned allocator based on compile-time build mode
    pub fn init() BuildTunedAllocator {
        if (builtin.mode == .ReleaseFast) {
            return .{
                .allocator_impl = std.heap.smp_allocator,
                .gpa = {},
            };
        } else {
            var gpa = std.heap.smp_allocator.create(std.heap.GeneralPurposeAllocator(.{})) catch @panic("Failed to create GeneralPurposeAllocator");
            gpa.* = std.heap.GeneralPurposeAllocator(.{}){};
            return .{
                .allocator_impl = gpa.allocator(),
                .gpa = gpa,
            };
        }
    }

    /// Clean up the allocator (only needed for GPA in non-ReleaseFast builds)
    pub fn deinit(self: *BuildTunedAllocator) void {
        if (builtin.mode != .ReleaseFast) {
            _ = self.gpa.deinit();
            std.heap.smp_allocator.destroy(self.gpa);
        }
        self.* = undefined;
    }

    /// Get the allocator interface
    pub fn allocator(self: *BuildTunedAllocator) std.mem.Allocator {
        return self.allocator_impl;
    }
};
