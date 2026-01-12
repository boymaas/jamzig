const std = @import("std");
pub const json_types = @import("./json_types/codec.zig");

pub fn CodecTestVector(comptime T: type) type {
    return struct {
        expected: std.json.Parsed(T),
        binary: []u8,

        allocator: std.mem.Allocator,

        pub fn build_from(
            allocator: std.mem.Allocator,
            json_path: []const u8,
        ) !CodecTestVector(T) {
            const file = try std.fs.cwd().openFile(json_path, .{});
            defer file.close();

            const json_buffer = try file.readToEndAlloc(allocator, 5 * 1024 * 1024);
            defer allocator.free(json_buffer);

            var diagnostics = std.json.Diagnostics{};
            var scanner = std.json.Scanner.initCompleteInput(allocator, json_buffer);
            scanner.enableDiagnostics(&diagnostics);
            defer scanner.deinit();

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

        pub fn deinit(self: *@This()) void {
            self.expected.deinit();
            self.allocator.free(self.binary);
            self.* = undefined;
        }
    };
}
