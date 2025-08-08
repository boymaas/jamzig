const std = @import("std");

/// Tracks the current decoding path and position for error reporting
pub const DecodingContext = struct {
    /// Stack of what we're currently decoding
    path: std.ArrayList(PathSegment),
    /// Current byte offset in the stream
    offset: usize,
    /// Stored error information
    error_info: ?ErrorInfo,
    /// Allocator for error storage
    allocator: std.mem.Allocator,
    /// Track if an error occurred to preserve path
    error_marked: bool = false,

    pub const PathSegment = union(enum) {
        type_name: []const u8, // "Header", "WorkPackage", etc.
        field: []const u8, // "pool_length", "validator_data", etc.
        array_index: usize, // [0], [1], etc.
        map_key: []const u8, // for map entries
        slice_item: usize, // for slice items
        union_variant: []const u8, // for union variants
    };

    pub const ErrorInfo = struct {
        err: anyerror,
        message: []u8,
        offset: usize,
    };

    /// Create a new context
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
    }

    /// Push a new segment to the path
    pub fn push(self: *DecodingContext, segment: PathSegment) !void {
        try self.path.append(segment);
    }

    /// Pop the last segment (only if no error is marked)
    pub fn pop(self: *DecodingContext) void {
        if (!self.error_marked) {
            _ = self.path.pop();
        }
    }

    /// Mark that an error occurred - prevents path from being popped
    pub fn markError(self: *DecodingContext) void {
        self.error_marked = true;
    }

    /// Update the current byte offset
    pub fn updateOffset(self: *DecodingContext, new_offset: usize) void {
        self.offset = new_offset;
    }

    /// Add to the current byte offset
    pub fn addOffset(self: *DecodingContext, bytes: usize) void {
        self.offset += bytes;
    }

    /// Format current path as string for error messages
    pub fn formatPath(self: *const DecodingContext, writer: anytype) !void {
        for (self.path.items, 0..) |segment, i| {
            if (i > 0) {
                switch (segment) {
                    .array_index, .slice_item => {}, // No dot before array indices
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

    /// Clear stored error information
    pub fn clearError(self: *DecodingContext) void {
        if (self.error_info) |info| {
            self.allocator.free(info.message);
            self.error_info = null;
        }
        // Don't reset error_marked here - it should persist
    }

    /// Reset the context for reuse
    pub fn reset(self: *DecodingContext) void {
        self.clearError();
        self.error_marked = false;
        self.path.clearRetainingCapacity();
        self.offset = 0;
    }

    /// Format the stored error as a string
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

    /// Log the stored error using std.log.err
    pub fn dumpError(self: *const DecodingContext) void {
        // Create an allocator for formatting
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        // Format the path on-the-fly
        var path_buffer = std.ArrayList(u8).init(allocator);
        defer path_buffer.deinit();
        self.formatPath(path_buffer.writer()) catch |err| {
            // If path formatting fails, still try to show what we can
            std.log.err("Error formatting path: {s}", .{@errorName(err)});
        };

        const path_str = if (path_buffer.items.len > 0) path_buffer.items else "root";

        if (self.error_info) |info| {
            // We have detailed error information
            const error_msg = std.fmt.allocPrint(allocator, "Decoding failed at {s} (byte offset {}): {s}", .{
                path_str,
                info.offset,
                info.message,
            }) catch {
                // Fallback if allocation fails
                std.log.err("Decoding failed at byte {}: {s}", .{ info.offset, info.message });
                return;
            };

            std.log.err("{s}", .{error_msg});
        } else {
            // No detailed error info, but we can still show where we were
            if (self.path.items.len > 0) {
                std.log.err("Error occurred at: {s} (byte offset {})", .{ path_str, self.offset });
                std.log.err("Path preserved due to error marking", .{});
            } else {
                std.log.err("No decoding error information available.", .{});
            }
        }
    }

    /// Create an error with context information
    /// Stores error details in the context for later retrieval/logging
    pub fn makeError(self: *DecodingContext, err: anyerror, comptime fmt: []const u8, args: anytype) anyerror {
        // Only store the first error - it's usually the most informative
        if (self.error_info != null) {
            return err;
        }

        // Allocate and store error info
        const message = std.fmt.allocPrint(self.allocator, fmt, args) catch {
            // If allocation fails, just return the error without storing context
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
