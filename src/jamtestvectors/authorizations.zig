const std = @import("std");
const types = @import("../types.zig");
const jam_params = @import("../jam_params.zig");

const BASE_PATH = "src/jamtestvectors/data/stf/authorizations/";

pub const AuthPool = struct {
    items: []types.OpaqueHash,

    pub fn init() AuthPool {
        const empty_items = &[_]types.OpaqueHash{};
        return AuthPool{ .items = empty_items };
    }

    pub fn deinit(self: *AuthPool, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub const AuthQueue = struct {
    items: []types.OpaqueHash,

    pub fn items_size(params: jam_params.Params) usize {
        return params.max_authorizations_queue_items;
    }

    pub fn init() AuthQueue {
        const empty_items = &[_]types.OpaqueHash{};
        return AuthQueue{ .items = empty_items };
    }

    pub fn deinit(self: *AuthQueue, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub fn State(params: jam_params.Params) type {
    return struct {
        auth_pools: [params.core_count]AuthPool,
        auth_queues: [params.core_count]AuthQueue,

        pub fn init() !@This() {
            const state: @This() = undefined;

            for (state.auth_pools) |*pool| {
                pool.* = AuthPool.init();
            }

            for (state.auth_queues) |*queue| {
                queue.* = AuthQueue.init();
            }

            return state;
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            for (&self.auth_pools) |*pool| {
                pool.deinit(allocator);
            }
            for (&self.auth_queues) |*queue| {
                queue.deinit(allocator);
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
        post_state: State(params),

        pub fn init(allocator: std.mem.Allocator) !@This() {
            return .{
                .input = .{
                    .slot = 0,
                    .auths = &[_]CoreAuthorizer{},
                },
                .pre_state = try State(params).init(allocator),
                .post_state = try State(params).init(allocator),
            };
        }

        pub fn buildFrom(
            allocator: std.mem.Allocator,
            bin_file_path: []const u8,
        ) !@This() {
            const test_case = try @import("./loader.zig").loadAndDeserializeTestVector(
                TestCase(params),
                params,
                allocator,
                bin_file_path,
            );

            return test_case;
        }

        pub fn debugInput(self: *const @This()) void {
            std.debug.print("{}\n", .{types.fmt.format(self.input)});
        }

        pub fn debugPrintStateDiff(self: *@This(), alloc: std.mem.Allocator) !void {
            try @import("../tests/diff.zig").printDiffBasedOnFormatToStdErr(
                alloc,
                types.fmt.format(self.pre_state),
                types.fmt.format(self.post_state),
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
        // BASE_PATH ++ "tiny/progress_authorizations-2.bin",
        // BASE_PATH ++ "tiny/progress_authorizations-3.bin",
    };

    for (test_jsons) |test_json| {
        var test_vector = try TestCase(jam_params.TINY_PARAMS).buildFrom(
            allocator,
            test_json,
        );
        defer test_vector.deinit(allocator);

        std.debug.print("{}", .{types.fmt.format(test_vector.input)});
        try test_vector.debugPrintStateDiff(allocator);
    }
}

test "authorizations_vector:tiny" {
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

test "authorizations_vector:full" {
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
