//! Accumulation statistics calculation according to JAM §12.25
//!
//! This module computes the accumulation statistics after work reports
//! have been processed. It calculates the AccumulateRoot and tracks
//! gas usage and transfer counts per service.

const std = @import("std");
const types = @import("../types.zig");
const meta = @import("../meta.zig");
const Params = @import("../jam_params.zig").Params;

const execution = @import("execution.zig");
const AccumulationServiceStats = execution.AccumulationServiceStats;
const TransferServiceStats = execution.TransferServiceStats;
const OuterAccumulationResult = execution.OuterAccumulationResult;
const ProcessAccumulationResult = execution.ProcessAccumulationResult;

const trace = @import("../tracing.zig").scoped(.accumulate);

/// Error types for statistics calculation
pub const StatisticsError = error{
    InvalidAccumulationOutput,
    MissingServiceData,
} || error{OutOfMemory};

pub fn StatisticsCalculator(comptime params: Params) type {
    _ = params; // Reserved for future use
    return struct {
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        /// Computes all statistics from accumulation results
        pub fn computeAllStatistics(
            self: Self,
            accumulated: []const types.WorkReport,
            execution_result: *OuterAccumulationResult,
            transfer_stats: std.AutoHashMap(types.ServiceId, TransferServiceStats),
        ) !ProcessAccumulationResult {
            const span = trace.span(.compute_all_statistics);
            defer span.deinit();

            // Calculate the AccumulateRoot
            const accumulate_root = try self.calculateAccumulateRoot(
                execution_result.accumulation_outputs,
            );

            // Calculate accumulation statistics
            const accumulation_stats = try self.calculateAccumulationStats(
                accumulated,
                &execution_result.service_gas_used,
            );

            span.debug("Statistics computation complete", .{});
            return ProcessAccumulationResult{
                .accumulate_root = accumulate_root,
                .accumulation_stats = accumulation_stats,
                .transfer_stats = transfer_stats,
            };
        }

        /// Calculates the AccumulateRoot from accumulation outputs
        fn calculateAccumulateRoot(
            self: Self,
            accumulation_outputs: std.AutoHashMap(types.ServiceId, types.AccumulateOutput),
        ) !types.AccumulateRoot {
            const span = trace.span(.calculate_accumulate_root);
            defer span.deinit();

            span.debug("Calculating AccumulateRoot from {d} accumulation outputs", .{accumulation_outputs.count()});

            // Collect and sort service IDs
            var keys = try std.ArrayList(types.ServiceId).initCapacity(self.allocator, accumulation_outputs.count());
            defer keys.deinit();

            span.trace("Collecting service IDs from accumulation outputs", .{});
            var key_iter = accumulation_outputs.keyIterator();
            while (key_iter.next()) |key| {
                try keys.append(key.*);
                span.trace("Added service ID: {d}", .{key.*});
            }

            span.debug("Sorting {d} service IDs in ascending order", .{keys.items.len});
            std.mem.sort(u32, keys.items, {}, std.sort.asc(u32));

            // Prepare blobs for Merkle tree
            var blobs = try std.ArrayList([]u8).initCapacity(self.allocator, accumulation_outputs.count());
            defer meta.deinit.allocFreeEntriesAndAggregate(self.allocator, blobs);

            span.debug("Creating blobs for Merkle tree calculation", .{});
            for (keys.items, 0..) |key, i| {
                const blob_span = span.child(.create_blob);
                defer blob_span.deinit();

                blob_span.trace("Processing service ID {d} at index {d}", .{ key, i });

                // Convert service ID to bytes
                var service_id: [4]u8 = undefined;
                std.mem.writeInt(u32, &service_id, key, .little);
                blob_span.trace("Service ID bytes: {s}", .{std.fmt.fmtSliceHexLower(&service_id)});

                // Get accumulation output for this service
                const output = accumulation_outputs.get(key).?;
                blob_span.trace("Accumulation output: {s}", .{std.fmt.fmtSliceHexLower(&output)});

                // Concatenate service ID and output
                const blob = try self.allocator.dupe(u8, &(service_id ++ output));
                try blobs.append(blob);
            }

            span.debug("Computing Merkle root from {d} blobs", .{blobs.items.len});
            const accumulate_root = @import("../merkle/binary.zig").binaryMerkleRoot(blobs.items, std.crypto.hash.sha3.Keccak256);
            span.debug("AccumulateRoot calculated: {s}", .{std.fmt.fmtSliceHexLower(&accumulate_root)});

            return accumulate_root;
        }

        /// Calculates accumulation statistics for services (Eq 12.25)
        fn calculateAccumulationStats(
            self: Self,
            accumulated: []const types.WorkReport,
            service_gas_used: *std.AutoHashMap(types.ServiceId, types.Gas),
        ) !std.AutoHashMap(types.ServiceId, AccumulationServiceStats) {
            const span = trace.span(.calculate_accumulation_stats);
            defer span.deinit();

            var accumulation_stats = std.AutoHashMap(types.ServiceId, AccumulationServiceStats).init(self.allocator);
            errdefer accumulation_stats.deinit();

            span.debug("Calculating I (Accumulation) statistics for {d} accumulated reports", .{accumulated.len});

            // Use the per-service gas usage returned by outerAccumulation
            var service_gas_iter = service_gas_used.iterator();
            while (service_gas_iter.next()) |entry| {
                const service_id = entry.key_ptr.*;
                const gas_used = entry.value_ptr.*;

                // Count how many reports were processed for this service
                var count: u32 = 0;
                for (accumulated) |report| {
                    // Check if this report contains any work result for this service
                    for (report.results) |work_result| {
                        if (work_result.service_id == service_id) {
                            count += 1;
                        }
                    }
                }

                try accumulation_stats.put(service_id, .{
                    .gas_used = gas_used,
                    .accumulated_count = count,
                });
                span.trace("Added I stats for service {d}: count={d}, gas={d}", .{ service_id, count, gas_used });
            }

            return accumulation_stats;
        }
    };
}

