const std = @import("std");

const TestVector = @import("tests/vectors/libs/safrole.zig").TestVector;

const tests = @import("tests.zig");
const safrole = @import("safrole.zig");

test "format State" {
    const allocator = std.testing.allocator;
    const tv_parsed = try TestVector.build_from(allocator, "src/tests/vectors/jam/safrole/tiny/enact-epoch-change-with-no-tickets-1.json");
    defer tv_parsed.deinit();
    const tv = &tv_parsed.value;

    const pre_state = try tests.stateFromTestVector(allocator, &tv.pre_state);
    defer pre_state.deinit(allocator);

    std.debug.print("\n{any}\n", .{pre_state});

    const post_state = try tests.stateFromTestVector(allocator, &tv.post_state);
    defer post_state.deinit(allocator);

    std.debug.print("\n{any}\n", .{post_state});
}

// *** /tmp/pre_state  2024-09-03 20:36:21.442597011 +0200
// --- /tmp/post_state 2024-09-03 20:36:28.579596880 +0200
// ***************
// *** 1,11 ****
//   State {
//
//   ---- Timeslot (τ) ----
// !   tau: 0
//
//   ---- Entropy Accumulator (η) ----
//     eta: [
// !     0x03170a2e7597b7b7e3d84c05391d139a62b157e78786d8c082f29dcf4c111314
//       0xee155ace9c40292074cb6aff8c9ccdd273c81648ff1149ef36bcea6ebb8a3e25
//       0xbb30a42c1e62f0afda5f0a4e8a562f7a13a24cea00ee81917b86b89e801314aa
//       0xe88bd757ad5b9bedf372d8d3f0cf6c962a469db61a265f6418e1ffed86da29ec
// --- 1,11 ----
//   State {
//
//   ---- Timeslot (τ) ----
// !   tau: 1
//
//   ---- Entropy Accumulator (η) ----
//     eta: [
// !     0xa0243a82952899598fcbc74aff0df58a71059a9882d4416919055c5d64bf2a45
//       0xee155ace9c40292074cb6aff8c9ccdd273c81648ff1149ef36bcea6ebb8a3e25
//       0xbb30a42c1e62f0afda5f0a4e8a562f7a13a24cea00ee81917b86b89e801314aa
//       0xe88bd757ad5b9bedf372d8d3f0cf6c962a469db61a265f6418e1ffed86da29ec
test "tiny/enact-epoch-change-with-no-tickets-1" {
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
