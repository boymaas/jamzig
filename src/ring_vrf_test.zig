const std = @import("std");
const types = @import("types.zig");
const Bandersnatch = @import("crypto/bandersnatch.zig").Bandersnatch;
const ring_vrf = @import("ring_vrf.zig");

test "ring_signature.vrf: ring signature and VRF" {
    const RING_SIZE: usize = 10;
    var ring: [RING_SIZE]types.BandersnatchPublic = undefined;

    for (0..RING_SIZE) |i| {
        const seed = std.mem.asBytes(&std.mem.nativeToLittle(usize, i));
        const key_pair = try Bandersnatch.KeyPair.generateDeterministic(seed);
        ring[i] = key_pair.public_key.toBytes();

        if (i < 3) {
            std.debug.print("Public key {}: ", .{i});
            for (key_pair.public_key.toBytes()) |byte| {
                std.debug.print("{x:0>2}", .{byte});
            }
            std.debug.print("\n", .{});
        }
    }

    // Zero keys are converted to padding points by the verifier
    const padding_point = try ring_vrf.getPaddingPoint(RING_SIZE);
    ring[2] = padding_point;
    ring[7] = std.mem.zeroes(types.BandersnatchPublic);

    var verifier = try ring_vrf.RingVerifier.init(&ring);
    defer verifier.deinit();

    const prover_key_index: usize = 3;
    const prover_seed = std.mem.asBytes(&std.mem.nativeToLittle(usize, prover_key_index));
    const prover_key_pair = try Bandersnatch.KeyPair.generateDeterministic(prover_seed);

    var prover = try ring_vrf.RingProver.init(
        prover_key_pair.secret_key.toBytes(),
        &ring,
        prover_key_index,
    );
    defer prover.deinit();

    const vrf_input_data = [_]u8{ 'f', 'o', 'o' };
    const aux_data = [_]u8{ 'b', 'a', 'r' };

    const ring_signature = try ring_vrf.RingProver.sign(
        &prover,
        &vrf_input_data,
        &aux_data,
    );

    _ = try ring_vrf.RingVerifier.verify(
        &verifier,
        &vrf_input_data,
        &aux_data,
        &ring_signature,
    );
}

test "verify.commitment: verify against commitment" {
    const RING_SIZE: usize = 10;
    var ring: [RING_SIZE]types.BandersnatchPublic = undefined;

    for (0..RING_SIZE) |i| {
        const seed = std.mem.asBytes(&std.mem.nativeToLittle(usize, i));
        const key_pair = try Bandersnatch.KeyPair.generateDeterministic(seed);
        ring[i] = key_pair.public_key.toBytes();
    }

    var verifier = try ring_vrf.RingVerifier.init(&ring);
    defer verifier.deinit();

    const commitment = try verifier.get_commitment();
    const prover_key_index: usize = 3;
    const prover_seed = std.mem.asBytes(&std.mem.nativeToLittle(usize, prover_key_index));
    const prover_key_pair = try Bandersnatch.KeyPair.generateDeterministic(prover_seed);

    var prover = try ring_vrf.RingProver.init(
        prover_key_pair.secret_key.toBytes(),
        &ring,
        prover_key_index,
    );
    defer prover.deinit();

    const vrf_input_data = [_]u8{ 't', 'e', 's', 't' };
    const aux_data = [_]u8{ 'd', 'a', 't', 'a' };

    const ring_signature = try ring_vrf.RingProver.sign(&prover, &vrf_input_data, &aux_data);

    _ = try ring_vrf.verifyRingSignatureAgainstCommitment(
        &commitment,
        RING_SIZE,
        &vrf_input_data,
        &aux_data,
        &ring_signature,
    );

    _ = try ring_vrf.RingVerifier.verify(
        &verifier,
        &vrf_input_data,
        &aux_data,
        &ring_signature,
    );
}

