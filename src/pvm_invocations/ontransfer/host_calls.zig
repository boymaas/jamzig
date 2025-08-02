const std = @import("std");
const types = @import("../../types.zig");
const state = @import("../../state.zig");

const general = @import("../host_calls_general.zig");
const Params = @import("../../jam_params.zig").Params;

const ReturnCode = @import("../host_calls.zig").ReturnCode;
const DeltaSnapshot = @import("../../services_snapshot.zig").DeltaSnapshot;

const PVM = @import("../../pvm.zig").PVM;

// Add tracing import
const trace = @import("../../tracing.zig").scoped(.host_calls);

// Import shared encoding utilities
const encoding_utils = @import("../encoding_utils.zig");

pub fn HostCalls(comptime params: Params) type {
    return struct {
        // Simplified context for OnTransfer execution (B.5 in the graypaper)
        // Except that the only state alteration it facilitates are basic alteration to the
        // storage of the subject account.
        // TODO: make sure no other mutable acess to service account is allowed from this context
        pub const Context = struct {
            service_id: types.ServiceId,
            service_accounts: DeltaSnapshot,
            allocator: std.mem.Allocator,
            transfers: []const @import("../accumulate/types.zig").DeferredTransfer,
            entropy: types.Entropy,
            timeslot: types.TimeSlot,

            const Self = @This();

            pub fn commit(self: *Self) !void {
                try self.service_accounts.commit();
            }

            pub fn deepClone(self: Self) !Self {
                return Self{
                    .service_accounts = try self.service_accounts.deepClone(),
                    .service_id = self.service_id,
                    .allocator = self.allocator,
                    .transfers = self.transfers,
                    .entropy = self.entropy,
                    .timeslot = self.timeslot,
                };
            }

            pub fn toGeneralContext(self: *Self) general.GeneralHostCalls(params).Context {
                return general.GeneralHostCalls(params).Context.init(
                    self.service_id,
                    &self.service_accounts,
                    self.allocator,
                );
            }

            pub fn deinit(self: *Self) void {
                self.service_accounts.deinit();
                self.* = undefined;
            }
        };

        /// Host call implementation for gas remaining (Ω_G)
        pub fn gasRemaining(
            exec_ctx: *PVM.ExecutionContext,
            _: ?*anyopaque,
        ) PVM.HostCallResult {
            return general.GeneralHostCalls(params).gasRemaining(exec_ctx);
        }

        /// Host call implementation for lookup preimage (Ω_L)
        pub fn lookupPreimage(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) PVM.HostCallResult {
            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));

            return general.GeneralHostCalls(params).lookupPreimage(
                exec_ctx,
                host_ctx.toGeneralContext(),
            );
        }

        /// Host call implementation for read storage (Ω_R)
        pub fn readStorage(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) PVM.HostCallResult {
            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));

            return general.GeneralHostCalls(params).readStorage(
                exec_ctx,
                host_ctx.toGeneralContext(),
            );
        }

        /// Host call implementation for write storage (Ω_W)
        pub fn writeStorage(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) PVM.HostCallResult {
            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));

            const general_context = host_ctx.toGeneralContext();
            return general.GeneralHostCalls(params).writeStorage(
                exec_ctx,
                general_context,
            );
        }

        /// Host call implementation for info service (Ω_I)
        pub fn infoService(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) PVM.HostCallResult {
            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));

            return general.GeneralHostCalls(params).infoService(
                exec_ctx,
                host_ctx.toGeneralContext(),
            );
        }

        /// Host call implementation for fetch (Ω_Y) - OnTransfer context
        /// ΩY(ϱ, ω, µ, ∅, η'₀, ∅, ∅, ∅, ∅, ∅, t)
        /// Fetch for ontransfer context supporting selectors:
        /// 0: System constants
        /// 1: Current random accumulator (η'₀)
        /// 2-15: NOT available (no work package or accumulation context)
        /// 16: Transfer list (from t)
        /// 17: Specific transfer by index (from t)
        pub fn fetch(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) PVM.HostCallResult {
            const span = trace.span(.host_call_fetch);
            defer span.deinit();

            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));

            const output_ptr = exec_ctx.registers[7]; // Output pointer (o)
            const offset = exec_ctx.registers[8]; // Offset (f)
            const limit = exec_ctx.registers[9]; // Length limit (l)
            const selector = exec_ctx.registers[10]; // Data selector
            const index1 = @as(u32, @intCast(exec_ctx.registers[11])); // Index 1

            span.debug("Host call: fetch selector={d}", .{selector});
            span.debug("Output ptr: 0x{x}, offset: {d}, limit: {d}", .{ output_ptr, offset, limit });

            // Determine what data to fetch based on selector
            var data_to_fetch: ?[]const u8 = null;
            var needs_cleanup = false;

            switch (selector) {
                0 => {
                    // Return JAM parameters as encoded bytes per graypaper
                    span.debug("Encoding JAM chain constants", .{});
                    const encoded_constants = encoding_utils.encodeJamParams(host_ctx.allocator, params) catch {
                        span.err("Failed to encode JAM chain constants", .{});
                        exec_ctx.registers[7] = @intFromEnum(ReturnCode.NONE);
                        return .play;
                    };
                    data_to_fetch = encoded_constants;
                    needs_cleanup = true;
                },

                1 => {
                    // Selector 1: Current random accumulator (η'₀)
                    span.debug("Random accumulator available from ontransfer context", .{});
                    data_to_fetch = host_ctx.entropy[0..];
                },

                2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 => {
                    // Selectors 2-13: Work package related data - NOT available in ontransfer
                    span.debug("Work package data (selector {d}) not available in ontransfer context", .{selector});
                    exec_ctx.registers[7] = @intFromEnum(ReturnCode.NONE);
                    return .play;
                },

                14, 15 => {
                    // Selectors 14-15: Operand data - NOT available in ontransfer
                    span.debug("Operand data (selector {d}) not available in ontransfer context", .{selector});
                    exec_ctx.registers[7] = @intFromEnum(ReturnCode.NONE);
                    return .play;
                },

                16 => {
                    // Selector 16: Transfer list (from t)
                    const transfers_data = encoding_utils.encodeTransfers(host_ctx.allocator, host_ctx.transfers) catch {
                        span.err("Failed to encode transfer sequence", .{});
                        exec_ctx.registers[7] = @intFromEnum(ReturnCode.NONE);
                        return .play;
                    };
                    span.debug("Transfer sequence encoded successfully, count={d}", .{host_ctx.transfers.len});
                    data_to_fetch = transfers_data;
                    needs_cleanup = true;
                },

                17 => {
                    // Selector 17: Specific transfer by index (from t)
                    if (index1 < host_ctx.transfers.len) {
                        const transfer_item = &host_ctx.transfers[index1];
                        const transfer_data = encoding_utils.encodeTransfer(host_ctx.allocator, transfer_item) catch {
                            span.err("Failed to encode transfer", .{});
                            exec_ctx.registers[7] = @intFromEnum(ReturnCode.NONE);
                            return .play;
                        };
                        span.debug("Transfer encoded successfully: index={d}", .{index1});
                        data_to_fetch = transfer_data;
                        needs_cleanup = true;
                    } else {
                        span.debug("Transfer index out of bounds: index={d}, count={d}", .{ index1, host_ctx.transfers.len });
                        exec_ctx.registers[7] = @intFromEnum(ReturnCode.NONE);
                        return .play;
                    }
                },

                else => {
                    // Invalid selector for ontransfer context
                    span.debug("Invalid fetch selector for ontransfer: {d} (valid: 0,1,16,17)", .{selector});
                    exec_ctx.registers[7] = @intFromEnum(ReturnCode.NONE);
                    return .play;
                },
            }
            defer if (needs_cleanup and data_to_fetch != null) host_ctx.allocator.free(data_to_fetch.?);

            if (data_to_fetch) |data| {
                // Calculate what to return based on offset and limit
                const f = @min(offset, data.len);
                const l = @min(limit, data.len - f);

                span.debug("Fetching {d} bytes from offset {d}", .{ l, f });

                // Check if we're being asked for zero bytes (length query only)
                if (l == 0) {
                    span.debug("Zero len requested, returning size: {d}", .{data.len});
                    exec_ctx.registers[7] = data.len;
                    return .play;
                }

                // Write data to memory
                exec_ctx.memory.writeSlice(@truncate(output_ptr), data[f..][0..l]) catch {
                    span.err("Memory access failed while writing fetch data", .{});
                    return .{ .terminal = .panic };
                };

                // Return the total length of the data
                exec_ctx.registers[7] = data.len;
                span.debug("Fetch successful, total length: {d}", .{data.len});
            }

            return .play;
        }

        pub fn debugLog(
            exec_ctx: *PVM.ExecutionContext,
            _: ?*anyopaque,
        ) PVM.HostCallResult {
            return general.GeneralHostCalls(params).debugLog(
                exec_ctx,
            );
        }
    };
}
