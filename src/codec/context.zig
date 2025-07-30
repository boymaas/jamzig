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
        path_snapshot: []u8,
        offset: usize,
    };

    /// Create a new context
    pub fn init(allocator: std.mem.Allocator) DecodingContext {
        return .{
            .path = std.ArrayList(PathSegment).init(allocator),
            .offset = 0,
            .error_info = null,
            .allocator = allocator,
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

    /// Pop the last segment
    pub fn pop(self: *DecodingContext) void {
        _ = self.path.pop();
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
            self.allocator.free(info.path_snapshot);
            self.error_info = null;
        }
    }

    /// Format the stored error as a string
    pub fn formatError(self: *const DecodingContext, writer: anytype) !void {
        if (self.error_info) |info| {
            try writer.print("Decoding error at byte {}: ", .{info.offset});
            if (info.path_snapshot.len > 0) {
                try writer.writeAll(info.path_snapshot);
                try writer.writeAll(": ");
            }
            try writer.writeAll(info.message);
        }
    }

    /// Log the stored error using std.log.err
    pub fn dumpError(self: *const DecodingContext) void {
        if (self.error_info) |info| {
            // Create an allocator for formatting
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const allocator = arena.allocator();
            
            // Format the complete error message
            const error_msg = std.fmt.allocPrint(allocator, "Decoding failed at {s} (byte offset {}): {s}", .{
                if (info.path_snapshot.len > 0) info.path_snapshot else "root",
                info.offset,
                info.message,
            }) catch {
                // Fallback if allocation fails
                std.log.err("Decoding failed at byte {}: {s}", .{ info.offset, info.message });
                return;
            };
            
            std.log.err("{s}", .{error_msg});
        }
    }

    /// Create an error with context information
    /// Stores error details in the context for later retrieval/logging
    pub fn makeError(self: *DecodingContext, err: anyerror, comptime fmt: []const u8, args: anytype) anyerror {
        // Clear any previous error
        self.clearError();

        // Allocate and store error info
        const message = std.fmt.allocPrint(self.allocator, fmt, args) catch {
            // If allocation fails, just return the error without storing context
            return err;
        };

        var path_snapshot_stream = std.ArrayList(u8).init(self.allocator);
        self.formatPath(path_snapshot_stream.writer()) catch {
            // Clean up message allocation if path allocation fails
            self.allocator.free(message);
            return err;
        };

        const path_snapshot = path_snapshot_stream.toOwnedSlice() catch {
            // Clean up message allocation if path snapshot fails
            self.allocator.free(message);
            path_snapshot_stream.deinit();
            return err;
        };

        self.error_info = .{
            .err = err,
            .message = message,
            .path_snapshot = path_snapshot,
            .offset = self.offset,
        };

        return err;
    }
};