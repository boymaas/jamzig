const std = @import("std");
const bls = @import("bls.zig");

// Boneh-Lynn-Shacham (BLS) is a cryptographic signature scheme that allows multiple signatures
// to be aggregated into a single signature. This property makes it particularly useful in blockchain
// systems and other distributed systems where we need to validate multiple signatures efficiently.
// Key features:
// - Signature aggregation: Multiple signatures can be combined into a single signature
// - Short signatures: BLS signatures are very compact
// - Deterministic: Same message and key always produce the same signature
// - Non-interactive: Aggregation doesn't require signers to interact

test "BLS initialization" {
    // BLS requires initialization before any operations can be performed
    // This sets up the BLS curve parameters (BLS12-381)
    try bls.init();
}

test "Secret Key Operations" {
    try bls.init();

    // Test key generation and serialization
    var sk: bls.SecretKey = undefined;
    sk.setByCSPRNG(); // Generate random secret key

    var buf: [128]u8 = undefined;
    const serialized = try sk.serialize(buf[0..]);

    // Test deserialization
    var sk2: bls.SecretKey = undefined;
    try sk2.deserialize(serialized);

    // Verify both keys serialize to same value
    const serialized2 = try sk2.serialize(buf[0..]);
    try std.testing.expectEqualSlices(u8, serialized, serialized2);

    // Test different string representations
    try sk.setStr("123456789", 10); // Base 10
    const str_base10 = try sk.getStr(buf[0..], 10);
    try std.testing.expectEqualStrings("123456789", str_base10);

    // Test endianness conversions
    const test_bytes = [_]u8{ 1, 2, 3, 4, 5 };
    try sk.setLittleEndianMod(&test_bytes);
    try sk.setBigEndianMod(&test_bytes);
}

test "Public Key Operations" {
    try bls.init();

    var sk: bls.SecretKey = undefined;
    var pk: bls.PublicKey = undefined;
    sk.setByCSPRNG();

    // Generate public key from secret key
    sk.getPublicKey(&pk);

    // Test serialization/deserialization
    var buf: [128]u8 = undefined;
    const serialized = try pk.serialize(buf[0..]);

    var pk2: bls.PublicKey = undefined;
    try pk2.deserialize(serialized);

    // Verify both keys serialize to same value
    const serialized2 = try pk2.serialize(buf[0..]);
    try std.testing.expectEqualSlices(u8, serialized, serialized2);
}

test "Basic Signature Operations" {
    try bls.init();

    // Setup keys
    var sk: bls.SecretKey = undefined;
    var pk: bls.PublicKey = undefined;
    sk.setByCSPRNG();
    sk.getPublicKey(&pk);

    const message = "test message";
    var sig: bls.Signature = undefined;

    // Sign and verify
    sk.sign(&sig, message);
    try std.testing.expect(pk.verify(&sig, message));

    // Verify fails with wrong message
    try std.testing.expect(!pk.verify(&sig, "wrong message"));

    // Test signature serialization
    var buf: [128]u8 = undefined;
    const serialized = try sig.serialize(buf[0..]);

    var sig2: bls.Signature = undefined;
    try sig2.deserialize(serialized);

    // Verify deserialized signature still works
    try std.testing.expect(pk.verify(&sig2, message));
}

test "Signature Aggregation" {
    try bls.init();

    const N = 10; // Number of signers
    var sk_vec: [N]bls.SecretKey = undefined;
    var pk_vec: [N]bls.PublicKey = undefined;
    var sig_vec: [N]bls.Signature = undefined;

    // Common message for all signers
    const message = "shared message";

    // Generate keys and signatures
    for (0..N) |i| {
        sk_vec[i].setByCSPRNG();
        sk_vec[i].getPublicKey(&pk_vec[i]);
        sk_vec[i].sign(&sig_vec[i], message);

        // Verify individual signatures
        try std.testing.expect(pk_vec[i].verify(&sig_vec[i], message));
    }

    // Test fast aggregate verification
    var agg_sig: bls.Signature = undefined;
    try agg_sig.aggregate(&sig_vec);

    // Verify aggregated signature
    try std.testing.expect(try agg_sig.fastAggregateVerify(&pk_vec, message));

    // Should fail with subset of public keys
    try std.testing.expect(!try agg_sig.fastAggregateVerify(pk_vec[0 .. N - 1], message));
}

test "Multi-Message Signature Aggregation" {
    try bls.init();

    const N = 5; // Number of signers
    var sk_vec: [N]bls.SecretKey = undefined;
    var pk_vec: [N]bls.PublicKey = undefined;
    var sig_vec: [N]bls.Signature = undefined;
    var msg_vec: [N]bls.Message = undefined;

    // Generate unique messages and signatures
    const msg_prefix = "msg"; // Add a prefix to make messages more distinct
    for (0..N) |i| {
        // Create unique message - ensure full 32 bytes are unique
        @memset(&msg_vec[i], 0);
        @memcpy(msg_vec[i][0..msg_prefix.len], msg_prefix);
        msg_vec[i][msg_prefix.len] = @intCast(i); // Add unique identifier

        // Generate and sign
        sk_vec[i].setByCSPRNG();
        sk_vec[i].getPublicKey(&pk_vec[i]);
        sk_vec[i].sign(&sig_vec[i], &msg_vec[i]);

        // Verify individual signatures
        try std.testing.expect(pk_vec[i].verify(&sig_vec[i], &msg_vec[i]));
    }

    // First verify that messages are actually different
    try std.testing.expect(try bls.areAllMessageDifferent(std.testing.allocator, &msg_vec));

    // Aggregate signatures
    var agg_sig: bls.Signature = undefined;
    try agg_sig.aggregate(&sig_vec);

    // Verify aggregated signature with different messages
    try std.testing.expect(try agg_sig.aggregateVerify(std.testing.allocator, &pk_vec, &msg_vec));

    // Should fail if we modify any message
    const original_byte = msg_vec[0][msg_prefix.len];
    msg_vec[0][msg_prefix.len] = original_byte + 1;
    try std.testing.expect(!try agg_sig.aggregateVerify(std.testing.allocator, &pk_vec, &msg_vec));
}

test "Message Uniqueness Check" {
    // Test edge cases for message uniqueness
    var msg_vec: [258]bls.Message = undefined;

    // Initialize messages to be different
    for (0..msg_vec.len) |i| {
        @memset(&msg_vec[i], 0);
        msg_vec[i][0] = @intCast(i & 255);
    }

    // Test different array sizes
    try std.testing.expect(try bls.areAllMessageDifferent(std.testing.allocator, msg_vec[0..1])); // Single message
    try std.testing.expect(try bls.areAllMessageDifferent(std.testing.allocator, msg_vec[0..100])); // Many different messages
    try std.testing.expect(try bls.areAllMessageDifferent(std.testing.allocator, msg_vec[0..256])); // Max unique messages

    // Test with duplicate messages
    msg_vec[256] = msg_vec[0]; // Create duplicate
    try std.testing.expect(!try bls.areAllMessageDifferent(std.testing.allocator, msg_vec[0..257]));
}
