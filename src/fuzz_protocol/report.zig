const std = @import("std");
const messages = @import("messages.zig");
const types = @import("../types.zig");
const state_dictionary = @import("../state_dictionary.zig");
const state_converter = @import("state_converter.zig");
const jam_params = @import("../jam_params.zig");

/// Represents a state root mismatch between local and target
pub const Mismatch = struct {
    block_number: usize,
    block: types.Block,
    reported_state_root: messages.StateRootHash,
    local_dict: ?state_dictionary.MerklizationDictionary = null,
    target_dict: ?state_dictionary.MerklizationDictionary = null,
    target_computed_root: ?messages.StateRootHash = null,

    /// Clean up allocated state if present
    pub fn deinit(self: *Mismatch, allocator: std.mem.Allocator) void {
        if (self.local_dict) |*dict| {
            dict.deinit();
        }
        if (self.target_dict) |*dict| {
            dict.deinit();
        }
        self.block.deinit(allocator);
    }
};

/// Result of a fuzzing cycle
pub const FuzzResult = struct {
    seed: u64,
    blocks_processed: usize,
    mismatch: ?Mismatch,
    success: bool,
    err: ?anyerror = null,

    /// Clean up all allocated data
    pub fn deinit(self: *FuzzResult, allocator: std.mem.Allocator) void {
        if (self.mismatch) |*mismatch| {
            mismatch.deinit(allocator);
        }
    }

    /// Check if the fuzzing cycle was successful (no mismatches)
    pub fn isSuccess(self: *const FuzzResult) bool {
        return self.success;
    }
};

/// Generate a detailed report of fuzzing results
pub fn generateReport(comptime params: jam_params.Params, allocator: std.mem.Allocator, result: FuzzResult) ![]u8 {
    var report = std.ArrayList(u8).init(allocator);
    errdefer report.deinit();

    const writer = report.writer();

    // Report header
    try writer.print("JAM Fuzzing Report\n", .{});
    try writer.print("=================\n\n", .{});
    try writer.print("Seed: {d}\n", .{result.seed});
    try writer.print("Blocks Processed: {d}\n", .{result.blocks_processed});
    try writer.print("Success: {}\n", .{result.isSuccess()});
    try writer.print("Mismatches Found: {d}\n", .{if (result.mismatch != null) @as(usize, 1) else @as(usize, 0)});

    // Show error if present
    if (result.err) |err| {
        try writer.print("Error: {s}\n", .{@errorName(err)});
        if (err == error.BrokenPipe or err == error.UnexpectedEndOfStream) {
            try writer.print("(Target appears to have disconnected)\n", .{});
        }
    }
    try writer.print("\n", .{});

    // Reproduction instructions
    try writer.print("Reproduction Instructions:\n", .{});
    try writer.print("-------------------------\n", .{});
    try writer.print("To reproduce this test:\n", .{});
    try writer.print("1. Initialize fuzzer with seed: {d}\n", .{result.seed});
    try writer.print("2. Run fuzzing cycle with {d} blocks\n\n", .{result.blocks_processed});

    // Detailed mismatch information
    if (result.mismatch) |mismatch| {
        try writer.print("Detailed Mismatch Analysis:\n", .{});
        try writer.print("---------------------------\n\n", .{});

        try writer.print("Mismatch Details:\n", .{});
        try writer.print("  Block Number: {d}\n", .{mismatch.block_number});

        // Calculate local state root from dictionary
        if (mismatch.local_dict) |*local_dict| {
            const local_root = try local_dict.buildStateRoot(allocator);
            try writer.print("  Local State Root:  {s}\n", .{std.fmt.fmtSliceHexLower(&local_root)});
        } else {
            try writer.print("  Local State Root:  <unavailable>\n", .{});
        }

        try writer.print("  Reported State Root: {s}\n", .{std.fmt.fmtSliceHexLower(&mismatch.reported_state_root)});

        // Block information
        const block_hash = try mismatch.block.header.header_hash(params, allocator);
        try writer.print("  Block Hash: {s}\n", .{std.fmt.fmtSliceHexLower(&block_hash)});
        try writer.print("  Block Slot: {d}\n", .{mismatch.block.header.slot});

        // Compute and show state diff if both dictionaries are available
        if (mismatch.local_dict != null and mismatch.target_dict != null) {
            const local_dict = mismatch.local_dict.?;
            const target_dict = mismatch.target_dict.?;

            try writer.print("\n  State Comparison:\n", .{});

            // Calculate and show expected root
            const local_root = try local_dict.buildStateRoot(allocator);
            try writer.print("  Expected Root: {s}\n", .{std.fmt.fmtSliceHexLower(&local_root)});

            try writer.print("  Target Reported Root: {s}\n", .{std.fmt.fmtSliceHexLower(&mismatch.reported_state_root)});

            // Check if target state verification failed
            const computed_target_root = try target_dict.buildStateRoot(allocator);
            if (!std.mem.eql(
                u8,
                &computed_target_root,
                &mismatch.reported_state_root,
            )) {
                try writer.print("\n  🚨 CRITICAL ERROR: Target state verification failed!\n", .{});
                try writer.print("  The target's provided state does not produce its claimed reported root.\n", .{});

                try writer.print("  Target's state actually produces: {s}\n", .{std.fmt.fmtSliceHexLower(&computed_target_root)});
            }

            // Compute diff directly from dictionaries
            var dict_diff = try mismatch.local_dict.?.diff(&mismatch.target_dict.?);
            defer dict_diff.deinit();

            if (dict_diff.has_changes()) {
                try writer.print("\n  State Differences:\n", .{});
                try writer.print("{}", .{dict_diff});
            } else {
                try writer.print("\n  ⚠️  States appear identical but roots differ!\n", .{});
                try writer.print("  This may indicate a merklization issue.\n", .{});
            }
        } else if (mismatch.target_dict) |*target_dict| {
            // Fallback to showing target dictionary info if we only have that
            const kv_array = try target_dict.toKeyValueArray();
            defer allocator.free(kv_array);

            try writer.print("  Target State Entries: {d}\n", .{kv_array.len});

            // Show first few entries as sample
            const max_entries = @min(5, kv_array.len);
            if (max_entries > 0) {
                try writer.print("  Sample State Entries:\n", .{});
                for (kv_array[0..max_entries]) |kv| {
                    try writer.print("    Key: {s}, Value: {d} bytes\n", .{
                        std.fmt.fmtSliceHexLower(&kv.key),
                        kv.value.len,
                    });
                }
                if (kv_array.len > max_entries) {
                    try writer.print("    ... and {d} more entries\n", .{kv_array.len - max_entries});
                }
            }
        }
        try writer.print("\n", .{});
    } else {
        try writer.print("No mismatches found - all state roots matched!\n\n", .{});
    }

    // Summary and recommendations
    try writer.print("Summary:\n", .{});
    try writer.print("--------\n", .{});
    if (result.isSuccess()) {
        try writer.print("✓ All {d} blocks processed successfully\n", .{result.blocks_processed});
        try writer.print("✓ All state roots matched between local and target\n", .{});
        try writer.print("✓ Target implementation appears to be conformant for this test\n", .{});
    } else {
        if (result.err) |err| {
            try writer.print("✗ Error occurred during testing: {s}\n", .{@errorName(err)});
            try writer.print("✗ Testing stopped at block {d}\n", .{result.blocks_processed});
            if (err == error.BrokenPipe or err == error.UnexpectedEndOfStream) {
                try writer.print("✗ Target connection was lost\n", .{});
            }
        } else if (result.mismatch != null) {
            try writer.print("✗ 1 mismatch detected during fuzzing\n", .{});
            try writer.print("✗ Target implementation may have conformance issues\n", .{});
            try writer.print("✗ Manual inspection required to determine root cause\n", .{});
        }
        try writer.print("\nRecommendations:\n", .{});
        if (result.err) |_| {
            try writer.print("1. Check that the target is still running\n", .{});
            try writer.print("2. Verify network connectivity\n", .{});
            try writer.print("3. Re-run the test to see if error persists\n", .{});
        } else {
            try writer.print("1. Examine the mismatched blocks against the JAM specification\n", .{});
            try writer.print("2. Compare target state with expected local state\n", .{});
            try writer.print("3. Verify target implementation of state transition logic\n", .{});
            try writer.print("4. Re-run with same seed to confirm reproducibility\n", .{});
        }
    }

    return report.items;
}

