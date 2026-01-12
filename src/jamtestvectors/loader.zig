const std = @import("std");
const codec = @import("../codec.zig");
const types = @import("../types.zig");

const Params = @import("../jam_params.zig").Params;

pub fn loadAndDeserializeTestVector(comptime T: type, comptime params: Params, allocator: std.mem.Allocator, file_path: []const u8) !T {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    return try codec.deserializeAlloc(T, params, allocator, file.reader());
}

pub fn loadAndDeserializeTestVectorWithContext(comptime T: type, comptime params: Params, allocator: std.mem.Allocator, file_path: []const u8) !T {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    var context = codec.DecodingContext.init(allocator);
    defer context.deinit();

    return codec.deserializeAllocWithContext(T, params, allocator, file.reader(), &context) catch |err| {
        std.log.err("\n===== Deserialization Error =====", .{});
        std.log.err("Error: {s}", .{@errorName(err)});
        std.log.err("Test vector file: {s}", .{file_path});
        std.log.err("Root type being decoded: {s}", .{@typeName(T)});
        context.dumpError();
        std.log.err("=================================\n", .{});
        return err;
    };
}
