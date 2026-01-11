/// χ (chi) is part of the state structure in the Jam protocol and represents the privileged service indices.
///
/// It consists of several components:
/// - χ_m: The index of the empower service.
/// - χ_a: The index of the assign service.
/// - χ_v: The index of the designate service.
/// - χ_g: The always-accumulate service indices and their basic gas allowance.
///
/// These indices define which services hold special privileges, such as modifying other parts of the state
/// or always being included in the accumulation process in each block.
///
/// Host calls, specifically Ω_E (empower), can modify the components of χ, including χ_m, χ_a, χ_v, and χ_g.
/// These changes directly impact which services are privileged in their operations within the protocol.
///
/// Additionally, χ is included in the state that is Merklized to generate the state root, ensuring its role
/// in the protocol's integrity and governance processes.
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Hash = [32]u8;
pub const ServiceIndex = u32;
pub const Balance = u64;
pub const GasLimit = u64;
pub const Timeslot = u32;

/// Generic Chi type parameterized by core_count
pub fn Chi(comptime core_count: u16) type {
    return struct {
        manager: ServiceIndex,
        assign: [core_count]ServiceIndex, // Fixed-size array, always exactly C elements
        designate: ServiceIndex,
        registrar: ServiceIndex, // v0.7.1 GP #473
        always_accumulate: std.AutoHashMap(ServiceIndex, GasLimit),
        allocator: Allocator,

        const Self = @This();

        pub fn init(allocator: Allocator) !Self {
            return .{
                .manager = 0,
                .assign = [_]ServiceIndex{0} ** core_count, // Initialize all to 0
                .designate = 0,
                .registrar = 0, // v0.7.1 GP #473
                .always_accumulate = std.AutoHashMap(ServiceIndex, GasLimit).init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.always_accumulate.deinit();
            self.* = undefined;
        }

        pub fn format(
            self: *const Self,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            const tfmt = @import("types/fmt.zig");
            const formatter = tfmt.Format(@TypeOf(self.*)){
                .value = self.*,
                .options = .{},
            };
            try formatter.format(fmt, options, writer);
        }

        pub fn setManager(self: *Self, index: ServiceIndex) void {
            self.manager = index;
        }

        pub fn setAssign(self: *Self, core_index: usize, service_index: ServiceIndex) void {
            std.debug.assert(core_index < core_count);
            self.assign[core_index] = service_index;
        }

        pub fn getAssign(self: *const Self, core_index: usize) ServiceIndex {
            std.debug.assert(core_index < core_count);
            return self.assign[core_index];
        }

        pub fn setDesignate(self: *Self, index: ServiceIndex) void {
            self.designate = index;
        }

        pub fn addAlwaysAccumulate(self: *Self, index: ServiceIndex, gas_limit: GasLimit) !void {
            try self.always_accumulate.put(index, gas_limit);
        }

        pub fn removeAlwaysAccumulate(self: *Self, index: ServiceIndex) void {
            _ = self.always_accumulate.remove(index);
        }

        pub fn getAlwaysAccumulateGasLimit(self: *const Self, index: ServiceIndex) ?GasLimit {
            return self.always_accumulate.get(index);
        }

        pub fn isPrivilegedService(self: *const Self, index: ServiceIndex) bool {
            // Check if index is in the assign list
            const is_assign_service = blk: {
                for (self.assign) |assign_index| {
                    if (index == assign_index and assign_index != 0) break :blk true;
                }
                break :blk false;
            };
            
            return (self.manager != 0 and index == self.manager) or
                is_assign_service or
                (self.designate != 0 and index == self.designate) or
                self.always_accumulate.contains(index);
        }

        pub fn clearServices(self: *Self) void {
            self.manager = 0;
            self.assign = [_]ServiceIndex{0} ** core_count;
            self.designate = 0;
            self.always_accumulate.clearRetainingCapacity();
        }

        /// Create a deep copy
        pub fn deepClone(self: *const Self) !Self {
            var cloned_always_accumulate = std.AutoHashMap(ServiceIndex, GasLimit).init(self.allocator);
            errdefer cloned_always_accumulate.deinit();

            var iter = self.always_accumulate.iterator();
            while (iter.next()) |entry| {
                try cloned_always_accumulate.put(entry.key_ptr.*, entry.value_ptr.*);
            }

            return .{
                .manager = self.manager,
                .assign = self.assign, // Fixed array can be copied directly
                .designate = self.designate,
                .registrar = self.registrar, // v0.7.1 GP #473
                .always_accumulate = cloned_always_accumulate,
                .allocator = self.allocator,
            };
        }
    };
}

//
// Tests
//

const testing = std.testing;

test "Chi service privileges" {
    const allocator = testing.allocator;
    var chi = try Chi(2).init(allocator); // Use 2 cores for testing
    defer chi.deinit();

    const manager_index: ServiceIndex = 1;
    const assign_index: ServiceIndex = 2;
    const designate_index: ServiceIndex = 3;
    const always_accumulate_index: ServiceIndex = 4;

    chi.setManager(manager_index);
    chi.setAssign(0, assign_index); // Set first core's assign service
    chi.setDesignate(designate_index);
    try chi.addAlwaysAccumulate(always_accumulate_index, 1000);

    try testing.expect(chi.isPrivilegedService(manager_index));
    try testing.expect(chi.isPrivilegedService(assign_index));
    try testing.expect(chi.isPrivilegedService(designate_index));
    try testing.expect(chi.isPrivilegedService(always_accumulate_index));
    try testing.expect(!chi.isPrivilegedService(5));

    chi.removeAlwaysAccumulate(always_accumulate_index);
    try testing.expect(!chi.isPrivilegedService(always_accumulate_index));
}