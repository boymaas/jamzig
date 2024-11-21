const std = @import("std");
const testing = std.testing;
const types = @import("types.zig");
const crypto = @import("crypto.zig");

const Blake2b256 = std.crypto.hash.blake2.Blake2b(256);

/// Error set for VRF operations
pub const VrfError = error{InvalidSignatureLength};

/// Extract VRF proof from signature
pub fn extractProof(signature: *const types.BandersnatchVrfSignature) types.OpaqueHash {
    // Convert first part of signature to OpaqueHash
    return @as(*const types.OpaqueHash, @ptrCast(&signature)).*;
}

/// Generate VRF output from proof using Blake2b
pub fn hashedOutput(proof: types.OpaqueHash) types.OpaqueHash {
    var output: types.OpaqueHash = undefined;
    // Using domain separation prefix for VRF output
    const domain_separator: []const u8 = "$vrf_output";

    var hasher = Blake2b256.init(.{});
    hasher.update(domain_separator);
    hasher.update(proof);
    hasher.final(&output);

    return output;
}

/// Complete process to get VRF output from signature
pub fn getVrfOutput(signature: *const types.BandersnatchVrfSignature) types.BandersnatchVrfOutput {
    const proof = extractProof(signature);
    return hashedOutput(proof);
}

test "VRF signature handling" {
    // Example signature (just for testing)
    var test_signature: types.BandersnatchVrfSignature = undefined;
    @memset(std.mem.asBytes(&test_signature), 0);

    // Test proof extraction
    const proof = extractProof(&test_signature);
    try testing.expectEqual(@TypeOf(proof), types.OpaqueHash);

    // Test VRF output generation
    const output = hashedOutput(proof);
    try testing.expectEqual(@TypeOf(output), types.OpaqueHash);
}

test "VRF output consistency" {
    // Test that same proof produces same output
    var test_proof: types.OpaqueHash = undefined;
    @memset(std.mem.asBytes(&test_proof), 1);

    const output1 = hashedOutput(test_proof);
    const output2 = hashedOutput(test_proof);

    try testing.expectEqual(output1, output2);
}

test "Different proofs yield different outputs" {
    var proof1: types.OpaqueHash = undefined;
    var proof2: types.OpaqueHash = undefined;
    @memset(std.mem.asBytes(&proof1), 1);
    @memset(std.mem.asBytes(&proof2), 2);

    const output1 = hashedOutput(proof1);
    const output2 = hashedOutput(proof2);

    try testing.expect(!std.mem.eql(u8, std.mem.asBytes(&output1), std.mem.asBytes(&output2)));
}

test "Complete VRF process" {
    // Example signature with known components
    var test_signature: types.BandersnatchVrfSignature = undefined;
    @memset(std.mem.asBytes(&test_signature), 0);

    const output = getVrfOutput(&test_signature);
    try testing.expectEqual(@TypeOf(output), types.OpaqueHash);
}
