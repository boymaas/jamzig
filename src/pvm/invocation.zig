const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("../types.zig");

const PVM = @import("../pvm.zig").PVM;

const trace = @import("../tracing.zig").scoped(.pvm);

const MachineInvocationResult = struct {
    gas_used: types.Gas,
    result: PVM.MachineInvocationResult,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.result.deinit(allocator);

        // Mark as undefined to prevent use-after-free
        self.* = undefined;
    }
};

pub fn machineInvocation(
    allocator: std.mem.Allocator,
    program_code: []const u8,
    pc: u32,
    gas: u32,
    args: []const u8,
    host_call_fns: *const PVM.HostCallMap,
    host_call_ctx: *anyopaque,
) PVM.Error!MachineInvocationResult {
    const span = trace.span(.machine_invocation);
    defer span.deinit();
    span.debug("Starting machine invocation with {d} gas", .{gas});

    // try to parse the code format. If we run into an error
    // here we should return a panic
    // TODO: we have now initStandardProgramCodeFormatWithMetaData which we can use
    var exec_ctx = PVM.ExecutionContext.initStandardProgramCodeFormat(
        allocator,
        program_code,
        args,
        gas,
        true, // enable dynamic allocation by default for machine invocations
    ) catch {
        return .{ .gas_used = 0, .result = .{ .terminal = .panic } };
    };
    defer exec_ctx.deinit(allocator);

    // Set up registers and PC
    exec_ctx.initRegisters(args.len);
    exec_ctx.pc = pc;

    // Register host calls
    exec_ctx.setHostCalls(host_call_fns);

    // result
    const result = try PVM.machineInvocation(allocator, &exec_ctx, host_call_ctx);

    // Run the machine invocation
    return .{
        .result = result,
        .gas_used = @intCast(@as(i64, gas) - exec_ctx.gas),
    };
}
