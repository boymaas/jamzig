//! Deferred transfer execution for accumulation
//!
//! This module handles the execution of deferred transfers between service
//! accounts after accumulation completes. It groups transfers by destination
//! and invokes the ontransfer PVM function for each service.

const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const state_delta = @import("../state_delta.zig");
const meta = @import("../meta.zig");
const Params = @import("../jam_params.zig").Params;

const DeferredTransfer = @import("../pvm_invocations/accumulate.zig").DeferredTransfer;
const TransferServiceStats = @import("execution.zig").TransferServiceStats;

const trace = @import("../tracing.zig").scoped(.accumulate);

/// Error types for transfer execution
pub const TransferError = error{
    InvalidTransfer,
    ServiceNotFound,
    TransferFailed,
} || error{OutOfMemory};

pub fn TransferExecutor(comptime params: Params) type {
    return struct {
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        /// Applies deferred transfers to service accounts (§12.23 and §12.24)
        pub fn applyDeferredTransfers(
            self: Self,
            stx: *state_delta.StateTransition(params),
            transfers: []DeferredTransfer,
        ) !std.AutoHashMap(types.ServiceId, TransferServiceStats) {
            const span = trace.span(.apply_deferred_transfers);
            defer span.deinit();

            span.debug("Applying {d} deferred transfers", .{transfers.len});

            var transfer_stats = std.AutoHashMap(types.ServiceId, TransferServiceStats).init(self.allocator);
            errdefer transfer_stats.deinit();

            if (transfers.len == 0) {
                span.debug("No transfers to apply", .{});
                return transfer_stats;
            }

            // Group transfers by destination service
            var grouped_transfers = try self.groupTransfersByDestination(transfers);
            defer meta.deinit.deinitHashMapValuesAndMap(self.allocator, grouped_transfers);

            // Get delta for service accounts
            const delta_prime: *state.Delta = try stx.ensure(.delta_prime);

            // Process transfers for each destination service
            var iter = grouped_transfers.iterator();
            while (iter.next()) |entry| {
                const service_id = entry.key_ptr.*;
                const deferred_transfers = entry.value_ptr.*.items;

                span.debug("Processing {d} transfers for service {d}", .{ deferred_transfers.len, service_id });

                // Create context for ontransfer invocation
                var context = @import("../pvm_invocations/ontransfer.zig").OnTransferContext(params){
                    .service_id = service_id,
                    .service_accounts = @import("../services_snapshot.zig").DeltaSnapshot.init(delta_prime),
                    .allocator = self.allocator,
                    .transfers = deferred_transfers,
                    .entropy = (try stx.ensure(.eta_prime))[0],
                    .timeslot = stx.time.current_slot,
                };
                defer context.deinit();

                // Invoke ontransfer for this service
                const res = try @import("../pvm_invocations/ontransfer.zig").invoke(
                    params,
                    self.allocator,
                    &context,
                );

                // Store transfer statistics
                try transfer_stats.put(service_id, .{
                    .gas_used = res.gas_used,
                    .transfer_count = @intCast(deferred_transfers.len),
                });

                span.debug("Service {d}: processed {d} transfers, used {d} gas", .{ 
                    service_id, deferred_transfers.len, res.gas_used 
                });
            }

            span.debug("All transfers applied successfully", .{});
            return transfer_stats;
        }

        /// Groups transfers by their destination service
        fn groupTransfersByDestination(
            self: Self,
            transfers: []DeferredTransfer,
        ) !std.AutoHashMap(types.ServiceId, std.ArrayList(DeferredTransfer)) {
            const span = trace.span(.group_transfers_by_destination);
            defer span.deinit();

            var grouped = std.AutoHashMap(types.ServiceId, std.ArrayList(DeferredTransfer)).init(self.allocator);
            errdefer meta.deinit.deinitHashMapValuesAndMap(self.allocator, grouped);

            for (transfers) |transfer| {
                span.trace("Transfer: {d} -> {d}, amount: {d}", .{ 
                    transfer.sender, transfer.destination, transfer.amount 
                });

                var entry = try grouped.getOrPut(transfer.destination);
                if (!entry.found_existing) {
                    entry.value_ptr.* = std.ArrayList(DeferredTransfer).init(self.allocator);
                }

                try entry.value_ptr.append(transfer);
            }

            span.debug("Grouped transfers into {d} destination services", .{grouped.count()});
            return grouped;
        }

        /// Validates a transfer before execution
        pub fn validateTransfer(self: Self, transfer: DeferredTransfer) !void {
            _ = self;
            if (transfer.sender == transfer.destination) {
                return error.InvalidTransfer;
            }
            if (transfer.amount == 0) {
                return error.InvalidTransfer;
            }
        }
    };
}