const std = @import("std");

const types = @import("../types.zig");
const state = @import("../state.zig");
const state_keys = @import("../state_keys.zig");

const codec = @import("../codec.zig");

const pvm = @import("../pvm.zig");
const pvm_invocation = @import("../pvm/invocation.zig");

const host_calls_map = @import("ontransfer/host_calls_map.zig");
const HostCalls = @import("ontransfer/host_calls.zig").HostCalls;

pub const DeferredTransfer = @import("accumulate/types.zig").DeferredTransfer;

const Params = @import("../jam_params.zig").Params;

pub fn OnTransferContext(comptime params: Params) type {
    return HostCalls(params).Context;
}

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
    context: *OnTransferContext(params),
) !OnTransferResult {
    const span = trace.span(.invoke);
    defer span.deinit();
    span.debug("Starting OnTransfer invocation for service {d}", .{context.service_id});
    span.debug("Time slot: {d}, Transfers count: {d}", .{ context.timeslot, context.transfers.len });

    // Skip execution if code hash is empty or there are no transfers
    if (context.transfers.len == 0) {
        span.debug("No code hash or no transfers, skipping execution", .{});
        return OnTransferResult{
            .service_id = context.service_id,
            .gas_used = 0,
        };
    }

    // Calculate total gas limit for all transfers
    var total_gas_limit: types.Gas = 0;
    for (context.transfers) |transfer| {
        total_gas_limit += transfer.gas_limit;
    }
    span.debug("Total gas limit: {d}", .{total_gas_limit});

    // Calculate total transfer amount
    var total_transfer_amount: types.Balance = 0;
    for (context.transfers) |transfer| {
        total_transfer_amount += transfer.amount;
    }
    span.debug("Total transfer amount: {d}", .{total_transfer_amount});

    // // Check if any transfer has a gas limit less than the service's minimum required gas (l in graypaper)
    // for (transfers) |transfer| {
    //     if (transfer.gas_limit < service_account.min_gas_on_transfer) {
    //         span.err("Transfer gas limit {d} is less than service minimum {d}", .{
    //             transfer.gas_limit, service_account.min_gas_on_transfer,
    //         });
    //         return error.InsufficientGas;
    //     }
    // }

    // Prepare on_transfer arguments
    span.debug("Preparing OnTransfer arguments", .{});
    var args_buffer = std.ArrayList(u8).init(allocator);
    defer args_buffer.deinit();

    const arguments = OnTransferArgs{
        .timeslot = context.timeslot,
        .service_id = context.service_id,
        .transfers = context.transfers,
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

    // Get the service account to which the transfers should be applied
    var destination_account = try context.service_accounts.getMutable(context.service_id) orelse {
        span.err("Service {d} not found", .{context.service_id});
        return error.ServiceNotFound;
    };

    // Update the balance, and commit to the balance to services
    span.debug("Found service account for ID {d}", .{context.service_id});
    destination_account.balance += total_transfer_amount;
    // NOTE: this commits the modification to the service accounts, which entails
    // removing and deinit the previous version and overwriting it with destination_accounts
    try context.service_accounts.commit();

    // this will always succeed
    const destination_account_prime = context.service_accounts.getReadOnly(context.service_id).?;

    // Execute the PVM invocation
    const code_key = state_keys.constructServicePreimageKey(context.service_id, destination_account_prime.code_hash);
    const code_preimage = destination_account_prime.getPreimage(code_key) orelse {
        span.err("Service code not available for hash: {s}", .{std.fmt.fmtSliceHexLower(&destination_account_prime.code_hash)});
        return OnTransferResult{
            .service_id = context.service_id,
            .gas_used = 0,
        };
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

    // Committing changes to service accounts
    try context.service_accounts.commit();

    // Calculate gas used (u in graypaper)
    const gas_used = result.gas_used;
    span.debug("Gas used for invocation: {d}", .{gas_used});

    span.debug("OnTransfer invocation completed", .{});
    return OnTransferResult{
        .service_id = context.service_id,
        .gas_used = gas_used,
    };
}

/// Return type for the ontransfer invoke function
pub const OnTransferResult = struct {
    /// Updated service account after applying transfers and executing on_transfer code
    /// we do not own this
    service_id: types.ServiceId,

    /// Amount of gas consumed during execution
    gas_used: types.Gas,

    pub fn deinit(self: *@This(), _: std.mem.Allocator) void {
        self.* = undefined;
    }
};
