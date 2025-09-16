const std = @import("std");
const testing = std.testing;
const messages = @import("../messages.zig");
const jam_params = @import("../../jam_params.zig");

const FUZZ_PARAMS = jam_params.TINY_PARAMS;

const V1_EXAMPLES_PATH = "src/jam-conformance/fuzz-proto/examples/v1";

test "v1_conformance_peer_info" {
    const allocator = testing.allocator;

    // Test fuzzer peer_info message
    const fuzzer_bin = try std.fs.cwd().readFileAlloc(allocator, V1_EXAMPLES_PATH ++ "/00000000_fuzzer_peer_info.bin", 1024);
    defer allocator.free(fuzzer_bin);

    var decoded = try messages.decodeMessage(FUZZ_PARAMS, allocator,fuzzer_bin);
    defer decoded.deinit(allocator);

    switch (decoded) {
        .peer_info => |peer_info| {
            try testing.expectEqual(@as(u8, 1), peer_info.fuzz_version);
            try testing.expectEqual(@as(u32, 2), peer_info.fuzz_features);
            try testing.expectEqual(@as(u8, 0), peer_info.jam_version.major);
            try testing.expectEqual(@as(u8, 7), peer_info.jam_version.minor);
            try testing.expectEqual(@as(u8, 0), peer_info.jam_version.patch);
            try testing.expectEqual(@as(u8, 0), peer_info.app_version.major);
            try testing.expectEqual(@as(u8, 1), peer_info.app_version.minor);
            try testing.expectEqual(@as(u8, 25), peer_info.app_version.patch);
            try testing.expectEqualStrings("fuzzer", peer_info.app_name);
        },
        else => try testing.expect(false), // Should be peer_info
    }

    // Test round-trip encoding
    const re_encoded = try messages.encodeMessage(FUZZ_PARAMS, allocator,decoded);
    defer allocator.free(re_encoded);
    try testing.expectEqualSlices(u8, fuzzer_bin, re_encoded);
}

test "v1_conformance_error_messages" {
    const allocator = testing.allocator;

    // Test cases for error messages
    const error_files = [_][]const u8{
        "00000002_target_error.bin",
        "00000006_target_error.bin",
        "00000008_target_error.bin",
        "00000010_target_error.bin",
        "00000012_target_error.bin",
        "00000013_target_error.bin",
        "00000016_target_error.bin",
        "00000020_target_error.bin",
        "00000023_target_error.bin",
        "00000025_target_error.bin",
    };

    for (error_files) |filename| {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ V1_EXAMPLES_PATH, filename });
        defer allocator.free(full_path);
        const bin_data = std.fs.cwd().readFileAlloc(allocator, full_path, 1024) catch |err| {
            std.debug.print("Failed to read {s}: {}\n", .{ full_path, err });
            continue;
        };
        defer allocator.free(bin_data);

        var decoded = messages.decodeMessage(FUZZ_PARAMS, allocator,bin_data) catch |err| {
            std.debug.print("Failed to decode {s}: {}\n", .{ filename, err });
            return err;
        };
        defer decoded.deinit(allocator);

        switch (decoded) {
            .@"error" => |error_msg| {
                try testing.expect(error_msg.len > 0);

                // Test round-trip encoding
                const re_encoded = try messages.encodeMessage(FUZZ_PARAMS, allocator,decoded);
                defer allocator.free(re_encoded);
                try testing.expectEqualSlices(u8, bin_data, re_encoded);
            },
            else => {
                std.debug.print("Expected error message but got: {}\n", .{std.meta.activeTag(decoded)});
                try testing.expect(false);
            },
        }
    }
}

