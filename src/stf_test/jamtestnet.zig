const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const ordered_files = @import("../tests/ordered_files.zig");
const getOrderedFiles = ordered_files.getOrderedFiles;
const hex_bytes = @import("../tests/vectors/libs/types/hex_bytes.zig");

pub const OutputFormats = struct {
    bin: ordered_files.Entry,
    json: ordered_files.Entry,

    pub fn deinit(self: *const OutputFormats, allocator: Allocator) void {
        self.bin.deinit(allocator);
        self.json.deinit(allocator);
    }
};

const state_dictionary = @import("../state_dictionary.zig");
const MerklizationDictionary = state_dictionary.MerklizationDictionary;

pub const JamProcessingOutput = struct {
    block: OutputFormats,
    trace: OutputFormats,
    state_snapshot: OutputFormats,

    pub fn parseTraceJson(self: *const JamProcessingOutput, allocator: Allocator) !MerklizationDictionary {
        return loadStateDictionaryDump(allocator, self.trace.json.path);
    }
};

pub const JamOutputs = struct {
    outputs: ArrayList(JamProcessingOutput),

    pub fn items(self: *JamOutputs) []JamProcessingOutput {
        return self.outputs.items;
    }

    pub fn deinit(self: *JamOutputs, allocator: Allocator) void {
        for (self.outputs.items) |output| {
            output.block.deinit(allocator);
            output.trace.deinit(allocator);
            output.state_snapshot.deinit(allocator);
        }
        self.outputs.deinit();
    }
};

fn isValidJamFilename(filename: []const u8) bool {
    // Check minimum length: at least "1_0.bin" (7 chars)
    if (filename.len < 7) return false;

    // Find underscore position
    const underscore_pos = std.mem.indexOf(u8, filename, "_") orelse return false;
    if (underscore_pos == 0) return false;

    // Find extension position
    const ext_pos = std.mem.indexOf(u8, filename, ".") orelse return false;
    if (ext_pos <= underscore_pos + 1) return false;

    // Validate extension
    const ext = filename[ext_pos..];
    if (!std.mem.eql(u8, ext, ".bin") and !std.mem.eql(u8, ext, ".json")) return false;

    // Check if parts before and after underscore are numbers
    const first_num = filename[0..underscore_pos];
    const second_num = filename[underscore_pos + 1 .. ext_pos];

    // Validate each character in the number portions
    for (first_num) |c| {
        if (c < '0' or c > '9') return false;
    }
    for (second_num) |c| {
        if (c < '0' or c > '9') return false;
    }

    return true;
}

// TODO: move this into serparate file, loaders of the dumps
pub fn loadStateDictionaryDump(allocator: Allocator, file_path: []const u8) !MerklizationDictionary {
    const slurp = @import("../utils/slurp.zig");
    // Read the JSON file
    var content = try slurp.slurpFile(allocator, file_path);
    defer content.deinit();

    // Parse JSON
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, content.buffer, .{});
    defer parsed.deinit();

    var dict = MerklizationDictionary.init(allocator);
    errdefer dict.deinit();

    // Extract keyvals array
    const root = parsed.value;
    const keyvals = root.object.get("keyvals").?.array;

    // Process each keyval pair
    for (keyvals.items) |pair| {
        const key = pair.array.items[0].string;
        const value = pair.array.items[1].string;

        // TODO: could be optimized by using fixed
        const key_bytes = try hex_bytes.hexStringToBytes(allocator, key[2..]);
        errdefer allocator.free(key_bytes);

        if (key_bytes.len != 32) {
            std.debug.print("Invalid key length: got {d} bytes, expected 32. Key hex: {s}\n", .{
                key_bytes.len,
                key,
            });
            return error.KeyError;
        }

        var key_array: [32]u8 = undefined;
        @memcpy(&key_array, key_bytes);
        allocator.free(key_bytes);

        // Alloc the value which will be owned by the dict
        const value_bytes = try hex_bytes.hexStringToBytes(allocator, value[2..]);
        try dict.entries.put(key_array, value_bytes);
    }

    return dict;
}

