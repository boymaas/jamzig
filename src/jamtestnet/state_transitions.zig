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
    json: ?ordered_files.Entry,

    pub fn deinit(self: *StateTransitionPair, allocator: Allocator) void {
        self.bin.deinit(allocator);
        if (self.json) |*json| {
            json.deinit(allocator);
        }
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

fn isValidStateTransitionBinFile(filename: []const u8) bool {
    // Must end with .bin
    if (!std.mem.endsWith(u8, filename, ".bin")) return false;
    
    // Extract basename (remove .bin)
    const basename = filename[0..filename.len - ".bin".len];
    
    // Must have at least one character in basename
    if (basename.len == 0) return false;
    
    // Must contain only digits and underscores
    for (basename) |c| {
        if (!std.ascii.isDigit(c) and c != '_') {
            return false;
        }
    }
    
    return true;
}

fn createJsonEntryIfExists(allocator: Allocator, dir_path: []const u8, basename: []const u8) !?ordered_files.Entry {
    const json_filename = try std.fmt.allocPrint(allocator, "{s}.json", .{basename});
    defer allocator.free(json_filename);
    
    const json_path = try std.fs.path.join(allocator, &[_][]const u8{
        dir_path,
        json_filename,
    });
    defer allocator.free(json_path);
    
    return if (std.fs.cwd().access(json_path, .{})) |_|
        ordered_files.Entry{
            .name = try allocator.dupe(u8, json_filename),
            .path = try allocator.dupe(u8, json_path),
        }
    else |_|
        null;
}

pub fn collectStateTransitions(state_transitions_path: []const u8, allocator: Allocator) !StateTransitions {
    // Get only valid .bin files
    var bin_files = try ordered_files.getOrderedFilesWithFilter(
        allocator,
        state_transitions_path,
        isValidStateTransitionBinFile,
    );
    defer bin_files.deinit();

    var transitions = ArrayList(StateTransitionPair).init(allocator);
    errdefer {
        for (transitions.items) |*transition| {
            transition.deinit(allocator);
        }
        transitions.deinit();
    }

    // For each valid .bin file, check if corresponding .json exists
    for (bin_files.items()) |bin_file| {
        const basename = bin_file.name[0..bin_file.name.len - ".bin".len]; // Remove .bin
        const json_entry = try createJsonEntryIfExists(allocator, state_transitions_path, basename);
        
        try transitions.append(.{
            .bin = try bin_file.deepClone(allocator),
            .json = json_entry,
        });
    }

    return StateTransitions{
        .transitions = transitions,
    };
}
