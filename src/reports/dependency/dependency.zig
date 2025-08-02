const std = @import("std");
const types = @import("../../types.zig");
const state = @import("../../state.zig");
const tracing = @import("../../tracing.zig");

const trace = tracing.scoped(.reports);
const StateTransition = @import("../../state_delta.zig").StateTransition;

/// Error types for dependency validation
pub const Error = error{
    TooManyDependencies,
    DependencyMissing,
    SegmentRootLookupInvalid,
};

/// Check total dependencies don't exceed J according to equation 11.3
pub fn validateDependencyCount(
    comptime params: @import("../../jam_params.zig").Params,
    guarantee: types.ReportGuarantee,
) !void {
    const span = trace.span(.check_dependencies);
    defer span.deinit();
    span.debug("Checking total dependencies", .{});

    const total_deps = guarantee.report.segment_root_lookup.len + guarantee.report.context.prerequisites.len;
    span.debug("Found {d} segment roots and {d} prerequisites, total {d}", .{
        guarantee.report.segment_root_lookup.len,
        guarantee.report.context.prerequisites.len,
        total_deps,
    });

    if (total_deps > params.max_number_of_dependencies_for_work_reports) {
        span.err("Too many dependencies: {d} > {d}", .{ total_deps, params.max_work_items_per_package });
        return Error.TooManyDependencies;
    }
    span.debug("Dependencies check passed", .{});
}

/// Validate report prerequisites exist
pub fn validatePrerequisites(
    comptime params: @import("../../jam_params.zig").Params,
    stx: *StateTransition(params),
    guarantee: types.ReportGuarantee,
    guarantees: types.GuaranteesExtrinsic,
) !void {
    const span = trace.span(.validate_prerequisites);
    defer span.deinit();

    span.debug("Validating {d} prerequisites", .{guarantee.report.context.prerequisites.len});

    const beta: *const state.Beta = try stx.ensure(.beta_prime);

    for (guarantee.report.context.prerequisites, 0..) |prereq, i| {
        const single_prereq_span = span.child(.validate_prerequisite);
        defer single_prereq_span.deinit();

        single_prereq_span.debug("Checking prerequisite {d}: {s}", .{ i, std.fmt.fmtSliceHexLower(&prereq) });

        var found_prereq = false;

        // First check in recent blocks
        {
            const blocks_span = single_prereq_span.child(.check_recent_blocks);
            defer blocks_span.deinit();

            blocks_span.debug("Searching in {d} recent blocks", .{beta.blocks.items.len});

            outer: for (beta.blocks.items, 0..) |block, block_idx| {
                blocks_span.trace("Checking block {d} with {d} reports", .{ block_idx, block.work_reports.len });

                for (block.work_reports, 0..) |report, report_idx| {
                    blocks_span.trace("Comparing with report {d}: {s}", .{ report_idx, std.fmt.fmtSliceHexLower(&report.hash) });

                    if (std.mem.eql(u8, &report.hash, &prereq)) {
                        blocks_span.debug("Found prerequisite in block {d}, report {d}", .{ block_idx, report_idx });
                        found_prereq = true;
                        break :outer;
                    }
                }
            }

            if (!found_prereq) {
                blocks_span.debug("Prerequisite not found in recent blocks", .{});
            }
        }

        // If not found in blocks, check current guarantees
        if (!found_prereq) {
            const guarantees_span = single_prereq_span.child(.check_current_guarantees);
            defer guarantees_span.deinit();

            guarantees_span.debug("Searching in {d} current guarantees", .{guarantees.data.len});

            for (guarantees.data, 0..) |g, g_idx| {
                guarantees_span.trace("Comparing with guarantee {d}: {s}", .{ g_idx, std.fmt.fmtSliceHexLower(&g.report.package_spec.hash) });

                if (std.mem.eql(u8, &g.report.package_spec.hash, &prereq)) {
                    guarantees_span.debug("Found prerequisite in current guarantee {d}", .{g_idx});
                    found_prereq = true;
                    break;
                }
            }

            if (!found_prereq) {
                guarantees_span.debug("Prerequisite not found in current guarantees", .{});
            }
        }

        if (!found_prereq) {
            single_prereq_span.err("Prerequisite {d} not found: {s}", .{ i, std.fmt.fmtSliceHexLower(&prereq) });
            return Error.DependencyMissing;
        }

        single_prereq_span.debug("Prerequisite {d} validated successfully", .{i});
    }

    span.debug("All prerequisites validated successfully", .{});
}

