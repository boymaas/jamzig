const Memory = @import("memory.zig").Memory;
const ExecutionContext = @import("execution_context.zig").ExecutionContext;

pub const HostCallResult = union(enum) {
    play,
    page_fault: u32,
};

pub const HostCallFn = *const fn (*ExecutionContext) HostCallResult;
