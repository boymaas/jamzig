const std = @import("std");

const TestVector = @import("tests/vectors/libs/safrole.zig").TestVector;

const safrole = @import("safrole.zig");

test "update tau" {
    const allocator = std.testing.allocator;
    const tv_parsed = try TestVector.build_from(allocator, "src/tests/vectors/jam/safrole/tiny/enact-epoch-change-with-no-tickets-1.json");
    defer tv_parsed.deinit();
    const tv = &tv_parsed.value;

    // Assume these are populated from your JSON parsing
    var pre_state = safrole.State{ .tau = tv.pre_state.tau };
    const input = safrole.Input{ .slot = tv.input.slot };

    const output = safrole.transition(&pre_state, input);

    // Handle the output
    switch (output) {
        .ok => |_| {
            std.debug.print("Tau updated successfully to: {}\n", .{pre_state.tau});
            // Handle marks if needed
        },
        .err => |error_code| {
            std.debug.print("Error updating tau: {}\n", .{error_code});
        },
    }
}
