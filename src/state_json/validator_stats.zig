const Pi = @import("../validator_stats.zig").Pi;
const ValidatorStats = @import("../validator_stats.zig").ValidatorStats;

pub fn jsonStringifyPi(pi: *const Pi, jw: anytype) !void {
    try jw.beginObject();

    try jw.objectField("current_epoch_stats");
    try jw.beginArray();
    for (pi.current_epoch_stats.items) |*stats| {
        try stats.jsonStringify(jw);
    }
    try jw.endArray();

    try jw.objectField("previous_epoch_stats");
    try jw.beginArray();
    for (pi.previous_epoch_stats.items) |*stats| {
        try stats.jsonStringify(jw);
    }
    try jw.endArray();

    try jw.endObject();
}

pub fn jsonStringifyValidatorStats(stats: *const ValidatorStats, jw: anytype) !void {
    try jw.beginObject();
    try jw.objectField("blocks_produced");
    try jw.write(stats.blocks_produced);
    try jw.objectField("tickets_introduced");
    try jw.write(stats.tickets_introduced);
    try jw.objectField("preimages_introduced");
    try jw.write(stats.preimages_introduced);
    try jw.objectField("octets_across_preimages");
    try jw.write(stats.octets_across_preimages);
    try jw.objectField("reports_guaranteed");
    try jw.write(stats.reports_guaranteed);
    try jw.objectField("availability_assurances");
    try jw.write(stats.availability_assurances);
    try jw.endObject();
}
