pub const deinit = @import("meta/deinit.zig");
pub const calls = @import("meta/calls.zig");
pub const cow = @import("meta/cow.zig");

pub const callDeepClone = @import("meta/calls.zig").callDeepClone;
pub const callDeinit = @import("meta/calls.zig").callDeinit;
pub const isComplexType = @import("meta/calls.zig").isComplexType;

pub const CopyOnWrite = @import("meta/cow.zig").CopyOnWrite;
