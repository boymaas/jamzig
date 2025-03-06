const std = @import("std");
const types = @import("../../types.zig");

const Params = @import("../../jam_params.zig").Params;

const AccumulateHostCalls = @import("host_calls.zig").HostCalls;
const HostCallId = @import("host_calls.zig").HostCallId;

const PVM = @import("../../pvm.zig").PVM;

const trace = @import("../../tracing.zig").scoped(.accumulate);

threadlocal var cached_map: ?std.AutoHashMapUnmanaged(u32, PVM.HostCallFn) = null;

pub fn buildOrGetCached(comptime params: Params, allocator: std.mem.Allocator) !*const std.AutoHashMapUnmanaged(u32, PVM.HostCallFn) {
    const span = trace.span(.build_host_call_fn_map);
    defer span.deinit();

    if (cached_map) |m| {
        return &m;
    }

    var host_call_map = std.AutoHashMapUnmanaged(u32, PVM.HostCallFn){};
    const HostCalls = AccumulateHostCalls(params);

    // Register host calls
    span.debug("Registering host call functions", .{});
    try host_call_map.put(allocator, @intFromEnum(HostCallId.gas), HostCalls.gasRemaining);
    try host_call_map.put(allocator, @intFromEnum(HostCallId.lookup), HostCalls.lookupPreimage);
    // try host_call_map.put(allocator, @intFromEnum(HostCallId.read), host_calls.readStorage);
    try host_call_map.put(allocator, @intFromEnum(HostCallId.write), HostCalls.writeStorage);
    // try host_call_map.put(allocator, @intFromEnum(HostCallId.info), host_calls.getServiceInfo);
    // try host_call_map.put(allocator, @intFromEnum(HostCallId.bless), host_calls.blessService);
    // try host_call_map.put(allocator, @intFromEnum(HostCallId.assign), host_calls.callAssignCore);
    // try host_call_map.put(allocator, @intFromEnum(HostCallId.designate), host_calls.designateValidators);
    // try host_call_map.put(allocator, @intFromEnum(HostCallId.checkpoint), host_calls.checkpoint);
    try host_call_map.put(allocator, @intFromEnum(HostCallId.new), HostCalls.newService);
    // try host_call_map.put(allocator, @intFromEnum(HostCallId.upgrade), host_calls.upgradeService);
    try host_call_map.put(allocator, @intFromEnum(HostCallId.transfer), HostCalls.transfer);
    // try host_call_map.put(allocator, @intFromEnum(HostCallId.eject), host_calls.ejectService);
    // try host_call_map.put(allocator, @intFromEnum(HostCallId.query), host_calls.queryPreimage);
    // try host_call_map.put(allocator, @intFromEnum(HostCallId.solicit), host_calls.solicitPreimage);
    // try host_call_map.put(allocator, @intFromEnum(HostCallId.forget), host_calls.forgetPreimage);
    // try host_call_map.put(allocator, @intFromEnum(HostCallId.yield), host_calls.yieldAccumulateResult);
    cached_map = host_call_map;

    return &cached_map.?;
}

pub fn deinitCachedMap(allocator: std.mem.Allocator) void {
    if (cached_map) |*m| {
        m.deinit(allocator);
    }
}
