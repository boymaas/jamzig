const std = @import("std");
const Allocator = std.mem.Allocator;

const PVM = @import("../pvm.zig").PVM;

const trace = @import("../tracing.zig").scoped(.pvm);

pub fn machineInvocation(
    allocator: std.mem.Allocator,
    program_code: []const u8,
    pc: u32,
    gas: u32,
    args: []const u8,
    host_call_fns: *const PVM.HostCallMap,
    host_call_ctx: *anyopaque,
) PVM.Error!PVM.MachineInvocationResult {
    const span = trace.span(.machine_invocation);
    defer span.deinit();
    span.debug("Starting machine invocation with {d} gas", .{gas});

    // try to parse the code format. If we run into an error
    // here we should return a panic
    var exec_ctx = PVM.ExecutionContext.initStandardProgramCodeFormat(
        allocator,
        program_code,
        args,
        std.math.maxInt(u32),
    ) catch {
        return .{ .terminal = .panic };
    };
    defer exec_ctx.deinit(allocator);

    // Set up registers and PC
    exec_ctx.initRegisters(args.len);
    exec_ctx.pc = pc;

    // Register host calls
    exec_ctx.setHostCalls(host_call_fns);

    // Run the machine invocation
    return PVM.machineInvocation(allocator, &exec_ctx, host_call_ctx);
}
