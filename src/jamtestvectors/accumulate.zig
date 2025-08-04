const std = @import("std");
const types = @import("../types.zig");
const jam_types = @import("./jam_types.zig");

pub const jam_params = @import("../jam_params.zig");

pub const BASE_PATH = "src/jamtestvectors/data/stf/accumulate/";

// --------------------------------------------
// -- Accumulation
// --------------------------------------------
pub const ReadyRecord = struct {
    report: types.WorkReport,
    dependencies: []types.WorkPackageHash,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.report.deinit(allocator);
        allocator.free(self.dependencies);
        self.* = undefined;
    }
};

pub const ReadyQueueItem = []ReadyRecord;

pub const ReadyQueue = struct {
    items: []ReadyQueueItem, // SIZE(epoch_length)

    pub fn items_size(params: jam_params.Params) usize {
        return params.epoch_length;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.items) |item| {
            for (item) |*record| {
                record.deinit(allocator);
            }
            allocator.free(item);
        }
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub const AccumulatedQueueItem = []types.WorkPackageHash;

pub const AccumulatedQueue = struct {
    items: []AccumulatedQueueItem, // SIZE(epoch_length)

    pub fn items_size(params: jam_params.Params) usize {
        return params.epoch_length;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.items) |item| {
            allocator.free(item);
        }
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub const AlwaysAccumulateMapItem = struct {
    id: types.ServiceId,
    gas: types.Gas,
};

// TODO: this is introduced by the testvectors this maybe should be removed
// to the jamtestvectors/accumulate as they are tv specific.
pub const Privileges = struct {
    bless: types.ServiceId,
    assign: []types.ServiceId, // Changed to array in v0.6.7
    designate: types.ServiceId,
    always_acc: []AlwaysAccumulateMapItem,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.assign);
        allocator.free(self.always_acc);
        self.* = undefined;
    }
};

pub const AccumulateRoot = types.OpaqueHash;

/// Represents the state for accumulate processing according to the GP
pub const State = struct {
    /// [H_t] Block's timeslot
    slot: types.TimeSlot,
    /// [η] Current entropy
    entropy: types.Entropy,
    /// [θ_r] Ready queue for accumulation
    ready_queue: ReadyQueue,
    /// [θ_a] Accumulated queue
    accumulated: AccumulatedQueue,
    /// [χ] Privileged service identities
    privileges: Privileges,

    statistics: jam_types.ServiceStatistics,

    /// [δ] Service accounts
    accounts: []ServiceAccount,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.ready_queue.deinit(allocator);
        self.accumulated.deinit(allocator);
        self.privileges.deinit(allocator);
        self.statistics.deinit(allocator);
        for (self.accounts) |*account| {
            account.deinit(allocator);
        }
        allocator.free(self.accounts);
        self.* = undefined;
    }
};

pub const ServiceAccount = struct {
    id: types.ServiceId,
    data: Account,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.data.deinit(allocator);
        self.* = undefined;
    }
};

pub const StorageMapEntry = struct {
    key: []u8,
    value: []u8,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
        self.* = undefined;
    }
};

/// ServiceInfo type for test vectors with additional fields
pub const ServiceInfoTestVector = struct {
    code_hash: types.OpaqueHash,
    balance: types.Balance,
    min_item_gas: types.Gas,
    min_memo_gas: types.Gas,
    bytes: types.U64,
    deposit_offset: types.U64,
    items: types.U32,
    creation_slot: types.U32,
    last_accumulation_slot: types.U32,
    parent_service: types.U32,

    pub fn toCore(self: @This()) types.ServiceInfo {
        return .{
            .code_hash = self.code_hash,
            .balance = self.balance,
            .min_item_gas = self.min_item_gas,
            .min_memo_gas = self.min_memo_gas,
            .bytes = self.bytes,
            .items = self.items,
        };
    }
};

pub const Account = struct {
    service: ServiceInfoTestVector,
    storage: []StorageMapEntry,
    preimages: []PreimageEntry,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.preimages) |*entry| {
            entry.deinit(allocator);
        }
        allocator.free(self.preimages);
        for (self.storage) |*entry| {
            entry.deinit(allocator);
        }
        allocator.free(self.storage);
        self.* = undefined;
    }
};

pub const PreimageEntry = struct {
    hash: types.OpaqueHash,
    blob: []u8,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.blob);
        self.* = undefined;
    }
};

pub const Input = struct {
    /// [H_t] Block's timeslot
    slot: types.TimeSlot,
    /// Work reports to accumulate
    reports: []types.WorkReport,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.reports) |*report| {
            report.deinit(allocator);
        }
        allocator.free(self.reports);
        self.* = undefined;
    }
};

pub const Output = union(enum) {
    ok: AccumulateRoot,
    err,

    pub fn deinit(self: *@This(), _: std.mem.Allocator) void {
        self.* = undefined;
    }
};

pub const TestCase = struct {
    input: Input,
    pre_state: State,
    output: Output,
    post_state: State,

    pub fn build_from(
        comptime params: jam_params.Params,
        allocator: std.mem.Allocator,
        bin_file_path: []const u8,
    ) !@This() {
        return try @import("./loader.zig").loadAndDeserializeTestVector(
            TestCase,
            params,
            allocator,
            bin_file_path,
        );
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.input.deinit(allocator);
        self.pre_state.deinit(allocator);
        self.output.deinit(allocator);
        self.post_state.deinit(allocator);
        self.* = undefined;
    }
};

test "tiny_load_and_dump" {
    const allocator = std.testing.allocator;

    const test_jsons: [1][]const u8 = .{
        BASE_PATH ++ "tiny/process_one_immediate_report-1.bin",
    };

    for (test_jsons) |test_json| {
        var test_vector = try TestCase.build_from(
            jam_params.TINY_PARAMS,
            allocator,
            test_json,
        );
        defer test_vector.deinit(allocator);

        std.debug.print("Test vector: {?}\n", .{test_vector.output});
    }
}

test "tiny_all" {
    const allocator = std.testing.allocator;

    const dir = @import("dir.zig");
    var test_vectors = try dir.scan(
        TestCase,
        jam_params.TINY_PARAMS,
        allocator,
        BASE_PATH ++ "tiny/",
    );
    defer test_vectors.deinit();
}

test "full_all" {
    const allocator = std.testing.allocator;

    const dir = @import("dir.zig");
    var test_vectors = try dir.scan(
        TestCase,
        jam_params.FULL_PARAMS,
        allocator,
        BASE_PATH ++ "full/",
    );
    defer test_vectors.deinit();
}
