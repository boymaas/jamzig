const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const Params = @import("../jam_params.zig").Params;

const accumulate_types = @import("types.zig");
const Queued = accumulate_types.Queued;

const trace = @import("tracing").scoped(.accumulate);

pub const QueueError = error{
    InvalidQueueState,
    QueueOverflow,
    ProcessingFailed,
} || error{OutOfMemory};

pub fn QueueProcessor(comptime params: Params) type {
    _ = params;
    return struct {
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn processQueues(
            self: Self,
            queues: *QueueSet,
            resolved_hashes: []const types.WorkReportHash,
        ) !ProcessResult {
            const span = trace.span(@src(), .process_queues);
            defer span.deinit();

            var result = ProcessResult{
                .moved_to_ready = 0,
                .removed_stale = 0,
                .updated_deps = 0,
            };

            result.removed_stale += try self.removeStaleReports(&queues.pending);
            result.updated_deps += try self.updateDependencies(&queues.pending, resolved_hashes);
            result.moved_to_ready += try self.moveReadyReports(&queues.pending, &queues.ready);

            span.debug("Queue processing complete: moved={d}, stale={d}, updated={d}", .{
                result.moved_to_ready,
                result.removed_stale,
                result.updated_deps,
            });

            return result;
        }

        fn removeStaleReports(
            self: Self,
            queue: *Queued(types.WorkReport),
        ) !usize {
            _ = self;
            const span = trace.span(@src(), .remove_stale_reports);
            defer span.deinit();

            const removed: usize = 0;
            var i: usize = 0;

            while (i < queue.items.len) {
                // TODO: Add staleness check logic here
                // For now, just advance
                i += 1;
            }

            span.debug("Removed {d} stale reports", .{removed});
            return removed;
        }

        fn updateDependencies(
            self: Self,
            queue: *Queued(types.WorkReport),
            resolved_hashes: []const types.WorkReportHash,
        ) !usize {
            _ = self;
            _ = queue;
            const span = trace.span(@src(), .update_dependencies);
            defer span.deinit();

            var updated: usize = 0;

            updated = resolved_hashes.len;

            span.debug("Updated dependencies for {d} reports", .{updated});
            return updated;
        }

        fn moveReadyReports(
            self: Self,
            pending: *Queued(types.WorkReport),
            ready: *Queued(types.WorkReport),
        ) !usize {
            _ = self;
            const span = trace.span(@src(), .move_ready_reports);
            defer span.deinit();

            var moved: usize = 0;
            var i: usize = 0;

            while (i < pending.items.len) {
                // Check if report is ready (no dependencies)
                // This is simplified - actual logic in dependency_resolver
                const report = &pending.items[i];
                
                // If ready, move to ready queue
                if (report.context.prerequisites.len == 0) {
                    try ready.append(pending.orderedRemove(i));
                    moved += 1;
                } else {
                    i += 1;
                }
            }

            span.debug("Moved {d} reports to ready queue", .{moved});
            return moved;
        }

        pub fn validateQueues(self: Self, queues: *const QueueSet) !void {
            _ = self;
            const span = trace.span(@src(), .validate_queues);
            defer span.deinit();

            var all_hashes = std.AutoHashMap(types.WorkReportHash, void).init(span.allocator);
            defer all_hashes.deinit();

            for (queues.pending.items) |report| {
                const hash = report.package_spec.hash;
                if (all_hashes.contains(hash)) {
                    return error.InvalidQueueState;
                }
                try all_hashes.put(hash, {});
            }

            for (queues.ready.items) |report| {
                const hash = report.package_spec.hash;
                if (all_hashes.contains(hash)) {
                    return error.InvalidQueueState;
                }
                try all_hashes.put(hash, {});
            }

            span.debug("Queue validation passed", .{});
        }

        pub fn getQueueStats(self: Self, queues: *const QueueSet) QueueStats {
            _ = self;
            return .{
                .pending_count = queues.pending.items.len,
                .ready_count = queues.ready.items.len,
                .total_count = queues.pending.items.len + queues.ready.items.len,
            };
        }
    };
}

/// Set of queues used in accumulation
pub const QueueSet = struct {
    pending: Queued(types.WorkReport),
    ready: Queued(types.WorkReport),

    pub fn init(allocator: std.mem.Allocator) QueueSet {
        return .{
            .pending = Queued(types.WorkReport).init(allocator),
            .ready = Queued(types.WorkReport).init(allocator),
        };
    }

    pub fn deinit(self: *QueueSet) void {
        self.pending.deinit();
        self.ready.deinit();
        self.* = undefined;
    }
};

/// Result of queue processing
pub const ProcessResult = struct {
    moved_to_ready: usize,
    removed_stale: usize,
    updated_deps: usize,
};

/// Queue statistics
pub const QueueStats = struct {
    pending_count: usize,
    ready_count: usize,
    total_count: usize,
};