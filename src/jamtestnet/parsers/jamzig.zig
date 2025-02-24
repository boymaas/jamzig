const std = @import("std");
const types = @import("../../types.zig");

pub const state_dictionary = @import("../../state_dictionary.zig");

const Params = @import("../../jam_params.zig").Params;

const MerklizationDictionary = state_dictionary.MerklizationDictionary;

pub const jamzig_state_transition = @import("jamzig/state_transition.zig");
const JamZigStateTransition = jamzig_state_transition.StateTransition;

const parsers = @import("../parsers.zig");

pub fn Loader(comptime params: Params) type {
    return struct {
        const vtable = parsers.Loader.VTable{
            .loadTestVector = loadTestVector,
        };

        pub fn loader(self: *const @This()) parsers.Loader {
            return .{ .ptr = @ptrCast(@constCast(self)), .vtable = &vtable };
        }

        fn loadTestVector(
            _: *anyopaque,
            allocator: std.mem.Allocator,
            file_path: []const u8,
        ) anyerror!parsers.StateTransition {
            const transition = try jamzig_state_transition.loadTestVector(params, allocator, file_path);
            return .{
                .ptr = @ptrCast(try StateTransition.initOnHeap(allocator, transition)),
                .vtable = &StateTransition.VTable,
            };
        }
    };
}

pub const StateTransition = struct {
    state_transition: JamZigStateTransition,

    const Context = @This();

    ///
    pub fn initOnHeap(allocator: std.mem.Allocator, transition: JamZigStateTransition) !*StateTransition {
        const self = try allocator.create(@This());
        self.state_transition = transition;
        return self;
    }

    const VTable = parsers.StateTransition.VTable{
        .preStateAsMerklizationDict = preStateAsMerklizationDict,
        .preStateRoot = preStateRoot,
        .block = block,
        .postStateAsMerklizationDict = postStateAsMerklizationDict,
        .postStateRoot = postStateRoot,
        .validateRoots = validateRoots,
        .deinit = deinit,
    };

    fn preStateAsMerklizationDict(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
    ) anyerror!MerklizationDictionary {
        return try @as(*JamZigStateTransition, @alignCast(@ptrCast(ctx))).preStateAsMerklizationDict(allocator);
    }

    fn preStateRoot(ctx: *anyopaque) types.StateRoot {
        return @as(*JamZigStateTransition, @alignCast(@ptrCast(ctx))).preStateRoot();
    }

    fn block(ctx: *anyopaque) types.Block {
        return @as(*JamZigStateTransition, @alignCast(@ptrCast(ctx))).block;
    }

    fn postStateAsMerklizationDict(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
    ) !MerklizationDictionary {
        return try @as(*JamZigStateTransition, @alignCast(@ptrCast(ctx))).postStateAsMerklizationDict(allocator);
    }

    fn postStateRoot(ctx: *anyopaque) types.StateRoot {
        return @as(*JamZigStateTransition, @alignCast(@ptrCast(ctx))).postStateRoot();
    }

    fn validateRoots(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
    ) !void {
        return @as(*JamZigStateTransition, @alignCast(@ptrCast(ctx))).validateRoots(allocator);
    }

    fn deinit(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
    ) void {
        return @as(*JamZigStateTransition, @alignCast(@ptrCast(ctx))).deinitHeap(allocator);
    }
};
