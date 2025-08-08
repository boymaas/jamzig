const std = @import("std");
const state = @import("state.zig");

pub const alpha = @import("state_decoding/alpha.zig");
pub const beta = @import("state_decoding/beta.zig");
pub const chi = @import("state_decoding/chi.zig");
pub const delta = @import("state_decoding/delta.zig");
pub const eta = @import("state_decoding/eta.zig");
pub const gamma = @import("state_decoding/gamma.zig");
pub const phi = @import("state_decoding/phi.zig");
pub const pi = @import("state_decoding/pi.zig");
pub const psi = @import("state_decoding/psi.zig");
pub const rho = @import("state_decoding/rho.zig");
pub const tau = @import("state_decoding/tau.zig");
pub const theta = @import("state_decoding/theta.zig");
pub const vartheta = @import("state_decoding/vartheta.zig");
pub const xi = @import("state_decoding/xi.zig");

pub const iota = @import("state_decoding/validator_datas.zig");
pub const kappa = @import("state_decoding/validator_datas.zig");
pub const lambda = @import("state_decoding/validator_datas.zig");

pub const decodeAlpha = alpha.decode;
pub const decodeBeta = beta.decode;
pub const decodeChi = chi.decode;
pub const decodeEta = eta.decode;
pub const decodeGamma = gamma.decode;
pub const decodePhi = phi.decode;
pub const decodePi = pi.decode;
pub const decodePsi = psi.decode;
pub const decodeTau = tau.decode;
pub const decodeTheta = theta.decode;
pub const decodeVarTheta = vartheta.decode;
pub const decodeRho = rho.decode;
pub const decodeIota = iota.decode;
pub const decodeKappa = kappa.decode;
pub const decodeLambda = lambda.decode;
pub const decodeXi = xi.decode;

comptime {
    _ = @import("state_decoding/alpha.zig");
    _ = @import("state_decoding/beta.zig");
    _ = @import("state_decoding/chi.zig");
    _ = @import("state_decoding/delta.zig");
    _ = @import("state_decoding/eta.zig");
    _ = @import("state_decoding/gamma.zig");
    _ = @import("state_decoding/phi.zig");
    _ = @import("state_decoding/pi.zig");
    _ = @import("state_decoding/psi.zig");
    _ = @import("state_decoding/rho.zig");
    _ = @import("state_decoding/tau.zig");
    _ = @import("state_decoding/theta.zig");
    _ = @import("state_decoding/vartheta.zig");
    _ = @import("state_decoding/validator_datas.zig");
    _ = @import("state_decoding/xi.zig");
}

pub const DecodingError = error{
    // Basic errors
    InvalidData,
    OutOfMemory,
    EndOfStream,

    // Size/bounds errors
    InvalidSize,
    InvalidArrayLength,
    ExceededMaximumSize,

    // Format errors
    InvalidFormat,
    InvalidEnumValue,
    InvalidStateType,
    UnexpectedVersion,

    // Value validation errors
    InvalidValue,
    InvalidServiceIndex,
    InvalidValidatorIndex,
    InvalidTimestamp,

    // State consistency errors
    InvalidState,
    InconsistentState,
    MissingRequiredField,
    InvalidExistenceMarker,
};

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
        component: []const u8, // "alpha", "beta", etc.
        field: []const u8, // "pool_length", "validator_data", etc.
        array_index: usize, // [0], [1], etc.
        map_key: []const u8, // for map entries
    };

    pub const ErrorInfo = struct {
        err: DecodingError,
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

    /// Format current path as string for error messages
    pub fn formatPath(self: *const DecodingContext, writer: anytype) !void {
        for (self.path.items, 0..) |segment, i| {
            if (i > 0) try writer.writeAll(".");
            switch (segment) {
                .component => |name| try writer.writeAll(name),
                .field => |name| try writer.writeAll(name),
                .array_index => |idx| try writer.print("[{}]", .{idx}),
                .map_key => |key| try writer.print("[{s}]", .{key}),
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
        if (self.error_info) |_| {
            var buf: [1024]u8 = undefined;
            var stream = std.io.fixedBufferStream(&buf);
            self.formatError(stream.writer()) catch return;
            std.log.err("{s}", .{stream.getWritten()});
        }
    }

    /// Create an error with context information
    /// Stores error details in the context for later retrieval/logging
    pub fn makeError(self: *DecodingContext, err: DecodingError, comptime fmt: []const u8, args: anytype) DecodingError {
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
