const std = @import("std");
const messages = @import("messages.zig");
const jam_params_format = @import("../jam_params_format.zig");
const build_options = @import("build_options");

/// Dump protocol parameters in the specified format
pub fn dumpParams(format: []const u8, writer: anytype) !void {
    const params_type = if (@hasDecl(build_options, "conformance_params") and build_options.conformance_params == .tiny) "TINY" else "FULL";

    if (std.mem.eql(u8, format, "json")) {
        jam_params_format.formatParamsJson(messages.FUZZ_PARAMS, params_type, writer) catch |err| {
            // Handle BrokenPipe error gracefully (e.g., when piping to head)
            if (err == error.BrokenPipe) {
                std.process.exit(0);
            }
            return err;
        };
    } else if (std.mem.eql(u8, format, "text")) {
        jam_params_format.formatParamsText(messages.FUZZ_PARAMS, params_type, writer) catch |err| {
            // Handle BrokenPipe error gracefully (e.g., when piping to head)
            if (err == error.BrokenPipe) {
                std.process.exit(0);
            }
            return err;
        };
    } else {
        std.debug.print("Error: Invalid format '{s}'. Use 'json' or 'text'.\n", .{format});
        return error.InvalidFormat;
    }
}

/// Process command line arguments for parameter dumping
pub fn handleParamDump(dump_params: bool, format: ?[]const u8) !bool {
    if (!dump_params) {
        return false;
    }

    const fmt = format orelse "text";
    const stdout = std.io.getStdOut().writer();
    
    try dumpParams(fmt, stdout);
    return true;
}