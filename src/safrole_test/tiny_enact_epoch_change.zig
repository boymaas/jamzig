const std = @import("std");
const tests = @import("../tests.zig");
const safrole = @import("../safrole.zig");
const safrole_fixtures = @import("fixtures.zig");
const tiny_params = @import("tiny.zig").TINY_PARAMS;

test "tiny/enact-epoch-change-with-no-tickets-1" {
    const allocator = std.testing.allocator;

    const fixtures = try safrole_fixtures.buildFixtures(
        allocator,
        "tiny/enact-epoch-change-with-no-tickets-1.json",
    );
    defer fixtures.deinit();

    var result = try safrole.transition(
        allocator,
        tiny_params,
        fixtures.pre_state,
        fixtures.input,
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(1, result.state.?.tau);

    var post_eta = try tests.hexStringToBytes(allocator, "a0243a82952899598fcbc74aff0df58a71059a9882d4416919055c5d64bf2a45");
    defer allocator.free(post_eta);

    try std.testing.expectEqual(
        post_eta[0..32].*,
        result.state.?.eta[0],
    );

    try std.testing.expectEqualDeep(fixtures.post_state, result.state.?);
    try fixtures.expectOkOutputWithNullEpochAndTicketMarkers(result.output);
}

test "tiny/enact-epoch-change-with-no-tickets-2" {
    const allocator = std.testing.allocator;

    const fixtures = try safrole_fixtures.buildFixtures(
        allocator,
        "tiny/enact-epoch-change-with-no-tickets-2.json",
    );
    defer fixtures.deinit();

    var result = try safrole.transition(
        allocator,
        tiny_params,
        fixtures.pre_state,
        fixtures.input,
    );
    defer result.deinit(allocator);

    try std.testing.expect(result.state == null);

    try std.testing.expect(result.output == .err);
    try std.testing.expectEqual(.bad_slot, result.output.err);
}

test "tiny/enact-epoch-change-with-no-tickets-3" {
    const allocator = std.testing.allocator;

    const fixtures = try safrole_fixtures.buildFixtures(
        allocator,
        "tiny/enact-epoch-change-with-no-tickets-3.json",
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
    try fixtures.expectOkOutputWithNullEpochAndTicketMarkers(result.output);
}

test "tiny/enact-epoch-change-with-no-tickets-4" {
    const allocator = std.testing.allocator;

    const fixtures = try safrole_fixtures.buildFixtures(
        allocator,
        "tiny/enact-epoch-change-with-no-tickets-4.json",
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
