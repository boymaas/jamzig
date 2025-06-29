const std = @import("std");
const types = @import("../../types.zig");
const state = @import("../../state.zig");

const general = @import("../host_calls_general.zig");
const Params = @import("../../jam_params.zig").Params;

const ReturnCode = @import("../host_calls.zig").ReturnCode;
const DeltaSnapshot = @import("../../services_snapshot.zig").DeltaSnapshot;

const PVM = @import("../../pvm.zig").PVM;

// Add tracing import
const trace = @import("../../tracing.zig").scoped(.host_calls);

pub fn HostCalls(comptime params: Params) type {
    return struct {
        // Simplified context for OnTransfer execution (B.5 in the graypaper)
        // Except that the only state alteration it facilitates are basic alteration to the
        // storage of the subject account.
        // TODO: make sure no other mutable acess to service account is allowed from this context
        pub const Context = struct {
            service_id: types.ServiceId,
            service_accounts: DeltaSnapshot,
            allocator: std.mem.Allocator,

            const Self = @This();

            pub fn commit(self: *Self) !void {
                try self.service_accounts.commit();
            }

            pub fn deepClone(self: Self) !Self {
                return Self{
                    .service_accounts = try self.service_accounts.deepClone(),
                    .service_id = self.service_id,
                    .allocator = self.allocator,
                };
            }

            pub fn toGeneralContext(self: *Self) general.GeneralHostCalls(params).Context {
                // Create ontransfer-specific invocation context
                const invocation_ctx = general.GeneralHostCalls(params).InvocationContext{
                    .ontransfer = .{
                        // Note: transfer_memo would be set if available
                        .transfer_memo = null,
                    }
                };
                
                return general.GeneralHostCalls(params).Context.initWithContext(
                    self.service_id,
                    &self.service_accounts,
                    self.allocator,
                    invocation_ctx,
                );
            }

            pub fn deinit(self: *Self) void {
                self.service_accounts.deinit();
                self.* = undefined;
            }
        };

        /// Host call implementation for gas remaining (Ω_G)
        pub fn gasRemaining(
            exec_ctx: *PVM.ExecutionContext,
            _: ?*anyopaque,
        ) PVM.HostCallResult {
            return general.GeneralHostCalls(params).gasRemaining(exec_ctx);
        }

        /// Host call implementation for lookup preimage (Ω_L)
        pub fn lookupPreimage(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) PVM.HostCallResult {
            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));

            return general.GeneralHostCalls(params).lookupPreimage(
                exec_ctx,
                host_ctx.toGeneralContext(),
            );
        }

        /// Host call implementation for read storage (Ω_R)
        pub fn readStorage(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) PVM.HostCallResult {
            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));

            return general.GeneralHostCalls(params).readStorage(
                exec_ctx,
                host_ctx.toGeneralContext(),
            );
        }

        /// Host call implementation for write storage (Ω_W)
        pub fn writeStorage(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) PVM.HostCallResult {
            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));

            const general_context = host_ctx.toGeneralContext();
            return general.GeneralHostCalls(params).writeStorage(
                exec_ctx,
                general_context,
            );
        }

        /// Host call implementation for info service (Ω_I)
        pub fn infoService(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) PVM.HostCallResult {
            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));

            return general.GeneralHostCalls(params).infoService(
                exec_ctx,
                host_ctx.toGeneralContext(),
            );
        }

        /// Host call implementation for fetch (Ω_Y)
        pub fn fetch(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) PVM.HostCallResult {
            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));

            return general.GeneralHostCalls(params).fetch(
                exec_ctx,
                host_ctx.toGeneralContext(),
            );
        }

        pub fn debugLog(
            exec_ctx: *PVM.ExecutionContext,
            _: ?*anyopaque,
        ) PVM.HostCallResult {
            return general.GeneralHostCalls(params).debugLog(
                exec_ctx,
            );
        }
    };
}