test "fuzz: takes 10s" {
    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    const RING_SIZE: usize = 10;

    var ring_keypairs: [RING_SIZE]types.BandersnatchKeyPair = undefined;
    var ring: [RING_SIZE]types.BandersnatchPublic = undefined;
    for (0..RING_SIZE) |i| {
        var seed: [32]u8 = undefined;
        random.bytes(&seed);
        const key_pair = try Bandersnatch.KeyPair.generateDeterministic(&seed);
        ring_keypairs[i] = .{
            .public_key = key_pair.public_key.toBytes(),
            .private_key = key_pair.secret_key.toBytes(),
        };
        ring[i] = key_pair.public_key.toBytes();
    }

    var verifier = try ring_vrf.RingVerifier.init(&ring);
    defer verifier.deinit();

    const ITERATIONS: usize = 4;
    for (0..ITERATIONS) |iteration| {
        const prover_key_index = random.uintLessThan(usize, RING_SIZE);

        var prover = try ring_vrf.RingProver.init(
            ring_keypairs[prover_key_index].private_key,
            &ring,
            prover_key_index,
        );
        defer prover.deinit();

        var vrf_input_data: [32]u8 = undefined;
        random.bytes(&vrf_input_data);
        var aux_data: [32]u8 = undefined;
        random.bytes(&aux_data);

        std.debug.print("Iteration: {}, Prover Key Index: {}\n", .{ iteration, prover_key_index });

        const ring_signature = try prover.sign(&vrf_input_data, &aux_data);

        _ = try verifier.verify(&vrf_input_data, &aux_data, &ring_signature);
    }

    std.debug.print("\n\nFuzz test completed successfully.\n", .{});
}

test "equivalence.paths: Test VRF output equivalence paths" {
    const allocator = std.testing.allocator;

    const ring_size: usize = 5;
    var public_keys: [ring_size]types.BandersnatchPublic = undefined;
    var key_pairs: [ring_size]Bandersnatch.KeyPair = undefined;

    for (0..ring_size) |i| {
        const seed = std.mem.asBytes(&std.mem.nativeToLittle(usize, i));
        key_pairs[i] = try Bandersnatch.KeyPair.generateDeterministic(seed);
        public_keys[i] = key_pairs[i].public_key.toBytes();
    }

    const prover_idx = 2;
    const our_keypair = key_pairs[prover_idx];

    var ring_verifier = try ring_vrf.RingVerifier.init(&public_keys);
    defer ring_verifier.deinit();

    var ring_prover = try ring_vrf.RingProver.init(our_keypair.secret_key.toBytes(), &public_keys, prover_idx);
    defer ring_prover.deinit();

    // Path 1: Ring VRF (used when submitting tickets)
    const ring_vrf_output = ticket_path: {
        std.debug.print("\n=== Path 1: Ring VRF ===\n", .{});

        const context = "jam_ticket_seal";
        const eta_3 = [_]u8{0} ** 32;
        const ticket_attempt: u8 = 1;

        var ticket_context = std.ArrayList(u8).init(allocator);
        defer ticket_context.deinit();
        try ticket_context.appendSlice(context);
        try ticket_context.appendSlice(&eta_3);
        try ticket_context.append(ticket_attempt);

        const ring_signature = try ring_prover.sign(&[_]u8{}, ticket_context.items);

        std.debug.print("Ring VRF Signature: {x}\n", .{ring_signature});

        const vrf_output = try ring_verifier.verify(&[_]u8{}, ticket_context.items, &ring_signature);

        std.debug.print("Ring VRF output({d}): {x}\n", .{ vrf_output.len, vrf_output });

        break :ticket_path vrf_output;
    };

    // Path 2: Regular signature (used for block seal)
    const fallback_vrf_output = fallback_path: {
        std.debug.print("\n=== Path 2: Regular Signature ===\n", .{});

        const prefix = "jam_ticket_fallback";
        const eta_3 = [_]u8{0} ** 32;

        var context = std.ArrayList(u8).init(allocator);
        defer context.deinit();
        try context.appendSlice(prefix);
        try context.appendSlice(&eta_3);

        const vrf_signature = try our_keypair.sign(&[_]u8{}, context.items);
        const vrf_signature_raw = vrf_signature.toBytes();
        std.debug.print("Fallback VRF Signature({d}): {x}\n", .{ @sizeOf(@TypeOf(vrf_signature_raw)), vrf_signature_raw });

        const vrf_output = try vrf_signature.outputHash();
        std.debug.print("Ring VRF output({d}): {x}\n", .{ vrf_output.len, vrf_output });

        break :fallback_path vrf_output;
    };

    try std.testing.expectEqualSlices(u8, &ring_vrf_output, &fallback_vrf_output);
}
