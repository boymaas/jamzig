const std = @import("std");
const tests = @import("../tests.zig");
const safrole = @import("../safrole.zig");
const safrole_fixtures = @import("fixtures.zig");
const tiny_params = @import("tiny.zig").TINY_PARAMS;

test "safrole/tiny/skip-epochs-1.json" {
    const allocator = std.testing.allocator;

    const fixtures = try safrole_fixtures.buildFixtures(
        allocator,
        "tiny/skip-epochs-1.json",
    );
    defer fixtures.deinit();

    // try fixtures.printInput();
    // try fixtures.printInputStateChangesAndOutput();

    var result = try safrole.transition(
        allocator,
        tiny_params,
        fixtures.pre_state,
        fixtures.input,
    );
    defer result.deinit(allocator);

    // try fixtures.diffAgainstPostStateAndPrint(&result.state.?);
    try std.testing.expectEqualDeep(fixtures.post_state, result.state.?);
    try fixtures.expectOutput(result.output);
}

test "safrole/tiny/skip-epoch-tail-1.json" {
    const allocator = std.testing.allocator;

    const fixtures = try safrole_fixtures.buildFixtures(
        allocator,
        "tiny/skip-epoch-tail-1.json",
    );
    defer fixtures.deinit();

    // try fixtures.printInput();
    // try fixtures.printInputStateChangesAndOutput();

    var result = try safrole.transition(
        allocator,
        tiny_params,
        fixtures.pre_state,
        fixtures.input,
    );
    defer result.deinit(allocator);

    // try fixtures.diffAgainstPostStateAndPrint(&result.state.?);
    try std.testing.expectEqualDeep(fixtures.post_state, result.state.?);
    try fixtures.expectOutput(result.output);
}
