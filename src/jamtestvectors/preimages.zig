const std = @import("std");
const types = @import("../types.zig");
const jam_types = @import("jam_types.zig");

pub const jam_params = @import("../jam_params.zig");

pub const BASE_PATH = "src/jamtestvectors/data/stf/preimages/";

// --------------------------------------------
// -- Preimages
// --------------------------------------------

// PreimagesMapEntry ::= SEQUENCE {
//     hash OpaqueHash,
//     blob ByteSequence
// }
pub const PreimagesMapEntry = struct {
    hash: types.OpaqueHash,
    blob: []u8,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.blob);
        self.* = undefined;
    }
};

// LookupMetaMapKey ::= SEQUENCE {
//     hash OpaqueHash,
//     length U32
// }
pub const LookupMetaMapKey = struct {
    hash: types.OpaqueHash,
    length: types.U32,
};

// LookupMetaMapEntry ::= SEQUENCE {
//     key LookupMetaMapKey,
//     value SEQUENCE OF TimeSlot
// }
pub const LookupMetaMapEntry = struct {
    key: LookupMetaMapKey,
    value: []types.TimeSlot,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.value);
        self.* = undefined;
    }
};

// Account ::= SEQUENCE {
//     -- [a_p] Preimages blobs.
//     preimages SEQUENCE OF PreimagesMapEntry,
//     -- [a_l] Preimages lookup metadata.
//     lookup-meta SEQUENCE OF LookupMetaMapEntry
// }
pub const Account = struct {
    // [a_p] Preimages blobs
    preimages: []PreimagesMapEntry,
    // [a_l] Preimages lookup metadata
    lookup_meta: []LookupMetaMapEntry,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.preimages) |*entry| {
            entry.deinit(allocator);
        }
        allocator.free(self.preimages);

        for (self.lookup_meta) |*entry| {
            entry.deinit(allocator);
        }
        allocator.free(self.lookup_meta);

        self.* = undefined;
    }
};

// AccountsMapEntry ::= SEQUENCE {
//     id ServiceId,
//     data Account
// }
pub const AccountsMapEntry = struct {
    id: types.ServiceId,
    data: Account,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.data.deinit(allocator);
        self.* = undefined;
    }
};

// State ::= SEQUENCE {
//     Relevant services account data [δ]. Refer to T(σ) in GP Appendix D.
//     accounts SEQUENCE OF AccountsMapEntry
// }
pub const State = struct {
    // [δ] Relevant services account data
    accounts: []AccountsMapEntry,
    statistics: jam_types.ServiceStatistics,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.accounts) |*account| {
            account.deinit(allocator);
        }
        allocator.free(self.accounts);
        self.statistics.deinit(allocator);
        self.* = undefined;
    }
};

// Input ::= SEQUENCE {
//     -- [E_P] Preimages extrinsic.
//     preimages PreimagesExtrinsic,
//
//     -- [H_t] Block's timeslot.
//     slot TimeSlot
// }
pub const Input = struct {
    // [E_P] Preimages extrinsic
    preimages: types.PreimagesExtrinsic,
    // [H_t] Block's timeslot
    slot: types.TimeSlot,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.preimages.deinit(allocator);
        self.* = undefined;
    }
};

pub const ErrorCode = enum {
    preimage_unneeded,
    preimages_not_sorted_unique,
};

pub const Output = union(enum) {
    ok: void,
    err: ErrorCode,

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

test "Correct parsing of all tiny test vectors" {
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

test "Correct parsing of all full test vectors" {
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
