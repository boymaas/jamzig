const std = @import("std");
const types = @import("../types.zig");
const meta = @import("../meta.zig");
const Params = @import("../jam_params.zig").Params;
const HashSet = @import("../datastruct/hash_set.zig").HashSet;

const execution = @import("execution.zig");
const AccumulationServiceStats = execution.AccumulationServiceStats;
const OuterAccumulationResult = execution.OuterAccumulationResult;
const ProcessAccumulationResult = execution.ProcessAccumulationResult;

const trace = @import("tracing").scoped(.accumulate);

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
        ) !ProcessAccumulationResult {
            const span = trace.span(@src(), .compute_all_statistics);
            defer span.deinit();

            const accumulate_root = try self.calculateAccumulateRoot(
                execution_result.accumulation_outputs,
            );

            const accumulation_stats = try self.calculateAccumulationStats(
                accumulated,
                &execution_result.gas_used_per_service,
            );

            span.debug("Statistics computation complete", .{});
            return ProcessAccumulationResult{
                .accumulate_root = accumulate_root,
                .accumulation_stats = accumulation_stats,
                .invoked_services = execution_result.takeInvokedServices(),
            };
        }

        /// Calculates the AccumulateRoot from accumulation outputs
        fn calculateAccumulateRoot(
            self: Self,
            accumulation_outputs: HashSet(execution.ServiceAccumulationOutput),
        ) !types.AccumulateRoot {
            const span = trace.span(@src(), .calculate_accumulate_root);
            defer span.deinit();

            span.debug("Calculating AccumulateRoot from {d} accumulation outputs", .{accumulation_outputs.count()});

            // Collect all outputs into an array for sorting
            var outputs = try std.ArrayList(execution.ServiceAccumulationOutput).initCapacity(self.allocator, accumulation_outputs.count());
            defer outputs.deinit();

            span.trace("Collecting service outputs from accumulation outputs", .{});
            var iter = accumulation_outputs.iterator();
            while (iter.next()) |entry| {
                try outputs.append(entry.key_ptr.*);
                span.trace("Added service ID: {d} with output", .{entry.key_ptr.service_id});
            }

            // Sort outputs by service ID, and if equal by output, we cannot have doubles since we are using
            // a HashSet which ensures uniqueness.
            span.debug("Sorting {d} outputs by service ID in ascending order", .{outputs.items.len});
            std.mem.sort(
                execution.ServiceAccumulationOutput,
                outputs.items,
                {},
                struct {
                    fn lessThan(_: void, a: execution.ServiceAccumulationOutput, b: execution.ServiceAccumulationOutput) bool {
                        if (a.service_id == b.service_id) {
                            // If service IDs are equal, compare outputs
                            return std.mem.lessThan(u8, &a.output, &b.output);
                        }
                        return a.service_id < b.service_id;
                    }
                }.lessThan,
            );

            // Prepare blobs for Merkle tree (as per graypaper eq. 24)
            var blobs = try std.ArrayList([]u8).initCapacity(self.allocator, outputs.items.len);
            defer meta.deinit.allocFreeEntriesAndAggregate(self.allocator, blobs);

            span.debug("Creating blobs for Merkle tree calculation", .{});
            for (outputs.items, 0..) |item, i| {
                const blob_span = span.child(@src(), .create_blob);
                defer blob_span.deinit();

                blob_span.trace("Processing service ID {d} at index {d}", .{ item.service_id, i });

                // Convert service ID to bytes (4-byte little-endian as per graypaper)
                var service_id: [4]u8 = undefined;
                std.mem.writeInt(u32, &service_id, item.service_id, .little);
                blob_span.trace("Service ID bytes: {s}", .{std.fmt.fmtSliceHexLower(&service_id)});

                blob_span.trace("Accumulation output: {s}", .{std.fmt.fmtSliceHexLower(&item.output)});

                // Concatenate service ID and output (as per graypaper eq. 24: se_4(s) || se(h))
                const blob = try self.allocator.dupe(u8, &(service_id ++ item.output));
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
            const span = trace.span(@src(), .calculate_accumulation_stats);
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

                // v0.7.1: Skip services that didn't actually accumulate
                // Services may be invoked for transfer credit but if code is unavailable,
                // they have gas_used=0 and count=0, and should not appear in statistics.
                if (gas_used == 0 and count == 0) {
                    span.trace("Skipping service {d} with no accumulation activity", .{service_id});
                    continue;
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
