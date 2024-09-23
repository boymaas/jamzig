const std = @import("std");
const safrole = @import("../safrole.zig");
const fixtures = @import("fixtures.zig");
const assert = std.debug.assert;

// NOTE: RING_SIZE = 1023 in ffi/rust/crypto/ring_vrf.rs
// https://github.com/w3f/jamtestvectors/pull/5#issuecomment-2208938416

pub const FULL_PARAMS = safrole.Params{
    .epoch_length = 600,
    .ticket_submission_end_epoch_slot = 500,
    .max_ticket_entries_per_validator = 2,
    .validators_count = 1023,
};

const TEST_VECTOR_DIR = "src/tests/vectors/safrole/safrole/full";

fn testSafroleVector(allocator: std.mem.Allocator, file_name: []const u8) !void {
    var fixture = try fixtures.buildFixtures(allocator, file_name);
    defer fixture.deinit();

    const actual_result = try safrole.transition(
        allocator,
        FULL_PARAMS,
        fixture.pre_state,
        fixture.input,
    );
    defer actual_result.deinit(allocator);

    fixture.expectOutput(actual_result.output) catch {};
    if (actual_result.state) |state| {
        fixture.expectPostState(&state) catch {
            try fixture.diffAgainstPostStateAndPrint(&state);
        };
    }
}

test "safrole/full/automated" {
    const allocator = std.testing.allocator;

    var dir = try std.fs.cwd().openDir(TEST_VECTOR_DIR, .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        const path = try std.fmt.allocPrint(
            allocator,
            "full/{s}",
            .{entry.name},
        );
        defer allocator.free(path);
        std.debug.print("Safrole full vector: {s}\n", .{path});
        try testSafroleVector(
            allocator,
            path,
        );
    }
}
