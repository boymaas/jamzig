const std = @import("std");

const types = @import("../types.zig");
const state = @import("../state.zig");
const state_keys = @import("../state_keys.zig");

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
const trace = @import("tracing").scoped(.accumulate);

// Replace the AccumulateArgs struct definition with this:
const AccumulateArgs = struct {
    timeslot: types.TimeSlot,
    service_id: types.ServiceId,
    operand_count: u64, // |o| - just the count, not the operands themselves

    /// Encodes according to JAM specification E(t, s, |o|) using varint encoding
    pub fn encode(self: *const @This(), writer: anytype) !void {
        // E(t, s, |o|) - all three values are varint encoded
        try codec.writeInteger(self.timeslot, writer); // t
        try codec.writeInteger(self.service_id, writer); // s
        try codec.writeInteger(self.operand_count, writer); // |o|
    }
};

/// Accumulation Invocation
pub fn invoke(
    comptime params: Params,
    allocator: std.mem.Allocator,
    context: AccumulationContext(params),
    service_id: types.ServiceId,
    gas_limit: types.Gas,
    accumulation_operands: []const AccumulationOperand, // O
) !AccumulationResult(params) {
    const span = trace.span(@src(), .invoke);
    defer span.deinit();
    span.debug("Starting accumulation invocation for service {d}", .{service_id});
    span.debug("Time slot: {d}, Gas limit: {d}, Operand count: {d}", .{ context.time.current_slot, gas_limit, accumulation_operands.len });
    span.trace("Entropy: {s}", .{std.fmt.fmtSliceHexLower(&context.entropy)});

    // Look up the service account - if not found (ejected), return empty result
    const service_account = context.service_accounts.getReadOnly(service_id) orelse {
        span.info("Service {d} not found (likely ejected), returning empty result", .{service_id});
        return try AccumulationResult(params).createEmpty(allocator, context, service_id);
    };

    span.debug("Found service account for ID {d}", .{service_id});

    // Prepare accumulation arguments
    span.debug("Preparing accumulation arguments", .{});
    var args_buffer = std.ArrayList(u8).init(allocator);
    defer args_buffer.deinit();

    const arguments = AccumulateArgs{
        .timeslot = context.time.current_slot,
        .service_id = service_id,
        .operand_count = @intCast(accumulation_operands.len), // Just the count!
    };

    span.trace("AccumulateArgs: timeslot={d}, service_id={d}, operand_count={d}", .{ arguments.timeslot, arguments.service_id, arguments.operand_count });

    // Use the proper JAM varint encoding instead of generic serialization
    try arguments.encode(args_buffer.writer());

    span.trace("AccumulateArgs Encoded ({d} bytes): {}", .{ args_buffer.items.len, std.fmt.fmtSliceHexLower(args_buffer.items) });

    span.debug("Setting up host call functions", .{});
    var host_call_map = try HostCallMap.buildOrGetCached(params, allocator);
    defer host_call_map.deinit(allocator);

    const host_calls = @import("host_calls.zig");

    const accumulate_wrapper = struct {
        fn wrap(
            host_call_fn: pvm.PVM.HostCallFn,
            exec_ctx: *pvm.PVM.ExecutionContext,
            host_ctx: *anyopaque,
        ) pvm.PVM.HostCallResult {
            const result = host_call_fn(exec_ctx, host_ctx) catch |err| switch (err) {
                error.MemoryAccessFault => {
                    // Memory faults cause panic per graypaper
                    return .{ .terminal = .panic };
                },
                else => {
                    // Handle protocol errors by setting register and continuing
                    exec_ctx.registers[7] = @intFromEnum(host_calls.errorToReturnCode(err));

                    return .play;
                },
            };
            return result;
        }
    }.wrap;

    // Create HostCallsConfig with the default catchall and wrapper
    const host_calls_config = pvm.PVM.HostCallsConfig{
        .map = host_call_map,
        .catchall = host_calls.defaultHostCallCatchall,
        .wrapper = accumulate_wrapper,
    };

    span.debug("Cloning accumulation context and updating fetch context", .{});

    // Initialize host call context B.6
    span.debug("Initializing host call context", .{});
    var host_call_context = try AccumulateHostCalls(params).Context.constructUsingRegular(.{
        .allocator = allocator,
        .service_id = service_id,
        // Clone the context for this invocation to ensure isolation
        .context = context,
        .new_service_id = service_util.generateServiceId(&context.service_accounts, service_id, context.entropy, context.time.current_slot),
        .deferred_transfers = std.ArrayList(DeferredTransfer).init(allocator),
        .accumulation_output = null,
        .operands = accumulation_operands,
        .provided_preimages = std.AutoHashMap(AccumulateHostCalls(params).ProvidedKey, []const u8).init(allocator),
    });
    defer host_call_context.deinit();
    span.debug("Generated new service ID: {d}", .{host_call_context.regular.new_service_id});

    // Execute the PVM invocation
    //
    // The ΨA function (Equation B.9) specifies that if ud[s]c = ∅, the function
    // returns a tuple indicating no state change for that service's
    // accumulation, no deferred transfers generated by it, no accumulation
    // output hash, and zero gas consumed for the PVM execution: (I(u,s)u, [], ∅, 0).
    span.debug("Retrieving service code preimage: code_hash={}", .{std.fmt.fmtSliceHexLower(&service_account.code_hash)});
    const code_key = state_keys.constructServicePreimageKey(service_id, service_account.code_hash);
    const code_preimage = service_account.getPreimage(code_key) orelse {
        span.err("Service code not available for hash: {s}", .{std.fmt.fmtSliceHexLower(&service_account.code_hash)});
        return try AccumulationResult(params).createEmpty(allocator, context, service_id);
    };

    span.debug("Retrieved service code with metadata, total length: {d} bytes", .{code_preimage.len});

    span.debug("Starting PVM machine invocation", .{});
    const pvm_span = span.child(@src(), .pvm_invocation);
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
        code_preimage, // Pass the code with metadata directly
        5, // Accumulation entry point index per section 9.1
        @intCast(gas_limit),
        args_buffer.items,
        &host_calls_config,
        @ptrCast(&host_call_context),
    );
    defer result.deinit(allocator);

    pvm_span.debug("PVM invocation completed: {s}", .{@tagName(result.result)});

    // IMPORTANT: Understanding the collapsed dimension and why we still process transfers/preimages:
    //
    // The PVM execution maintains two context dimensions:
    // 1. Regular dimension (x): Contains all state changes from the execution
    // 2. Exceptional dimension (y): Contains the checkpoint/rollback state
    //
    // The checkpoint hostcall (Ω_C) copies regular → exceptional, creating a savepoint.
    //
    // After PVM execution, we collapse to one dimension based on success/failure:
    // - SUCCESS: Use regular dimension (all changes preserved)
    // - FAILURE: Use exceptional dimension (rollback to checkpoint or initial state)
    //
    // The collapsed dimension may contain valid transfers and preimages in THREE scenarios:
    //
    // 1. SUCCESSFUL EXECUTION:
    //    - collapsed_dimension = regular
    //    - Contains all transfers and preimages from the entire execution
    //    - Everything should be applied
    //
    // 2. FAILED EXECUTION WITHOUT CHECKPOINT:
    //    - collapsed_dimension = exceptional (initial state)
    //    - Contains no transfers or preimages (empty initial state)
    //    - Nothing to apply (correct behavior - full rollback)
    //
    // 3. FAILED EXECUTION WITH CHECKPOINT:
    //    - collapsed_dimension = exceptional (checkpoint state)
    //    - Contains transfers and preimages from BEFORE the checkpoint
    //    - These should still be applied (partial commit up to checkpoint)
    //
    // This design allows services to checkpoint successful work before attempting
    // risky operations. If the risky operations fail, the work before the checkpoint
    // is still preserved and applied.
    //
    // Therefore, we ALWAYS extract transfers and apply preimages from the collapsed
    // dimension, regardless of whether the execution succeeded or failed.
    var collapsed_dimension = if (result.result.isSuccess())
        &host_call_context.regular
    else
        &host_call_context.exceptional;

    // Calculate gas used
    const gas_used = result.gas_used;
    span.debug("Gas used for invocation: {d}", .{gas_used});

    // Build the result array of deferred transfers
    // Note: toOwnedSlice() removes items from the ArrayList, but these transfers
    // will be applied later in the accumulation pipeline
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

    // Return the collapsed dimension to the caller, who will apply preimages and commit changes
    // at the appropriate level after all services have been processed
    span.debug("Accumulation invocation completed", .{});
    return AccumulationResult(params){
        .transfers = transfers,
        .accumulation_output = accumulation_output,
        .gas_used = gas_used,
        .collapsed_dimension = try collapsed_dimension.deepCloneHeap(),
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
/// Following JAM protocol naming conventions: h, e, a, y, g, d, o
/// Encoded according to graypaper C.29: E(xh, xe, xa, xy, xg, O(xd), ↕xo)
pub const AccumulationOperand = struct {
    pub const Output = types.WorkExecResult;

    /// h: The hash of the work package
    h: [32]u8,

    /// e: The segment root containing the export
    e: [32]u8,

    /// a: The authorizer hash
    a: [32]u8,

    /// y: The hash of the payload within the work item
    y: [32]u8,

    /// g: Gas used/allocated for this operand
    g: types.Gas,

    /// d: The data output (success or error)
    d: Output,

    /// o: The authorization output blob (variable length)
    o: []const u8,

    /// Encodes according to graypaper C.29: E(xh, xe, xa, xy, xg, O(xd), ↕xo)
    pub fn encode(self: *const @This(), params: anytype, writer: anytype) !void {
        // E(xh, xe, xa, xy, xg, O(xd), ↕xo)
        try writer.writeAll(&self.h); // xh
        try writer.writeAll(&self.e); // xe
        try writer.writeAll(&self.a); // xa
        try writer.writeAll(&self.y); // xy
        try codec.writeInteger(self.g, writer); // xg
        try self.d.encode(params, writer); // O(xd)
        // ↕xo - length-prefixed authorization output
        try codec.writeInteger(@intCast(self.o.len), writer);
        try writer.writeAll(self.o);
    }

    pub fn decode(params: anytype, reader: anytype, allocator: std.mem.Allocator) !@This() {
        var self: @This() = undefined;

        // Read fields in C.29 order: E(xh, xe, xa, xy, xg, O(xd), ↕xo)
        try reader.readNoEof(&self.h); // xh
        try reader.readNoEof(&self.e); // xe
        try reader.readNoEof(&self.a); // xa
        try reader.readNoEof(&self.y); // xy
        self.g = try codec.readInteger(reader); // xg
        self.d = try Output.decode(params, reader, allocator); // O(xd)

        // ↕xo - length-prefixed authorization output
        const o_len = try codec.readInteger(reader);
        self.o = try allocator.alloc(u8, @intCast(o_len));
        errdefer allocator.free(self.o);
        try reader.readNoEof(self.o);

        return self;
    }

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
            const output: Output = try result.result.deepClone(allocator);

            // Set up the operand according to JAM protocol fields (h, e, a, o, y, d)
            operands[i] = .{
                .item = .{
                    .h = report.package_spec.hash, // Work package hash
                    .e = report.package_spec.exports_root, // Segment root
                    .a = report.authorizer_hash, // Authorizer hash
                    .g = result.accumulate_gas,
                    .o = try allocator.dupe(u8, report.auth_output), // Authorization output
                    .y = result.payload_hash, // Payload hash
                    .d = output, // Data output (success or error)
                },
            };
        }

        return .{ .items = operands };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.d.deinit(allocator);
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
        .{ .ok = try alloc.dupe(u8, &[_]u8{ 1, 2, 3, 4, 5 }) },
        .{ .out_of_gas = {} },
        .{ .panic = {} },
        .{ .bad_exports = {} },
        .{ .oversize = {} },
        .{ .bad_code = {} },
        .{ .code_oversize = {} },
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
            if (decoded == .ok) {
                alloc.free(decoded.ok);
            }
        }

        // Compare
        try testing.expectEqual(@as(std.meta.Tag(AccumulationOperand.Output), output), @as(std.meta.Tag(AccumulationOperand.Output), decoded));

        switch (output) {
            .ok => |data| {
                try testing.expectEqualSlices(u8, data, decoded.ok);
            },
            else => {},
        }
    }
}

