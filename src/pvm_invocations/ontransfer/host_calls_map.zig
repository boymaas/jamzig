const std = @import("std");
const types = @import("../../types.zig");

const Params = @import("../../jam_params.zig").Params;

const HostCallsOnTransfer = @import("host_calls.zig").HostCalls;
const HostCallId = @import("../host_calls.zig").Id;

const PVM = @import("../../pvm.zig").PVM;

const trace = @import("../../tracing.zig").scoped(.ontransfer);

pub fn buildOrGetCached(comptime params: Params, allocator: std.mem.Allocator) !std.AutoHashMapUnmanaged(u32, PVM.HostCallFn) {
    const span = trace.span(.build_host_call_fn_map);
    defer span.deinit();

    var host_call_map = std.AutoHashMapUnmanaged(u32, PVM.HostCallFn){};
    const HostCalls = HostCallsOnTransfer(params);

    // Register host calls
    span.debug("Registering host call functions", .{});
    try host_call_map.put(allocator, @intFromEnum(HostCallId.gas), HostCalls.gasRemaining);
    try host_call_map.put(allocator, @intFromEnum(HostCallId.fetch), HostCalls.fetch);
    try host_call_map.put(allocator, @intFromEnum(HostCallId.lookup), HostCalls.lookupPreimage);
    try host_call_map.put(allocator, @intFromEnum(HostCallId.read), HostCalls.readStorage);
    try host_call_map.put(allocator, @intFromEnum(HostCallId.write), HostCalls.writeStorage);
    try host_call_map.put(allocator, @intFromEnum(HostCallId.info), HostCalls.infoService);

    try host_call_map.put(allocator, @intFromEnum(HostCallId.log), HostCalls.debugLog);

    return host_call_map;
}
