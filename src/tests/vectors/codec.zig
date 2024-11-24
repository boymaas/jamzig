const std = @import("std");
pub const types = @import("./libs/codec.zig");

pub fn CodecTestVector(comptime T: type) type {
    return struct {
        expected: std.json.Parsed(T),
        binary: []u8,

        allocator: std.mem.Allocator,

        /// Build the vector from the JSON file. The binary is loaded by stripping the JSON
        /// and using the bin extension to load the binary associated as the expected binary format,
        /// to which serialization and deserialization should conform.
        pub fn build_from(
            allocator: std.mem.Allocator,
            json_path: []const u8,
        ) !CodecTestVector(T) {
            const file = try std.fs.cwd().openFile(json_path, .{});
            defer file.close();

            const json_buffer = try file.readToEndAlloc(allocator, 5 * 1024 * 1024);
            defer allocator.free(json_buffer);

            // configure json scanner to track diagnostics for easier debugging
            var diagnostics = std.json.Diagnostics{};
            var scanner = std.json.Scanner.initCompleteInput(allocator, json_buffer);
            scanner.enableDiagnostics(&diagnostics);
            defer scanner.deinit();

            // parse from tokensource using the scanner
            const expected = std.json.parseFromTokenSource(
                T,
                allocator,
                &scanner,
                .{
                    .ignore_unknown_fields = true,
                    .parse_numbers = false,
                },
            ) catch |err| {
                std.debug.print("Could not parse {s} [{s}]: {}\n{any}", .{ @typeName(T), json_path, err, diagnostics });
                return err;
            };
            errdefer expected.deinit();

            // Read the corresponding binary file
            const bin_path = try std.mem.replaceOwned(
                u8,
                allocator,
                json_path,
                ".json",
                ".bin",
            );
            defer allocator.free(bin_path);

            const bin_file = try std.fs.cwd().openFile(bin_path, .{});
            defer bin_file.close();

            const binary = try bin_file.readToEndAlloc(allocator, 5 * 1024 * 1024);

            return .{
                .expected = expected,
                .binary = binary,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: @This()) void {
            self.expected.deinit();
            self.allocator.free(self.binary);
        }
    };
}

test "codec: parsing the block" {
    const allocator = std.heap.page_allocator;
    const vector = try CodecTestVector(types.Block).build_from(allocator, "src/tests/vectors/codec/codec/data/block.json");
    defer vector.deinit();

    // Test if the vector contains the block type
    const parent_value = try std.fmt.allocPrint(allocator, "{}", .{vector.expected.value.header.parent});
    defer allocator.free(parent_value);
    try std.testing.expectEqualStrings(
        "0x5c743dbc514284b2ea57798787c5a155ef9d7ac1e9499ec65910a7a3d65897b7",
        parent_value,
    );

    // Test if the vector contains the binary type
    try std.testing.expectEqual(4907, vector.binary.len);
}
