const std = @import("std");

const types = @import("../types.zig");
const state = @import("../state.zig");

const codec = @import("../codec.zig");

const pvm = @import("../pvm.zig");
const pvm_invocation = @import("../pvm/invocation.zig");

const service_util = @import("accumulate/service_util.zig");

pub const AccumulationContext = @import("accumulate/context.zig").AccumulationContext;
pub const DeferredTransfer = @import("accumulate/types.zig").DeferredTransfer;
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

    span.trace("AccumulateArgs:  {}\n", .{types.fmt.format(arguments)});

    try codec.serialize(AccumulateArgs, .{}, args_buffer.writer(), arguments);

    span.trace("AccumulateArgs Encoded: {}", .{std.fmt.fmtSliceHexLower(args_buffer.items)});

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
            const metadata = data[result.bytes_read..result.value];
            const code = data[result.bytes_read + result.value ..];

            return .{ .code = code, .metadata = metadata };
        }
    };

    const code_with_metadata = try CodeWithMetadata.decode(code_preimage);

    span.debug("Retrieved service code, length: {d} bytes. Metadata: {d} bytes", .{ code_with_metadata.code.len, code_with_metadata.metadata.len });

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
        code_with_metadata.code,
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

    span.debug("Accumulation invocation completed", .{});
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
/// Following JAM protocol naming conventions: h, e, a, o, y, d
pub const AccumulationOperand = struct {
    pub const Output = union(enum) {
        /// Represents possible error types from work execution
        const WorkExecutionError = enum(u8) {
            OutOfGas = 1, // ∞
            ProgramTermination = 2, // ☇
            InvalidExportCount = 3, // ⊚
            ServiceCodeUnavailable = 4, // BAD
            ServiceCodeTooLarge = 5, // BIG
        };

        /// Successful execution output as an octet sequence
        success: []const u8,
        /// Error code if execution failed
        err: WorkExecutionError,

        pub fn encode(value: *const @This(), _: anytype, writer: anytype) !void {
            // First write a tag byte based on the union variant
            switch (value.*) {
                .success => |data| {
                    // For success, write 0 followed by the length and data
                    try writer.writeByte(0);
                    try codec.writeInteger(@intCast(data.len), writer);
                    try writer.writeAll(data);
                },
                .err => |err_code| {
                    // For error types, simply write the error code's integer value
                    try writer.writeByte(@intFromEnum(err_code));
                },
            }
        }

        pub fn decode(_: anytype, reader: anytype, allocator: std.mem.Allocator) !@This() {
            // Read the tag byte to determine the variant
            const tag = try reader.readByte();

            // Tag 0 indicates success, other values map to error codes
            return switch (tag) {
                0 => blk: {
                    // Success variant contains length-prefixed data
                    const length = try codec.readInteger(reader);
                    const data = try allocator.alloc(u8, @intCast(length)); // FIXME: check on max size before allocating
                    errdefer allocator.free(data);

                    try reader.readNoEof(data);
                    break :blk .{ .success = data };
                },
                1 => .{ .err = .OutOfGas },
                2 => .{ .err = .ProgramTermination },
                3 => .{ .err = .InvalidExportCount },
                4 => .{ .err = .ServiceCodeUnavailable },
                5 => .{ .err = .ServiceCodeTooLarge },
                else => error.InvalidOutputTag,
            };
        }
    };

    /// h: The hash of the work package
    h: [32]u8,

    /// e: The segment root containing the export
    e: [32]u8,

    /// a: The authorizer hash
    a: [32]u8,

    /// o: The authorization output blob
    o: []const u8,

    /// y: The hash of the payload within the work item
    y: [32]u8,

    /// d: The data output (success or error)
    d: Output,

    pub fn deepClone(self: @This(), alloc: std.mem.Allocator) !@This() {
        // Create a new operand with deep copies of all dynamic data
        var cloned = @This(){
            .h = self.h,
            .e = self.e,
            .a = self.a,
            .y = self.y,
            .o = try alloc.dupe(u8, self.o),
            .d = undefined,
        };

        // Deep copy the output based on its type
        switch (self.d) {
            .success => |data| {
                cloned.d = .{ .success = try alloc.dupe(u8, data) };
            },
            .err => |err_code| {
                cloned.d = .{ .err = err_code };
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

            // Set up the operand according to JAM protocol fields (h, e, a, o, y, d)
            operands[i] = .{
                .item = .{
                    .h = report.package_spec.hash, // Work package hash
                    .e = report.package_spec.exports_root, // Segment root
                    .a = report.authorizer_hash, // Authorizer hash
                    .o = try allocator.dupe(u8, report.auth_output), // Authorization output
                    .y = result.payload_hash, // Payload hash
                    .d = output, // Data output (success or error)
                },
            };
        }

        return .{ .items = operands };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.d == .success) {
            allocator.free(self.d.success);
        }

        // Free the authorization output
        allocator.free(self.o);
        self.* = undefined;
    }
};

test "AccumulationOperand.Output encode/decode" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Test all possible Output variants
    const test_cases = [_]AccumulationOperand.Output{
        .{ .success = try alloc.dupe(u8, &[_]u8{ 1, 2, 3, 4, 5 }) },
        .{ .err = .OutOfGas },
        .{ .err = .ProgramTermination },
        .{ .err = .InvalidExportCount },
        .{ .err = .ServiceCodeUnavailable },
        .{ .err = .ServiceCodeTooLarge },
    };

    for (test_cases) |output| {
        // Encode
        var buffer = std.ArrayList(u8).init(alloc);
        defer buffer.deinit();

        try output.encode(.{}, buffer.writer());
        const encoded = buffer.items;

        // Decode
        var fbs = std.io.fixedBufferStream(encoded);
        const reader = fbs.reader();
        const decoded = try AccumulationOperand.Output.decode(.{}, reader, alloc);
        defer {
            if (decoded == .success) {
                alloc.free(decoded.success);
            }
        }

        // Compare
        try testing.expectEqual(@as(std.meta.Tag(AccumulationOperand.Output), output), @as(std.meta.Tag(AccumulationOperand.Output), decoded));

        switch (output) {
            .success => |data| {
                try testing.expectEqualSlices(u8, data, decoded.success);
            },
            .err => |code| {
                try testing.expectEqual(code, decoded.err);
            },
        }
    }
}

/// Return type for the accumulation invoke function,
pub const AccumulationResult = struct {
    /// Sequence of deferred transfers resulting from accumulation
    transfers: []DeferredTransfer,

    /// Optional accumulation output hash (null if no output was produced)
    accumulation_output: ?types.AccumulateOutput,

    /// Amount of gas consumed during accumulation
    gas_used: types.Gas,

    pub const Empty = @This(){
        .transfers = &[_]DeferredTransfer{},
        .accumulation_output = null,
        .gas_used = 0,
    };

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
