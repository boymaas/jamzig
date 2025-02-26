const std = @import("std");
const types = @import("../types.zig");
const jam_params = @import("../jam_params.zig");

const BASE_PATH = "src/jamtestvectors/data/authorizations/";

// O = 8
// Q = 80
// Core const

pub fn State(params: jam_params.Params) type {
    return struct {
        auth_pools: [params.core_count][]types.OpaqueHash,
        auth_queues: [params.core_count][params.max_authorizations_queue_items]types.OpaqueHash,

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            for (self.auth_pools) |pool| {
                allocator.free(pool);
            }
            self.* = undefined;
        }
    };
}

pub const CoreAuthorizer = struct {
    core: types.CoreIndex,
    auth_hash: types.OpaqueHash,

    pub fn deinit(self: *@This(), _: std.mem.Allocator) void {
        self.* = undefined;
    }
};

pub const Input = struct {
    slot: types.TimeSlot,
    auths: []CoreAuthorizer,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.auths);
        self.* = undefined;
    }
};

pub const Output = void;

pub fn TestCase(comptime params: jam_params.Params) type {
    return struct {
        input: Input,
        pre_state: State(params),
        // output: Output,
        post_state: State(params),

        pub fn buildFrom(
            allocator: std.mem.Allocator,
            bin_file_path: []const u8,
        ) !@This() {
            return try @import("./loader.zig").loadAndDeserializeTestVector(
                TestCase(params),
                params,
                allocator,
                bin_file_path,
            );
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.input.deinit(allocator);
            self.pre_state.deinit(allocator);
            self.post_state.deinit(allocator);
            self.* = undefined;
        }
    };
}

test "authorizations:single" {
    const allocator = std.testing.allocator;

    const test_jsons: [1][]const u8 = .{
        BASE_PATH ++ "tiny/progress_authorizations-1.bin",
    };

    for (test_jsons) |test_json| {
        var test_vector = try TestCase(jam_params.TINY_PARAMS).buildFrom(
            allocator,
            test_json,
        );
        defer test_vector.deinit(allocator);

        // std.debug.print("{}", .{types.fmt.format(test_vector)});

    }
}

test "authorizations:tiny" {
    const allocator = std.testing.allocator;

    const dir = @import("dir.zig");
    var test_vectors = try dir.scan(
        TestCase(jam_params.TINY_PARAMS),
        jam_params.TINY_PARAMS,
        allocator,
        BASE_PATH ++ "tiny/",
    );
    defer test_vectors.deinit();
}

test "authorizations:full" {
    const allocator = std.testing.allocator;

    const dir = @import("dir.zig");
    var test_vectors = try dir.scan(
        TestCase(jam_params.FULL_PARAMS),
        jam_params.FULL_PARAMS,
        allocator,
        BASE_PATH ++ "full/",
    );
    defer test_vectors.deinit();
}
