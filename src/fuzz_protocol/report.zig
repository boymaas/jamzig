const std = @import("std");
const messages = @import("messages.zig");
const types = @import("../types.zig");

/// Represents a state root mismatch between local and target
pub const Mismatch = struct {
    block_number: usize,
    block: types.Block,
    local_state_root: messages.StateRootHash,
    target_state_root: messages.StateRootHash,
    target_state: ?messages.State = null,

    /// Clean up allocated state if present
    pub fn deinit(self: *Mismatch, allocator: std.mem.Allocator) void {
        if (self.target_state) |state| {
            for (state) |kv| {
                allocator.free(kv.value);
            }
            allocator.free(state);
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
    allocator: std.mem.Allocator,

    /// Clean up all allocated data
    pub fn deinit(self: *FuzzResult) void {
        if (self.mismatch) |*mismatch| {
            mismatch.deinit(self.allocator);
        }
    }

    /// Check if the fuzzing cycle was successful (no mismatches)
    pub fn isSuccess(self: *const FuzzResult) bool {
        return self.success;
    }
};

/// Generate a detailed report of fuzzing results
pub fn generateReport(allocator: std.mem.Allocator, result: FuzzResult) ![]u8 {
    var report = std.ArrayList(u8).init(allocator);
    defer report.deinit();

    const writer = report.writer();

    // Report header
    try writer.print("JAM Fuzzing Report\n", .{});
    try writer.print("=================\n\n", .{});
    try writer.print("Seed: {d}\n", .{result.seed});
    try writer.print("Blocks Processed: {d}\n", .{result.blocks_processed});
    try writer.print("Success: {}\n", .{result.isSuccess()});
    try writer.print("Mismatches Found: {d}\n\n", .{result.mismatches.len});

    // Reproduction instructions
    try writer.print("Reproduction Instructions:\n", .{});
    try writer.print("-------------------------\n", .{});
    try writer.print("To reproduce this test:\n", .{});
    try writer.print("1. Initialize fuzzer with seed: {d}\n", .{result.seed});
    try writer.print("2. Run fuzzing cycle with {d} blocks\n\n", .{result.blocks_processed});

    // Detailed mismatch information
    if (result.mismatches.len > 0) {
        try writer.print("Detailed Mismatch Analysis:\n", .{});
        try writer.print("---------------------------\n\n", .{});

        for (result.mismatches, 0..) |mismatch, i| {
            try writer.print("Mismatch #{d}:\n", .{i + 1});
            try writer.print("  Block Number: {d}\n", .{mismatch.block_number});
            try writer.print("  Local State Root:  {s}\n", .{std.fmt.fmtSliceHexLower(&mismatch.local_state_root)});
            try writer.print("  Target State Root: {s}\n", .{std.fmt.fmtSliceHexLower(&mismatch.target_state_root)});

            // Block information
            const block_hash = try mismatch.block.header.header_hash(messages.FUZZ_PARAMS, allocator);
            try writer.print("  Block Hash: {s}\n", .{std.fmt.fmtSliceHexLower(&block_hash)});
            try writer.print("  Block Slot: {d}\n", .{mismatch.block.header.slot});

            // State information if available
            if (mismatch.target_state) |state| {
                try writer.print("  Target State Entries: {d}\n", .{state.len});

                // Show first few entries as sample
                const max_entries = @min(5, state.len);
                if (max_entries > 0) {
                    try writer.print("  Sample State Entries:\n", .{});
                    for (state[0..max_entries]) |kv| {
                        try writer.print("    Key: {s}, Value: {d} bytes\n", .{
                            std.fmt.fmtSliceHexLower(&kv.key),
                            kv.value.len,
                        });
                    }
                    if (state.len > max_entries) {
                        try writer.print("    ... and {d} more entries\n", .{state.len - max_entries});
                    }
                }
            }
            try writer.print("\n", .{});
        }
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
        try writer.print("✗ {d} mismatch(es) detected during fuzzing\n", .{result.mismatches.len});
        try writer.print("✗ Target implementation may have conformance issues\n", .{});
        try writer.print("✗ Manual inspection required to determine root cause\n", .{});
        try writer.print("\nRecommendations:\n", .{});
        try writer.print("1. Examine the mismatched blocks against the JAM specification\n", .{});
        try writer.print("2. Compare target state with expected local state\n", .{});
        try writer.print("3. Verify target implementation of state transition logic\n", .{});
        try writer.print("4. Re-run with same seed to confirm reproducibility\n", .{});
    }

    return allocator.dupe(u8, report.items);
}

/// Generate a JSON report for programmatic consumption
pub fn generateJsonReport(allocator: std.mem.Allocator, result: FuzzResult) ![]u8 {
    var json = std.ArrayList(u8).init(allocator);
    defer json.deinit();

    const writer = json.writer();

    try writer.print("{{", .{});
    try writer.print("\"seed\": {d},", .{result.seed});
    try writer.print("\"blocks_processed\": {d},", .{result.blocks_processed});
    try writer.print("\"success\": {},", .{result.isSuccess()});
    try writer.print("\"mismatch_count\": {d},", .{result.mismatches.len});
    try writer.print("\"mismatches\": [", .{});

    for (result.mismatches, 0..) |mismatch, i| {
        if (i > 0) try writer.print(",", .{});
        try writer.print("{{", .{});
        try writer.print("\"block_number\": {d},", .{mismatch.block_number});
        try writer.print("\"local_state_root\": \"{s}\",", .{std.fmt.fmtSliceHexLower(&mismatch.local_state_root)});
        try writer.print("\"target_state_root\": \"{s}\",", .{std.fmt.fmtSliceHexLower(&mismatch.target_state_root)});
        const block_hash = try mismatch.block.header.header_hash(messages.FUZZ_PARAMS, allocator);
        try writer.print("\"block_hash\": \"{s}\",", .{std.fmt.fmtSliceHexLower(&block_hash)});
        try writer.print("\"block_slot\": {d}", .{mismatch.block.header.slot});

        if (mismatch.target_state) |state| {
            try writer.print(",\"target_state_entries\": {d}", .{state.len});
        }

        try writer.print("}}", .{});
    }

    try writer.print("]", .{});
    try writer.print("}}", .{});

    return allocator.dupe(u8, json.items);
}

