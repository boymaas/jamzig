const std = @import("std");
const tests = @import("../tests.zig");
const safrole = @import("../safrole.zig");
const safrole_fixtures = @import("fixtures.zig");

// Safrole tests for the tiny network
// https://github.com/w3f/jamtestvectors/blob/master/safrole/README.md
//
// Tiny tests with reduced validators (6) and a shorter epoch duration (12)
//
// NOTE: RING_SIZE = 6 in ffi/rust/crypto/ring_vrf.rs

const TINY_PARAMS = safrole.Params{
    .epoch_length = 12,
    // TODO: what value of Y (ticket_submission_end_slot) should we use for the tiny vectors, now set to
    // same ratio. Production values is 500 of and epohc length of 600 which
    // would suggest 10
    .ticket_submission_end_epoch_slot = 10,
    .max_ticket_entries_per_validator = 2,
};

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

    // try fixtures.printInput();
    // try fixtures.printPreState();
    // try fixtures.diffAgainstPostStateAndPrint(&result.state.?);

    // Compare the fixture poststate with the result state
    try std.testing.expectEqualDeep(fixtures.post_state, result.state.?);
}

test "tiny/publish-tickets-no-mark-1.json" {
    const allocator = std.testing.allocator;

    // src/tests/vectors/safrole/safrole/tiny/publish-tickets-no-mark-1.json
    const fixtures = try safrole_fixtures.buildFixtures(
        allocator,
        "tiny/publish-tickets-no-mark-1.json",
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

    // NOTE: this should produce a bad ticket attempt
    try std.testing.expect(result.output == .err);
    try std.testing.expectEqual(.bad_ticket_attempt, result.output.err);
}

test "tiny/publish-tickets-no-mark-2.json" {
    const allocator = std.testing.allocator;

    // src/tests/vectors/safrole/safrole/tiny/publish-tickets-no-mark-2.json
    const fixtures = try safrole_fixtures.buildFixtures(
        allocator,
        "tiny/publish-tickets-no-mark-2.json",
    );
    defer fixtures.deinit();

    // try fixtures.printInput();
    // try fixtures.printInputStateChangesAndOutput();

    var result = try safrole.transition(
        allocator,
        TINY_PARAMS,
        fixtures.pre_state,
        fixtures.input,
    );
    defer result.deinit(allocator);

    // std.debug.print("Result: {any}\n", .{result});

    // try fixtures.printPreState();
    // try fixtures.diffAgainstPostStateAndPrint(&result.state.?);

    try std.testing.expectEqualDeep(fixtures.post_state, result.state.?);
}

test "tiny/publish-tickets-no-mark-3.json" {
    const allocator = std.testing.allocator;

    // src/tests/vectors/safrole/safrole/tiny/publish-tickets-no-mark-3.json
    const fixtures = try safrole_fixtures.buildFixtures(
        allocator,
        "tiny/publish-tickets-no-mark-3.json",
    );
    defer fixtures.deinit();

    // try fixtures.printInput();
    // try fixtures.printInputStateChangesAndOutput();

    var result = try safrole.transition(
        allocator,
        TINY_PARAMS,
        fixtures.pre_state,
        fixtures.input,
    );
    defer result.deinit(allocator);

    // std.debug.print("Result: {any}\n", .{result});

    // try fixtures.printPreState();
    // try fixtures.diffAgainstPostStateAndPrint(&result.state.?);

    try std.testing.expect(result.output == .err);
    try std.testing.expectEqual(.duplicate_ticket, result.output.err);

    // try std.testing.expectEqualDeep(fixtures.post_state, result.state.?);
}

test "tiny/publish-tickets-no-mark-4.json" {
    const allocator = std.testing.allocator;

    // src/tests/vectors/safrole/safrole/tiny/publish-tickets-no-mark-4.json
    const fixtures = try safrole_fixtures.buildFixtures(
        allocator,
        "tiny/publish-tickets-no-mark-4.json",
    );
    defer fixtures.deinit();

    // try fixtures.printInput();
    // try fixtures.printInputStateChangesAndOutput();

    var result = try safrole.transition(
        allocator,
        TINY_PARAMS,
        fixtures.pre_state,
        fixtures.input,
    );
    defer result.deinit(allocator);

    // std.debug.print("Result: {any}\n", .{result});

    // try fixtures.printPreState();
    // try fixtures.diffAgainstPostStateAndPrint(&result.state.?);

    try std.testing.expect(result.output == .err);
    try std.testing.expectEqual(.bad_ticket_order, result.output.err);

    // try std.testing.expectEqualDeep(fixtures.post_state, result.state.?);
}

test "tiny/publish-tickets-no-mark-5.json" {
    const allocator = std.testing.allocator;

    // src/tests/vectors/safrole/safrole/tiny/publish-tickets-no-mark-5.json
    const fixtures = try safrole_fixtures.buildFixtures(
        allocator,
        "tiny/publish-tickets-no-mark-5.json",
    );
    defer fixtures.deinit();

    // try fixtures.printInput();
    // try fixtures.printInputStateChangesAndOutput();

    var result = try safrole.transition(
        allocator,
        TINY_PARAMS,
        fixtures.pre_state,
        fixtures.input,
    );
    defer result.deinit(allocator);

    try std.testing.expect(result.output == .err);
    try std.testing.expectEqual(.bad_ticket_proof, result.output.err);
}

test "tiny/publish-tickets-no-mark-6.json" {
    const allocator = std.testing.allocator;

    // src/tests/vectors/safrole/safrole/tiny/publish-tickets-no-mark-6.json
    const fixtures = try safrole_fixtures.buildFixtures(
        allocator,
        "tiny/publish-tickets-no-mark-6.json",
    );
    defer fixtures.deinit();

    // try fixtures.printInput();
    // try fixtures.printInputStateChangesAndOutput();

    var result = try safrole.transition(
        allocator,
        TINY_PARAMS,
        fixtures.pre_state,
        fixtures.input,
    );
    defer result.deinit(allocator);

    try std.testing.expect(result.output == .ok);
    try std.testing.expectEqualDeep(fixtures.post_state, result.state.?);
}

// Test an epoch slot higher than Y with tickets. Which is not allowed.
test "tiny/publish-tickets-no-mark-7.json" {
    const allocator = std.testing.allocator;

    // src/tests/vectors/safrole/safrole/tiny/publish-tickets-no-mark-7.json
    const fixtures = try safrole_fixtures.buildFixtures(
        allocator,
        "tiny/publish-tickets-no-mark-7.json",
    );
    defer fixtures.deinit();

    // try fixtures.printInput();
    // try fixtures.printInputStateChangesAndOutput();

    var result = try safrole.transition(
        allocator,
        TINY_PARAMS,
        fixtures.pre_state,
        fixtures.input,
    );
    defer result.deinit(allocator);

    // try fixtures.printInput();
    // try fixtures.diffAgainstPostStateAndPrint(&result.state.?);

    try std.testing.expect(result.output == .err);
    try std.testing.expectEqual(.unexpected_ticket, result.output.err);
}

// This tests an epoch_slot > Y with no tickets, which should
// result in an OK.
test "tiny/publish-tickets-no-mark-8.json" {
    const allocator = std.testing.allocator;

    // src/tests/vectors/safrole/safrole/tiny/publish-tickets-no-mark-8.json
    const fixtures = try safrole_fixtures.buildFixtures(
        allocator,
        "tiny/publish-tickets-no-mark-8.json",
    );
    defer fixtures.deinit();

    // try fixtures.printInput();
    // try fixtures.printInputStateChangesAndOutput();

    var result = try safrole.transition(
        allocator,
        TINY_PARAMS,
        fixtures.pre_state,
        fixtures.input,
    );
    defer result.deinit(allocator);

    // try fixtures.printInput();
    // try fixtures.diffAgainstPostStateAndPrint(&result.state.?);

    try std.testing.expect(result.output == .ok);
    try std.testing.expectEqualDeep(fixtures.post_state, result.state.?);
}

// This tests an epoch transition
test "tiny/publish-tickets-no-mark-9.json" {
    const allocator = std.testing.allocator;

    // src/tests/vectors/safrole/safrole/tiny/publish-tickets-no-mark-9.json
    const fixtures = try safrole_fixtures.buildFixtures(
        allocator,
        "tiny/publish-tickets-no-mark-9.json",
    );
    defer fixtures.deinit();

    // try fixtures.printInput();
    // try fixtures.printInputStateChangesAndOutput();

    var result = try safrole.transition(
        allocator,
        TINY_PARAMS,
        fixtures.pre_state,
        fixtures.input,
    );
    defer result.deinit(allocator);

    // try fixtures.printInput();
    // try fixtures.diffAgainstPostStateAndPrint(&result.state.?);

    try std.testing.expect(result.output == .ok);
    try std.testing.expectEqualDeep(fixtures.post_state, result.state.?);
}

// Publish tickets with mark

test "tiny/publish-tickets-with-mark-1.json" {
    const allocator = std.testing.allocator;

    // src/tests/vectors/safrole/safrole/tiny/publish-tickets-with-mark-1.json
    const fixtures = try safrole_fixtures.buildFixtures(
        allocator,
        "tiny/publish-tickets-with-mark-1.json",
    );
    defer fixtures.deinit();

    // try fixtures.printInput();
    // try fixtures.printInputStateChangesAndOutput();

    var result = try safrole.transition(
        allocator,
        TINY_PARAMS,
        fixtures.pre_state,
        fixtures.input,
    );
    defer result.deinit(allocator);

    // try fixtures.printInput();
    try fixtures.diffAgainstPostStateAndPrint(&result.state.?);
    try std.testing.expectEqualDeep(fixtures.post_state, result.state.?);
}

test "tiny/publish-tickets-with-mark-2.json" {
    const allocator = std.testing.allocator;

    // src/tests/vectors/safrole/safrole/tiny/publish-tickets-with-mark-2.json
    const fixtures = try safrole_fixtures.buildFixtures(
        allocator,
        "tiny/publish-tickets-with-mark-2.json",
    );
    defer fixtures.deinit();

    // try fixtures.printInput();
    // try fixtures.printInputStateChangesAndOutput();

    var result = try safrole.transition(
        allocator,
        TINY_PARAMS,
        fixtures.pre_state,
        fixtures.input,
    );
    defer result.deinit(allocator);

    // try fixtures.printInput();
    try fixtures.diffAgainstPostStateAndPrint(&result.state.?);
    try std.testing.expectEqualDeep(fixtures.post_state, result.state.?);
}

test "tiny/publish-tickets-with-mark-3.json" {
    const allocator = std.testing.allocator;

    // src/tests/vectors/safrole/safrole/tiny/publish-tickets-with-mark-3.json
    const fixtures = try safrole_fixtures.buildFixtures(
        allocator,
        "tiny/publish-tickets-with-mark-3.json",
    );
    defer fixtures.deinit();

    // try fixtures.printInput();
    // try fixtures.printInputStateChangesAndOutput();

    var result = try safrole.transition(
        allocator,
        TINY_PARAMS,
        fixtures.pre_state,
        fixtures.input,
    );
    defer result.deinit(allocator);

    // try fixtures.printInput();
    try fixtures.diffAgainstPostStateAndPrint(&result.state.?);
    try std.testing.expectEqualDeep(fixtures.post_state, result.state.?);
}

test "tiny/publish-tickets-with-mark-4.json" {
    const allocator = std.testing.allocator;

    // src/tests/vectors/safrole/safrole/tiny/publish-tickets-with-mark-4.json
    const fixtures = try safrole_fixtures.buildFixtures(
        allocator,
        "tiny/publish-tickets-with-mark-4.json",
    );
    defer fixtures.deinit();

    // try fixtures.printInput();
    // try fixtures.printInputStateChangesAndOutput();

    var result = try safrole.transition(
        allocator,
        TINY_PARAMS,
        fixtures.pre_state,
        fixtures.input,
    );
    defer result.deinit(allocator);

    // try fixtures.printInput();
    try fixtures.diffAgainstPostStateAndPrint(&result.state.?);
    try std.testing.expectEqualDeep(fixtures.post_state, result.state.?);
}
