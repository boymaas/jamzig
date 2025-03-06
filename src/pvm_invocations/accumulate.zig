const std = @import("std");

const types = @import("../types.zig");
const state = @import("../state.zig");

const codec = @import("../codec.zig");

const pvm = @import("../pvm.zig");
const pvm_invocation = @import("../pvm/invocation.zig");

const service_util = @import("accumulate/service_util.zig");

pub const AccumulationContext = @import("accumulate/context.zig").AccumulationContext;
const DeferredTransfer = @import("accumulate/types.zig").DeferredTransfer;
const AccumulateHostCalls = @import("accumulate/host_calls.zig").HostCalls;
const HostCallId = @import("accumulate/host_calls.zig").HostCallId;

const Params = @import("../jam_params.zig").Params;

const HostCallMap = @import("accumulate/host_calls_map.zig");

// Add tracing import
const trace = @import("../tracing.zig").scoped(.accumulate);

// The to be encoded arguments
const AccumulateArgs = struct {
    timeslot: types.TimeSlot,
    service_id: types.ServiceId,
    operands: []const AccumulationOperand,
};

/// Accumulation Invocation
pub fn invoke(
    comptime params: Params,
    allocator: std.mem.Allocator,
    context: AccumulationContext(params),
    tau: types.TimeSlot,
    entropy: types.Entropy, // n0
    service_id: types.ServiceId,
    gas_limit: types.Gas,
    accumulation_operands: []const AccumulationOperand, // O
) !AccumulationResult(params) {
    const span = trace.span(.invoke);
    defer span.deinit();
    span.debug("Starting accumulation invocation for service {d}", .{service_id});
    span.debug("Time slot: {d}, Gas limit: {d}, Operand count: {d}", .{ tau, gas_limit, accumulation_operands.len });
    span.trace("Entropy: {s}", .{std.fmt.fmtSliceHexLower(&entropy)});

    // Look up the service account
    const service_account = context.service_accounts.getAccount(service_id) orelse {
        span.err("Service {d} not found", .{service_id});
        return error.ServiceNotFound;
    };

    span.debug("Found service account for ID {d}", .{service_id});

    // Prepare accumulation arguments
    span.debug("Preparing accumulation arguments", .{});
    var args_buffer = std.ArrayList(u8).init(allocator);
    defer args_buffer.deinit();

    const arguments = AccumulateArgs{
        .timeslot = tau,
        .service_id = service_id,
        .operands = accumulation_operands,
    };

    try codec.serialize(AccumulateArgs, .{}, args_buffer.writer(), arguments);

    span.debug("Setting up host call functions", .{});
    const host_call_map = try HostCallMap.buildOrGetCached(params, allocator);

    // Initialize host call context B.6
    span.debug("Initializing host call context", .{});
    var host_call_context = AccumulateHostCalls(params).Context{
        .allocator = allocator,
        .service_id = service_id,
        .context = context,
        .new_service_id = service_util.generateServiceId(context.service_accounts, service_id, entropy, tau),
        .deferred_transfers = std.ArrayList(DeferredTransfer).init(allocator),
        .accumulation_output = null,
    };
    defer host_call_context.deinit();
    span.debug("Generated new service ID: {d}", .{host_call_context.new_service_id});

    // Execute the PVM invocation
    const code = service_account.getPreimage(service_account.code_hash) orelse {
        span.err("Service code not available for hash: {s}", .{std.fmt.fmtSliceHexLower(&service_account.code_hash)});
        return error.ServiceCodeNotAvailable;
    };
    span.debug("Retrieved service code, length: {d} bytes", .{code.len});

    span.debug("Starting PVM machine invocation", .{});
    const pvm_span = span.child(.pvm_invocation);
    defer pvm_span.deinit();

    const result = try pvm_invocation.machineInvocation(
        allocator,
        code,
        5, // Accumulation entry point index per section 9.1
        @intCast(gas_limit),
        args_buffer.items,
        host_call_map,
        @ptrCast(&host_call_context),
    );

    pvm_span.debug("PVM invocation completed: {s}", .{@tagName(result)});

    // Calculate gas used
    const gas_used = 10; // FIXME: add gas calc here
    span.debug("Gas used for invocation: {d}", .{gas_used});

    // Build the result array of deferred transfers
    const transfers = try host_call_context.deferred_transfers.toOwnedSlice();
    span.debug("Number of deferred transfers created: {d}", .{transfers.len});

    for (transfers, 0..) |transfer, i| {
        span.debug("Transfer {d}: {d} -> {d}, amount: {d}", .{
            i, transfer.sender, transfer.destination, transfer.amount,
        });
    }

    if (host_call_context.accumulation_output) |output| {
        span.debug("Accumulation output present: {s}", .{std.fmt.fmtSliceHexLower(&output)});
    } else {
        span.debug("No accumulation output produced", .{});
    }

    span.debug("Accumulation invocation completed successfully", .{});
    return AccumulationResult(params){
        .state_context = context,
        .transfers = transfers,
        .accumulation_output = host_call_context.accumulation_output,
        .gas_used = gas_used,
    };
}

