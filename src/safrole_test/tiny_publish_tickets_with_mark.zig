const std = @import("std");
const tests = @import("../tests.zig");
const safrole = @import("../safrole.zig");
const safrole_fixtures = @import("fixtures.zig");
const tiny_params = @import("tiny.zig").TINY_PARAMS;

test "safrole/tiny/publish-tickets-with-mark-1.json" {
    const allocator = std.testing.allocator;

    const fixtures = try safrole_fixtures.buildFixtures(
        allocator,
        "tiny/publish-tickets-with-mark-1.json",
    );
    defer fixtures.deinit();

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

test "safrole/tiny/publish-tickets-with-mark-2.json" {
    const allocator = std.testing.allocator;

    const fixtures = try safrole_fixtures.buildFixtures(
        allocator,
        "tiny/publish-tickets-with-mark-2.json",
    );
    defer fixtures.deinit();

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

test "safrole/tiny/publish-tickets-with-mark-3.json" {
    const allocator = std.testing.allocator;

    const fixtures = try safrole_fixtures.buildFixtures(
        allocator,
        "tiny/publish-tickets-with-mark-3.json",
    );
    defer fixtures.deinit();

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

test "safrole/tiny/publish-tickets-with-mark-4.json" {
    const allocator = std.testing.allocator;

    const fixtures = try safrole_fixtures.buildFixtures(
        allocator,
        "tiny/publish-tickets-with-mark-4.json",
    );
    defer fixtures.deinit();

    var result = try safrole.transition(
        allocator,
        tiny_params,
        fixtures.pre_state,
        fixtures.input,
    );
    defer result.deinit(allocator);

    try std.testing.expectEqualDeep(fixtures.post_state, result.state.?);
    try fixtures.expectOutput(result.output);
}

test "safrole/tiny/publish-tickets-with-mark-5.json" {
    const allocator = std.testing.allocator;

    const fixtures = try safrole_fixtures.buildFixtures(
        allocator,
        "tiny/publish-tickets-with-mark-5.json",
    );
    defer fixtures.deinit();

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
