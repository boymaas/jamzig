const std = @import("std");

// Iterator utilities
pub const collect = @import("itertools/collect.zig");
pub const map_struct_field = @import("itertools/map_struct_field.zig");
pub const map_function = @import("itertools/map_function.zig");
pub const slice = @import("itertools/slice.zig");
pub const multi_slice = @import("itertools/multi_slice.zig");

// Re-export all public functionality
pub const collectIntoArrayList = collect.collectIntoArrayList;
pub const collectIntoAppendable = collect.collectIntoAppendable;
pub const collectIntoSet = collect.collectIntoSet;
pub const MapStructFieldIter = map_struct_field.MapStructFieldIter;
pub const SliceIter = slice.SliceIter;
pub const MultiSliceIter = multi_slice.MultiSliceIter;
pub const MapFunc = map_function.MapFunc;

test {
    // Run tests from all modules
    // std.testing.refAllDecls(@This());
    _ = @import("itertools/collect.zig");
    _ = @import("itertools/map_struct_field.zig");
    _ = @import("itertools/map_function.zig");
    _ = @import("itertools/multi_slice.zig");
}
