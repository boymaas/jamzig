const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

/// Basic erasure coding test vector
pub const ECTestVector = struct {
    data: []u8,
    chunks: [][]u8,

    pub fn build_from(
        allocator: Allocator,
        file_path: []const u8,
    ) !json.Parsed(ECTestVector) {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();
        const json_buffer = try file.readToEndAlloc(allocator, 5 * 1024 * 1024);
        defer allocator.free(json_buffer);

        var diagnostics = std.json.Diagnostics{};
        var scanner = std.json.Scanner.initCompleteInput(allocator, json_buffer);
        scanner.enableDiagnostics(&diagnostics);
        defer scanner.deinit();

        const parsed = std.json.parseFromTokenSource(
            ECTestVector,
            allocator,
            &scanner,
            .{
                .ignore_unknown_fields = true,
                .parse_numbers = false,
            },
        ) catch |err| {
            std.debug.print("Could not parse ECTestVector [{s}]: {}\n{any}", .{ file_path, err, diagnostics });
            return err;
        };
        return parsed;
    }
};

/// Page proof test vector
pub const PageProofTestVector = struct {
    data: []u8,
    page_proofs: [][]u8,
    segments_root: []u8,

    pub fn build_from(
        allocator: Allocator,
        file_path: []const u8,
    ) !json.Parsed(PageProofTestVector) {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();
        const json_buffer = try file.readToEndAlloc(allocator, 5 * 1024 * 1024);
        defer allocator.free(json_buffer);

        var diagnostics = std.json.Diagnostics{};
        var scanner = std.json.Scanner.initCompleteInput(allocator, json_buffer);
        scanner.enableDiagnostics(&diagnostics);
        defer scanner.deinit();

        const parsed = std.json.parseFromTokenSource(
            PageProofTestVector,
            allocator,
            &scanner,
            .{
                .ignore_unknown_fields = true,
                .parse_numbers = false,
            },
        ) catch |err| {
            std.debug.print("Could not parse PageProofTestVector [{s}]: {}\n{any}", .{ file_path, err, diagnostics });
            return err;
        };
        return parsed;
    }
};

/// Segment EC test vector
pub const SegmentECVector = struct {
    pub const Segment = struct {
        segment_ec: [][]u8,
    };

    data: []u8,
    segments: []Segment,
    segments_root: []u8,

    pub fn build_from(
        allocator: Allocator,
        file_path: []const u8,
    ) !json.Parsed(SegmentECVector) {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();
        const json_buffer = try file.readToEndAlloc(allocator, 5 * 1024 * 1024);
        defer allocator.free(json_buffer);

        var diagnostics = std.json.Diagnostics{};
        var scanner = std.json.Scanner.initCompleteInput(allocator, json_buffer);
        scanner.enableDiagnostics(&diagnostics);
        defer scanner.deinit();

        const parsed = std.json.parseFromTokenSource(
            SegmentECVector,
            allocator,
            &scanner,
            .{
                .ignore_unknown_fields = true,
                .parse_numbers = false,
            },
        ) catch |err| {
            std.debug.print("Could not parse SegmentECVector [{s}]: {}\n{any}", .{ file_path, err, diagnostics });
            return err;
        };
        return parsed;
    }
};

/// Segment root test vector
pub const SegmentRootVector = struct {
    data: []u8,
    chunks: [][]u8,
    chunks_root: []u8,

    pub fn build_from(
        allocator: Allocator,
        file_path: []const u8,
    ) !json.Parsed(SegmentRootVector) {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();
        const json_buffer = try file.readToEndAlloc(allocator, 5 * 1024 * 1024);
        defer allocator.free(json_buffer);

        var diagnostics = std.json.Diagnostics{};
        var scanner = std.json.Scanner.initCompleteInput(allocator, json_buffer);
        scanner.enableDiagnostics(&diagnostics);
        defer scanner.deinit();

        const parsed = std.json.parseFromTokenSource(
            SegmentRootVector,
            allocator,
            &scanner,
            .{
                .ignore_unknown_fields = true,
                .parse_numbers = false,
            },
        ) catch |err| {
            std.debug.print("Could not parse SegmentRootVector [{s}]: {}\n{any}", .{ file_path, err, diagnostics });
            return err;
        };
        return parsed;
    }
};

test "ec: parsing basic ec test vector" {
    const allocator = std.testing.allocator;
    const vector = try ECTestVector.build_from(allocator, "src/tests/vectors/erasure_coding/erasure_coding/vectors/ec_1.json");
    defer vector.deinit();

    // Add specific test assertions based on your test vector contents
    try std.testing.expect(vector.value.data.len > 0);
    try std.testing.expect(vector.value.chunks.len > 0);
}

test "ec: parsing page proof test vector" {
    const allocator = std.testing.allocator;
    const vector = try PageProofTestVector.build_from(allocator, "src/tests/vectors/erasure_coding/erasure_coding/vectors/page_proof_32.json");
    defer vector.deinit();

    try std.testing.expect(vector.value.data.len > 0);
    try std.testing.expect(vector.value.page_proofs.len > 0);
    try std.testing.expect(vector.value.segments_root.len > 0);
}

test "ec: parsing segment ec test vector" {
    const allocator = std.testing.allocator;
    const vector = try SegmentECVector.build_from(allocator, "src/tests/vectors/erasure_coding/erasure_coding/vectors/segment_ec_1.json");
    defer vector.deinit();

    try std.testing.expect(vector.value.data.len > 0);
    try std.testing.expect(vector.value.segments.len > 0);
    try std.testing.expect(vector.value.segments_root.len > 0);
}

test "ec: parsing segment root test vector" {
    const allocator = std.testing.allocator;
    const vector = try SegmentRootVector.build_from(allocator, "src/tests/vectors/erasure_coding/erasure_coding/vectors/segment_root_21824.json");
    defer vector.deinit();

    try std.testing.expect(vector.value.data.len > 0);
    try std.testing.expect(vector.value.chunks.len > 0);
    try std.testing.expect(vector.value.chunks_root.len > 0);
}
