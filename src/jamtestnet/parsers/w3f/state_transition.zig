const std = @import("std");
const types = @import("../../../types.zig");
const codec = @import("../../../codec.zig");
const state_dictionary = @import("../../../state_dictionary.zig");
const merkle = @import("../../../merkle.zig");
const export_types = @import("../../export.zig");

const tracing = @import("../../../tracing.zig");
const codec_scope = tracing.scoped(.codec);

const Params = @import("../../../jam_params.zig").Params;
const MerklizationDictionary = state_dictionary.MerklizationDictionary;

// Use the same types as export.zig for consistency
pub const KeyVal = export_types.KeyVal;
pub const StateSnapshot = export_types.StateSnapshot;
pub const StateTransition = export_types.StateTransition;

// Load test vector - supports both binary and JSON formats
pub fn loadTestVector(comptime params: Params, allocator: std.mem.Allocator, file_path: []const u8) !StateTransition {
    // Check file extension to determine format
    if (std.mem.endsWith(u8, file_path, ".bin")) {
        // Binary format - use codec deserialization
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        var context = codec.DecodingContext.init(allocator);
        defer context.deinit();

        const reader = file.reader();
        return codec.deserializeAllocWithContext(StateTransition, params, allocator, reader, &context) catch |err| {
            // Log comprehensive error information
            std.log.err("\n===== Deserialization Error =====", .{});
            std.log.err("Error: {s}", .{@errorName(err)});
            std.log.err("Test vector file: {s}", .{file_path});
            context.dumpError();
            std.log.err("=================================\n", .{});
            return err;
        };
    } else {
        return error.UnknownFileFormat;
    }
}
