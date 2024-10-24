const std = @import("std");
const types = @import("types.zig");
const merkle = @import("merkle.zig");
const jamstate = @import("state.zig");
const state_dictionary = @import("state_dictionary.zig");

pub fn merklizeState(
    allocator: std.mem.Allocator,
    state: *const jamstate.JamState,
) !types.Hash {
    var map = try state_dictionary.buildStateMerklizationDictionary(allocator, state);
    defer map.deinit();

    return try merklizeStateDictionary(allocator, &map);
}

pub fn merklizeStateDictionary(
    allocator: std.mem.Allocator,
    state_dict: *const state_dictionary.MerklizationDictionary,
) !types.Hash {
    const entries = try state_dict.toOwnedSlice();
    defer allocator.free(entries);

    return try merkle.M_sigma(allocator, entries);
}

//  _   _       _ _  _____         _
// | | | |_ __ (_) ||_   _|__  ___| |_
// | | | | '_ \| | __|| |/ _ \/ __| __|
// | |_| | | | | | |_ | |  __/\__ \ |_
//  \___/|_| |_|_|\__||_|\___||___/\__|
//

test "merklizeState" {
    const allocator = std.testing.allocator;

    var state = try jamstate.JamState.init(allocator);
    defer state.deinit(allocator);

    const hash = try merklizeState(allocator, &state);

    std.debug.print("Hash: {s}\n", .{std.fmt.fmtSliceHexLower(&hash)});
}

test "merklizeStateDictionary" {
    const allocator = std.testing.allocator;

    var state = try jamstate.JamState.init(allocator);
    defer state.deinit(allocator);

    var map = try state_dictionary.buildStateMerklizationDictionary(allocator, &state);
    defer map.deinit();

    const hash = try merklizeStateDictionary(allocator, &map);

    std.debug.print("Hash: {s}\n", .{std.fmt.fmtSliceHexLower(&hash)});
}
