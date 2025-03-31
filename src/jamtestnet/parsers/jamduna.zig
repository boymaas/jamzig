const std = @import("std");
const types = @import("../../types.zig");
pub const state_dictionary = @import("../../state_dictionary.zig");
pub const state_transition = @import("jamduna/state_transition.zig");

const codec = @import("../../codec.zig");

const Params = @import("../../jam_params.zig").Params;

const MerklizationDictionary = state_dictionary.MerklizationDictionary;
const TestStateTransition = state_transition.TestStateTransition;

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
            const transition = try state_transition.loadTestVector(params, allocator, file_path);
            return .{
                .ptr = @ptrCast(try StateTransition.initOnHeap(allocator, transition)),
                .vtable = &StateTransition.VTable,
            };
        }
    };
}

pub const StateTransition = struct {
    state_transition: codec.Deserialized(TestStateTransition),

    const Context = @This();

    pub fn initOnHeap(allocator: std.mem.Allocator, transition: codec.Deserialized(TestStateTransition)) !*StateTransition {
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
        return try @as(*StateTransition, @alignCast(@ptrCast(ctx))).state_transition.value.preStateAsMerklizationDict(allocator);
    }

    fn preStateRoot(ctx: *anyopaque) types.StateRoot {
        return @as(*StateTransition, @alignCast(@ptrCast(ctx))).state_transition.value.preStateRoot();
    }

    fn block(ctx: *anyopaque) types.Block {
        return @as(*StateTransition, @alignCast(@ptrCast(ctx))).state_transition.value.block;
    }

    fn postStateAsMerklizationDict(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
    ) !MerklizationDictionary {
        return try @as(*StateTransition, @alignCast(@ptrCast(ctx))).state_transition.value.postStateAsMerklizationDict(allocator);
    }

    fn postStateRoot(ctx: *anyopaque) types.StateRoot {
        return @as(*StateTransition, @alignCast(@ptrCast(ctx))).state_transition.value.postStateRoot();
    }

    fn validateRoots(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
    ) !void {
        return @as(*StateTransition, @alignCast(@ptrCast(ctx))).state_transition.value.validateRoots(allocator);
    }

    fn deinit(
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
    ) void {
        var self = @as(*StateTransition, @alignCast(@ptrCast(ctx)));
        self.state_transition.deinit();
        alloc.destroy(self);
    }
};
