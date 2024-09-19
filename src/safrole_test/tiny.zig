const std = @import("std");
const tests = @import("../tests.zig");
const safrole = @import("../safrole.zig");
const safrole_fixtures = @import("fixtures.zig");

// Safrole tests for the tiny network
// https://github.com/w3f/jamtestvectors/blob/master/safrole/README.md
//
// Tiny tests with reduced validators (6) and a shorter epoch duration (12)

const TINY_PARAMS = safrole.Params{ .epoch_length = 12 };

test "tiny/enact-epoch-change-with-no-tickets-1" {
    const allocator = std.testing.allocator;

    const fixtures = try safrole_fixtures.buildFixtures(
        allocator,
        "tiny/enact-epoch-change-with-no-tickets-1.json",
    );
    defer fixtures.deinit();

    // try fixtures.printInputStateChangesAndOutput();

    var result = try safrole.transition(
        allocator,
        TINY_PARAMS,
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
}

test "tiny/enact-epoch-change-with-no-tickets-2" {
    const allocator = std.testing.allocator;

    const fixtures = try safrole_fixtures.buildFixtures(
        allocator,
        "tiny/enact-epoch-change-with-no-tickets-2.json",
    );
    defer fixtures.deinit();

    // try fixtures.printInputStateChangesAndOutput();

    var result = try safrole.transition(
        allocator,
        TINY_PARAMS,
        fixtures.pre_state,
        fixtures.input,
    );
    defer result.deinit(allocator);

    // ensure result.state is null
    try std.testing.expect(result.state == null);

    try std.testing.expect(result.output == .err);
    if (result.output == .err) {
        try std.testing.expectEqual(.bad_slot, result.output.err);
    } else {
        @panic("unexpected output, expected and error");
    }
}

test "tiny/enact-epoch-change-with-no-tickets-3" {
    const allocator = std.testing.allocator;

    const fixtures = try safrole_fixtures.buildFixtures(
        allocator,
        "tiny/enact-epoch-change-with-no-tickets-3.json",
    );
    defer fixtures.deinit();

    // try fixtures.printInputStateChangesAndOutput();

    var result = try safrole.transition(
        allocator,
        TINY_PARAMS,
        fixtures.pre_state,
        fixtures.input,
    );
    defer result.deinit(allocator);

    // Compare the fixture poststate with the result state
    try std.testing.expectEqualDeep(fixtures.post_state, result.state.?);
}

test "tiny/enact-epoch-change-with-no-tickets-4" {
    const allocator = std.testing.allocator;

    const fixtures = try safrole_fixtures.buildFixtures(
        allocator,
        "tiny/enact-epoch-change-with-no-tickets-4.json",
    );
    defer fixtures.deinit();

    // try fixtures.printInputStateChangesAndOutput();

    var result = try safrole.transition(
        allocator,
        TINY_PARAMS,
        fixtures.pre_state,
        fixtures.input,
    );
    defer result.deinit(allocator);

    try fixtures.printInput();
    // try fixtures.printPreState();
    try fixtures.diffAgainstPostStateAndPrint(&result.state.?);

    // Compare the fixture poststate with the result state
    // try std.testing.expectEqualDeep(fixtures.post_state, result.state.?);
}
