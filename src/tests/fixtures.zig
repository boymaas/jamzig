const types = @import("../types.zig");
const WorkReport = types.WorkReport;
const RefineContext = types.RefineContext;
const WorkPackageSpec = types.WorkPackageSpec;

pub fn createEmptyWorkReport(id: [32]u8) WorkReport {
    return WorkReport{
        .package_spec = WorkPackageSpec{
            .hash = id,
            .length = 0,
            .erasure_root = [_]u8{0} ** 32,
            .exports_root = [_]u8{0} ** 32,
            .exports_count = 0,
        },
        .context = RefineContext{
            .anchor = [_]u8{0} ** 32,
            .state_root = [_]u8{0} ** 32,
            .beefy_root = [_]u8{0} ** 32,
            .lookup_anchor = [_]u8{0} ** 32,
            .lookup_anchor_slot = 0,
            .prerequisites = &[_]types.OpaqueHash{},
        },
        .core_index = types.VarInt(types.CoreIndex).init(0),
        .authorizer_hash = [_]u8{0} ** 32,
        .auth_gas_used = types.VarInt(types.Gas).init(0),
        .segment_root_lookup = &[_]types.SegmentRootLookupItem{},
        .auth_output = &[_]u8{},
        .results = &[_]types.WorkResult{},
    };
}
