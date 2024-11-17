const std = @import("std");
const testing = std.testing;

const stf = @import("stf.zig");
const types = @import("types.zig");
const state = @import("state.zig");
const codec = @import("codec.zig");

const ordered_files = @import("tests/ordered_files.zig");

const TINY_PARAMS = @import("jam_params.zig").TINY_PARAMS;

const SlurpedFile = struct {
    allocator: std.mem.Allocator,
    buffer: []const u8,

    pub fn deinit(self: *SlurpedFile) void {
        self.allocator.free(self.buffer);
    }
};

fn slurpBin(allocator: std.mem.Allocator, path: []const u8) !SlurpedFile {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const buffer = try file.readToEndAlloc(allocator, std.math.maxInt(usize));

    return SlurpedFile{
        .allocator = allocator,
        .buffer = buffer,
    };
}

test "jamtestnet: block import" {
    // Get test allocator
    const allocator = testing.allocator;

    // Get ordered block files

    // src/stf_test/jamtestnet/traces/safrole/
    // src/stf_test/jamtestnet/traces/safrole/jam_duna
    // src/stf_test/jamtestnet/traces/safrole/jam_duna/traces
    // src/stf_test/jamtestnet/traces/safrole/jam_duna/state_snapshots0

    // generate the block file from epoch 373496..=373500 and and for each of
    // those number 0..12 epochs
    const base_path = "src/stf_test/jamtestnet/traces/safrole/jam_duna/blocks";
    for (373496..373500) |epoch| {
        for (0..12) |number| {
            const block_path = try std.fmt.allocPrint(allocator, "{s}/{d}_{d}.bin", .{ base_path, epoch, number });
            defer allocator.free(block_path);
            std.debug.print("Generated block path: {s}\n", .{block_path});

            // Slurp the binary file
            var slurped = try slurpBin(allocator, block_path);
            defer slurped.deinit();

            // Now decode the block
            const block = try codec.deserialize(types.Block, .{
                .validators = TINY_PARAMS.validators_count,
                .epoch_length = TINY_PARAMS.epoch_length,
                .cores_count = TINY_PARAMS.core_count, // TODO: consistent naming
                .validators_super_majority = TINY_PARAMS.validators_super_majority,
                .avail_bitfield_bytes = TINY_PARAMS.avail_bitfield_bytes,
            }, allocator, slurped.buffer);
            defer block.deinit();

            std.debug.print("block {}", .{block});
            break;
        }
        break;
    }
    // NOTE: there is one more 373500_0.bin which we can do later

    // Perform state transition
    // var new_state = try stf.stateTransition(allocator, TINY_PARAMS, &initial_state, test_block);
    // defer new_state.deinit();

}
