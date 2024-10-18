const types = @import("../types.zig");
const WorkReport = types.WorkReport;
const RefineContext = types.RefineContext;
const WorkPackageSpec = types.WorkPackageSpec;

// TODO: move these test fixtures to a central place
pub fn createEmptyWorkReport(id: [32]u8) WorkReport {
    return WorkReport{
        .package_spec = WorkPackageSpec{
            .hash = id,
            .len = 0,
            .root = [_]u8{0} ** 32,
            .segments = [_]u8{0} ** 32,
        },
        .context = RefineContext{
            .anchor = [_]u8{0} ** 32,
            .state_root = [_]u8{0} ** 32,
            .beefy_root = [_]u8{0} ** 32,
            .lookup_anchor = [_]u8{0} ** 32,
            .lookup_anchor_slot = 0,
            .prerequisite = null,
        },
        .core_index = 0,
        .authorizer_hash = [_]u8{0} ** 32,
        .auth_output = &[_]u8{},
        .results = &[_]types.WorkResult{},
    };
}
