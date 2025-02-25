const std = @import("std");
const json = std.json;
const types = @import("../../../types.zig");

const json_types = @import("../../../jamtestvectors/json_types/codec.zig");
const json_types_safrole = @import("../../../jamtestvectors/json_types/safrole.zig");

// Simple rewrite of domain type to parsable Json type
fn ToJsonType(T: type) type {
    // I want to iterate into this whole type
    // to build an
    switch (@typeInfo(T)) {
        .@"struct" => |i| {
            var n = i;
            n.decls = &[_]std.builtin.Type.Declaration{};
            var idx = 0;
            var buffer: [n.fields.len]std.builtin.Type.StructField = undefined;
            inline while (idx < n.fields.len) : (idx += 1) {
                buffer[idx] = n.fields[idx];
                buffer[idx].type = ToJsonType(n.fields[idx].type);
            }
            n.fields = &buffer;
            return @Type(.{ .@"struct" = n });
        },
        .pointer => |p| {
            switch (p.size) {
                .slice => {
                    // make a HexBytes
                    if (p.child == u8) {
                        return json_types.HexBytes;
                    }
                    var n = p;
                    n.child = ToJsonType(p.child);
                    return @Type(.{ .pointer = n });
                },
                else => {},
            }
            return @Type(.{ .pointer = p });
        },
        .array => |a| {
            if (a.child == u8) {
                return json_types.HexBytesFixed(a.len);
            }
            var n = a;
            n.child = ToJsonType(a.child);

            return @Type(.{ .array = a });
        },
        .@"union" => |u| {
            var n = u;
            n.decls = &[_]std.builtin.Type.Declaration{};
            var idx = 0;
            var buffer: [n.fields.len]std.builtin.Type.UnionField = undefined;
            inline while (idx < n.fields.len) : (idx += 1) {
                buffer[idx] = n.fields[idx];
                buffer[idx].type = ToJsonType(n.fields[idx].type);
            }
            n.fields = &buffer;
            return @Type(.{ .@"union" = n });
        },
        else => |v| {
            return @Type(v);
        },
    }
}

const Allocator = std.mem.Allocator;

pub const GammaS = union(enum) {
    tickets: []types.TicketBody,
    keys: []types.BandersnatchPublic,
};

pub const Psi = struct {
    good: []types.OpaqueHash,
    bad: []types.OpaqueHash,
    wonky: []types.OpaqueHash,
    offenders: []types.OpaqueHash,
};

pub const Eta = [4]json_types.HexBytesFixed(32);

pub const Chi = struct {
    chi_m: u32,
    chi_a: u32,
    chi_v: u32,
    chi_g: struct {}, // FIXME: needs to be able to parse dictionary
};

const StateSnapshot = struct {
    alpha: [][]json_types.HexBytesFixed(32),
    varphi: [][]json_types.HexBytesFixed(32),
    beta: json_types.BlocksHistory,
    gamma: struct {
        gamma_k: []json_types.ValidatorData,
        gamma_z: json_types_safrole.GammaZ,
        gamma_s: json_types_safrole.GammaS,
        gamma_a: ToJsonType(types.GammaA),
    },
    psi: Psi,
    eta: Eta,
    iota: []json_types.ValidatorData,
    kappa: []json_types.ValidatorData,
    lambda: []json_types.ValidatorData,
    rho: []?ToJsonType(types.AvailabilityAssignment),
    tau: u32,
    chi: Chi,
    pi: json_types.Statistics,
    theta: [][]json_types.ReadyRecord,
    xi: [][]json_types.WorkPackageHash,
    accounts: []json_types.Account,
};

test "parseSnapshotJson" {
    const allocator = std.testing.allocator;
    const file = try std.fs.cwd().openFile("src/jamtestnet/teams/jamduna/data/assurances/state_snapshots/1_009.json", .{});
    const contents = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(contents);

    var diagnostics = std.json.Diagnostics{};
    var scanner = std.json.Scanner.initCompleteInput(allocator, contents);
    scanner.enableDiagnostics(&diagnostics);
    defer scanner.deinit();

    const parsed = std.json.parseFromTokenSource(
        StateSnapshot,
        allocator,
        &scanner,
        .{
            .ignore_unknown_fields = true,
            .parse_numbers = false,
        },
    ) catch |err| {
        std.debug.print("Could not parse : {}\n{any}", .{ err, diagnostics });
        return err;
    };

    defer parsed.deinit();

    std.debug.print("{}\n", .{types.fmt.format(parsed.value)});
}
