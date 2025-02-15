const std = @import("std");
const converters = @import("./converters.zig");
const tvector = @import("../jamtestvectors/accumulate.zig");
const accumulate = @import("../accumulate.zig");
const state = @import("../state.zig");
const types = @import("../types.zig");
const helpers = @import("../tests/helpers.zig");
const diff = @import("../tests/diff.zig");
const Params = @import("../jam_params.zig").Params;

pub fn processAccumulateReports(
    comptime params: Params,
    allocator: std.mem.Allocator,
    test_case: *const tvector.TestCase,
    delta: *state.Delta,
    theta: *state.Theta(params.epoch_length),
    chi: *state.Chi,
    xi: *state.Xi(params.epoch_length),
) !types.AccumulateRoot {
    // Process the work reports
    return try accumulate.processAccumulateReports(
        params,
        allocator,
        test_case.input.reports,
        params.Time().init(test_case.pre_state.slot, test_case.input.slot),
        delta,
        theta,
        chi,
        xi,
    );
}

pub fn runAccumulateTest(comptime params: Params, allocator: std.mem.Allocator, test_case: tvector.TestCase) !void {
    // Convert pre-state from test vector format to native format
    var pre_state_services = try converters.convertServiceAccounts(
        allocator,
        test_case.pre_state.accounts,
    );
    defer pre_state_services.deinit();

    var pre_state_privileges = try converters.convertPrivileges(
        allocator,
        test_case.pre_state.privileges,
    );
    defer pre_state_privileges.deinit();

    var pre_state_ready = try converters.convertReadyQueue(
        params.epoch_length,
        allocator,
        test_case.pre_state.ready_queue,
    );
    defer pre_state_ready.deinit();

    var pre_state_accumulated = try converters.convertAccumulated(
        params.epoch_length,
        allocator,
        test_case.pre_state.accumulated,
    );
    defer pre_state_accumulated.deinit();

    // Convert post-state for later comparison
    var expected_services = try converters.convertServiceAccounts(
        allocator,
        test_case.post_state.accounts,
    );
    defer expected_services.deinit();

    var expected_privileges = try converters.convertPrivileges(
        allocator,
        test_case.post_state.privileges,
    );
    defer expected_privileges.deinit();

    var expected_ready = try converters.convertReadyQueue(
        params.epoch_length,
        allocator,
        test_case.post_state.ready_queue,
    );
    defer expected_ready.deinit();

    var expected_accumulated = try converters.convertAccumulated(
        params.epoch_length,
        allocator,
        test_case.post_state.accumulated,
    );
    defer expected_accumulated.deinit();

    const process_result = processAccumulateReports(
        params,
        allocator,
        &test_case,
        &pre_state_services,
        &pre_state_ready,
        &pre_state_privileges,
        &pre_state_accumulated,
    );

    switch (test_case.output) {
        .err => {
            if (process_result) |_| {
                std.debug.print("\nGot success, expected error\n", .{});
                return error.UnexpectedSuccess;
            } else |_| {
                // Error was expected, test passes
            }
        },
        .ok => |expected_root| {
            if (process_result) |actual_root| {
                if (!std.mem.eql(u8, &actual_root, &expected_root)) {
                    std.debug.print("Mismatch: actual root != expected root\n", .{});
                    return error.RootMismatch;
                }

                // Verify state matches expected state
                diff.expectFormattedEqual(*state.Delta, allocator, &pre_state_services, &expected_services) catch {
                    std.debug.print("Mismatch: actual Delta != expected Delta\n", .{});
                    return error.StateDeltaMismatch;
                };

                diff.expectTypesFmtEqual(*state.Chi, allocator, &pre_state_privileges, &expected_privileges) catch {
                    std.debug.print("Mismatch: actual Chi != expected Chi\n", .{});
                    return error.StateChiMismatch;
                };

                diff.expectTypesFmtEqual(*state.Theta(params.epoch_length), allocator, &pre_state_ready, &expected_ready) catch {
                    std.debug.print("Mismatch: actual Theta != expected Theta\n", .{});
                    return error.StateThetaMismatch;
                };

                diff.expectTypesFmtEqual(*state.Xi(params.epoch_length), allocator, &pre_state_accumulated, &expected_accumulated) catch {
                    std.debug.print("Mismatch: actual Xi != expected Xi\n", .{});
                    return error.StateXiMismatch;
                };
            } else |err| {
                std.debug.print("UnexpectedError: {any}\n", .{err});
                return error.UnexpectedError;
            }
        },
    }
}
