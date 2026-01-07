const std = @import("std");
const crypto = std.crypto;
const debug = std.debug;
const fmt = std.fmt;
const mem = std.mem;

extern fn bandersnatch_new_secret(
    seed: [*]const u8,
    seed_len: usize,
    secret_out: [*]u8,
) c_int;

extern fn bandersnatch_derive_public(
    secret: [*]const u8,
    public_out: [*]u8,
) c_int;

extern fn bandersnatch_sign(
    secret: [*]const u8,
    vrf_input_data: [*]const u8,
    vrf_input_len: usize,
    context_data: [*]const u8,
    context_len: usize,
    signature_out: [*]u8,
) c_int;

extern fn bandersnatch_verify(
    public_key: [*]const u8,
    vrf_input_data: [*]const u8,
    vrf_input_len: usize,
    context_data: [*]const u8,
    context_len: usize,
    signature: [*]const u8,
    output_hash_out: [*]u8,
) c_int;

extern fn bandersnatch_output_hash(
    signature: [*]const u8,
    output_hash_out: [*]u8,
) c_int;

pub const Bandersnatch = struct {
    pub const secret_length = 32;
    pub const public_length = 32;
    pub const signature_length = 96;
    pub const output_length = 32;

    pub const Error = error{
        KeyGenerationFailed,
        SigningFailed,
        VerificationFailed,
        InvalidLength,
        OutputHashFailed,
    };

    pub const SecretKey = struct {
        bytes: [secret_length]u8,

        pub fn fromBytes(bytes: [secret_length]u8) SecretKey {
            return SecretKey{ .bytes = bytes };
        }

        pub fn toBytes(sk: SecretKey) [secret_length]u8 {
            return sk.bytes;
        }
    };

    pub const PublicKey = struct {
        bytes: [public_length]u8,

        pub fn fromBytes(bytes: [public_length]u8) PublicKey {
            return PublicKey{ .bytes = bytes };
        }

        pub fn toBytes(pk: PublicKey) [public_length]u8 {
            return pk.bytes;
        }
    };

    pub const Signature = struct {
        bytes: [signature_length]u8,

        pub fn fromBytes(bytes: [signature_length]u8) Signature {
            return Signature{ .bytes = bytes };
        }

        pub fn toBytes(sig: Signature) [signature_length]u8 {
            return sig.bytes;
        }

        pub fn outputHash(sig: Signature) Error![output_length]u8 {
            var output: [output_length]u8 = undefined;
            const rc = bandersnatch_output_hash(
                &sig.bytes,
                &output,
            );
            if (rc != 0) return Error.OutputHashFailed;
            return output;
        }

        pub fn verify(
            sig: Signature,
            msg: []const u8,
            context: []const u8,
            public_key: PublicKey,
        ) Error![output_length]u8 {
            var output: [output_length]u8 = undefined;
            const rc = bandersnatch_verify(
                &public_key.bytes,
                msg.ptr,
                msg.len,
                context.ptr,
                context.len,
                &sig.bytes,
                &output,
            );
            if (rc != 0) return Error.VerificationFailed;
            return output;
        }
    };

    pub const KeyPair = struct {
        public_key: PublicKey,
        secret_key: SecretKey,

        pub fn generateDeterministic(seed: ?[]const u8) Error!KeyPair {
            var secret_bytes: [secret_length]u8 = undefined;
            var public_bytes: [public_length]u8 = undefined;

            if (seed) |s| {
                const rc = bandersnatch_new_secret(
                    s.ptr,
                    s.len,
                    &secret_bytes,
                );
                if (rc != 0) return Error.KeyGenerationFailed;
            } else {
                crypto.random.bytes(&secret_bytes);
                const rc = bandersnatch_new_secret(
                    &secret_bytes,
                    secret_bytes.len,
                    &secret_bytes,
                );
                if (rc != 0) return Error.KeyGenerationFailed;
            }

            const rc = bandersnatch_derive_public(
                &secret_bytes,
                &public_bytes,
            );
            if (rc != 0) return Error.KeyGenerationFailed;

            return KeyPair{
                .secret_key = SecretKey.fromBytes(secret_bytes),
                .public_key = PublicKey.fromBytes(public_bytes),
            };
        }

        pub fn sign(
            key_pair: KeyPair,
            msg: []const u8,
            context: []const u8,
        ) Error!Signature {
            var sig_bytes: [signature_length]u8 = undefined;
            const rc = bandersnatch_sign(
                &key_pair.secret_key.bytes,
                msg.ptr,
                msg.len,
                context.ptr,
                context.len,
                &sig_bytes,
            );
            if (rc != 0) return Error.SigningFailed;
            return Signature.fromBytes(sig_bytes);
        }
    };
};

test "bandersnatch: key pair creation and signing" {
    // Test with fixed seed
    const seed = "test seed for bandersnatch key generation";
    const key_pair = try Bandersnatch.KeyPair.generateDeterministic(seed);

    // Test signing and verification
    const msg = "test message";
    const context = "test context";
    const sig = try key_pair.sign(msg, context);

    // Verify signature
    const vrf_output = try sig.verify(msg, context, key_pair.public_key);

    // Test output hash extraction
    const output_hash = try sig.outputHash();
    try std.testing.expectEqualSlices(u8, &vrf_output, &output_hash);

    // Test random key generation
    const random_key_pair = try Bandersnatch.KeyPair.generateDeterministic(null);
    const random_sig = try random_key_pair.sign(msg, context);
    _ = try random_sig.verify(msg, context, random_key_pair.public_key);
}