const FilteredFiles = struct {
    entries: ArrayList(ordered_files.Entry),
    allocator: Allocator,

    pub fn init(allocator: Allocator) FilteredFiles {
        return .{
            .entries = ArrayList(ordered_files.Entry).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit_entries(self: *FilteredFiles) void {
        for (self.entries.items) |entry| {
            entry.deinit(self.allocator);
        }
    }

    pub fn deinit(self: *FilteredFiles) void {
        self.entries.deinit();
    }
};

fn filterValidJamFiles(allocator: Allocator, files: []const ordered_files.Entry) !FilteredFiles {
    var filtered = FilteredFiles.init(allocator);
    errdefer filtered.deinit();

    for (files) |file| {
        if (isValidJamFilename(file.name)) {
            try filtered.entries.append(try file.deepClone(allocator));
        }
    }
    return filtered;
}

fn getBaseNameFromEntry(entry: ordered_files.Entry) ![]const u8 {
    const ext_pos = std.mem.indexOf(u8, entry.name, ".") orelse return error.CouldNotExtractBasename;
    return entry.name[0..ext_pos];
}

pub fn collectJamOutputs(base_path: []const u8, allocator: Allocator) !JamOutputs {
    // Get raw files from each directory
    const blocks_path = try std.fs.path.join(allocator, &[_][]const u8{ base_path, "blocks" });
    defer allocator.free(blocks_path);
    var block_files = try getOrderedFiles(allocator, blocks_path);
    defer block_files.deinit();

    const traces_path = try std.fs.path.join(allocator, &[_][]const u8{ base_path, "traces" });
    defer allocator.free(traces_path);
    var trace_files = try getOrderedFiles(allocator, traces_path);
    defer trace_files.deinit();

    const snapshots_path = try std.fs.path.join(allocator, &[_][]const u8{ base_path, "state_snapshots" });
    defer allocator.free(snapshots_path);
    var snapshot_files = try getOrderedFiles(allocator, snapshots_path);
    defer snapshot_files.deinit();

    // Filter to only valid filenames
    // NOTE: we errdefer because on success we moved ownerschip of all items in
    // the filtered_{blocks,traces,snapshots} to the outputs ArrayList
    var filtered_blocks = try filterValidJamFiles(allocator, block_files.items());
    errdefer filtered_blocks.deinit_entries();
    defer filtered_blocks.deinit();

    var filtered_traces = try filterValidJamFiles(allocator, trace_files.items());
    errdefer filtered_traces.deinit_entries();
    defer filtered_traces.deinit();

    var filtered_snapshots = try filterValidJamFiles(allocator, snapshot_files.items());
    errdefer filtered_snapshots.deinit_entries();
    defer filtered_snapshots.deinit();

    // Create map to group bin/json pairs
    var outputs = ArrayList(JamProcessingOutput).init(allocator);
    errdefer {
        outputs.deinit();
    }

    // all the lengts should be the same, otherwise print error on length
    if (!(filtered_blocks.entries.items.len == filtered_traces.entries.items.len and //
        filtered_traces.entries.items.len == filtered_snapshots.entries.items.len))
    {
        std.debug.print("File counts do not match: blocks({d}) traces({d}) snapshots({d})", .{
            filtered_blocks.entries.items.len,
            filtered_traces.entries.items.len,
            filtered_snapshots.entries.items.len,
        });
        return error.FileCountsDoNotMatch;
    }

    const file_count = filtered_blocks.entries.items.len;
    if (file_count % 2 != 0) {
        std.log.err(
            \\Found {d} files, but expected an even number
            \\Each type (blocks/traces/snapshots) should have matching .bin and .json files
        , .{file_count});
        return error.FileCountNotEven;
    }

    // Process block files first to establish the base names we'll look for
    var i: usize = 0;
    while (i < file_count) : (i += 2) {
        const block_bin = filtered_blocks.entries.items[i];
        const block_json = filtered_blocks.entries.items[i + 1];
        const trace_bin = filtered_traces.entries.items[i];
        const trace_json = filtered_traces.entries.items[i + 1];
        const snapshot_bin = filtered_snapshots.entries.items[i];
        const snapshot_json = filtered_snapshots.entries.items[i + 1];

        // Verify they match the same base name
        // Ensure we have a bin/json pair
        const files = [_]ordered_files.Entry{ block_bin, block_json, trace_bin, trace_json, snapshot_bin, snapshot_json };
        var maybe_basename: ?[]const u8 = null;
        for (files) |file| {
            if (maybe_basename) |basename| {
                if (!std.mem.eql(u8, basename, try getBaseNameFromEntry(file))) {
                    std.log.err(
                        \\Basename mismatch in file group:
                        \\  Expected basename: {s}
                        \\  Found different basename in: {s}
                        \\  Full path: {s}
                        \\All files in the group (blocks/traces/snapshots) must share the same basename
                    , .{ basename, file.name, file.path });
                    return error.BasenameMismatch;
                }
            } else {
                maybe_basename = try getBaseNameFromEntry(file);
            }
        }

        // Debug assertions to verify bin/json ordering
        std.debug.assert(std.mem.endsWith(u8, block_bin.name, ".bin"));
        std.debug.assert(std.mem.endsWith(u8, block_json.name, ".json"));
        std.debug.assert(std.mem.endsWith(u8, trace_bin.name, ".bin"));
        std.debug.assert(std.mem.endsWith(u8, trace_json.name, ".json"));
        std.debug.assert(std.mem.endsWith(u8, snapshot_bin.name, ".bin"));
        std.debug.assert(std.mem.endsWith(u8, snapshot_json.name, ".json"));

        // Create output entry
        try outputs.append(.{
            .block = .{
                .bin = block_bin,
                .json = block_json,
            },
            .trace = .{
                .bin = trace_bin,
                .json = trace_json,
            },
            .state_snapshot = .{
                .bin = snapshot_bin,
                .json = snapshot_json,
            },
        });
    }

    return JamOutputs{
        .outputs = outputs,
    };
}

// Test the implementation
test "valid jam filename detection" {
    try std.testing.expect(isValidJamFilename("392934_000.bin"));
    try std.testing.expect(isValidJamFilename("392934_000.json"));
    try std.testing.expect(isValidJamFilename("1_0.bin"));
    try std.testing.expect(!isValidJamFilename("invalid.bin"));
    try std.testing.expect(!isValidJamFilename("123_abc.bin"));
    try std.testing.expect(!isValidJamFilename("123_.bin"));
    try std.testing.expect(!isValidJamFilename("_123.bin"));
    try std.testing.expect(!isValidJamFilename("123_456.txt"));
}
