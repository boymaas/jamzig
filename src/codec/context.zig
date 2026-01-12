const std = @import("std");

pub const DecodingContext = struct {
    path: std.ArrayList(PathSegment),
    offset: usize,
    error_info: ?ErrorInfo,
    allocator: std.mem.Allocator,
    error_marked: bool = false,

    pub const PathSegment = union(enum) {
        type_name: []const u8,
        field: []const u8,
        array_index: usize,
        map_key: []const u8,
        slice_item: usize,
        union_variant: []const u8,
    };

    pub const ErrorInfo = struct {
        err: anyerror,
        message: []u8,
        offset: usize,
    };

    pub fn init(allocator: std.mem.Allocator) DecodingContext {
        return .{
            .path = std.ArrayList(PathSegment).init(allocator),
            .offset = 0,
            .error_info = null,
            .allocator = allocator,
            .error_marked = false,
        };
    }

    pub fn deinit(self: *DecodingContext) void {
        self.clearError();
        self.path.deinit();
        self.* = undefined;
    }

    pub fn push(self: *DecodingContext, segment: PathSegment) !void {
        try self.path.append(segment);
    }

    pub fn pop(self: *DecodingContext) void {
        if (!self.error_marked) {
            _ = self.path.pop();
        }
    }

    pub fn markError(self: *DecodingContext) void {
        self.error_marked = true;
    }

    pub fn updateOffset(self: *DecodingContext, new_offset: usize) void {
        self.offset = new_offset;
    }

    pub fn addOffset(self: *DecodingContext, bytes: usize) void {
        self.offset += bytes;
    }

    pub fn formatPath(self: *const DecodingContext, writer: anytype) !void {
        for (self.path.items, 0..) |segment, i| {
            if (i > 0) {
                switch (segment) {
                    .array_index, .slice_item => {},
                    else => try writer.writeAll("."),
                }
            }
            switch (segment) {
                .type_name => |name| try writer.writeAll(name),
                .field => |name| try writer.writeAll(name),
                .array_index => |idx| try writer.print("[{}]", .{idx}),
                .map_key => |key| try writer.print("[{s}]", .{key}),
                .slice_item => |idx| try writer.print("[{}]", .{idx}),
                .union_variant => |name| try writer.print("({s})", .{name}),
            }
        }
    }

    pub fn clearError(self: *DecodingContext) void {
        if (self.error_info) |info| {
            self.allocator.free(info.message);
            self.error_info = null;
        }
    }

    pub fn reset(self: *DecodingContext) void {
        self.clearError();
        self.error_marked = false;
        self.path.clearRetainingCapacity();
        self.offset = 0;
    }

    pub fn formatError(self: *const DecodingContext, writer: anytype) !void {
        if (self.error_info) |info| {
            try writer.print("Decoding error at byte {}: ", .{info.offset});
            if (self.path.items.len > 0) {
                try self.formatPath(writer);
                try writer.writeAll(": ");
            }
            try writer.writeAll(info.message);
        }
    }

    pub fn dumpError(self: *const DecodingContext) void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var path_buffer = std.ArrayList(u8).init(allocator);
        defer path_buffer.deinit();
        self.formatPath(path_buffer.writer()) catch |err| {
            std.log.err("Error formatting path: {s}", .{@errorName(err)});
        };

        const path_str = if (path_buffer.items.len > 0) path_buffer.items else "root";

        if (self.error_info) |info| {
            const error_msg = std.fmt.allocPrint(allocator, "Decoding failed at {s} (byte offset {}): {s}", .{
                path_str,
                info.offset,
                info.message,
            }) catch {
                std.log.err("Decoding failed at byte {}: {s}", .{ info.offset, info.message });
                return;
            };

            std.log.err("{s}", .{error_msg});
        } else {
            if (self.path.items.len > 0) {
                std.log.err("Error occurred at: {s} (byte offset {})", .{ path_str, self.offset });
                std.log.err("Path preserved due to error marking", .{});
            } else {
                std.log.err("No decoding error information available.", .{});
            }
        }
    }

    pub fn makeError(self: *DecodingContext, err: anyerror, comptime fmt: []const u8, args: anytype) anyerror {
        if (self.error_info != null) {
            return err;
        }

        const message = std.fmt.allocPrint(self.allocator, fmt, args) catch {
            return err;
        };

        self.error_info = .{
            .err = err,
            .message = message,
            .offset = self.offset,
        };

        return err;
    }
};
