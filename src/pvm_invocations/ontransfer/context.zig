const std = @import("std");

const types = @import("../../types.zig");
const state = @import("../../state.zig");
const general = @import("../host_calls_general.zig");

const CopyOnWrite = @import("../../meta.zig").CopyOnWrite;
const DeltaSnapshot = @import("../../services_snapshot.zig").DeltaSnapshot;
const Params = @import("../../jam_params.zig").Params;

// Simplified context for OnTransfer execution (B.5 in the graypaper)
// Except that the only state alteration it facilitates are basic alteration to the
// storage of the subject account.
// TODO: make sure no other mutable acess to service account is allowed from this context
pub const OnTransferContext = struct {
    service_id: types.ServiceId,
    service_accounts: DeltaSnapshot,
    allocator: std.mem.Allocator,

    pub fn commit(self: *@This()) !void {
        try self.service_accounts.commit();
    }

    pub fn deepClone(self: @This()) !@This() {
        return @This(){
            .service_accounts = try self.service_accounts.deepClone(),
            .service_id = self.time,
        };
    }

    pub fn toGeneralContext(self: *const @This()) general.GeneralContext {
        return .{
            .service_id = self.service_id,
            .service_accounts = self.service_accounts,
            .allocator = self.allocator,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.service_accounts.deinit();
        self.* = undefined;
    }
};
