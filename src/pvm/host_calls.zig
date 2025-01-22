const Memory = @import("memory.zig").Memory;

pub const HostCallResult = union(enum) {
    play,
    page_fault: u32,
};

pub const HostCallFn = *const fn (gas: *i64, registers: *[13]u64, memory: *Memory) HostCallResult;
