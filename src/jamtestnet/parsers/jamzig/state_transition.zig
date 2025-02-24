const std = @import("std");
const types = @import("../../../types.zig");
const codec = @import("../../../codec.zig");
const state_dictionary = @import("../../../state_dictionary.zig");

const tracing = @import("../../../tracing.zig");
const codec_scope = tracing.scoped(.codec);

pub const KeyVal = @import("../../export.zig").KeyVal;
pub const StateSnapshot = @import("../../export.zig").KeyVal;
pub const StateTransition = @import("../../export.zig").StateTransition;

pub fn loadTestVector(
    comptime params: @import("../../../jam_params.zig").Params,
    allocator: std.mem.Allocator,
    file_path: []const u8,
) !StateTransition {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const reader = file.reader();
    return try codec.deserializeAlloc(StateTransition, params, allocator, reader);
}
