const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const ordered_files = @import("../tests/ordered_files.zig");
const getOrderedFiles = ordered_files.getOrderedFiles;
const hex_bytes = @import("../jamtestvectors/json_types/hex_bytes.zig");

const jam_params = @import("../jam_params.zig");

pub const StateTransitionPair = struct {
    bin: ordered_files.Entry,
    json: ordered_files.Entry,

    pub fn deinit(self: *StateTransitionPair, allocator: Allocator) void {
        self.bin.deinit(allocator);
        self.json.deinit(allocator);
        self.* = undefined;
    }
};

pub const StateTransitions = struct {
    transitions: ArrayList(StateTransitionPair),

    pub fn items(self: *StateTransitions) []StateTransitionPair {
        return self.transitions.items;
    }

    pub fn deinit(self: *StateTransitions, allocator: Allocator) void {
        for (self.transitions.items) |*transition| {
            transition.deinit(allocator);
        }
        self.transitions.deinit();
        self.* = undefined;
    }
};

fn isValidStateTransitionFilename(filename: []const u8) bool {
    if (filename.len < 7) return false;

    const ext_pos = std.mem.indexOf(u8, filename, ".") orelse return false;

    const ext = filename[ext_pos..];
    if (!std.mem.eql(u8, ext, ".bin") and !std.mem.eql(u8, ext, ".json")) return false;

    return true;
}

fn getBaseNameFromEntry(entry: ordered_files.Entry) ![]const u8 {
    const ext_pos = std.mem.indexOf(u8, entry.name, ".") orelse return error.CouldNotExtractBasename;
    return entry.name[0..ext_pos];
}

pub fn collectStateTransitions(state_transitions_path: []const u8, allocator: Allocator) !StateTransitions {
    var files = try getOrderedFiles(allocator, state_transitions_path);
    defer files.deinit();

    var transitions = ArrayList(StateTransitionPair).init(allocator);
    errdefer transitions.deinit();

    var i: usize = 0;
    while (i < files.items().len) : (i += 2) {
        if (i + 1 >= files.items().len) {
            return error.UnpairedFile;
        }

        const bin_file = files.items()[i];
        const json_file = files.items()[i + 1];

        if (!isValidStateTransitionFilename(bin_file.name) or
            !isValidStateTransitionFilename(json_file.name))
        {
            continue;
        }

        const bin_base = try getBaseNameFromEntry(bin_file);
        const json_base = try getBaseNameFromEntry(json_file);

        if (!std.mem.eql(u8, bin_base, json_base)) {
            continue;
        }

        if (!std.mem.endsWith(u8, bin_file.name, ".bin") or
            !std.mem.endsWith(u8, json_file.name, ".json"))
        {
            continue;
        }

        try transitions.append(.{
            .bin = try bin_file.deepClone(allocator),
            .json = try json_file.deepClone(allocator),
        });
    }

    return StateTransitions{
        .transitions = transitions,
    };
}
