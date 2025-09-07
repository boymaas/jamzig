/// No-op Tracy profiler module for zero-overhead when Tracy is disabled.
/// This module provides the same API as the real Tracy module but with
/// stub implementations that compile to nothing.

const std = @import("std");

/// Zone context struct that tracks nothing when Tracy is disabled
pub const ZoneCtx = struct {
    /// No-op zone end
    pub fn End(_: ZoneCtx) void {}
    
    /// No-op set zone text
    pub fn Text(_: ZoneCtx, _: []const u8) void {}
    
    /// No-op set zone name
    pub fn Name(_: ZoneCtx, _: []const u8) void {}
    
    /// No-op set zone value
    pub fn Value(_: ZoneCtx, _: u64) void {}
};

/// Create a basic profiling zone - returns no-op zone when disabled
pub fn Zone(_: std.builtin.SourceLocation) ZoneCtx {
    return ZoneCtx{};
}

/// Create a named profiling zone - returns no-op zone when disabled
pub fn ZoneN(_: std.builtin.SourceLocation, _: []const u8) ZoneCtx {
    return ZoneCtx{};
}

/// Create a colored profiling zone - returns no-op zone when disabled
pub fn ZoneC(_: std.builtin.SourceLocation, _: u32) ZoneCtx {
    return ZoneCtx{};
}

/// Create a named and colored profiling zone - returns no-op zone when disabled
pub fn ZoneNC(_: std.builtin.SourceLocation, _: []const u8, _: u32) ZoneCtx {
    return ZoneCtx{};
}

/// Mark the end of a frame - no-op when disabled
pub fn FrameMark() void {}

/// Mark the end of a named frame - no-op when disabled
pub fn FrameMarkNamed(_: []const u8) void {}

/// Mark start of a named frame - no-op when disabled
pub fn FrameMarkStart(_: []const u8) void {}

/// Mark end of a named frame - no-op when disabled
pub fn FrameMarkEnd(_: []const u8) void {}

/// Set the name of the current thread - no-op when disabled
pub fn SetThreadName(_: [*:0]const u8) void {}

/// Send a message to Tracy - no-op when disabled
pub fn Message(_: []const u8) void {}

// Memory tracking no-ops

/// Track allocation - no-op when disabled
pub fn Alloc(_: ?*anyopaque, _: usize) void {}

/// Track named allocation - no-op when disabled
pub fn AllocN(_: ?*anyopaque, _: usize, _: []const u8) void {}

/// Track deallocation - no-op when disabled
pub fn Free(_: ?*anyopaque) void {}

/// Track named deallocation - no-op when disabled
pub fn FreeN(_: ?*anyopaque, _: []const u8) void {}

// Plot tracking no-ops

/// Plot integer value - no-op when disabled
pub fn PlotI(_: []const u8, _: i64) void {}

/// Plot float value - no-op when disabled
pub fn PlotF(_: []const u8, _: f64) void {}

/// Plot unsigned integer value - no-op when disabled
pub fn PlotU(_: []const u8, _: u64) void {}

// Fiber tracking no-ops

/// Enter fiber context - no-op when disabled
pub fn FiberEnter(_: []const u8) void {}

/// Leave fiber context - no-op when disabled
pub fn FiberLeave() void {}

// Lock tracking no-ops

/// Announce lock - no-op when disabled
pub fn lockAnnounce(_: ?*anyopaque, _: []const u8) void {}

/// Mark lock wait - no-op when disabled
pub fn lockWait(_: ?*anyopaque) void {}

/// Mark lock obtained - no-op when disabled
pub fn lockObtained(_: ?*anyopaque) void {}

/// Mark lock released - no-op when disabled
pub fn lockReleased(_: ?*anyopaque) void {}

/// Mark lock terminated - no-op when disabled
pub fn lockTerminate(_: ?*anyopaque) void {}