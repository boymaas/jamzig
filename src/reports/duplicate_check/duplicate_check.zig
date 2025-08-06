const std = @import("std");
const types = @import("../../types.zig");
const state = @import("../../state.zig");
const tracing = @import("../../tracing.zig");

const trace = tracing.scoped(.reports);
const StateTransition = @import("../../state_delta.zig").StateTransition;

/// Error types for duplicate validation
pub const Error = error{
    DuplicatePackage,
    DuplicatePackageInGuarantees,
};

/// Check for duplicate packages in a batch of guarantees
/// Uses a sorting-based approach for better runtime complexity (O(n log n) vs O(n²))
pub fn checkDuplicatePackageInBatch(
    comptime params: @import("../../jam_params.zig").Params,
    guarantees: types.GuaranteesExtrinsic,
) !void {
    const span = trace.span(.check_duplicate_package_in_batch);
    defer span.deinit();

    span.debug("Starting duplicate check for {d} guarantees", .{guarantees.data.len});

    // Create temporary array to store hashes for sorting
    // avoid allocation
    var bounded_buffer = try std.BoundedArray(types.WorkPackageHash, params.core_count).init(0);

    // Copy all package hashes
    for (guarantees.data, 0..) |g, i| {
        try bounded_buffer.append(g.report.package_spec.hash);
        span.trace("Collected hash at index {d}: {s}", .{ i, std.fmt.fmtSliceHexLower(&bounded_buffer.get(i)) });
    }

    // Sort hashes for efficient duplicate checking
    std.mem.sortUnstable(types.WorkPackageHash, bounded_buffer.slice(), {}, @import("../../utils/sort.zig").ascHashFn);

    // Get access to the sorted hashes
    const sorted_hashes = bounded_buffer.constSlice();

    // Check adjacent hashes for duplicates
    if (sorted_hashes.len > 1) {
        for (sorted_hashes[0 .. sorted_hashes.len - 1], sorted_hashes[1..], 0..) |hash1, hash2, i| {
            span.trace("Comparing sorted hashes at indices {d} and {d}", .{ i, i + 1 });

            if (std.mem.eql(u8, &hash1, &hash2)) {
                span.err("Found duplicate package hash: {s}", .{std.fmt.fmtSliceHexLower(&hash1)});
                return Error.DuplicatePackage;
            }
        }
    }

    span.debug("No duplicates found in batch of {d} packages", .{guarantees.data.len});
}

/// Check for duplicate packages across recent history
pub fn checkDuplicatePackageInRecentHistory(
    comptime params: @import("../../jam_params.zig").Params,
    stx: *StateTransition(params),
    guarantee: types.ReportGuarantee,
    guarantees: types.GuaranteesExtrinsic,
) !void {
    const span = trace.span(.check_duplicate_package_in_recent_history);
    defer span.deinit();

    const package_hash = guarantee.report.package_spec.hash;
    span.debug("Checking for duplicate package hash {s}", .{
        std.fmt.fmtSliceHexLower(&package_hash),
    });

    const beta: *const state.Beta = try stx.ensure(.beta_prime);
    const blocks = beta.recent_history.blocks;
    span.debug("Comparing against {d} blocks", .{blocks.items.len});
    for (blocks.items, 0..) |block, block_idx| {
        const block_span = span.child(.check_block);
        defer block_span.deinit();

        block_span.debug("Checking block {d} with {d} reports", .{
            block_idx,
            block.work_reports.len,
        });

        for (block.work_reports, 0..) |report, report_idx| {
            block_span.trace("Comparing against report {d}: {s}", .{
                report_idx,
                std.fmt.fmtSliceHexLower(&report.hash),
            });
            if (std.mem.eql(u8, &report.hash, &package_hash)) {
                block_span.err("Found duplicate package in report {d}", .{
                    report_idx,
                });
                return Error.DuplicatePackage;
            }
        }
        block_span.debug("No duplicates found in block {d}", .{block_idx});
    }

    // Also check against other guarantees in the current batch
    for (guarantees.data) |g| {
        if (g.report.core_index != guarantee.report.core_index and
            std.mem.eql(u8, &g.report.package_spec.hash, &package_hash))
        {
            span.err("Found duplicate package in current guarantees batch", .{});
            return Error.DuplicatePackageInGuarantees;
        }
    }

    span.debug("No duplicates found for package hash", .{});
}