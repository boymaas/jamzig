const std = @import("std");
const tests = @import("../tests.zig");
const safrole = @import("adaptor.zig");
const safrole_fixtures = @import("fixtures.zig");
const tiny_params = @import("tiny.zig").TINY_PARAMS;

test "safrole/tiny/publish-tickets-no-mark-1.json" {
    const allocator = std.testing.allocator;

    const fixtures = try safrole_fixtures.buildFixtures(
        allocator,
        "tiny/publish-tickets-no-mark-1.json",
    );
    defer fixtures.deinit();

    var result = try safrole.transition(
        allocator,
        tiny_params,
        fixtures.pre_state,
        fixtures.input,
    );
    defer result.deinit(allocator);

    try std.testing.expect(result.output == .err);
    try std.testing.expectEqual(.bad_ticket_attempt, result.output.err);
}

test "safrole/tiny/publish-tickets-no-mark-2.json" {
    const allocator = std.testing.allocator;

    const fixtures = try safrole_fixtures.buildFixtures(
        allocator,
        "tiny/publish-tickets-no-mark-2.json",
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

test "safrole/tiny/publish-tickets-no-mark-3.json" {
    const allocator = std.testing.allocator;

    const fixtures = try safrole_fixtures.buildFixtures(
        allocator,
        "tiny/publish-tickets-no-mark-3.json",
    );
    defer fixtures.deinit();

    var result = try safrole.transition(
        allocator,
        tiny_params,
        fixtures.pre_state,
        fixtures.input,
    );
    defer result.deinit(allocator);

    try std.testing.expect(result.output == .err);
    try std.testing.expectEqual(.duplicate_ticket, result.output.err);
}

test "safrole/tiny/publish-tickets-no-mark-4.json" {
    const allocator = std.testing.allocator;

    const fixtures = try safrole_fixtures.buildFixtures(
        allocator,
        "tiny/publish-tickets-no-mark-4.json",
    );
    defer fixtures.deinit();

    var result = try safrole.transition(
        allocator,
        tiny_params,
        fixtures.pre_state,
        fixtures.input,
    );
    defer result.deinit(allocator);

    try std.testing.expect(result.output == .err);
    try std.testing.expectEqual(.bad_ticket_order, result.output.err);
}

test "safrole/tiny/publish-tickets-no-mark-5.json" {
    const allocator = std.testing.allocator;

    const fixtures = try safrole_fixtures.buildFixtures(
        allocator,
        "tiny/publish-tickets-no-mark-5.json",
    );
    defer fixtures.deinit();

    var result = try safrole.transition(
        allocator,
        tiny_params,
        fixtures.pre_state,
        fixtures.input,
    );
    defer result.deinit(allocator);

    try std.testing.expect(result.output == .err);
    try std.testing.expectEqual(.bad_ticket_proof, result.output.err);
}

test "safrole/tiny/publish-tickets-no-mark-6.json" {
    const allocator = std.testing.allocator;

    const fixtures = try safrole_fixtures.buildFixtures(
        allocator,
        "tiny/publish-tickets-no-mark-6.json",
    );
    defer fixtures.deinit();

    var result = try safrole.transition(
        allocator,
        tiny_params,
        fixtures.pre_state,
        fixtures.input,
    );
    defer result.deinit(allocator);

    try std.testing.expect(result.output == .ok);
    try std.testing.expectEqualDeep(fixtures.post_state, result.state.?);
    try fixtures.expectOutput(result.output);
}

test "safrole/tiny/publish-tickets-no-mark-7.json" {
    const allocator = std.testing.allocator;

    const fixtures = try safrole_fixtures.buildFixtures(
        allocator,
        "tiny/publish-tickets-no-mark-7.json",
    );
    defer fixtures.deinit();

    var result = try safrole.transition(
        allocator,
        tiny_params,
        fixtures.pre_state,
        fixtures.input,
    );
    defer result.deinit(allocator);

    try std.testing.expect(result.output == .err);
    try std.testing.expectEqual(.unexpected_ticket, result.output.err);
}

test "safrole/tiny/publish-tickets-no-mark-8.json" {
    const allocator = std.testing.allocator;

    const fixtures = try safrole_fixtures.buildFixtures(
        allocator,
        "tiny/publish-tickets-no-mark-8.json",
    );
    defer fixtures.deinit();

    var result = try safrole.transition(
        allocator,
        tiny_params,
        fixtures.pre_state,
        fixtures.input,
    );
    defer result.deinit(allocator);

    try std.testing.expect(result.output == .ok);
    try std.testing.expectEqualDeep(fixtures.post_state, result.state.?);
    try fixtures.expectOutput(result.output);
}

test "safrole/tiny/publish-tickets-no-mark-9.json" {
    const allocator = std.testing.allocator;

    const fixtures = try safrole_fixtures.buildFixtures(
        allocator,
        "tiny/publish-tickets-no-mark-9.json",
    );
    defer fixtures.deinit();

    var result = try safrole.transition(
        allocator,
        tiny_params,
        fixtures.pre_state,
        fixtures.input,
    );
    defer result.deinit(allocator);

    try std.testing.expect(result.output == .ok);
    try std.testing.expectEqualDeep(fixtures.post_state, result.state.?);
    try fixtures.expectOutput(result.output);
}
