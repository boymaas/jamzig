const std = @import("std");
const types = @import("../types.zig");

pub const WorkReportBuilder = struct {
    pub fn generateRandomWorkReport(
        comptime _: @import("../jam_params.zig").Params,
        allocator: std.mem.Allocator,
        random: std.Random,
        complexity: @import("../state_random_generator.zig").StateComplexity,
    ) !types.WorkReport {
        var auth_output = std.ArrayList(u8).init(allocator);
        defer auth_output.deinit();

        // Generate random auth output (simple blob)
        const auth_output_size: usize = switch (complexity) {
            .minimal => 32,
            .moderate => 128,
            .maximal => 512,
        };

        try auth_output.resize(auth_output_size);
        random.bytes(auth_output.items);

        // Generate random number of results (1-4)
        const num_results: usize = switch (complexity) {
            .minimal => 1,
            .moderate => random.intRangeAtMost(u8, 1, 2),
            .maximal => random.intRangeAtMost(u8, 1, 4),
        };

        var results = std.ArrayList(types.WorkResult).init(allocator);
        errdefer {
            // Clean up any WorkResults that were created if we fail
            for (results.items) |*result| {
                result.deinit(allocator);
            }
            results.deinit();
        }

        for (0..num_results) |_| {
            const work_result = try generateRandomWorkResult(allocator, random, complexity);
            try results.append(work_result);
        }

        var context = generateRandomRefineContext(allocator, random, complexity) catch |err| {
            // Clean up results before propagating error
            for (results.items) |*result| {
                result.deinit(allocator);
            }
            results.deinit();
            return err;
        };
        errdefer context.deinit(allocator);

        const segment_root_lookup = generateRandomSegmentRootLookup(allocator, random, complexity) catch |err| {
            // Clean up before propagating error
            context.deinit(allocator);
            for (results.items) |*result| {
                result.deinit(allocator);
            }
            results.deinit();
            return err;
        };
        errdefer allocator.free(segment_root_lookup);

        const auth_output_slice = try auth_output.toOwnedSlice();
        errdefer allocator.free(auth_output_slice);

        const results_slice = try results.toOwnedSlice();
        errdefer {
            for (results_slice) |*result| {
                result.deinit(allocator);
            }
            allocator.free(results_slice);
        }

        return types.WorkReport{
            .package_spec = generateRandomWorkPackageSpec(random, complexity),
            .context = context,
            .core_index = types.VarInt(types.CoreIndex).init(random.int(types.CoreIndex)),
            .authorizer_hash = generateRandomHash(random),
            .auth_gas_used = types.VarInt(types.Gas).init(switch (complexity) {
                .minimal => random.intRangeAtMost(types.Gas, 1000, 10000),
                .moderate => random.intRangeAtMost(types.Gas, 10000, 100000),
                .maximal => random.intRangeAtMost(types.Gas, 100000, 1000000),
            }),
            .auth_output = auth_output_slice,
            .segment_root_lookup = segment_root_lookup,
            .results = results_slice,
        };
    }

    fn generateRandomWorkResult(
        allocator: std.mem.Allocator,
        random: std.Random,
        complexity: @import("../state_random_generator.zig").StateComplexity,
    ) !types.WorkResult {
        var payload = std.ArrayList(u8).init(allocator);
        defer payload.deinit();

        // Generate random payload
        const payload_size: usize = switch (complexity) {
            .minimal => 64,
            .moderate => random.intRangeAtMost(u16, 64, 512),
            .maximal => random.intRangeAtMost(u16, 512, 2048),
        };

        try payload.resize(payload_size);
        random.bytes(payload.items);

        // Generate work execution result
        const exec_result = switch (random.intRangeAtMost(u8, 0, 5)) {
            0 => blk: {
                const owned_payload = try payload.toOwnedSlice();
                break :blk types.WorkExecResult{ .ok = owned_payload };
            },
            1 => types.WorkExecResult.out_of_gas,
            2 => types.WorkExecResult.panic,
            3 => types.WorkExecResult.bad_exports,
            4 => types.WorkExecResult.bad_code,
            5 => types.WorkExecResult.code_oversize,
            else => unreachable,
        };

        const VarInt = types.VarInt;

        return types.WorkResult{
            .service_id = random.int(types.ServiceId),
            .code_hash = generateRandomHash(random),
            .payload_hash = generateRandomHash(random),
            .accumulate_gas = random.intRangeAtMost(types.Gas, 1000, 100000),
            .result = exec_result,
            .refine_load = types.RefineLoad{
                .gas_used = VarInt(types.Gas).init(random.intRangeAtMost(types.Gas, 100, 50000)),
                .imports = VarInt(u16).init(random.intRangeAtMost(u16, 0, 8)),
                .extrinsic_count = VarInt(u16).init(random.intRangeAtMost(u16, 0, 4)),
                .extrinsic_size = VarInt(u32).init(random.intRangeAtMost(u32, 0, 1024)),
                .exports = VarInt(u16).init(random.intRangeAtMost(u16, 0, 8)),
            },
        };
    }

    fn generateRandomWorkPackageSpec(
        random: std.Random,
        complexity: @import("../state_random_generator.zig").StateComplexity,
    ) types.WorkPackageSpec {
        return types.WorkPackageSpec{
            .hash = generateRandomHash(random),
            .length = switch (complexity) {
                .minimal => random.intRangeAtMost(u32, 100, 1000),
                .moderate => random.intRangeAtMost(u32, 1000, 10000),
                .maximal => random.intRangeAtMost(u32, 10000, 100000),
            },
            .erasure_root = generateRandomHash(random),
            .exports_root = generateRandomHash(random),
            .exports_count = random.intRangeAtMost(u16, 1, 64),
        };
    }

    fn generateRandomRefineContext(
        allocator: std.mem.Allocator,
        random: std.Random,
        complexity: @import("../state_random_generator.zig").StateComplexity,
    ) !types.RefineContext {
        // Generate prerequisites array
        const prereq_count: usize = switch (complexity) {
            .minimal => 0,
            .moderate => random.intRangeAtMost(u8, 0, 4),
            .maximal => random.intRangeAtMost(u8, 0, 8),
        };

        var prerequisites = std.ArrayList(types.WorkPackageHash).init(allocator);
        errdefer prerequisites.deinit();

        for (0..prereq_count) |_| {
            try prerequisites.append(generateRandomHash(random));
        }

        return types.RefineContext{
            .anchor = generateRandomHash(random),
            .state_root = generateRandomHash(random),
            .beefy_root = generateRandomHash(random),
            .lookup_anchor = generateRandomHash(random),
            .lookup_anchor_slot = random.int(types.TimeSlot),
            .prerequisites = try prerequisites.toOwnedSlice(),
        };
    }

    fn generateRandomSegmentRootLookup(
        allocator: std.mem.Allocator,
        random: std.Random,
        complexity: @import("../state_random_generator.zig").StateComplexity,
    ) !types.SegmentRootLookup {
        const entry_count: usize = switch (complexity) {
            .minimal => 0,
            .moderate => random.intRangeAtMost(u8, 0, 4),
            .maximal => random.intRangeAtMost(u8, 0, 8),
        };

        var lookup_items = std.ArrayList(types.SegmentRootLookupItem).init(allocator);
        errdefer lookup_items.deinit();

        for (0..entry_count) |_| {
            const item = types.SegmentRootLookupItem{
                .work_package_hash = generateRandomHash(random),
                .segment_tree_root = generateRandomHash(random),
            };
            try lookup_items.append(item);
        }

        return try lookup_items.toOwnedSlice();
    }

    fn generateRandomHash(random: std.Random) types.Hash {
        var hash: types.Hash = undefined;
        random.bytes(&hash);
        return hash;
    }
};

