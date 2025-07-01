const std = @import("std");
const Delta = @import("../state.zig").Delta;

pub fn jsonStringify(self: *const Delta, jw: anytype) !void {
    try jw.beginObject();
    try jw.objectField("accounts");
    try jw.beginObject();

    var it = self.accounts.iterator();
    while (it.next()) |entry| {
        const index = entry.key_ptr.*;
        const account = entry.value_ptr.*;
        const account_index = try std.fmt.allocPrint(self.allocator, "{d}", .{index});
        defer self.allocator.free(account_index);
        try jw.objectField(account_index);
        // try jw.beginObjectFieldRaw();
        // try jw.write(index);
        // jw.endObjectFieldRaw();

        try jw.beginObject();

        try jw.objectField("balance");
        try jw.write(account.balance);

        try jw.objectField("min_gas_accumulate");
        try jw.write(account.min_gas_accumulate);

        try jw.objectField("min_gas_on_transfer");
        try jw.write(account.min_gas_on_transfer);

        try jw.objectField("code_hash");
        try jw.write(std.fmt.fmtSliceHexLower(&account.code_hash));

        try jw.objectField("storage");
        try jw.beginObject();
        var storage_it = account.storage.iterator();
        while (storage_it.next()) |storage_entry| {
            const key = std.fmt.fmtSliceHexLower(storage_entry.key_ptr).data;
            const value = std.fmt.fmtSliceHexLower(storage_entry.value_ptr.*);
            try jw.objectField(key);
            try jw.write(value);
        }
        try jw.endObject();

        try jw.objectField("preimage_lookups");
        try jw.beginObject();
        var lookup_it = account.preimage_lookups.iterator();
        while (lookup_it.next()) |lookup_entry| {
            const key = lookup_entry.key_ptr.*;
            const value = lookup_entry.value_ptr.*;
            const lookup_key = try std.fmt.allocPrint(self.allocator, "{s}", .{std.fmt.fmtSliceHexLower(&key)});
            defer self.allocator.free(lookup_key);
            try jw.objectField(lookup_key);
            const value_str = try std.fmt.allocPrint(self.allocator, "{d},{d},{d}", .{ value.status[0] orelse 0, value.status[1] orelse 0, value.status[2] orelse 0 });
            defer self.allocator.free(value_str);
            try jw.write(value_str);
        }
        try jw.endObject();

        try jw.endObject();
    }

    try jw.endObject();
    try jw.endObject();
}
