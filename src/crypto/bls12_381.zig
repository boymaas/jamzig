//! BLS (Boneh-Lynn-Shacham) signatures on BLS12-381 curve
//! This module provides a high-level interface for BLS signatures
//! following patterns similar to the zig standard library's crypto implementations.
const std = @import("std");
const crypto = std.crypto;
const mem = std.mem;
const ffi = @import("ffi/bls.zig");

/// Track if the BLS library has been initialized
var is_initialized: bool = false;

/// Common errors that can occur during BLS operations
pub const Error = error{
    CantInit,
    BufferTooSmall,
    BufferTooLarge,
    InvalidFormat,
    InvalidLength,
    SignatureVerificationFailed,
    WeakPublicKey,
    IdentityElement,
    KeyMismatch,
};

/// BLS signatures on BLS12-381 curve
pub const Bls12_381 = struct {
    /// Initialize the BLS library. Must be called before any other operations.
    pub fn init() !void {
        try ffi.init();
        is_initialized = true;
    }

    /// A BLS12-381 key pair containing both public and secret keys
    pub const KeyPair = struct {
        /// Length (in bytes) of a seed required to create a key pair
        pub const seed_length = 32;

        /// Public part
        public_key: PublicKey,
        /// Secret part
        secret_key: SecretKey,

        /// Create a new key pair from an optional seed
        /// If no seed is provided, random values will be used
        pub fn create(seed: ?[seed_length]u8) !KeyPair {
            std.debug.assert(is_initialized);
            var sk: SecretKey = undefined;
            if (seed) |s| {
                // Use the provided seed for deterministic key generation
                try sk.key.setLittleEndianMod(&s);
            } else {
                // Generate a random key using the library's CSPRNG
                sk.key.setByCSPRNG();
            }
            return KeyPair{
                .secret_key = sk,
                .public_key = sk.getPublicKey(),
            };
        }

        /// Create a key pair from an existing secret key
        pub fn fromSecretKey(secret_key: SecretKey) KeyPair {
            return KeyPair{
                .secret_key = secret_key,
                .public_key = secret_key.getPublicKey(),
            };
        }

        /// Sign a message using this key pair
        pub fn sign(self: KeyPair, msg: []const u8) Signature {
            std.debug.assert(is_initialized);
            var sig: Signature = undefined;
            self.secret_key.key.sign(&sig.sig, msg);
            return sig;
        }
    };

    /// A BLS12-381 signature
    pub const Signature = struct {
        /// Length (in bytes) of a serialized signature
        pub const encoded_length = 96;

        sig: ffi.Signature,

        /// Create a signature from raw bytes
        pub fn fromBytes(bytes: [encoded_length]u8) !Signature {
            std.debug.assert(is_initialized);
            var sig: Signature = undefined;
            try sig.sig.deserialize(&bytes);
            return sig;
        }

        /// Convert the signature to raw bytes
        pub fn toBytes(self: Signature) ![encoded_length]u8 {
            var bytes: [encoded_length]u8 = undefined;
            _ = try self.sig.serialize(&bytes);
            return bytes;
        }

        /// Verify the signature against a message and public key
        pub fn verify(self: Signature, msg: []const u8, public_key: PublicKey) !void {
            std.debug.assert(is_initialized);
            if (!public_key.key.verify(&self.sig, msg)) {
                return error.SignatureVerificationFailed;
            }
        }

        /// Aggregate multiple signatures into a single signature
        pub fn aggregate(signatures: []const Signature) !Signature {
            std.debug.assert(is_initialized);
            var result: Signature = undefined;
            var raw_sigs = try std.ArrayList(ffi.Signature).initCapacity(
                std.heap.page_allocator,
                signatures.len,
            );
            defer raw_sigs.deinit();

            for (signatures) |sig| {
                try raw_sigs.append(sig.sig);
            }

            try result.sig.aggregate(raw_sigs.items);
            return result;
        }

        /// Verify an aggregated signature against multiple public keys and messages
        pub fn aggregateVerify(self: Signature, allocator: std.mem.Allocator, public_keys: []const PublicKey, messages: []const [32]u8) !void {
            if (public_keys.len == 0 or public_keys.len != messages.len) {
                return error.InvalidLength;
            }

            var raw_keys = try std.ArrayList(ffi.PublicKey).initCapacity(
                allocator,
                public_keys.len,
            );
            defer raw_keys.deinit();

            for (public_keys) |pk| {
                try raw_keys.append(pk.key);
            }

            if (!try self.sig.aggregateVerify(allocator, raw_keys.items, messages)) {
                return error.SignatureVerificationFailed;
            }
        }

        /// Fast aggregate verify for a single message signed by multiple public keys
        pub fn fastAggregateVerify(self: Signature, public_keys: []const PublicKey, msg: []const u8) !void {
            var raw_keys = try std.ArrayList(ffi.PublicKey).initCapacity(
                std.heap.page_allocator,
                public_keys.len,
            );
            defer raw_keys.deinit();

            for (public_keys) |pk| {
                try raw_keys.append(pk.key);
            }

            if (!try self.sig.fastAggregateVerify(raw_keys.items, msg)) {
                return error.SignatureVerificationFailed;
            }
        }
    };

    /// A BLS12-381 public key
    pub const PublicKey = struct {
        /// Length (in bytes) of a serialized public key
        pub const encoded_length = 48;

        key: ffi.PublicKey,

        /// Create a public key from raw bytes
        pub fn fromBytes(bytes: [encoded_length]u8) !PublicKey {
            std.debug.assert(is_initialized);
            var pk: PublicKey = undefined;
            try pk.key.deserialize(&bytes);
            return pk;
        }

        /// Convert the public key to raw bytes
        pub fn toBytes(self: PublicKey) ![encoded_length]u8 {
            var bytes: [encoded_length]u8 = undefined;
            _ = try self.key.serialize(&bytes);
            return bytes;
        }

        /// Aggregate multiple public keys into a single key
        pub fn aggregate(self: *PublicKey, other: PublicKey) void {
            std.debug.assert(is_initialized);
            self.key.add(&other.key);
        }
    };

    /// A BLS12-381 secret key
    pub const SecretKey = struct {
        /// Length (in bytes) of a serialized secret key
        pub const encoded_length = 32;

        key: ffi.SecretKey,

        /// Generate a new random secret key
        pub fn create() SecretKey {
            std.debug.assert(is_initialized);
            var sk: SecretKey = undefined;
            sk.key.setByCSPRNG();
            return sk;
        }

        /// Create a secret key from raw bytes
        pub fn fromBytes(bytes: [encoded_length]u8) !SecretKey {
            std.debug.assert(is_initialized);
            var sk: SecretKey = undefined;
            try sk.key.deserialize(&bytes);
            return sk;
        }

        /// Convert the secret key to raw bytes
        pub fn toBytes(self: SecretKey) ![encoded_length]u8 {
            var bytes: [encoded_length]u8 = undefined;
            _ = try self.key.serialize(&bytes);
            return bytes;
        }

        /// Get the public key corresponding to this secret key
        pub fn getPublicKey(self: SecretKey) PublicKey {
            std.debug.assert(is_initialized);
            var pk: PublicKey = undefined;
            self.key.getPublicKey(&pk.key);
            return pk;
        }

        /// Sign a message using this secret key
        pub fn sign(self: SecretKey, msg: []const u8) Signature {
            std.debug.assert(is_initialized);
            var sig: Signature = undefined;
            self.key.sign(&sig.sig, msg);
            return sig;
        }

        /// Aggregate this secret key with another one
        pub fn aggregate(self: *SecretKey, other: SecretKey) void {
            std.debug.assert(is_initialized);
            self.key.add(&other.key);
        }
    };
};