/// 12.18 AccumulationOperand represents a wrangled tuple of operands used by the PVM Accumulation function.
/// It contains the rephrased work items for a specific service within work reports.
pub const AccumulationOperand = struct {
    pub const Output = union(enum) {
        /// Successful execution output as an octet sequence
        success: []const u8,
        /// Error code if execution failed
        err: WorkExecutionError,
    };

    /// The output or error of the work item execution.
    /// Can be either an octet sequence (Y) or an error (J).
    output: Output,

    /// The hash of the payload within the work item
    /// that was executed in the refine stage
    payload_hash: [32]u8,

    /// The hash of the work package
    work_package_hash: [32]u8,

    /// The authorization output blob for the work item
    authorization_output: []const u8,

    pub fn fromWorkReport(allocator: std.mem.Allocator, report: types.WorkReport) ![]AccumulationOperand {
        // Ensure there are results in the report
        if (report.results.len == 0) {
            return error.NoResults;
        }

        // Allocate an array of AccumulationOperand with the same length as report.results
        var operands = try allocator.alloc(AccumulationOperand, report.results.len);
        errdefer {
            // Clean up any already initialized operands
            for (operands) |*operand| {
                operand.deinit(allocator);
            }
            allocator.free(operands);
        }

        // Create an AccumulationOperand for each result in the report
        for (report.results, 0..) |result, i| {
            // Map output type from WorkExecResult to AccumulationOperand.output
            const output: Output = switch (result.result) {
                .ok => |data| .{
                    .success = try allocator.dupe(u8, data),
                },
                .out_of_gas => .{
                    .err = .OutOfGas,
                },
                .panic => .{
                    .err = .ProgramTermination,
                },
                .bad_code => .{
                    .err = .ServiceCodeUnavailable,
                },
                .code_oversize => .{
                    .err = .ServiceCodeTooLarge,
                },
            };

            // Set up the operand
            operands[i] = .{
                .output = output,
                .payload_hash = result.payload_hash,
                .work_package_hash = report.package_spec.hash,
                .authorization_output = try allocator.dupe(u8, report.auth_output),
            };
        }

        return operands;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.output == .success) {
            allocator.free(self.output.success);
        }

        // Free the authorization output
        allocator.free(self.authorization_output);
        self.* = undefined;
    }
};

/// Represents possible error types from work execution
const WorkExecutionError = enum {
    OutOfGas, // ∞
    ProgramTermination, // ☇
    InvalidExportCount, // ⊚
    ServiceCodeUnavailable, // BAD
    ServiceCodeTooLarge, // BIG
};

/// Return type for the accumulation invoke function,
pub fn AccumulationResult(params: Params) type {
    return struct {
        /// Updated state context after accumulation
        state_context: AccumulationContext(params),

        /// Sequence of deferred transfers resulting from accumulation
        transfers: []DeferredTransfer,

        /// Optional accumulation output hash (null if no output was produced)
        accumulation_output: ?types.AccumulateRoot,

        /// Amount of gas consumed during accumulation
        gas_used: types.Gas,

        pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
            alloc.free(self.transfers);
        }
    };
}
