const std = @import("std");

const TestVector = @import("tests/vectors/libs/safrole.zig").TestVector;

const tests = @import("tests.zig");
const safrole = @import("safrole.zig");

test "update tau" {
    const allocator = std.testing.allocator;
    const tv_parsed = try TestVector.build_from(allocator, "src/tests/vectors/jam/safrole/tiny/enact-epoch-change-with-no-tickets-1.json");
    defer tv_parsed.deinit();
    const tv = &tv_parsed.value;

    // Assume these are populated from your JSON parsing
    const pre_state = try tests.stateFromTestVector(allocator, &tv.pre_state);
    defer pre_state.deinit(allocator);
    const input = try tests.inputFromTestVector(allocator, &tv.input);
    defer input.deinit(allocator);

    _ = try safrole.transition(
        allocator,
        pre_state,
        input,
    );

    // try std.testing.expectEqual(1, post_state.tau);
}
