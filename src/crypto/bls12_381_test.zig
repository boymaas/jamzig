const std = @import("std");
const testing = std.testing;
const crypto = std.crypto;
const Bls12_381 = @import("bls12_381.zig").Bls12_381;

// Test initialization of the BLS library
test "bls12_381: initialization" {
    try Bls12_381.init();
}

// Test basic key pair generation and serialization
test "bls12_381: key pair creation and serialization" {
    try Bls12_381.init();

    // Create a new random key pair
    const key_pair = Bls12_381.KeyPair.create();

    // Test public key serialization and deserialization
    const pk_bytes = try key_pair.public_key.toBytes();
    // const pk2 = try Bls12_381.PublicKey.fromBytes(pk_bytes);

    // Test secret key serialization and deserialization
    const sk_bytes = try key_pair.secret_key.toBytes();
    const sk2 = try Bls12_381.SecretKey.fromBytes(sk_bytes);

    // Create a key pair from the deserialized secret key
    const key_pair2 = Bls12_381.KeyPair.fromSecretKey(sk2);

    // Verify that both key pairs generate the same public key bytes
    const pk_bytes2 = try key_pair2.public_key.toBytes();
    try testing.expectEqualSlices(u8, &pk_bytes, &pk_bytes2);
}

// Test basic signature creation and verification
test "bls12_381: signature and verification" {
    try Bls12_381.init();

    const key_pair = Bls12_381.KeyPair.create();
    const message = "Hello, BLS!";

    // Sign using the key pair
    const signature = key_pair.sign(message);

    // Test signature serialization and deserialization
    const sig_bytes = try signature.toBytes();
    const signature2 = try Bls12_381.Signature.fromBytes(sig_bytes);

    // Verify the signature using the public key
    try signature2.verify(message, key_pair.public_key);

    // Verify that the signature fails for a different message
    try testing.expectError(error.SignatureVerificationFailed, signature.verify("Different message", key_pair.public_key));
}

// Test signature aggregation with a single message
test "bls12_381: signature aggregation - single message" {
    try Bls12_381.init();

    const message = "Message to be signed by multiple parties";
    var public_keys: [3]Bls12_381.PublicKey = undefined;
    var signatures: [3]Bls12_381.Signature = undefined;

    // Generate multiple key pairs and signatures
    for (0..3) |i| {
        const key_pair = Bls12_381.KeyPair.create();
        public_keys[i] = key_pair.public_key;
        signatures[i] = key_pair.sign(message);
    }

    // Aggregate the signatures
    const aggregated_sig = try Bls12_381.Signature.aggregate(&signatures);

    // Verify the aggregated signature using fast aggregate verify
    try aggregated_sig.fastAggregateVerify(&public_keys, message);

    // Verify that the aggregated signature fails for a different message
    try testing.expectError(error.SignatureVerificationFailed, aggregated_sig.fastAggregateVerify(&public_keys, "Different message"));
}

// Test signature aggregation with multiple messages
test "bls12_381: signature aggregation - multiple messages" {
    try Bls12_381.init();

    const messages = [_][32]u8{
        [_]u8{1} ++ [_]u8{0} ** 31,
        [_]u8{2} ++ [_]u8{0} ** 31,
        [_]u8{3} ++ [_]u8{0} ** 31,
    };

    var public_keys: [3]Bls12_381.PublicKey = undefined;
    var signatures: [3]Bls12_381.Signature = undefined;

    // Generate signatures for different messages
    for (0..3) |i| {
        const key_pair = Bls12_381.KeyPair.create();
        public_keys[i] = key_pair.public_key;
        signatures[i] = key_pair.sign(&messages[i]);
    }

    // Aggregate the signatures
    const aggregated_sig = try Bls12_381.Signature.aggregate(&signatures);

    // Verify the aggregated signature
    try aggregated_sig.aggregateVerify(std.testing.allocator, &public_keys, &messages);

    // Verify that verification fails if we modify a message
    var modified_messages = messages;
    modified_messages[1] = [_]u8{255} ++ [_]u8{0} ** 31;
    try testing.expectError(
        error.SignatureVerificationFailed,
        aggregated_sig.aggregateVerify(
            std.testing.allocator,
            &public_keys,
            &modified_messages,
        ),
    );
}

// Test public key aggregation
test "bls12_381: public key aggregation" {
    try Bls12_381.init();

    var key_pairs: [3]Bls12_381.KeyPair = undefined;
    var aggregated_public_key: Bls12_381.PublicKey = undefined;

    // Generate multiple key pairs
    for (0..3) |i| {
        key_pairs[i] = Bls12_381.KeyPair.create();
        if (i == 0) {
            aggregated_public_key = key_pairs[i].public_key;
        } else {
            aggregated_public_key.aggregate(key_pairs[i].public_key);
        }
    }

    // Sign the same message with all secret keys
    const message = "Message for aggregated public key";
    var aggregated_secret_key = key_pairs[0].secret_key;
    for (key_pairs[1..]) |kp| {
        aggregated_secret_key.aggregate(kp.secret_key);
    }

    // The signature from the aggregated secret key should verify against
    // the aggregated public key
    const signature = aggregated_secret_key.sign(message);
    try signature.verify(message, aggregated_public_key);
}

// Test error cases
test "bls12_381: error cases" {
    try Bls12_381.init();

    // Test invalid signature length
    var invalid_sig_bytes: [Bls12_381.Signature.encoded_length]u8 = undefined;
    @memset(&invalid_sig_bytes, 0);
    try testing.expectError(error.InvalidFormat, Bls12_381.Signature.fromBytes(invalid_sig_bytes));

    // Test invalid public key length
    var invalid_pk_bytes: [Bls12_381.PublicKey.encoded_length]u8 = undefined;
    @memset(&invalid_pk_bytes, 0);
    try testing.expectError(error.InvalidFormat, Bls12_381.PublicKey.fromBytes(invalid_pk_bytes));

    // Test empty public key array for aggregation
    const key_pair = Bls12_381.KeyPair.create();
    const signature = key_pair.sign("test");
    try testing.expectError(error.InvalidLength, signature.fastAggregateVerify(&[_]Bls12_381.PublicKey{}, "test"));

    // Test mismatched lengths in aggregate verify
    const messages = [_][32]u8{
        [_]u8{1} ++ [_]u8{0} ** 31,
        [_]u8{2} ++ [_]u8{0} ** 31,
    };
    const public_keys = [_]Bls12_381.PublicKey{key_pair.public_key};
    try testing.expectError(error.InvalidLength, signature.aggregateVerify(std.testing.allocator, &public_keys, &messages));
}
