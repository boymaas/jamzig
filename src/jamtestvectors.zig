const std = @import("std");
const testing = std.testing;

pub const W3fLoader = @import("trace_runner/parsers.zig").w3f.Loader;
pub const runTracesInDir = @import("trace_runner/runner.zig").runTracesInDir;

const jam_params = @import("jam_params.zig");
const io = @import("io.zig");

const tracing = @import("tracing");
const trace = tracing.scoped(.jamtestvectors);

const block_import = @import("block_import.zig");

// W3F Traces Tests
pub const W3F_PARAMS = jam_params.TINY_PARAMS;

test "w3f:traces:fallback" {
    const allocator = std.testing.allocator;
    const loader = W3fLoader(W3F_PARAMS){};
    var sequential_executor = try io.SequentialExecutor.init(allocator);
    defer sequential_executor.deinit();
    var result = try runTracesInDir(
        io.SequentialExecutor,
        &sequential_executor,
        W3F_PARAMS,
        loader.loader(),
        allocator,
        "src/jamtestvectors/data/traces/fallback",
    );
    defer result.deinit(allocator);
}

test "w3f:traces:safrole" {
    const allocator = std.testing.allocator;
    const loader = W3fLoader(W3F_PARAMS){};
    var sequential_executor = try io.SequentialExecutor.init(allocator);
    defer sequential_executor.deinit();
    var result = try runTracesInDir(
        io.SequentialExecutor,
        &sequential_executor,
        W3F_PARAMS,
        loader.loader(),
        allocator,
        "src/jamtestvectors/data/traces/safrole",
    );
    defer result.deinit(allocator);
}

test "w3f:traces:preimages_normal" {
    const allocator = std.testing.allocator;
    const loader = W3fLoader(W3F_PARAMS){};
    var sequential_executor = try io.SequentialExecutor.init(allocator);
    defer sequential_executor.deinit();
    var result = try runTracesInDir(
        io.SequentialExecutor,
        &sequential_executor,
        W3F_PARAMS,
        loader.loader(),
        allocator,
        "src/jamtestvectors/data/traces/preimages",
    );
    defer result.deinit(allocator);
}

test "w3f:traces:preimages_light" {
    const allocator = std.testing.allocator;
    const loader = W3fLoader(W3F_PARAMS){};
    var sequential_executor = try io.SequentialExecutor.init(allocator);
    defer sequential_executor.deinit();
    var result = try runTracesInDir(
        io.SequentialExecutor,
        &sequential_executor,
        W3F_PARAMS,
        loader.loader(),
        allocator,
        "src/jamtestvectors/data/traces/preimages_light",
    );
    defer result.deinit(allocator);
}

test "w3f:traces:storage" {
    const allocator = std.testing.allocator;
    const loader = W3fLoader(W3F_PARAMS){};
    var sequential_executor = try io.SequentialExecutor.init(allocator);
    defer sequential_executor.deinit();
    var result = try runTracesInDir(
        io.SequentialExecutor,
        &sequential_executor,
        W3F_PARAMS,
        loader.loader(),
        allocator,
        "src/jamtestvectors/data/traces/storage",
    );
    defer result.deinit(allocator);
}

test "w3f:traces:storage_light" {
    const allocator = std.testing.allocator;
    const loader = W3fLoader(W3F_PARAMS){};
    var sequential_executor = try io.SequentialExecutor.init(allocator);
    defer sequential_executor.deinit();
    var result = try runTracesInDir(
        io.SequentialExecutor,
        &sequential_executor,
        W3F_PARAMS,
        loader.loader(),
        allocator,
        "src/jamtestvectors/data/traces/storage_light",
    );
    defer result.deinit(allocator);
}
