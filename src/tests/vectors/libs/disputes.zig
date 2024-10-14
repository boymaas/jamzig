const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const fmt = std.fmt;
const mem = std.mem;

const types = @import("types.zig");
const HexBytesFixed = types.hex.HexBytesFixed;

pub const WorkReportHash = HexBytesFixed(32);

pub const EpochIndex = u32;
pub const TimeSlot = u32;

pub const Ed25519Key = HexBytesFixed(32);
pub const Ed25519Signature = HexBytesFixed(64);

pub const BlsKey = HexBytesFixed(144);
pub const BandersnatchKey = HexBytesFixed(32);

fn formatHexBytes(writer: anytype, bytes: anytype) !void {
    try fmt.format(writer, "0x{}", .{fmt.fmtSliceHexLower(&bytes)});
}

pub fn formatWorkReportHash(self: WorkReportHash, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
    try formatHexBytes(writer, self);
}

pub fn formatEd25519Key(self: Ed25519Key, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
    try formatHexBytes(writer, self);
}

pub fn formatEd25519Signature(self: Ed25519Signature, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
    try formatHexBytes(writer, self);
}

pub fn formatBlsKey(self: BlsKey, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
    try formatHexBytes(writer, self);
}

pub fn formatBandersnatchKey(self: BandersnatchKey, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
    try formatHexBytes(writer, self);
}

pub const AvailabilityAssignment = struct {
    dummy_work_report: HexBytesFixed(353),
    timeout: u32,

    pub fn format(self: @This(), comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        try fmt.format(writer, "{{ dummy_work_report: 0x{}, timeout: {} }}", .{ fmt.fmtSliceHexLower(self.dummy_work_report.bytes), self.timeout });
    }
};

pub const AvailabilityAssignmentItem = union(enum) {
    none: void,
    some: AvailabilityAssignment,

    pub fn format(self: @This(), comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        switch (self) {
            .none => try writer.writeAll("none"),
            .some => |assignment| try fmt.format(writer, "some({})", .{assignment}),
        }
    }
};

pub const AvailabilityAssignments = []?AvailabilityAssignment;

pub const DisputeJudgement = struct {
    vote: bool,
    index: u16,
    signature: Ed25519Signature,

    pub fn format(self: @This(), comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        try fmt.format(writer, "{{ vote: {}, index: {}, signature: {} }}", .{ self.vote, self.index, self.signature });
    }
};

pub const DisputeVerdict = struct {
    target: WorkReportHash,
    age: EpochIndex,
    votes: []DisputeJudgement,

    pub fn format(self: @This(), comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        try fmt.format(writer, "{{ target: {}, age: {}, votes: [", .{ self.target, self.age });
        for (self.votes, 0..) |vote, i| {
            if (i > 0) try writer.writeAll(", ");
            try fmt.format(writer, "{}", .{vote});
        }
        try writer.writeAll("] }");
    }
};

pub const DisputeCulpritProof = struct {
    target: WorkReportHash,
    key: Ed25519Key,
    signature: Ed25519Signature,

    pub fn format(self: @This(), comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        try fmt.format(writer, "{{ target: {}, key: {}, signature: {} }}", .{ self.target, self.key, self.signature });
    }
};

pub const DisputeFaultProof = struct {
    target: WorkReportHash,
    vote: bool,
    key: Ed25519Key,
    signature: Ed25519Signature,

    pub fn format(self: @This(), comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        try fmt.format(writer, "{{ target: {}, vote: {}, key: {}, signature: {} }}", .{ self.target, self.vote, self.key, self.signature });
    }
};

pub const DisputesXt = struct {
    verdicts: []DisputeVerdict,
    culprits: []DisputeCulpritProof,
    faults: []DisputeFaultProof,

    pub fn format(self: @This(), comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        try writer.writeAll("{\n  verdicts: [");
        for (self.verdicts, 0..) |verdict, i| {
            if (i > 0) try writer.writeAll(",\n    ");
            try fmt.format(writer, "{}", .{verdict});
        }
        try writer.writeAll("],\n  culprits: [");
        for (self.culprits, 0..) |culprit, i| {
            if (i > 0) try writer.writeAll(",\n    ");
            try fmt.format(writer, "{}", .{culprit});
        }
        try writer.writeAll("],\n  faults: [");
        for (self.faults, 0..) |fault, i| {
            if (i > 0) try writer.writeAll(",\n    ");
            try fmt.format(writer, "{}", .{fault});
        }
        try writer.writeAll("]\n}");
    }
};

pub const DisputesOutputMarks = struct {
    offenders_mark: []Ed25519Key,

    pub fn format(self: @This(), comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        try writer.writeAll("{ offenders_mark: [");
        for (self.offenders_mark, 0..) |key, i| {
            if (i > 0) try writer.writeAll(", ");
            try fmt.format(writer, "{}", .{key});
        }
        try writer.writeAll("] }");
    }
};

