const std = @import("std");
const safrole = @import("../safrole.zig");

// Safrole tests for the tiny network
// https://github.com/w3f/jamtestvectors/blob/master/safrole/README.md
//
// Tiny tests with reduced validators (6) and a shorter epoch duration (12)
//
// NOTE: RING_SIZE = 6 in ffi/rust/crypto/ring_vrf.rs

pub const TINY_PARAMS = safrole.Params{
    .epoch_length = 12,
    // TODO: what value of Y (ticket_submission_end_slot) should we use for the tiny vectors, now set to
    // same ratio. Production values is 500 of and epohc length of 600 which
    // would suggest 10
    .ticket_submission_end_epoch_slot = 10,
    .max_ticket_entries_per_validator = 2,
    .validators_count = 6,
};

comptime {
    _ = @import("./tiny_enact_epoch_change.zig");
    _ = @import("./tiny_publish_tickets_no_mark.zig");
    _ = @import("./tiny_publish_tickets_with_mark.zig");
    _ = @import("./tiny_skip_epoch.zig");
}
