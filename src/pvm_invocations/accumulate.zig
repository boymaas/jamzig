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
    context: *const AccumulationContext(params),
    tau: types.TimeSlot,
    entropy: types.Entropy, // n0
    service_id: types.ServiceId,
    gas_limit: types.Gas,
    accumulation_operands: []const AccumulationOperand, // O
) !AccumulationResult {
    const span = trace.span(.invoke);
    defer span.deinit();
    span.debug("Starting accumulation invocation for service {d}", .{service_id});
    span.debug("Time slot: {d}, Gas limit: {d}, Operand count: {d}", .{ tau, gas_limit, accumulation_operands.len });
    span.trace("Entropy: {s}", .{std.fmt.fmtSliceHexLower(&entropy)});

    // Look up the service account
    const service_account = context.service_accounts.getReadOnly(service_id) orelse {
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
    var host_call_map = try HostCallMap.buildOrGetCached(params, allocator);
    defer host_call_map.deinit(allocator);

    // Initialize host call context B.6
    span.debug("Initializing host call context", .{});
    var host_call_context = try AccumulateHostCalls(params).Context.constructUsingRegular(.{
        .allocator = allocator,
        .service_id = service_id,
        .context = try context.deepClone(),
        .new_service_id = service_util.generateServiceId(&context.service_accounts, service_id, entropy, tau),
        .deferred_transfers = std.ArrayList(DeferredTransfer).init(allocator),
        .accumulation_output = null,
    });
    defer host_call_context.deinit();
    span.debug("Generated new service ID: {d}", .{host_call_context.regular.new_service_id});

    // Execute the PVM invocation
    const code = service_account.getPreimage(service_account.code_hash) orelse {
        span.err("Service code not available for hash: {s}", .{std.fmt.fmtSliceHexLower(&service_account.code_hash)});
        return error.ServiceCodeNotAvailable;
    };
    span.debug("Retrieved service code, length: {d} bytes", .{code.len});

    span.debug("Starting PVM machine invocation", .{});
    const pvm_span = span.child(.pvm_invocation);
    defer pvm_span.deinit();

    // Accumulation Host Function Context Domains
    //
    // The accumulation process uses a dual-domain context:
    // - Regular domain (x): Used by most host functions for normal operations
    // - Exceptional domain (y): Used as a fallback state in case of errors
    //
    // Only the checkpoint function (Ω_C, function ID 8) explicitly manipulates
    // the exceptional domain, setting it equal to the current regular domain.
    //
    // If execution ends with an error (out-of-gas or panic), the system will
    // use the exceptional domain state instead of the regular domain state,
    // effectively restoring to the last checkpoint.
    //
    // All other accumulation host functions operate solely on the regular domain.

    var result = try pvm_invocation.machineInvocation(
        allocator,
        code,
        5, // Accumulation entry point index per section 9.1
        @intCast(gas_limit),
        args_buffer.items,
        &host_call_map,
        @ptrCast(&host_call_context),
    );
    defer result.deinit(allocator);

    pvm_span.debug("PVM invocation completed: {s}", .{@tagName(result.result)});

    // B12. Based on result we collapse to either the regular domain or the exceptional domain
    var collapsed_dimension = if (result.result.isSuccess())
        &host_call_context.regular
    else
        &host_call_context.exceptional;

    // Calculate gas used
    const gas_used = result.gas_used;
    span.debug("Gas used for invocation: {d}", .{gas_used});

    // Build the result array of deferred transfers
    const transfers = try collapsed_dimension.deferred_transfers.toOwnedSlice();
    span.debug("Number of deferred transfers created: {d}", .{transfers.len});

    // TODO: add debugging condition
    for (transfers, 0..) |transfer, i| {
        span.debug("Transfer {d}: {d} -> {d}, amount: {d}", .{
            i, transfer.sender, transfer.destination, transfer.amount,
        });
    }

    // See: B.12
    const accumulation_output: ?[32]u8 = outer: switch (result.result) {
        .halt => |output| {
            // we do not include an empty accumulation output see 12.17 b
            if (output.len == 32) {
                break :outer output[0..32].*;
            }
            // else we use the accumulation_output of the context potentially set by the yield
            // host call
            break :outer collapsed_dimension.accumulation_output;
        },
        else => null,
    };

    if (accumulation_output) |output| {
        span.debug("Accumulation output present: {s}", .{std.fmt.fmtSliceHexLower(&output)});
    } else {
        span.debug("No accumulation output produced", .{});
    }

    // Commit our changes of the collapsed dimension to the state
    try collapsed_dimension.commit();

    span.debug("Accumulation invocation completed successfully", .{});
    return AccumulationResult{
        .transfers = transfers,
        .accumulation_output = accumulation_output,
        .gas_used = gas_used,
    };
}

pub const AccumulationOperands = struct {
    const MaybeNull = struct {
        item: ?AccumulationOperand,

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            if (self.item) |*operand| {
                operand.deinit(allocator);
                self.item = null;
            }
            self.* = undefined;
        }

        pub fn take(self: *@This()) !AccumulationOperand {
            if (self.item == null) {
                return error.AlreadyTookOperand;
            }
            const item = self.item.?;
            self.item = null;
            return item;
        }
    };

    items: []MaybeNull,

    /// takes all items out of the MaybeNull, this clears all the items, as such your cannot
    /// use this struct anymore
    pub fn toOwnedSlice(self: *@This(), allocator: std.mem.Allocator) ![]AccumulationOperand {
        var result = try allocator.alloc(AccumulationOperand, self.items.len);
        errdefer allocator.free(result);

        for (self.items, 0..) |*maybe_null, idx| {
            result[idx] = try maybe_null.take();
            maybe_null.deinit(allocator);
        }

        allocator.free(self.items);
        self.items = &[_]MaybeNull{};

        return result;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        // Clean up each AccumulationOperand in the items array
        for (self.items) |*operand| {
            operand.deinit(allocator);
        }

        // Free the items array itself
        allocator.free(self.items);

        // Mark as undefined to prevent use-after-free
        self.* = undefined;
    }
};

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

    pub fn deepClone(self: @This(), alloc: std.mem.Allocator) !@This() {
        // Create a new operand with deep copies of all dynamic data
        var cloned = @This(){
            .payload_hash = self.payload_hash,
            .work_package_hash = self.work_package_hash,
            .authorization_output = try alloc.dupe(u8, self.authorization_output),
            .output = undefined, // Will be set below
        };

        // Deep copy the output based on its type
        switch (self.output) {
            .success => |data| {
                cloned.output = .{ .success = try alloc.dupe(u8, data) };
            },
            .err => |err_code| {
                cloned.output = .{ .err = err_code };
            },
        }

        return cloned;
    }

    pub fn fromWorkReport(allocator: std.mem.Allocator, report: types.WorkReport) !AccumulationOperands {
        // Ensure there are results in the report
        if (report.results.len == 0) {
            return error.NoResults;
        }

        // Allocate an array of AccumulationOperand with the same length as report.results
        var operands = try allocator.alloc(AccumulationOperands.MaybeNull, report.results.len);
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
            operands[i] = .{ .item = .{
                .output = output,
                .payload_hash = result.payload_hash,
                .work_package_hash = report.package_spec.hash,
                .authorization_output = try allocator.dupe(u8, report.auth_output),
            } };
        }

        return .{ .items = operands };
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
pub const AccumulationResult = struct {
    /// Sequence of deferred transfers resulting from accumulation
    transfers: []DeferredTransfer,

    /// Optional accumulation output hash (null if no output was produced)
    accumulation_output: ?types.AccumulateOutput,

    /// Amount of gas consumed during accumulation
    gas_used: types.Gas,

    pub fn takeTransfers(self: *@This()) []DeferredTransfer {
        const result = self.transfers;
        self.transfers = &[_]DeferredTransfer{};
        return result;
    }

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        alloc.free(self.transfers);
        self.* = undefined;
    }
};
