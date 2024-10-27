const std = @import("std");
const testing = std.testing;
const json = std.json;

const JamState = @import("state.zig").JamState;

test "JamStateJSON" {
    const allocator = testing.allocator;
    const TINY = @import("jam_params.zig").TINY_PARAMS;

    var state = try JamState(TINY).init(allocator);
    defer state.deinit(allocator);

    const string = try json.stringifyAlloc(
        allocator,
        state,
        .{},
        // .{ .whitespace = .indent_1 },
    );
    defer allocator.free(string);

    // Print the JSON string (you can comment this out if you don't want to print)
    std.debug.print("JSON: {s}\n", .{string});
}
