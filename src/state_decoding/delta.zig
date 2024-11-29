const std = @import("std");
const testing = std.testing;
const services = @import("../services.zig");
const Delta = services.Delta;
const ServiceAccount = services.ServiceAccount;
const PreimageLookup = services.PreimageLookup;
const PreimageLookupKey = services.PreimageLookupKey;
const decoder = @import("../codec/decoder.zig");

pub fn decode(allocator: std.mem.Allocator, reader: anytype) !Delta {
    _ = allocator;
    _ = reader;
    @panic("decode: not yet implemented");
}

test "decode delta - empty state" {}

test "decode delta - single account" {}

test "decode delta - account with storage and preimages" {}

test "decode delta - roundtrip" {}
