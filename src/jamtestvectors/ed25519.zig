const std = @import("std");
const testing = std.testing;
const ed25519 = @import("../crypto/ed25519.zig").Ed25519;

/// Test vector from jam-conformance PR #112
/// All vectors should PASS under ZIP-215 compliant verification
const TestVector = struct {
    number: u32,
    desc: []const u8,
    pk: []const u8,
    r: []const u8,
    s: []const u8,
    msg: []const u8,
    pk_canonical: bool,
    r_canonical: bool,
};

fn hexToBytes(comptime len: usize, hex: []const u8) ![len]u8 {
    if (hex.len != len * 2) return error.InvalidHexLength;
    var result: [len]u8 = undefined;
    for (0..len) |i| {
        result[i] = std.fmt.parseInt(u8, hex[i * 2 .. i * 2 + 2], 16) catch return error.InvalidHex;
    }
    return result;
}

// Embed test vectors at compile time from crypto testdata
const json_data = @embedFile("../crypto/testdata/ed25519/vectors.json");

test "ed25519: ZIP-215 compliance test vectors" {
    const allocator = testing.allocator;

    const parsed = try std.json.parseFromSlice([]TestVector, allocator, json_data, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const vectors = parsed.value;

    var passed: usize = 0;
    var failed: usize = 0;

    for (vectors) |vec| {
        // Parse hex values
        const pk_bytes = hexToBytes(32, vec.pk) catch {
            std.debug.print("Vector {d}: Invalid public key hex\n", .{vec.number});
            failed += 1;
            continue;
        };
        const r_bytes = hexToBytes(32, vec.r) catch {
            std.debug.print("Vector {d}: Invalid R hex\n", .{vec.number});
            failed += 1;
            continue;
        };
        const s_bytes = hexToBytes(32, vec.s) catch {
            std.debug.print("Vector {d}: Invalid S hex\n", .{vec.number});
            failed += 1;
            continue;
        };
        const msg_bytes = hexToBytes(5, vec.msg) catch {
            std.debug.print("Vector {d}: Invalid msg hex\n", .{vec.number});
            failed += 1;
            continue;
        };

        // Construct signature: R || S (64 bytes)
        var sig_bytes: [64]u8 = undefined;
        @memcpy(sig_bytes[0..32], &r_bytes);
        @memcpy(sig_bytes[32..64], &s_bytes);

        // Create ed25519 types
        const public_key = ed25519.PublicKey.fromBytes(pk_bytes);
        const signature = ed25519.Signature.fromBytes(sig_bytes);

        // All vectors should PASS under ZIP-215
        // Non-canonical encodings are permitted, s=0 is valid
        const result = signature.verify(&msg_bytes, public_key);

        if (result) |_| {
            passed += 1;
        } else |_| {
            std.debug.print("Vector {d} FAILED: {s}\n", .{ vec.number, vec.desc });
            std.debug.print("  pk_canonical: {}, r_canonical: {}\n", .{ vec.pk_canonical, vec.r_canonical });
            failed += 1;
        }
    }

    std.debug.print("\nZIP-215 Test Results: {d}/{d} passed\n", .{ passed, vectors.len });

    // All vectors must pass for ZIP-215 compliance
    try testing.expectEqual(@as(usize, 0), failed);
    try testing.expectEqual(vectors.len, passed);
}
