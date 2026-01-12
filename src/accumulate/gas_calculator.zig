const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const Params = @import("../jam_params.zig").Params;

const trace = @import("tracing").scoped(.accumulate);

pub const GasError = error{
    GasOverflow,
    InvalidGasLimit,
};

pub fn GasCalculator(comptime params: Params) type {
    return struct {
        const Self = @This();

        pub fn calculateGasLimit(self: Self, chi: *state.Chi(params.core_count)) u64 {
            _ = self;
            const span = trace.span(@src(), .calculate_gas_limit);
            defer span.deinit();

            var gas_limit: u64 = params.total_gas_alloc_accumulation;

            const core_gas = @as(u64, params.gas_alloc_accumulation) * @as(u64, params.core_count);

            var free_services_gas: u64 = 0;
            var it = chi.always_accumulate.iterator();
            while (it.next()) |entry| {
                free_services_gas += entry.value_ptr.*;
            }

            const calculated_gas = core_gas + free_services_gas;
            if (calculated_gas > gas_limit) {
                gas_limit = calculated_gas;
            }

            span.debug("Gas limit calculated: {d} (G_T: {d}, core gas: {d}, free services gas: {d})", .{
                gas_limit,
                params.total_gas_alloc_accumulation,
                core_gas,
                free_services_gas
            });

            return gas_limit;
        }

        pub fn validateGasAmount(self: Self, gas: u64) !void {
            _ = self;
            if (gas > params.total_gas_alloc_accumulation * 2) {
                return error.InvalidGasLimit;
            }
        }

        pub fn calculateServiceGasLimits(
            self: Self,
            work_reports: []const types.WorkReport,
        ) !std.AutoHashMap(types.ServiceId, u64) {
            _ = self;
            const span = trace.span(@src(), .calculate_service_gas_limits);
            defer span.deinit();

            var service_gas = std.AutoHashMap(types.ServiceId, u64).init(span.allocator);
            errdefer service_gas.deinit();

            for (work_reports) |report| {
                for (report.results) |result| {
                    const current = service_gas.get(result.service_id) orelse 0;
                    const new_gas = current + result.accumulate_gas;
                    
                    // Check for overflow
                    if (new_gas < current) {
                        return error.GasOverflow;
                    }
                    
                    try service_gas.put(result.service_id, new_gas);
                }
            }

            span.debug("Calculated gas limits for {d} services", .{service_gas.count()});
            return service_gas;
        }
    };
}