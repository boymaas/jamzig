const std = @import("std");
const messages = @import("messages.zig");
const jam_params = @import("../jam_params.zig");
const jam_params_format = @import("../jam_params_format.zig");
const build_options = @import("build_options");

pub fn dumpParams(comptime params: jam_params.Params, format: []const u8, writer: anytype) !void {
    const params_type = if (@hasDecl(build_options, "conformance_params") and build_options.conformance_params == .tiny) "TINY" else "FULL";

    if (std.mem.eql(u8, format, "json")) {
        jam_params_format.formatParamsJson(params, params_type, writer) catch |err| {
            if (err == error.BrokenPipe) {
                std.process.exit(0);
            }
            return err;
        };
    } else if (std.mem.eql(u8, format, "text")) {
        jam_params_format.formatParamsText(params, params_type, writer) catch |err| {
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

pub fn handleParamDump(comptime params: jam_params.Params, dump_params: bool, format: ?[]const u8) !bool {
    if (!dump_params) {
        return false;
    }

    const fmt = format orelse "text";
    const stdout = std.io.getStdOut().writer();

    try dumpParams(params, fmt, stdout);
    return true;
}

