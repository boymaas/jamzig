const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

pub const BASE_PATH = "src/jamtestvectors/pulls/pvm/pvm/programs/";

pub const PageMap = struct {
    address: u32,
    length: u32,
    @"is-writable": bool,
};

pub const MemoryChunk = struct {
    address: u32,
    contents: []u8,
};

pub const Status = enum {
    panic,
    halt,
    @"page-fault",
};

pub const PVMTestVector = struct {
    name: []u8,
    @"initial-regs": [13]u64,
    @"initial-pc": u32,
    @"initial-page-map": []PageMap,
    @"initial-memory": []MemoryChunk,
    @"initial-gas": i64,
    program: []u8,
    @"expected-status": Status,
    @"expected-regs": [13]u64,
    @"expected-pc": u32,
    @"expected-memory": []MemoryChunk,
    @"expected-gas": i64,
    @"expected-page-fault-address": ?u32 = null,

    pub fn build_from(
        allocator: Allocator,
        file_path: []const u8,
    ) !json.Parsed(PVMTestVector) {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const json_buffer = try file.readToEndAlloc(allocator, 5 * 1024 * 1024);
        defer allocator.free(json_buffer);

        var diagnostics = std.json.Diagnostics{};
        var scanner = std.json.Scanner.initCompleteInput(allocator, json_buffer);
        scanner.enableDiagnostics(&diagnostics);
        defer scanner.deinit();

        const expected = std.json.parseFromTokenSource(
            PVMTestVector,
            allocator,
            &scanner,
            .{
                .ignore_unknown_fields = true,
                .parse_numbers = false,
            },
        ) catch |err| {
            std.debug.print("Could not parse PVMTestVector [{s}]: {}\n{any}", .{ file_path, err, diagnostics });
            return err;
        };

        return expected;
    }
};

test "pvm: parsing the inst_add test vector" {
    const allocator = std.testing.allocator;
    const vector = try PVMTestVector.build_from(allocator, BASE_PATH ++ "inst_add_32.json");
    defer vector.deinit();

    try std.testing.expectEqualStrings("inst_add_32", vector.value.name);
    try std.testing.expectEqual(@as(u32, 0), vector.value.@"initial-pc");
    try std.testing.expectEqual(@as(i64, 10000), vector.value.@"initial-gas");
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 3, 190, 135, 9, 1 }, vector.value.program);
    try std.testing.expectEqual(@as(u32, 3), vector.value.@"expected-pc");
    try std.testing.expectEqual(@as(i64, 9998), vector.value.@"expected-gas");
}