/// Verify segment root lookup is valid
pub fn validateSegmentRootLookup(
    comptime params: @import("../../jam_params.zig").Params,
    stx: *StateTransition(params),
    guarantee: types.ReportGuarantee,
    guarantees: types.GuaranteesExtrinsic,
) !void {
    const span = trace.span(.validate_segment_roots);
    defer span.deinit();

    span.debug("Validating {d} segment root lookups", .{guarantee.report.segment_root_lookup.len});

    const beta: *const state.Beta = try stx.ensure(.beta_prime);

    for (guarantee.report.segment_root_lookup, 0..) |segment, i| {
        const lookup_span = span.child(.validate_segment_lookup);
        defer lookup_span.deinit();

        lookup_span.debug("Validating segment lookup {d}: package hash {s}", .{
            i,
            std.fmt.fmtSliceHexLower(&segment.work_package_hash),
        });
        lookup_span.trace("Segment tree root: {s}", .{
            std.fmt.fmtSliceHexLower(&segment.segment_tree_root),
        });

        var found_package = false;
        var matching_segment_root = false;

        // First check recent blocks
        {
            const blocks_span = lookup_span.child(.check_recent_blocks);
            defer blocks_span.deinit();

            blocks_span.debug("Searching in {d} recent blocks", .{beta.blocks.items.len});

            outer: for (beta.blocks.items, 0..) |block, block_idx| {
                blocks_span.trace("Checking block {d} with {d} reports", .{
                    block_idx,
                    block.work_reports.len,
                });

                for (block.work_reports, 0..) |report, report_idx| {
                    blocks_span.trace("Comparing with report {d}: {s}", .{
                        report_idx,
                        std.fmt.fmtSliceHexLower(&report.hash),
                    });

                    if (std.mem.eql(u8, &report.hash, &segment.work_package_hash)) {
                        blocks_span.debug("Found matching package in block {d}, report {d}", .{
                            block_idx,
                            report_idx,
                        });
                        found_package = true;

                        // Check segment root
                        blocks_span.trace("Checking segment root against exports root: {s}", .{
                            std.fmt.fmtSliceHexLower(&report.exports_root),
                        });

                        if (std.mem.eql(u8, &report.exports_root, &segment.segment_tree_root)) {
                            blocks_span.debug("Found matching segment root", .{});
                            matching_segment_root = true;
                        }

                        break :outer;
                    }
                }
            }

            if (found_package) {
                blocks_span.debug("Package found in recent blocks, segment root match: {}", .{matching_segment_root});
            } else {
                blocks_span.debug("Package not found in recent blocks", .{});
            }
        }

        // If not found in blocks, check current guarantees
        if (!found_package) {
            const guarantees_span = lookup_span.child(.check_current_guarantees);
            defer guarantees_span.deinit();

            guarantees_span.debug("Searching in {d} current guarantees", .{guarantees.data.len});

            scan_guarantees: for (guarantees.data, 0..) |g, g_idx| {
                guarantees_span.trace("Comparing with guarantee {d}: {s}", .{
                    g_idx,
                    std.fmt.fmtSliceHexLower(&g.report.package_spec.hash),
                });

                // std.debug.print("{}\n", .{types.fmt.format(g)});
                if (std.mem.eql(u8, &segment.work_package_hash, &g.report.package_spec.hash)) {
                    found_package = true;

                    // if we have this work report in our guarantees lets look if this work_package
                    // export the correct root
                    if (std.mem.eql(u8, &g.report.package_spec.exports_root, &segment.segment_tree_root)) {
                        matching_segment_root = true;
                    }
                    break :scan_guarantees;
                }
            }

            if (found_package) {
                guarantees_span.debug("Package found in current guarantees, segment root match: {}", .{matching_segment_root});
            } else {
                guarantees_span.debug("Package not found in current guarantees", .{});
            }
        }

        if (!found_package) {
            lookup_span.err("Package not found: {s}", .{
                std.fmt.fmtSliceHexLower(&segment.work_package_hash),
            });
            return Error.SegmentRootLookupInvalid;
        }

        if (found_package and !matching_segment_root) {
            lookup_span.err("Segment root mismatch for package: {s}", .{
                std.fmt.fmtSliceHexLower(&segment.work_package_hash),
            });
            return Error.SegmentRootLookupInvalid;
        }

        lookup_span.debug("Segment lookup {d} validated successfully", .{i});
    }

    span.debug("All segment root lookups validated successfully", .{});
}