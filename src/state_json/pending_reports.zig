const std = @import("std");
const state = @import("../state.zig");

const Rho = @import("../pending_reports.zig").Rho;

pub fn jsonStringify(
    comptime core_count: u16,
    self: *const state.Rho(core_count),
    jw: anytype,
) !void {
    try jw.beginObject();

    // Write the reports field
    try jw.objectField("reports");
    try jw.beginArray();

    for (self.reports, 0..) |maybe_report, index| {
        if (maybe_report) |report| {
            const hash = report.cached_hash orelse try report.hash_uncached(self.allocator);

            try jw.beginObject();

            // Write core index
            try jw.objectField("core");
            try jw.write(index);

            // Write hash
            try jw.objectField("hash");
            try jw.write(std.fmt.fmtSliceHexLower(&hash));

            // Write report details
            try jw.objectField("report");
            try jw.beginObject();

            // Write package specification
            try jw.objectField("package_spec");
            try jw.beginObject();
            try jw.objectField("hash");
            try jw.write(std.fmt.fmtSliceHexLower(&report.assignment.report.package_spec.hash));
            try jw.objectField("length");
            try jw.write(report.assignment.report.package_spec.length);
            try jw.objectField("erasure_root");
            try jw.write(std.fmt.fmtSliceHexLower(&report.assignment.report.package_spec.erasure_root));
            try jw.objectField("exports_root");
            try jw.write(std.fmt.fmtSliceHexLower(&report.assignment.report.package_spec.exports_root));
            try jw.objectField("exports_count");
            try jw.write(report.assignment.report.package_spec.exports_count);
            try jw.endObject();

            // Write timeout
            try jw.objectField("timeout");
            try jw.write(report.assignment.timeout);

            try jw.endObject();
            try jw.endObject();
        }
    }

    try jw.endArray();
    try jw.endObject();
}
