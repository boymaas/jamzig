const std = @import("std");

const types = @import("../types.zig");
const state = @import("../state.zig");

const codec = @import("../codec.zig");

const pvm = @import("../pvm.zig");
const pvm_invocation = @import("../pvm/invocation.zig");

const host_calls_map = @import("ontransfer/host_calls_map.zig");

pub const OnTransferContext = @import("ontransfer/context.zig").OnTransferContext;
pub const DeferredTransfer = @import("accumulate/types.zig").DeferredTransfer;

const Params = @import("../jam_params.zig").Params;

// Add tracing import
const trace = @import("../tracing.zig").scoped(.ontransfer);

// The to be encoded arguments for OnTransfer
const OnTransferArgs = struct {
    timeslot: types.TimeSlot,
    service_id: types.ServiceId,
    transfers: []const DeferredTransfer,
};

/// OnTransfer Invocation - Section B.5 of the graypaper
pub fn invoke(
    comptime params: Params,
    allocator: std.mem.Allocator,
    context: *OnTransferContext,
    tau: types.TimeSlot,
    service_id: types.ServiceId,
    transfers: []const DeferredTransfer,
) !OnTransferResult {
    const span = trace.span(.invoke);
    defer span.deinit();
    span.debug("Starting OnTransfer invocation for service {d}", .{service_id});
    span.debug("Time slot: {d}, Transfers count: {d}", .{ tau, transfers.len });

    // Get the service account to which the transfers should be applied
    const service_account = try context.service_accounts.getMutable(service_id) orelse {
        span.err("Service {d} not found", .{service_id});
        return error.ServiceNotFound;
    };

    span.debug("Found service account for ID {d}", .{service_id});

    // Skip execution if code hash is empty or there are no transfers
    if (std.mem.eql(u8, &service_account.code_hash, &[_]u8{0} ** 32) or transfers.len == 0) {
        span.debug("No code hash or no transfers, skipping execution", .{});
        return OnTransferResult{
            .service_account = service_account,
            .gas_used = 0,
        };
    }

    // Calculate total gas limit for all transfers
    var total_gas_limit: types.Gas = 0;
    for (transfers) |transfer| {
        total_gas_limit += transfer.gas_limit;
    }
    span.debug("Total gas limit: {d}", .{total_gas_limit});

    // Calculate total transfer amount
    var total_transfer_amount: types.Balance = 0;
    for (transfers) |transfer| {
        total_transfer_amount += transfer.amount;
    }
    span.debug("Total transfer amount: {d}", .{total_transfer_amount});

    // Check if any transfer has a gas limit less than the service's minimum required gas (l in graypaper)
    for (transfers) |transfer| {
        if (transfer.gas_limit < service_account.min_gas_on_transfer) {
            span.err("Transfer gas limit {d} is less than service minimum {d}", .{
                transfer.gas_limit, service_account.min_gas_on_transfer,
            });
            return error.InsufficientGas;
        }
    }

    // Prepare on_transfer arguments
    span.debug("Preparing OnTransfer arguments", .{});
    var args_buffer = std.ArrayList(u8).init(allocator);
    defer args_buffer.deinit();

    const arguments = OnTransferArgs{
        .timeslot = tau,
        .service_id = service_id,
        .transfers = transfers,
    };

    span.trace("OnTransferArgs: {}\n", .{types.fmt.format(arguments)});

    try codec.serialize(OnTransferArgs, .{}, args_buffer.writer(), arguments);

    span.trace("OnTransferArgs Encoded: {}", .{std.fmt.fmtSliceHexLower(args_buffer.items)});

    span.debug("Setting up host call functions", .{});
    var host_call_map = try host_calls_map.buildOrGetCached(params, allocator);
    defer host_call_map.deinit(allocator);

    // Initialize host call context
    span.debug("Initializing host call context", .{});

    // Apply transfer balance to service before execution (as per the graypaper)
    span.debug("Applying transfer balance to service", .{});
    var updated_service = try service_account.deepClone(allocator);
    updated_service.balance += total_transfer_amount;

    // Execute the PVM invocation
    const code_preimage = service_account.getPreimage(service_account.code_hash) orelse {
        span.err("Service code not available for hash: {s}", .{std.fmt.fmtSliceHexLower(&service_account.code_hash)});
        return error.ServiceCodeNotAvailable;
    };

    // Now this has some metadata attached to it
    const CodeWithMetadata = struct {
        metadata: []const u8,
        code: []const u8,

        pub fn decode(data: []const u8) !@This() {
            const result = try codec.decoder.decodeInteger(data);
            if (result.value + result.bytes_read > data.len) {
                return error.MetadataSizeTooLarge;
            }
            const metadata = data[result.bytes_read .. result.value + result.bytes_read];
            const code = data[result.bytes_read + result.value ..];

            return .{ .code = code, .metadata = metadata };
        }
    };

    const code_with_metadata = try CodeWithMetadata.decode(code_preimage);

    span.debug("Retrieved service code, length: {d} bytes. Metadata: {d} bytes", .{ code_with_metadata.code.len, code_with_metadata.metadata.len });

    span.debug("Starting PVM machine invocation", .{});
    const pvm_span = span.child(.pvm_invocation);
    defer pvm_span.deinit();

    var result = try pvm_invocation.machineInvocation(
        allocator,
        code_with_metadata.code,
        10, // On_transfer entry point index per section 9.1
        @intCast(total_gas_limit),
        args_buffer.items,
        &host_call_map,
        @ptrCast(context),
    );
    defer result.deinit(allocator);

    pvm_span.debug("PVM invocation completed: {s}", .{@tagName(result.result)});

    // Calculate gas used (u in graypaper)
    const gas_used = result.gas_used;
    span.debug("Gas used for invocation: {d}", .{gas_used});

    span.debug("OnTransfer invocation completed", .{});
    return OnTransferResult{
        .service_account = service_account,
        .gas_used = gas_used,
    };
}

/// Return type for the ontransfer invoke function
pub const OnTransferResult = struct {
    /// Updated service account after applying transfers and executing on_transfer code
    /// we do not own this
    service_account: *state.services.ServiceAccount,

    /// Amount of gas consumed during execution
    gas_used: types.Gas,

    pub fn deinit(self: *@This(), _: std.mem.Allocator) void {
        self.* = undefined;
    }
};
