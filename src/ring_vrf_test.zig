const std = @import("std");
const types = @import("types.zig");
const Bandersnatch = @import("crypto/bandersnatch.zig").Bandersnatch;
const ring_vrf = @import("ring_vrf.zig");

fn timeFunction(comptime desc: []const u8, comptime func: anytype, args: anytype) @typeInfo(@TypeOf(func)).@"fn".return_type.? {
    var timer = std.time.Timer.start() catch unreachable;
    const result = @call(.auto, func, args);
    const elapsed_nanos = timer.read();
    const elapsed_time = @as(f64, @floatFromInt(elapsed_nanos)) / 1_000_000.0;

    std.debug.print(desc ++ " took {d:.3} ms\n", .{elapsed_time});
    return result;
}

test "ring_signature.vrf: ring signature and VRF" {
    const RING_SIZE: usize = 10;
    var ring: [RING_SIZE]types.BandersnatchPublic = undefined;

    // Generate public keys for the ring
    for (0..RING_SIZE) |i| {
        const seed = std.mem.asBytes(&std.mem.nativeToLittle(usize, i));
        const key_pair = try Bandersnatch.KeyPair.create(seed);
        ring[i] = key_pair.public_key.toBytes();

        // Print the first 3 keys in hex format
        if (i < 3) {
            std.debug.print("Public key {}: ", .{i});
            for (key_pair.public_key.toBytes()) |byte| {
                std.debug.print("{x:0>2}", .{byte});
            }
            std.debug.print("\n", .{});
        }
    }

    // Replace some keys with padding points
    const padding_point = try ring_vrf.getPaddingPoint(RING_SIZE);
    ring[2] = padding_point;
    // We can also set a key to 0, which will be converted to padding points by the verifier
    //
    ring[7] = std.mem.zeroes(types.BandersnatchPublic);

    // Create verifier
    var verifier = try ring_vrf.RingVerifier.init(&ring);
    defer verifier.deinit();

    const prover_key_index: usize = 3;

    // Generate a key pair for the prover
    const prover_seed = std.mem.asBytes(&std.mem.nativeToLittle(usize, prover_key_index));
    const prover_key_pair = try Bandersnatch.KeyPair.create(prover_seed);

    // Create prover
    var prover = try ring_vrf.RingProver.init(
        prover_key_pair.secret_key.toBytes(),
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

test "verify.commitment: verify against commitment" {
    const RING_SIZE: usize = 10;
    var ring: [RING_SIZE]types.BandersnatchPublic = undefined;

    // Generate public keys for the ring
    for (0..RING_SIZE) |i| {
        const seed = std.mem.asBytes(&std.mem.nativeToLittle(usize, i));
        const key_pair = try Bandersnatch.KeyPair.create(seed);
        ring[i] = key_pair.public_key.toBytes();
    }

    // Create verifier to get commitment
    var verifier = try ring_vrf.RingVerifier.init(&ring);
    defer verifier.deinit();

    // Get commitment before any signing
    const commitment = try verifier.get_commitment();

    const prover_key_index: usize = 3;

    // Generate a key pair for the prover
    const prover_seed = std.mem.asBytes(&std.mem.nativeToLittle(usize, prover_key_index));
    const prover_key_pair = try Bandersnatch.KeyPair.create(prover_seed);

    // Create prover
    var prover = try ring_vrf.RingProver.init(
        prover_key_pair.secret_key.toBytes(),
        &ring,
        prover_key_index,
    );
    defer prover.deinit();

    // Create test input data
    const vrf_input_data = [_]u8{ 't', 'e', 's', 't' };
    const aux_data = [_]u8{ 'd', 'a', 't', 'a' };

    // Generate ring signature
    const ring_signature = try timeFunction(
        "genRingSig",
        ring_vrf.RingProver.sign,
        .{ &prover, &vrf_input_data, &aux_data },
    );

    // Verify ring signature against commitment
    _ = try timeFunction(
        "verifyAgainstCommitment",
        ring_vrf.verifyRingSignatureAgainstCommitment,
        .{
            commitment,
            RING_SIZE,
            &vrf_input_data,
            &aux_data,
            &ring_signature,
        },
    );

    // For comparison, also verify using the verifier
    _ = try timeFunction(
        "verifyWithVerifier",
        ring_vrf.RingVerifier.verify,
        .{
            &verifier,
            &vrf_input_data,
            &aux_data,
            &ring_signature,
        },
    );
}

test "fuzz: takes 10s" {
    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    const RING_SIZE: usize = 10;

    // Generate public keys for the ring
    var ring_keypairs: [RING_SIZE]types.BandersnatchKeyPair = undefined;
    var ring: [RING_SIZE]types.BandersnatchPublic = undefined;
    for (0..RING_SIZE) |i| {
        var seed: [32]u8 = undefined;
        random.bytes(&seed);
        const key_pair = try Bandersnatch.KeyPair.create(&seed);
        ring_keypairs[i] = .{
            .public_key = key_pair.public_key.toBytes(),
            .private_key = key_pair.secret_key.toBytes(),
        };
        ring[i] = key_pair.public_key.toBytes();
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

test "equivalence.paths: Test VRF output equivalence paths" {
    // First, let's set up our test environment with some validators
    const allocator = std.testing.allocator;

    // Create a set of validator keys
    const ring_size: usize = 5;
    var public_keys: [ring_size]types.BandersnatchPublic = undefined;
    var key_pairs: [ring_size]Bandersnatch.KeyPair = undefined;

    // Generate keypairs for all validators
    for (0..ring_size) |i| {
        // Create deterministic seeds for reproducibility
        const seed = std.mem.asBytes(&std.mem.nativeToLittle(usize, i));
        key_pairs[i] = try Bandersnatch.KeyPair.create(seed);
        public_keys[i] = key_pairs[i].public_key.toBytes();
    }

    // Let's say we're validator index 2 and want to create a ticket
    const prover_idx = 2;
    const our_keypair = key_pairs[prover_idx];

    // Create the Ring VRF verifier with all public keys
    var ring_verifier = try ring_vrf.RingVerifier.init(&public_keys);
    defer ring_verifier.deinit();

    // Get the ring commitment (gamma_z)
    //const gamma_z = try ring_verifier.get_commitment();

    // Create our Ring VRF prover
    var ring_prover = try ring_vrf.RingProver.init(our_keypair.secret_key.toBytes(), &public_keys, prover_idx);
    defer ring_prover.deinit();

    // Path 1: Generate VRF output through Ring VRF
    // This is what we do when submitting a ticket
    const ring_vrf_output = ticket_path: {
        std.debug.print("\n=== Path 1: Ring VRF ===\n", .{});

        // Create ticket context as per protocol
        const context = "jam_ticket_seal";
        const eta_3 = [_]u8{0} ** 32; // Mock eta_3 value
        const ticket_attempt: u8 = 1;

        var ticket_context = std.ArrayList(u8).init(allocator);
        defer ticket_context.deinit();
        try ticket_context.appendSlice(context);
        try ticket_context.appendSlice(&eta_3);
        try ticket_context.append(ticket_attempt);

        // Generate Ring VRF signature
        const ring_signature = try ring_prover.sign(&[_]u8{}, // Empty message for VRF
            ticket_context.items);

        std.debug.print("Ring VRF Signature: {x}\n", .{ring_signature});

        // Verify and get VRF output
        const vrf_output = try ring_verifier.verify(&[_]u8{}, ticket_context.items, &ring_signature);

        std.debug.print("Ring VRF output({d}): {x}\n", .{ vrf_output.len, vrf_output });

        break :ticket_path vrf_output;
    };

    // Path 2: Generate VRF output through regular signature
    // This is what happens when we create the block seal
    const fallback_vrf_output = fallback_path: {
        std.debug.print("\n=== Path 2: Regular Signature ===\n", .{});

        // Create the seal signature
        const prefix = "jam_ticket_fallback";
        const eta_3 = [_]u8{0} ** 32; // Mock eta_3 value
        //
        var context = std.ArrayList(u8).init(allocator);
        defer context.deinit();
        try context.appendSlice(prefix);
        try context.appendSlice(&eta_3);

        // Generate VRF signature using our keypair
        const vrf_signature = try our_keypair.sign(&[_]u8{}, context.items);
        const vrf_signature_raw = vrf_signature.toBytes();
        std.debug.print("Fallback VRF Signature({d}): {x}\n", .{ @sizeOf(@TypeOf(vrf_signature_raw)), vrf_signature_raw });

        // Extract VRF output using Y function
        const vrf_output = try vrf_signature.outputHash();
        std.debug.print("Ring VRF output({d}): {x}\n", .{ vrf_output.len, vrf_output });

        // Verify the signature to confirm
        // const _ = try vrf_signature.verify(&unsigned_header, &[_]u8{}, our_keypair.public_key);

        // These should be equal
        break :fallback_path vrf_output;
    };

    try std.testing.expectEqualSlices(u8, &ring_vrf_output, &fallback_vrf_output);
}
