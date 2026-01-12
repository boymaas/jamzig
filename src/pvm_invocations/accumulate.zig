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

const trace = @import("tracing").scoped(.accumulate);
const trace_hostcalls = @import("tracing").scoped(.host_calls);

const AccumulateArgs = struct {
    timeslot: types.TimeSlot,
    service_id: types.ServiceId,
    operand_count: u64,

    pub fn encode(self: *const @This(), writer: anytype) !void {
        try codec.writeInteger(self.timeslot, writer);
        try codec.writeInteger(self.service_id, writer);
        try codec.writeInteger(self.operand_count, writer);
    }
};

pub fn invoke(
    comptime params: Params,
    allocator: std.mem.Allocator,
    context: AccumulationContext(params),
    service_id: types.ServiceId,
    gas_limit: types.Gas,
    accumulation_operands: []const AccumulationOperand,
    incoming_transfers: []const TransferOperand,
) !AccumulationResult(params) {
    const span = trace.span(@src(), .invoke);
    defer span.deinit();
    span.debug("Starting accumulation invocation for service {d}", .{service_id});
    span.debug("Time slot: {d}, Gas limit: {d}, Operands: {d}, Transfers: {d}", .{
        context.time.current_slot, gas_limit, accumulation_operands.len, incoming_transfers.len,
    });
    span.trace("Entropy: {s}", .{std.fmt.fmtSliceHexLower(&context.entropy)});

    const service_account = context.service_accounts.getReadOnly(service_id) orelse {
        span.info("Service {d} not found (likely ejected), returning empty result", .{service_id});
        return try AccumulationResult(params).createEmpty(allocator, context, service_id);
    };

    span.debug("Found service account for ID {d}", .{service_id});

    var transfer_count: usize = 0;
    for (incoming_transfers) |transfer| {
        if (transfer.destination == service_id) {
            transfer_count += 1;
        }
    }

    span.debug("Checking code availability: code_hash={}", .{std.fmt.fmtSliceHexLower(&service_account.code_hash)});
    const code_key = state_keys.constructServicePreimageKey(service_id, service_account.code_hash);
    const code_preimage = service_account.getPreimage(code_key) orelse {
        span.err("Service code not available for hash: {s}", .{std.fmt.fmtSliceHexLower(&service_account.code_hash)});
        return try AccumulationResult(params).createEmpty(allocator, context, service_id);
    };
    span.debug("Code available, total length: {d} bytes", .{code_preimage.len});

    var args_buffer = std.ArrayList(u8).init(allocator);
    defer args_buffer.deinit();

    const arguments = AccumulateArgs{
        .timeslot = context.time.current_slot,
        .service_id = service_id,
        .operand_count = @intCast(accumulation_operands.len + transfer_count),
    };

    span.trace("AccumulateArgs: timeslot={d}, service_id={d}, operand_count={d}", .{ arguments.timeslot, arguments.service_id, arguments.operand_count });

    try arguments.encode(args_buffer.writer());

    span.trace("AccumulateArgs Encoded ({d} bytes): {}", .{ args_buffer.items.len, std.fmt.fmtSliceHexLower(args_buffer.items) });

    var host_call_map = try HostCallMap.buildOrGetCached(params, allocator);
    defer host_call_map.deinit(allocator);

    const host_calls = @import("host_calls.zig");

    const accumulate_wrapper = struct {
        fn wrap(
            host_call_id: u32,
            host_call_fn: pvm.PVM.HostCallFn,
            exec_ctx: *pvm.PVM.ExecutionContext,
            host_ctx: *anyopaque,
        ) pvm.PVM.HostCallResult {
            const gas_before = exec_ctx.gas;

            {
                const enum_val: host_calls.Id = @enumFromInt(host_call_id);
                const hc_span = trace_hostcalls.span(@src(), .host_call_pre);
                defer hc_span.deinit();
                hc_span.debug(">>> {s} gas_before={d}", .{ @tagName(enum_val), gas_before });
            }

            const result = host_call_fn(exec_ctx, host_ctx) catch |err| switch (err) {
                error.MemoryAccessFault => {
                    return .{ .terminal = .panic };
                },
                else => {
                    exec_ctx.registers[7] = @intFromEnum(host_calls.errorToReturnCode(err));

                    return .play;
                },
            };

            {
                const enum_val: host_calls.Id = @enumFromInt(host_call_id);
                const hc_span = trace_hostcalls.span(@src(), .host_call_post);
                defer hc_span.deinit();
                const gas_charged = gas_before - exec_ctx.gas;
                hc_span.debug("<<< {s} gas_after={d} gas_charged={d}", .{
                    @tagName(enum_val),
                    exec_ctx.gas,
                    gas_charged,
                });
            }

            return result;
        }
    }.wrap;

    const host_calls_config = pvm.PVM.HostCallsConfig{
        .map = host_call_map,
        .catchall = host_calls.defaultHostCallCatchall,
        .wrapper = accumulate_wrapper,
    };

    span.debug("Cloning accumulation context and updating fetch context", .{});

    var transfers_for_service = std.ArrayList(TransferOperand).init(allocator);
    defer transfers_for_service.deinit();

    for (incoming_transfers) |transfer| {
        if (transfer.destination == service_id) {
            try transfers_for_service.append(transfer);
        }
    }

    const transfers_slice = try transfers_for_service.toOwnedSlice();
    defer allocator.free(transfers_slice);

    span.debug("Filtered {d} incoming transfers for service {d}", .{ transfers_slice.len, service_id });

    var host_call_context = try AccumulateHostCalls(params).Context.constructUsingRegular(.{
        .allocator = allocator,
        .service_id = service_id,
        .context = context,
        .new_service_id = service_util.generateServiceId(&context.service_accounts, service_id, context.entropy, context.time.current_slot),
        .incoming_transfers = transfers_slice,
        .generated_transfers = std.ArrayList(TransferOperand).init(allocator),
        .accumulation_output = null,
        .operands = accumulation_operands,
        .provided_preimages = std.AutoHashMap(AccumulateHostCalls(params).ProvidedKey, []const u8).init(allocator),
    });
    defer host_call_context.deinit();
    span.debug("Generated new service ID: {d}", .{host_call_context.regular.new_service_id});

    span.debug("Starting PVM machine invocation", .{});
    const pvm_span = span.child(@src(), .pvm_invocation);
    defer pvm_span.deinit();

    var result = try pvm_invocation.machineInvocation(
        allocator,
        code_preimage,
        5,
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

    const gas_used = result.gas_used;
    span.debug("Gas used for invocation: {d}", .{gas_used});

    const accumulation_output: ?[32]u8 = outer: switch (result.result) {
        .halt => |output| {
            if (output.len == 32) {
                break :outer output[0..32].*;
            }
            break :outer collapsed_dimension.accumulation_output;
        },
        else => collapsed_dimension.accumulation_output,
    };

    span.debug("Accumulation invocation completed", .{});

    const generated_transfers = try collapsed_dimension.generated_transfers.toOwnedSlice();
    span.debug("Number of generated transfers (for next service): {d}", .{generated_transfers.len});

    return AccumulationResult(params){
        .generated_transfers = generated_transfers,
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
        for (self.items) |*operand| {
            operand.deinit(allocator);
        }

        allocator.free(self.items);
        self.* = undefined;
    }
};

pub const TransferOperand = struct {
    sender: types.ServiceId,
    destination: types.ServiceId,
    amount: types.Balance,
    memo: [128]u8,
    gas_limit: types.Gas,
};

pub const AccumulationOperand = struct {
    pub const Output = types.WorkExecResult;

    h: [32]u8,
    e: [32]u8,
    a: [32]u8,
    y: [32]u8,
    g: types.Gas,
    d: Output,
    o: []const u8,

    /// Encodes according to graypaper C.29: E(xh, xe, xa, xy, xg, O(xd), ↕xo)
    pub fn encode(self: *const @This(), params: anytype, writer: anytype) !void {
        try writer.writeAll(&self.h);
        try writer.writeAll(&self.e);
        try writer.writeAll(&self.a);
        try writer.writeAll(&self.y);
        try codec.writeInteger(self.g, writer);
        try self.d.encode(params, writer);
        try codec.writeInteger(@intCast(self.o.len), writer);
        try writer.writeAll(self.o);
    }

    pub fn decode(params: anytype, reader: anytype, allocator: std.mem.Allocator) !@This() {
        var self: @This() = undefined;

        try reader.readNoEof(&self.h);
        try reader.readNoEof(&self.e);
        try reader.readNoEof(&self.a);
        try reader.readNoEof(&self.y);
        self.g = try codec.readInteger(reader);
        self.d = try Output.decode(params, reader, allocator);

        const o_len = try codec.readInteger(reader);
        self.o = try allocator.alloc(u8, @intCast(o_len));
        errdefer allocator.free(self.o);
        try reader.readNoEof(self.o);

        return self;
    }

    pub fn deepClone(self: @This(), alloc: std.mem.Allocator) !@This() {
        var cloned = @This(){
            .h = self.h,
            .e = self.e,
            .a = self.a,
            .y = self.y,
            .o = try alloc.dupe(u8, self.o),
            .d = undefined,
        };

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
        if (report.results.len == 0) {
            return error.NoResults;
        }

        var operands = try allocator.alloc(AccumulationOperands.MaybeNull, report.results.len);
        errdefer {
            for (operands) |*operand| {
                operand.deinit(allocator);
            }
            allocator.free(operands);
        }

        for (report.results, 0..) |result, i| {
            const output: Output = try result.result.deepClone(allocator);

            operands[i] = .{
                .item = .{
                    .h = report.package_spec.hash,
                    .e = report.package_spec.exports_root,
                    .a = report.authorizer_hash,
                    .g = result.accumulate_gas,
                    .o = try allocator.dupe(u8, report.auth_output),
                    .y = result.payload_hash,
                    .d = output,
                },
            };
        }

        return .{ .items = operands };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.d.deinit(allocator);
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
        /// Transfers generated during THIS accumulation for inline processing (v0.7.1)
        generated_transfers: []TransferOperand,

        /// Optional accumulation output hash (null if no output was produced)
        accumulation_output: ?types.AccumulateOutput,

        /// Amount of gas consumed during accumulation
        gas_used: types.Gas,

        /// The collapsed dimension containing all state changes from accumulation
        collapsed_dimension: *AccumulateHostCalls(params).Dimension,

        /// Create an empty result with a valid dimension
        /// The caller must provide an allocator and context reference
        pub fn createEmpty(allocator: std.mem.Allocator, context: AccumulationContext(params), service_id: types.ServiceId) !@This() {
            const dimension = try allocator.create(AccumulateHostCalls(params).Dimension);
            dimension.* = .{
                .allocator = allocator,
                .context = context,
                .service_id = service_id,
                .new_service_id = service_id,
                .incoming_transfers = &[_]TransferOperand{},
                .generated_transfers = std.ArrayList(TransferOperand).init(allocator),
                .accumulation_output = null,
                .operands = &[_]@import("accumulate.zig").AccumulationOperand{},
                .provided_preimages = std.AutoHashMap(AccumulateHostCalls(params).ProvidedKey, []const u8).init(allocator),
            };

            return @This(){
                .generated_transfers = &[_]TransferOperand{},
                .accumulation_output = null,
                .gas_used = 0,
                .collapsed_dimension = dimension,
            };
        }

        pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
            alloc.free(self.generated_transfers);
            self.collapsed_dimension.deinit();
            alloc.destroy(self.collapsed_dimension);
            self.* = undefined;
        }
    };
}
