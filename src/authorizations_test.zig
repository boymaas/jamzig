const std = @import("std");
const testing = std.testing;
const types = @import("types.zig");

const state = @import("state.zig");
const state_delta = @import("state_delta.zig");
const jam_params = @import("jam_params.zig");

const authorizations = @import("authorizations.zig");
const auth_pool = @import("authorizer_pool.zig");
const auth_queue = @import("authorizer_queue.zig");

const jamtestvectors = @import("jamtestvectors/authorizations.zig");
const dir = @import("jamtestvectors/dir.zig");

const converters = @import("authorizations_test/converters.zig");

const trace = @import("tracing.zig").scoped(.authorizations_test);

const BASE_PATH = "src/jamtestvectors/data/authorizations/";

test "authorizations:tiny" {
    const allocator = testing.allocator;

    // Scan all tiny test vectors
    var test_vectors = try dir.scan(
        jamtestvectors.TestCase(jam_params.TINY_PARAMS),
        jam_params.TINY_PARAMS,
        allocator,
        BASE_PATH ++ "tiny/",
    );
    defer test_vectors.deinit();

    // Run each test vector
    for (test_vectors.test_cases()) |*test_vector| {
        try runTestCase(jam_params.TINY_PARAMS, allocator, test_vector);
        break;
    }
}

test "authorizations:full" {
    const allocator = testing.allocator;

    // Scan all full test vectors
    var test_vectors = try dir.scan(
        jamtestvectors.TestCase(jam_params.FULL_PARAMS),
        jam_params.FULL_PARAMS,
        allocator,
        BASE_PATH ++ "full/",
    );
    defer test_vectors.deinit();

    // Run each test vector
    for (test_vectors.test_cases()) |*test_vector| {
        try runTestCase(jam_params.FULL_PARAMS, allocator, test_vector);
    }
}

fn runTestCase(
    comptime params: jam_params.Params,
    allocator: std.mem.Allocator,
    test_vector: *const jamtestvectors.TestCase(params),
) !void {
    // try test_vector.debugPrintStateDiff(allocator);
    // test_vector.debugInput();

    var current_state = try converters.buildTransientFromTestState(params, allocator, test_vector.pre_state);
    defer current_state.deinit(allocator);

    var transition = try state_delta.StateTransition(params).init(
        allocator,
        &current_state,
        params.Time().init(test_vector.input.slot - 1, test_vector.input.slot),
    );
    defer transition.deinit();

    // Process authorizations
    const auths = try converters.convertToAuthorizerList(allocator, test_vector.input);
    defer allocator.free(auths);

    try authorizations.processAuthorizations(
        params,
        &transition,
        auths,
    );

    try transition.mergePrimeOntoBase();

    var expected_state = try converters.buildTransientFromTestState(params, allocator, test_vector.post_state);
    defer expected_state.deinit(allocator);

    var diff = try @import("tests/diff.zig").diffBasedOnFormat(
        allocator,
        current_state,
        expected_state,
    );
    defer diff.deinit(allocator);

    try diff.debugPrintAndReturnErrorOnDiff();
}
