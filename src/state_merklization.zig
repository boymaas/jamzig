const std = @import("std");
const types = @import("types.zig");
const merkle = @import("merkle.zig");
const jamstate = @import("state.zig");
const state_dictionary = @import("state_dictionary.zig");

const Params = @import("jam_params.zig").Params;

pub fn merklizeState(
    comptime params: Params,
    allocator: std.mem.Allocator,
    state: *const jamstate.JamState(params),
) !types.Hash {
    var map = try state_dictionary.buildStateMerklizationDictionary(params, allocator, state);
    defer map.deinit();

    return try merklizeStateDictionary(allocator, &map);
}

pub fn merklizeStateDictionary(
    allocator: std.mem.Allocator,
    state_dict: *const state_dictionary.MerklizationDictionary,
) !types.Hash {
    const entries = try state_dict.toOwnedSlice();
    defer allocator.free(entries);

    return merkle.jamMerkleRoot(entries);
}

test "merklizeState" {
    const allocator = std.testing.allocator;
    const TINY = @import("jam_params.zig").TINY_PARAMS;

    var state = try jamstate.JamState(TINY).init(allocator);
    defer state.deinit(allocator);

    const hash = try merklizeState(TINY, allocator, &state);

    std.debug.print("Hash: {s}\n", .{std.fmt.fmtSliceHexLower(&hash)});
}

test "merklizeStateDictionary" {
    const allocator = std.testing.allocator;
    const TINY = @import("jam_params.zig").TINY_PARAMS;

    var state = try jamstate.JamState(TINY).init(allocator);
    defer state.deinit(allocator);

    var map = try state_dictionary.buildStateMerklizationDictionary(TINY, allocator, &state);
    defer map.deinit();

    const hash = try merklizeStateDictionary(allocator, &map);

    std.debug.print("Hash: {s}\n", .{std.fmt.fmtSliceHexLower(&hash)});
}
