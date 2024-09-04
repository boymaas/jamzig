const std = @import("std");
const pretty = @import("pretty");

const TestVector = @import("tests/vectors/libs/safrole.zig").TestVector;

const tests = @import("tests.zig");
const safrole = @import("safrole.zig");

// Input {
// ---- Slot ----
//   slot: 1
//
// ---- Entropy ----
//   entropy: 0x8c2e6d327dfaa6ff8195513810496949210ad20a96e2b0672a3e1b9335080801
//
// ---- Extrinsic ----
//   extrinsic: 0 ticket envelopes
// }

//   State Changes {
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

// Expected Output {
//   ok: {
//     epoch_mark: null
//     tickets_mark: null
//   }
// }
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

    var result = try safrole.transition(
        allocator,
        pre_state,
        input,
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(1, result.state.?.tau);
}
