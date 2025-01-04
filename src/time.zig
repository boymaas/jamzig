const std = @import("std");

pub fn Time(comptime epoch_length: u32, comptime slot_period: u32, comptime ticket_submission_end_epoch_slot: u32) type {
    return struct {
        prior_slot: u32,
        current_slot: u32,
        prior_epoch: u32,
        current_epoch: u32,
        prior_slot_in_epoch: u32,
        current_slot_in_epoch: u32,
        is_new_epoch: bool,
        seconds: u64,

        ticket_submission_end_epoch_slot: u32,
        is_in_ticket_submission_period: bool,

        const Self = @This();

        pub fn init(prior_slot: u32, new_slot: u32) Self {
            const prior_epoch = @divFloor(prior_slot, epoch_length);
            const current_epoch = @divFloor(new_slot, epoch_length);
            return .{
                .prior_slot = prior_slot,
                .current_slot = new_slot,
                .prior_epoch = prior_epoch,
                .current_epoch = current_epoch,
                .prior_slot_in_epoch = prior_slot % epoch_length,
                .current_slot_in_epoch = new_slot % epoch_length,
                .is_new_epoch = current_epoch > prior_epoch,
                .seconds = @as(u64, new_slot) * slot_period,
                .ticket_submission_end_epoch_slot = ticket_submission_end_epoch_slot,
                .is_in_ticket_submission_period = new_slot < ticket_submission_end_epoch_slot,
            };
        }

        pub inline fn isNewEpoch(self: Self) bool {
            return self.is_new_epoch;
        }

        pub fn format(
            self: Self,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;

            try writer.print(
                \\Time:
                \\  Current Slot: {d}
                \\  Prior Slot: {d}
                \\  Current Epoch: {d}
                \\  Prior Epoch: {d}
                \\  Current Slot in Epoch: {d}
                \\  Prior Slot in Epoch: {d}
                \\  Seconds: {d}
                \\  Is New Epoch: {}
                \\  In Ticket Submission Period: {}
                \\
            , .{
                self.current_slot,
                self.prior_slot,
                self.current_epoch,
                self.prior_epoch,
                self.current_slot_in_epoch,
                self.prior_slot_in_epoch,
                self.seconds,
                self.is_new_epoch,
                self.is_in_ticket_submission_period,
            });
        }
    };
}