pub const DisputesRecords = struct {
    psi_g: []WorkReportHash,
    psi_b: []WorkReportHash,
    psi_w: []WorkReportHash,
    psi_o: []Ed25519Key,

    pub fn format(self: @This(), comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        try writer.writeAll("{\n  psi_g: [");
        for (self.psi_g, 0..) |hash, i| {
            if (i > 0) try writer.writeAll(", ");
            try fmt.format(writer, "{}", .{hash});
        }
        try writer.writeAll("],\n  psi_b: [");
        for (self.psi_b, 0..) |hash, i| {
            if (i > 0) try writer.writeAll(", ");
            try fmt.format(writer, "{}", .{hash});
        }
        try writer.writeAll("],\n  psi_w: [");
        for (self.psi_w, 0..) |hash, i| {
            if (i > 0) try writer.writeAll(", ");
            try fmt.format(writer, "{}", .{hash});
        }
        try writer.writeAll("],\n  psi_o: [");
        for (self.psi_o, 0..) |key, i| {
            if (i > 0) try writer.writeAll(", ");
            try fmt.format(writer, "{}", .{key});
        }
        try writer.writeAll("]\n}");
    }
};

pub const ValidatorData = struct {
    bandersnatch: BandersnatchKey,
    ed25519: Ed25519Key,
    bls: BlsKey,
    metadata: HexBytesFixed(128),

    pub fn format(self: @This(), comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        try fmt.format(writer, "{{ bandersnatch: {}, ed25519: {}, bls: {}, metadata: 0x{} }}", .{ self.bandersnatch, self.ed25519, self.bls, fmt.fmtSliceHexLower(self.metadata.bytes) });
    }
};

pub const ValidatorsData = []ValidatorData;

pub const State = struct {
    psi: DisputesRecords,
    rho: AvailabilityAssignments,
    tau: TimeSlot,
    kappa: ValidatorsData,
    lambda: ValidatorsData,

    pub fn format(self: @This(), comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        try fmt.format(writer, "State {{\n  psi: {},\n  rho: [", .{self.psi});
        for (self.rho, 0..) |assignment, i| {
            if (i > 0) try writer.writeAll(", ");
            if (assignment) |a| {
                try fmt.format(writer, "{}", .{a});
            } else {
                try writer.writeAll("null");
            }
        }
        try fmt.format(writer, "],\n  tau: {},\n  kappa: [", .{self.tau});
        for (self.kappa, 0..) |validator, i| {
            if (i > 0) try writer.writeAll(",\n    ");
            try fmt.format(writer, "{}", .{validator});
        }
        try writer.writeAll("],\n  lambda: [");
        for (self.lambda, 0..) |validator, i| {
            if (i > 0) try writer.writeAll(",\n    ");
            try fmt.format(writer, "{}", .{validator});
        }
        try writer.writeAll("]\n}");
    }
};

pub const Input = struct {
    disputes: DisputesXt,

    pub fn format(self: @This(), comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        try fmt.format(writer, "Input {{ disputes: {} }}", .{self.disputes});
    }
};

pub const ErrorCode = enum(u8) {
    already_judged = 0,
    bad_vote_split = 1,
    verdicts_not_sorted_unique = 2,
    judgements_not_sorted_unique = 3,
    culprits_not_sorted_unique = 4,
    faults_not_sorted_unique = 5,
    not_enough_culprits = 6,
    not_enough_faults = 7,
    culprits_verdict_not_bad = 8,
    fault_verdict_wrong = 9,
    offender_already_reported = 10,
    bad_judgement_age = 11,
    bad_validator_index = 12,
    bad_signature = 13,

    pub fn format(self: @This(), comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        try fmt.format(writer, "{s}", .{@tagName(self)});
    }
};

pub const Output = union(enum) {
    ok: DisputesOutputMarks,
    err: ErrorCode,

    pub fn format(self: @This(), comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        switch (self) {
            .ok => |marks| try fmt.format(writer, "ok({})", .{marks}),
            .err => |code| try fmt.format(writer, "err({})", .{code}),
        }
    }
};

pub const TestCase = struct {
    input: Input,
    pre_state: State,
    output: Output,
    post_state: State,
};

pub const TestVector = struct {
    input: Input,
    pre_state: State,
    output: Output,
    post_state: State,

    pub fn build_from(
        allocator: Allocator,
        file_path: []const u8,
    ) !json.Parsed(TestVector) {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const json_buffer = try file.readToEndAlloc(allocator, 5 * 1024 * 1024);
        defer allocator.free(json_buffer);

        // configure json scanner to track diagnostics for easier debugging
        var diagnostics = std.json.Diagnostics{};
        var scanner = std.json.Scanner.initCompleteInput(allocator, json_buffer);
        scanner.enableDiagnostics(&diagnostics);
        defer scanner.deinit();

        // parse from tokensource using the scanner
        return std.json.parseFromTokenSource(
            TestVector,
            allocator,
            &scanner,
            .{
                .ignore_unknown_fields = true,
                .parse_numbers = false,
            },
        ) catch |err| {
            std.debug.print("Could not parse TestVector[{s}]: {}\n{any}", .{ file_path, err, diagnostics });
            return err;
        };
    }
};
