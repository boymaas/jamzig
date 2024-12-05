const std = @import("std");
const types = @import("types.zig");
const crypto = @import("crypto.zig");
const ring_vrf = @import("ring_vrf.zig");

fn timeFunction(comptime desc: []const u8, comptime func: anytype, args: anytype) @typeInfo(@TypeOf(func)).@"fn".return_type.? {
    var timer = std.time.Timer.start() catch unreachable;
    const result = @call(.auto, func, args);
    const elapsed_nanos = timer.read();
    const elapsed_time = @as(f64, @floatFromInt(elapsed_nanos)) / 1_000_000.0;

    std.debug.print(desc ++ " took {d:.3} ms\n", .{elapsed_time});
    return result;
}

test "ring_vrf: ring signature and VRF" {
    const RING_SIZE: usize = 10;
    var ring: [RING_SIZE]types.BandersnatchPublic = undefined;

    // Generate public keys for the ring
    for (0..RING_SIZE) |i| {
        const seed = std.mem.asBytes(&std.mem.nativeToLittle(usize, i));
        const key_pair = try crypto.createKeyPairFromSeed(seed);
        ring[i] = key_pair.public_key;

        // Print the first 3 keys in hex format
        if (i < 3) {
            std.debug.print("Public key {}: ", .{i});
            for (key_pair.public_key) |byte| {
                std.debug.print("{x:0>2}", .{byte});
            }
            std.debug.print("\n", .{});
        }
    }

    // Replace some keys with padding points
    const padding_point = try crypto.getPaddingPoint(RING_SIZE);
    ring[2] = padding_point;
    // We can also set a key to 0, which will be converted to padding points by the verifier
    ring[7] = std.mem.zeroes(types.BandersnatchPublic);

    // Create verifier
    var verifier = try ring_vrf.RingVerifier.init(&ring);
    defer verifier.deinit();

    const prover_key_index: usize = 3;

    // Generate a key pair for the prover
    const prover_seed = std.mem.asBytes(&std.mem.nativeToLittle(usize, prover_key_index));
    const prover_key_pair = try crypto.createKeyPairFromSeed(prover_seed);

    // Create prover
    var prover = try ring_vrf.RingProver.init(
        prover_key_pair.private_key,
        &ring,
        prover_key_index,
    );
    defer prover.deinit();

    // Create some input data
    const vrf_input_data = [_]u8{ 'f', 'o', 'o' };
    const aux_data = [_]u8{ 'b', 'a', 'r' };

    // Generate ring signature
    const ring_signature = try timeFunction("genRingSig", ring_vrf.RingProver.sign, .{
        &prover,
        &vrf_input_data,
        &aux_data,
    });

    // Verify ring signature
    _ = try timeFunction("verifyRingSig", ring_vrf.RingVerifier.verify, .{
        &verifier,
        &vrf_input_data,
        &aux_data,
        &ring_signature,
    });
}

test "ring_vrf: fuzz | takes 10s" {
    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    const RING_SIZE: usize = 10;

    // Generate public keys for the ring
    var ring_keypairs: [RING_SIZE]types.BandersnatchKeyPair = undefined;
    var ring: [RING_SIZE]types.BandersnatchPublic = undefined;
    for (0..RING_SIZE) |i| {
        var seed: [32]u8 = undefined;
        random.bytes(&seed);
        const key_pair = try crypto.createKeyPairFromSeed(&seed);
        ring_keypairs[i] = key_pair;
        ring[i] = key_pair.public_key;
    }

    // Create verifier once for all iterations
    var verifier = try ring_vrf.RingVerifier.init(&ring);
    defer verifier.deinit();

    // Test multiple iterations
    const ITERATIONS: usize = 4;
    for (0..ITERATIONS) |iteration| {
        // choose a random prover key index
        const prover_key_index = random.uintLessThan(usize, RING_SIZE);

        // Create prover for this iteration
        var prover = try ring_vrf.RingProver.init(
            ring_keypairs[prover_key_index].private_key,
            &ring,
            prover_key_index,
        );
        defer prover.deinit();

        // Create some input data
        var vrf_input_data: [32]u8 = undefined;
        random.bytes(&vrf_input_data);
        var aux_data: [32]u8 = undefined;
        random.bytes(&aux_data);

        std.debug.print("Iteration: {}, Prover Key Index: {}\n", .{ iteration, prover_key_index });

        // Generate ring signature
        const ring_signature = try prover.sign(&vrf_input_data, &aux_data);

        // Verify ring signature
        _ = try verifier.verify(&vrf_input_data, &aux_data, &ring_signature);
    }

    std.debug.print("\n\nFuzz test completed successfully.\n", .{});
}
