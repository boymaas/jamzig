const std = @import("std");
const types = @import("../../types.zig");
pub const state_dictionary = @import("../../state_dictionary.zig");

const Params = @import("../../jam_params.zig").Params;
const MerklizationDictionary = state_dictionary.MerklizationDictionary;

const parsers = @import("../parsers.zig");

pub const w3f_state_transition = @import("w3f/state_transition.zig");

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
            const transition = try w3f_state_transition.loadTestVector(params, allocator, file_path);
            return .{
                .ptr = @ptrCast(try StateTransition.initOnHeap(allocator, transition)),
                .vtable = &StateTransition.VTable,
            };
        }
    };
}

pub const StateTransition = struct {
    state_transition: w3f_state_transition.StateTransition,

    const Context = @This();

    pub fn initOnHeap(allocator: std.mem.Allocator, transition: w3f_state_transition.StateTransition) !*StateTransition {
        const self = try allocator.create(@This());
        self.state_transition = transition;
        return self;
    }

    const VTable = parsers.StateTransition.VTable{
        .preStateAsMerklizationDict = preStateAsMerklizationDict,
        .preStateRoot = preStateRoot,
        .postStateAsMerklizationDict = postStateAsMerklizationDict,
        .postStateRoot = postStateRoot,
        .validateRoots = validateRoots,
        .block = block,
        .deinit = deinit,
    };

    fn preStateAsMerklizationDict(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!MerklizationDictionary {
        const self: *Context = @ptrCast(@alignCast(ctx));
        return try self.state_transition.preStateAsMerklizationDict(allocator);
    }

    fn preStateRoot(ctx: *anyopaque) types.StateRoot {
        const self: *Context = @ptrCast(@alignCast(ctx));
        return self.state_transition.preStateRoot();
    }

    fn postStateAsMerklizationDict(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!MerklizationDictionary {
        const self: *Context = @ptrCast(@alignCast(ctx));
        return try self.state_transition.postStateAsMerklizationDict(allocator);
    }

    fn postStateRoot(ctx: *anyopaque) types.StateRoot {
        const self: *Context = @ptrCast(@alignCast(ctx));
        return self.state_transition.postStateRoot();
    }

    fn validateRoots(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
        const self: *Context = @ptrCast(@alignCast(ctx));
        return try self.state_transition.validateRoots(allocator);
    }

    fn block(ctx: *anyopaque) types.Block {
        const self: *Context = @ptrCast(@alignCast(ctx));
        return self.state_transition.block;
    }

    fn deinit(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *Context = @ptrCast(@alignCast(ctx));
        self.state_transition.deinit(allocator);
        allocator.destroy(self);
    }
};

