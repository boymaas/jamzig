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

/// Machine invocation function implementing the Y function from the JAM specification.
/// Y: (Y, Y_{:Z_I}) → (Y, regs, ram)?
/// 
/// The function takes a program blob (p) and argument data (a) as separate parameters,
/// where the program blob may optionally contain metadata prefix followed by the standard format:
/// [optional: E(|metadata|) ∥ metadata] ∥ E_3(|o|) ∥ E_3(|w|) ∥ E_2(z) ∥ E_3(s) ∥ o ∥ w ∥ E_4(|c|) ∥ c
/// and the argument data is passed separately and limited to Z_I bytes.
pub fn machineInvocation(
    allocator: std.mem.Allocator,
    program_code_with_metadata: []const u8,
    pc: u32,
    gas: u32,
    args: []const u8,
    host_calls_config: *const PVM.HostCallsConfig,
    host_call_ctx: *anyopaque,
) PVM.Error!MachineInvocationResult {
    const span = trace.span(.machine_invocation);
    defer span.deinit();
    span.debug("Starting machine invocation with {d} gas", .{gas});

    // try to parse the code format. If we run into an error
    // here we should return a panic
    var exec_ctx = PVM.ExecutionContext.initStandardProgramCodeFormatWithMetadata(
        allocator,
        program_code_with_metadata,
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

    // Register host calls (pass as anyopaque to avoid circular dependency)
    exec_ctx.setHostCalls(@ptrCast(host_calls_config));

    // result
    const result = try PVM.machineInvocation(allocator, &exec_ctx, host_call_ctx);

    // Run the machine invocation
    return .{
        .result = result,
        .gas_used = @intCast(@as(i64, gas) - exec_ctx.gas),
    };
}
