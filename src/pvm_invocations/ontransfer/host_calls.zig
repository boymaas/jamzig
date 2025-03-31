const std = @import("std");
const types = @import("../../types.zig");
const state = @import("../../state.zig");

const general = @import("../host_calls_general.zig");
const GeneralContext = @import("../host_calls_general.zig").GeneralContext;

const ReturnCode = @import("../host_calls.zig").ReturnCode;
const OnTransferContext = @import("context.zig").OnTransferContext;

const PVM = @import("../../pvm.zig").PVM;

// Add tracing import
const trace = @import("../../tracing.zig").scoped(.ontransfer);

pub const HostCalls =
    struct {
        pub const Context = @import("context.zig").OnTransferContext;

        /// Host call implementation for gas remaining (Ω_G)
        pub fn gasRemaining(
            exec_ctx: *PVM.ExecutionContext,
            _: ?*anyopaque,
        ) PVM.HostCallResult {
            return general.gasRemaining(exec_ctx);
        }

        /// Host call implementation for lookup preimage (Ω_L)
        pub fn lookupPreimage(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) PVM.HostCallResult {
            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));

            return general.lookupPreimage(
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

            return general.readStorage(
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

            var general_context = host_ctx.toGeneralContext();
            return general.writeStorage(
                exec_ctx,
                &general_context,
            );
        }

        /// Host call implementation for info service (Ω_I)
        pub fn infoService(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) PVM.HostCallResult {
            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));

            return general.infoService(
                exec_ctx,
                host_ctx.toGeneralContext(),
            );
        }
    };
