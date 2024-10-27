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

pub const Chi = struct {
    manager: ?ServiceIndex,
    assign: ?ServiceIndex,
    designate: ?ServiceIndex,
    always_accumulate: std.AutoHashMap(ServiceIndex, GasLimit),
    allocator: Allocator,

    pub fn init(allocator: Allocator) Chi {
        return .{
            .manager = null,
            .assign = null,
            .designate = null,
            .always_accumulate = std.AutoHashMap(ServiceIndex, GasLimit).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Chi) void {
        self.always_accumulate.deinit();
    }

    pub fn jsonStringify(self: *const @This(), jw: anytype) !void {
        try @import("state_json/services_priviledged.zig").jsonStringify(self, jw);
    }

    pub fn setManager(self: *Chi, index: ?ServiceIndex) void {
        self.manager = index;
    }

    pub fn setAssign(self: *Chi, index: ?ServiceIndex) void {
        self.assign = index;
    }

    pub fn setDesignate(self: *Chi, index: ?ServiceIndex) void {
        self.designate = index;
    }

    pub fn addAlwaysAccumulate(self: *Chi, index: ServiceIndex, gas_limit: GasLimit) !void {
        try self.always_accumulate.put(index, gas_limit);
    }

    pub fn removeAlwaysAccumulate(self: *Chi, index: ServiceIndex) void {
        _ = self.always_accumulate.remove(index);
    }

    pub fn getAlwaysAccumulateGasLimit(self: *Chi, index: ServiceIndex) ?GasLimit {
        return self.always_accumulate.get(index);
    }

    pub fn isPrivilegedService(self: *Chi, index: ServiceIndex) bool {
        return (self.manager != null and index == self.manager.?) or
            (self.assign != null and index == self.assign.?) or
            (self.designate != null and index == self.designate.?) or
            self.always_accumulate.contains(index);
    }
};

//  _   _       _ _  _____         _
// | | | |_ __ (_) ||_   _|__  ___| |_ ___
// | | | | '_ \| | __|| |/ _ \/ __| __/ __|
// | |_| | | | | | |_ | |  __/\__ \ |_\__ \
//  \___/|_| |_|_|\__||_|\___||___/\__|___/
//

const testing = std.testing;

test "Chi service privileges" {
    const allocator = testing.allocator;
    var chi = Chi.init(allocator);
    defer chi.deinit();

    const manager_index: ServiceIndex = 1;
    const assign_index: ServiceIndex = 2;
    const designate_index: ServiceIndex = 3;
    const always_accumulate_index: ServiceIndex = 4;

    chi.setManager(manager_index);
    chi.setAssign(assign_index);
    chi.setDesignate(designate_index);
    try chi.addAlwaysAccumulate(always_accumulate_index, 1000);

    try testing.expect(chi.isPrivilegedService(manager_index));
    try testing.expect(chi.isPrivilegedService(assign_index));
    try testing.expect(chi.isPrivilegedService(designate_index));
    try testing.expect(chi.isPrivilegedService(always_accumulate_index));
    try testing.expect(!chi.isPrivilegedService(5));

    try testing.expectEqual(@as(?GasLimit, 1000), chi.getAlwaysAccumulateGasLimit(always_accumulate_index));
    try testing.expectEqual(@as(?GasLimit, null), chi.getAlwaysAccumulateGasLimit(5));

    chi.removeAlwaysAccumulate(always_accumulate_index);
    try testing.expect(!chi.isPrivilegedService(always_accumulate_index));
}
