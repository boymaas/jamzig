const std = @import("std");

extern fn ed25519_verify(
    public_key: [*]const u8,
    signature: [*]const u8,
    message: [*]const u8,
    message_len: usize,
) c_int;

// Uses ed25519-consensus (ZIP-215) for deterministic validation across all JAM implementations
pub const Ed25519 = struct {
    pub const public_length = 32;
    pub const signature_length = 64;

    pub const Error = error{
        InvalidSignature,
    };

    pub const PublicKey = struct {
        bytes: [public_length]u8,

        pub fn fromBytes(bytes: [public_length]u8) PublicKey {
            return .{ .bytes = bytes };
        }

        pub fn toBytes(pk: PublicKey) [public_length]u8 {
            return pk.bytes;
        }
    };

    pub const Signature = struct {
        bytes: [signature_length]u8,

        pub fn fromBytes(bytes: [signature_length]u8) Signature {
            return .{ .bytes = bytes };
        }

        pub fn toBytes(sig: Signature) [signature_length]u8 {
            return sig.bytes;
        }

        pub fn verify(sig: Signature, message: []const u8, public_key: PublicKey) Error!void {
            const rc = ed25519_verify(
                &public_key.bytes,
                &sig.bytes,
                message.ptr,
                message.len,
            );
            if (rc != 0) return Error.InvalidSignature;
        }
    };
};

test "ed25519: invalid public key encoding rejected" {
    const invalid_pk = Ed25519.PublicKey.fromBytes([_]u8{0xff} ** 32);
    const signature = Ed25519.Signature.fromBytes([_]u8{0} ** 64);
    const message = "test message";

    const result = signature.verify(message, invalid_pk);
    try std.testing.expectError(Ed25519.Error.InvalidSignature, result);
}

test "ed25519: corrupted signature rejected" {
    const valid_pk = Ed25519.PublicKey.fromBytes(.{
        0xd7, 0x5a, 0x98, 0x01, 0x82, 0xb1, 0x0a, 0xb7,
        0xd5, 0x4b, 0xfe, 0xd3, 0xc9, 0x64, 0x07, 0x3a,
        0x0e, 0xe1, 0x72, 0xf3, 0xda, 0xa6, 0x23, 0x25,
        0xaf, 0x02, 0x1a, 0x68, 0xf7, 0x07, 0x51, 0x1a,
    });

    const bad_sig = Ed25519.Signature.fromBytes([_]u8{0} ** 64);
    const message = "test message";

    const result = bad_sig.verify(message, valid_pk);
    try std.testing.expectError(Ed25519.Error.InvalidSignature, result);
}
