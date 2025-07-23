const std = @import("std");
const types = @import("../types.zig");
const sort = std.sort;
const decoder = @import("../codec/decoder.zig");
const state = @import("../state.zig");
const state_decoding = @import("../state_decoding.zig");
const DecodingError = state_decoding.DecodingError;
const DecodingContext = state_decoding.DecodingContext;

const GlobalIndex = std.AutoHashMapUnmanaged(types.WorkPackageHash, void);

pub const DecoderParams = struct {
    epoch_length: u32,

    pub fn fromJamParams(comptime params: anytype) DecoderParams {
        return .{
            .epoch_length = params.epoch_length,
        };
    }
};

pub fn decode(
    comptime params: DecoderParams,
    allocator: std.mem.Allocator,
    context: *DecodingContext,
    reader: anytype,
) !state.Xi(params.epoch_length) {
    try context.push(.{ .component = "xi" });
    defer context.pop();

    var global_index: GlobalIndex = .{};
    var result: [params.epoch_length]std.AutoHashMapUnmanaged([32]u8, void) = undefined;
    
    try context.push(.{ .field = "entries" });
    for (&result, 0..) |*epoch, i| {
        try context.push(.{ .array_index = i });
        epoch.* = try decodeTimeslotEntryAndFillGlobalIndex(allocator, context, reader, &global_index);
        context.pop();
    }
    context.pop();
    
    return .{ .entries = result, .allocator = allocator, .global_index = global_index };
}

pub fn decodeTimeslotEntryAndFillGlobalIndex(
    allocator: std.mem.Allocator,
    context: *DecodingContext,
    reader: anytype,
    global_index: *GlobalIndex,
) !std.AutoHashMapUnmanaged([32]u8, void) {
    var result = std.AutoHashMapUnmanaged([32]u8, void){};
    errdefer result.deinit(allocator);

    // Read length prefix
    var length_buf: [1]u8 = undefined;
    reader.readNoEof(&length_buf) catch |err| {
        return context.makeError(error.EndOfStream, "failed to read entry count: {s}", .{@errorName(err)});
    };
    const count = length_buf[0];

    // Read each key-value pair
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try context.push(.{ .array_index = i });
        
        var key: [32]u8 = undefined;
        reader.readNoEof(&key) catch |err| {
            return context.makeError(error.EndOfStream, "failed to read work package hash: {s}", .{@errorName(err)});
        };

        result.put(allocator, key, {}) catch |err| {
            return context.makeError(error.OutOfMemory, "failed to add entry: {s}", .{@errorName(err)});
        };
        global_index.put(allocator, key, {}) catch |err| {
            return context.makeError(error.OutOfMemory, "failed to add to global index: {s}", .{@errorName(err)});
        };
        
        context.pop();
    }

    return result;
}