/// Return type for the accumulation invoke function,
/// Parameterized to allow proper typing of the collapsed dimension
pub fn AccumulationResult(comptime params: Params) type {
    return struct {
        /// Sequence of deferred transfers resulting from accumulation
        transfers: []DeferredTransfer,

        /// Optional accumulation output hash (null if no output was produced)
        accumulation_output: ?types.AccumulateOutput,

        /// Amount of gas consumed during accumulation
        gas_used: types.Gas,

        /// The collapsed dimension containing all state changes from accumulation
        /// This allows the caller to apply preimages and commit changes at the appropriate level
        collapsed_dimension: *AccumulateHostCalls(params).Dimension,

        /// Create an empty result with a valid dimension
        /// The caller must provide an allocator and context reference
        pub fn createEmpty(allocator: std.mem.Allocator, context: AccumulationContext(params), service_id: types.ServiceId) !@This() {
            const dimension = try allocator.create(AccumulateHostCalls(params).Dimension);
            dimension.* = .{
                .allocator = allocator,
                .context = context,
                .service_id = service_id,
                .new_service_id = service_id, // No new service generated for empty result
                .deferred_transfers = std.ArrayList(DeferredTransfer).init(allocator),
                .accumulation_output = null,
                .operands = &[_]@import("accumulate.zig").AccumulationOperand{},
                .provided_preimages = std.AutoHashMap(AccumulateHostCalls(params).ProvidedKey, []const u8).init(allocator),
            };

            return @This(){
                .transfers = &[_]DeferredTransfer{},
                .accumulation_output = null,
                .gas_used = 0,
                .collapsed_dimension = dimension,
            };
        }

        pub fn takeTransfers(self: *@This()) []DeferredTransfer {
            const result = self.transfers;
            self.transfers = &[_]DeferredTransfer{};
            return result;
        }

        pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
            alloc.free(self.transfers);
            // Now we own the dimension and must clean it up
            self.collapsed_dimension.deinit();
            alloc.destroy(self.collapsed_dimension);
            self.* = undefined;
        }
    };
}
