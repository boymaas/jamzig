const std = @import("std");
const types = @import("types.zig");
const merkle = @import("merkle_binary.zig");

const ServiceId = types.ServiceId;
const Hash = types.Hash;

/// Represents a successful accumulation output from service execution
pub const AccumulationOutput = struct {
    service_id: ServiceId,
    output_hash: Hash,
};

/// Formats a service ID and output hash according to protocol specification
/// Each entry is: E_4(service_id) ⌢ E(hash)
fn formatAccumulationEntry(
    service_id: ServiceId,
    output_hash: Hash,
    buffer: []u8,
) ![]u8 {
    std.mem.writeInt(u32, buffer[0..4], service_id, .little);
    @memcpy(buffer[4..], &output_hash);
    return buffer[0..36]; // 4 bytes service ID + 32 bytes hash
}

/// Calculates the accumulate root from a sequence of successful accumulations
/// Using well-balanced binary Merkle tree with Keccak256 as specified
pub fn calculateAccumulateRoot(
    allocator: std.mem.Allocator,
    outputs: []const AccumulationOutput,
) !Hash {
    if (outputs.len == 0) {
        return std.mem.zeroes(Hash);
    }

    var entries = try allocator.alloc([]u8, outputs.len);
    defer allocator.free(entries);

    var entry_buffers = try allocator.alloc(u8, outputs.len * 36);
    defer allocator.free(entry_buffers);

    for (outputs, 0..) |output, i| {
        const entry_buffer = entry_buffers[i * 36 .. (i + 1) * 36];
        entries[i] = try formatAccumulationEntry(
            output.service_id,
            output.output_hash,
            entry_buffer,
        );
    }

    // Sort entries by service ID as per protocol spec
    std.sort.block([]u8, entries, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            const service_id_a = std.mem.readInt(u32, a[0..4], .little);
            const service_id_b = std.mem.readInt(u32, b[0..4], .little);
            return service_id_a < service_id_b;
        }
    }.lessThan);

    return merkle.M_b(entries, std.crypto.hash.sha3.Keccak256);
}

test "calculateAccumulateRoot empty" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const outputs = [_]AccumulationOutput{};
    const root = try calculateAccumulateRoot(allocator, &outputs);
    try testing.expectEqualSlices(u8, &std.mem.zeroes(Hash), &root);
}

test "calculateAccumulateRoot single output" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const outputs = [_]AccumulationOutput{.{
        .service_id = 1,
        .output_hash = [_]u8{1} ** 32,
    }};
    const root = try calculateAccumulateRoot(allocator, &outputs);
    // Single output should hash E_4(1) ⌢ [1x32]
    var expected: Hash = undefined;
    var hasher = std.crypto.hash.sha3.Keccak256.init(.{});
    var entry: [36]u8 = undefined;
    _ = try formatAccumulationEntry(1, [_]u8{1} ** 32, &entry);
    hasher.update(&entry);
    hasher.final(&expected);
    try testing.expectEqualSlices(u8, &expected, &root);
}

test "calculateAccumulateRoot multiple sorted outputs" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const outputs = [_]AccumulationOutput{
        .{
            .service_id = 2,
            .output_hash = [_]u8{2} ** 32,
        },
        .{
            .service_id = 1,
            .output_hash = [_]u8{1} ** 32,
        },
        .{
            .service_id = 3,
            .output_hash = [_]u8{3} ** 32,
        },
    };
    const root = try calculateAccumulateRoot(allocator, &outputs);
    // Entries will be sorted by service_id before root calculation
    // TODO: Add expected root verification once test vectors are available
    try testing.expect(root.len == 32);
}