/// Generate a JSON report for programmatic consumption
pub fn generateJsonReport(allocator: std.mem.Allocator, result: FuzzResult) ![]u8 {
    var json = std.ArrayList(u8).init(allocator);
    errdefer json.deinit();

    const writer = json.writer();

    try writer.print("{{", .{});
    try writer.print("\"seed\": {d},", .{result.seed});
    try writer.print("\"blocks_processed\": {d},", .{result.blocks_processed});
    try writer.print("\"success\": {},", .{result.isSuccess()});

    if (result.err) |err| {
        try writer.print("\"error\": \"{s}\",", .{@errorName(err)});
    }

    if (result.mismatch) |mismatch| {
        try writer.print("\"mismatch\": {{", .{});
        try writer.print("\"block_number\": {d},", .{mismatch.block_number});

        // Calculate and include local state root
        if (mismatch.local_dict) |*local_dict| {
            const local_root = try local_dict.buildStateRoot(allocator);
            try writer.print("\"local_state_root\": \"{s}\",", .{std.fmt.fmtSliceHexLower(&local_root)});
        }

        try writer.print("\"reported_state_root\": \"{s}\",", .{std.fmt.fmtSliceHexLower(&mismatch.reported_state_root)});
        const block_hash = try mismatch.block.header.header_hash(messages.FUZZ_PARAMS, allocator);
        try writer.print("\"block_hash\": \"{s}\",", .{std.fmt.fmtSliceHexLower(&block_hash)});
        try writer.print("\"block_slot\": {d}", .{mismatch.block.header.slot});

        if (mismatch.target_dict) |*target_dict| {
            const kv_array = try target_dict.toKeyValueArray();
            defer allocator.free(kv_array);
            try writer.print(",\"target_state_entries\": {d}", .{kv_array.len});
        }

        try writer.print("}}", .{});
    } else {
        try writer.print("\"mismatch\": null", .{});
    }

    try writer.print("}}", .{});

    return json.items;
}