test "v1_conformance_state_root_messages" {
    const allocator = testing.allocator;

    // Test cases for state_root messages
    const state_root_files = [_][]const u8{
        "00000001_target_state_root.bin",
        "00000003_target_state_root.bin",
        "00000004_target_state_root.bin",
        "00000005_target_state_root.bin",
        "00000007_target_state_root.bin",
        "00000009_target_state_root.bin",
        "00000011_target_state_root.bin",
        "00000014_target_state_root.bin",
        "00000015_target_state_root.bin",
        "00000017_target_state_root.bin",
        "00000018_target_state_root.bin",
        "00000019_target_state_root.bin",
        "00000021_target_state_root.bin",
        "00000022_target_state_root.bin",
        "00000024_target_state_root.bin",
        "00000026_target_state_root.bin",
        "00000027_target_state_root.bin",
        "00000028_target_state_root.bin",
        "00000029_target_state_root.bin",
    };

    for (state_root_files) |filename| {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ V1_EXAMPLES_PATH, filename });
        defer allocator.free(full_path);
        const bin_data = std.fs.cwd().readFileAlloc(allocator, full_path, 1024) catch |err| {
            std.debug.print("Failed to read {s}: {}\n", .{ full_path, err });
            continue;
        };
        defer allocator.free(bin_data);

        var decoded = messages.decodeMessage(FUZZ_PARAMS, allocator,bin_data) catch |err| {
            std.debug.print("Failed to decode {s}: {}\n", .{ filename, err });
            return err;
        };
        defer decoded.deinit(allocator);

        switch (decoded) {
            .state_root => |state_root| {
                try testing.expectEqual(@as(usize, 32), state_root.len);

                // Test round-trip encoding
                const re_encoded = try messages.encodeMessage(FUZZ_PARAMS, allocator,decoded);
                defer allocator.free(re_encoded);
                try testing.expectEqualSlices(u8, bin_data, re_encoded);
            },
            else => {
                std.debug.print("Expected state_root message but got: {}\n", .{std.meta.activeTag(decoded)});
                try testing.expect(false);
            },
        }
    }
}

test "v1_conformance_get_state_message" {
    const allocator = testing.allocator;

    const bin_data = try std.fs.cwd().readFileAlloc(allocator, V1_EXAMPLES_PATH ++ "/00000030_fuzzer_get_state.bin", 1024);
    defer allocator.free(bin_data);

    var decoded = try messages.decodeMessage(FUZZ_PARAMS, allocator,bin_data);
    defer decoded.deinit(allocator);

    switch (decoded) {
        .get_state => |get_state| {
            try testing.expectEqual(@as(usize, 32), get_state.len);

            // Test round-trip encoding
            const re_encoded = try messages.encodeMessage(FUZZ_PARAMS, allocator,decoded);
            defer allocator.free(re_encoded);
            try testing.expectEqualSlices(u8, bin_data, re_encoded);
        },
        else => {
            std.debug.print("Expected get_state message but got: {}\n", .{std.meta.activeTag(decoded)});
            try testing.expect(false);
        },
    }
}

// Helper function to test message discriminant and decoding
fn testMessageDiscriminant(
    allocator: std.mem.Allocator,
    filename: []const u8,
    expected_discriminant: u8,
    expected_type: std.meta.Tag(messages.Message),
) !void {
    const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ V1_EXAMPLES_PATH, filename });
    defer allocator.free(full_path);
    const bin_data = try std.fs.cwd().readFileAlloc(allocator, full_path, 1024 * 1024);
    defer allocator.free(bin_data);

    // Check discriminant byte
    try testing.expect(bin_data.len > 0);
    try testing.expectEqual(expected_discriminant, bin_data[0]);

    // Try to decode (this will tell us if our decode logic works)
    var decoded = try messages.decodeMessage(FUZZ_PARAMS, allocator,bin_data);
    defer decoded.deinit(allocator);

    try testing.expectEqual(expected_type, std.meta.activeTag(decoded));
}

test "v1_conformance_discriminant_peer_info" {
    try testMessageDiscriminant(
        testing.allocator,
        "00000000_fuzzer_peer_info.bin",
        0,
        .peer_info,
    );
}

test "v1_conformance_discriminant_initialize" {
    try testMessageDiscriminant(
        testing.allocator,
        "00000001_fuzzer_initialize.bin",
        1,
        .initialize,
    );
}

test "v1_conformance_discriminant_state_root" {
    try testMessageDiscriminant(
        testing.allocator,
        "00000001_target_state_root.bin",
        2,
        .state_root,
    );
}

test "v1_conformance_discriminant_import_block" {
    try testMessageDiscriminant(
        testing.allocator,
        "00000002_fuzzer_import_block.bin",
        3,
        .import_block,
    );
}

test "v1_conformance_discriminant_get_state" {
    try testMessageDiscriminant(
        testing.allocator,
        "00000030_fuzzer_get_state.bin",
        4,
        .get_state,
    );
}

test "v1_conformance_discriminant_state" {
    try testMessageDiscriminant(
        testing.allocator,
        "00000030_target_state.bin",
        5,
        .state,
    );
}

test "v1_conformance_discriminant_error" {
    try testMessageDiscriminant(
        testing.allocator,
        "00000002_target_error.bin",
        255,
        .@"error",
    );
}

