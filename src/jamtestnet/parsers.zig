const std = @import("std");
const state_dictionary = @import("../state_dictionary.zig");
const types = @import("../types.zig");

pub const state_transitions = @import("state_transitions.zig");

const Params = @import("../jam_params.zig").Params;
const MerklizationDictionary = state_dictionary.MerklizationDictionary;

pub const jamduna =
    @import("parsers/jamduna.zig");

pub const jamzig =
    @import("parsers/jamzig.zig");

pub const w3f =
    @import("parsers/w3f.zig");

pub const Loader = struct {
    const Context = @This();

    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        loadTestVector: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            file_path: []const u8,
        ) anyerror!StateTransition,
    };

    pub fn loadTestVector(self: Context, allocator: std.mem.Allocator, file_path: []const u8) !StateTransition {
        return try self.vtable.loadTestVector(self.ptr, allocator, file_path);
    }
};

pub const StateTransition = struct {
    const Context = @This();

    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        preStateAsMerklizationDict: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
        ) anyerror!MerklizationDictionary,

        preStateRoot: *const fn (ctx: *anyopaque) types.StateRoot,

        postStateAsMerklizationDict: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
        ) anyerror!MerklizationDictionary,

        postStateRoot: *const fn (ctx: *anyopaque) types.StateRoot,

        validateRoots: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
        ) anyerror!void,

        block: *const fn (ctx: *anyopaque) types.Block,

        deinit: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
        ) void,
    };

    pub fn init(pointer: *anyopaque, vtable: *const VTable) @This() {
        return .{
            .ptr = pointer,
            .vtable = vtable,
        };
    }

    pub fn preStateAsMerklizationDict(
        self: Context,
        allocator: std.mem.Allocator,
    ) !MerklizationDictionary {
        return self.vtable.preStateAsMerklizationDict(self.ptr, allocator);
    }

    pub fn postStateAsMerklizationDict(
        self: Context,
        allocator: std.mem.Allocator,
    ) !MerklizationDictionary {
        return self.vtable.postStateAsMerklizationDict(self.ptr, allocator);
    }

    pub fn validateRoots(
        self: Context,
        allocator: std.mem.Allocator,
    ) !void {
        return self.vtable.validateRoots(self.ptr, allocator);
    }

    pub fn preStateRoot(self: Context) types.StateRoot {
        return self.vtable.preStateRoot(self.ptr);
    }
    pub fn block(self: Context) types.Block {
        return self.vtable.block(self.ptr);
    }
    pub fn postStateRoot(self: Context) types.StateRoot {
        return self.vtable.postStateRoot(self.ptr);
    }

    pub fn deinit(
        self: Context,
        allocator: std.mem.Allocator,
    ) void {
        self.vtable.deinit(self.ptr, allocator);
    }
};
