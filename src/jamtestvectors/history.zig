const std = @import("std");

const types = @import("json_types/types.zig");

pub const HexBytes = types.hex.HexBytes;
pub const HexBytesFixed = types.hex.HexBytesFixed;

pub const Hash = HexBytesFixed(32);
pub const ReportedWorkPackage = struct {
    hash: Hash,
    exports_root: Hash,
};

pub const MmrPeak = Hash;

pub const Mmr = struct {
    peaks: []?MmrPeak,
};

pub const BlockInfo = struct {
    header_hash: Hash,
    mmr: Mmr,
    state_root: Hash,
    reported: []ReportedWorkPackage,
};

pub const State = struct {
    beta: []BlockInfo,
};

pub const Input = struct {
    header_hash: Hash,
    parent_state_root: Hash,
    accumulate_root: Hash,
    work_packages: []ReportedWorkPackage,
};

pub const TestCase = struct {
    input: Input,
    pre_state: State,
    // output: Output, // in this case, the output is always null
    post_state: State,
};

pub const HistoryTestVector = @import("json_types/utils.zig").TestVector;

pub const BASE_PATH = "src/jamtestvectors/data/history/data";

test "history: parsing the test case" {
    const allocator = std.testing.allocator;
    var vector = try HistoryTestVector(TestCase).build_from(allocator, BASE_PATH ++ "/progress_blocks_history-1.json");
    defer vector.deinit();

    // Test if the vector contains the expected data
    var expected_bytes: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected_bytes, "530ef4636fedd498e99c7601581271894a53e965e901e8fa49581e525f165dae");
    try std.testing.expectEqualSlices(
        u8,
        &expected_bytes,
        &vector.expected.value.input.header_hash.bytes,
    );

    // Test if the pre_state is empty
    try std.testing.expectEqual(@as(usize, 0), vector.expected.value.pre_state.beta.len);

    // Test if the post_state contains one block
    try std.testing.expectEqual(@as(usize, 1), vector.expected.value.post_state.beta.len);
}

test "history: parsing all test cases" {
    const allocator = std.testing.allocator;

    var dir = try std.fs.cwd().openDir(BASE_PATH, .{ .iterate = true });
    defer dir.close();

    var dir_iterator = dir.iterate();
    while (try dir_iterator.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        const file_path = try std.fs.path.join(allocator, &[_][]const u8{ BASE_PATH, entry.name });
        defer allocator.free(file_path);

        var vector = try HistoryTestVector(TestCase).build_from(allocator, file_path);
        defer vector.deinit();
    }
}
