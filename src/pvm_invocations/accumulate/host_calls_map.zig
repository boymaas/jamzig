const std = @import("std");
const types = @import("../../types.zig");

const Params = @import("../../jam_params.zig").Params;

const HostCallsAccumulate = @import("host_calls.zig").HostCalls;
const HostCallId = @import("../host_calls.zig").Id;

const PVM = @import("../../pvm.zig").PVM;

const trace = @import("../../tracing.zig").scoped(.accumulate);

pub fn buildOrGetCached(comptime params: Params, allocator: std.mem.Allocator) !std.AutoHashMapUnmanaged(u32, PVM.HostCallFn) {
    const span = trace.span(.build_host_call_fn_map);
    defer span.deinit();

    var host_call_map = std.AutoHashMapUnmanaged(u32, PVM.HostCallFn){};
    const HostCall = HostCallsAccumulate(params);

    // Register host calls
    span.debug("Registering host call functions", .{});
    try host_call_map.put(allocator, @intFromEnum(HostCallId.gas), HostCall.gasRemaining);
    try host_call_map.put(allocator, @intFromEnum(HostCallId.lookup), HostCall.lookupPreimage);
    try host_call_map.put(allocator, @intFromEnum(HostCallId.read), HostCall.readStorage);
    try host_call_map.put(allocator, @intFromEnum(HostCallId.write), HostCall.writeStorage);
    try host_call_map.put(allocator, @intFromEnum(HostCallId.info), HostCall.infoService);
    try host_call_map.put(allocator, @intFromEnum(HostCallId.bless), HostCall.blessService);
    try host_call_map.put(allocator, @intFromEnum(HostCallId.assign), HostCall.assignCore);
    // try host_call_map.put(allocator, @intFromEnum(HostCallId.designate), host_calls.designateValidators);
    try host_call_map.put(allocator, @intFromEnum(HostCallId.checkpoint), HostCall.checkpoint);
    try host_call_map.put(allocator, @intFromEnum(HostCallId.new), HostCall.newService);
    try host_call_map.put(allocator, @intFromEnum(HostCallId.upgrade), HostCall.upgradeService);
    try host_call_map.put(allocator, @intFromEnum(HostCallId.transfer), HostCall.transfer);
    try host_call_map.put(allocator, @intFromEnum(HostCallId.eject), HostCall.ejectService);
    try host_call_map.put(allocator, @intFromEnum(HostCallId.query), HostCall.queryPreimage);
    try host_call_map.put(allocator, @intFromEnum(HostCallId.solicit), HostCall.solicitPreimage);
    try host_call_map.put(allocator, @intFromEnum(HostCallId.forget), HostCall.forgetPreimage);
    try host_call_map.put(allocator, @intFromEnum(HostCallId.yield), HostCall.yieldAccumulationResult);

    return host_call_map;
}
