const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // This is a list of filters that can be passed to the test step to run only
    // can be specified by:
    //
    //      -Dtest-filter=[list]         Skip tests that do not match filter
    //
    const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that do not match filter") orelse &[0][]const u8{};

    // Build any rust dependencies
    var rust_deps = try buildRustDependencies(b);
    defer rust_deps.deinit();

    const exe = b.addExecutable(.{
        .name = "jamzig",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // This declares that the executable depends on all Rust dependencies
    // to build correctly.
    for (rust_deps.deps.items) |dep| {
        exe.step.dependOn(dep.step);

        exe.addLibraryPath(b.path(dep.path));
        exe.linkSystemLibrary(dep.name);
    }

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // This creates the test step
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .filters = test_filters,
    });

    // Add the pretty module as a dependency to the executable
    //https://github.com/timfayz/pretty
    const pretty = b.dependency("pretty", .{ .target = target, .optimize = optimize });
    unit_tests.root_module.addImport("pretty", pretty.module("pretty"));

    // This declares that the tests depends on all Rust dependencies
    // to build correctly.
    for (rust_deps.deps.items) |dep| {
        unit_tests.step.dependOn(dep.step);

        unit_tests.addLibraryPath(b.path(dep.path));
        unit_tests.linkSystemLibrary(dep.name);
    }

    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

const RustDeps = struct {
    deps: std.ArrayList(RustDep),

    pub fn init(allocator: std.mem.Allocator) RustDeps {
        return RustDeps{
            .deps = std.ArrayList(RustDep).init(allocator),
        };
    }

    pub fn register(self: *RustDeps, path: []const u8, name: []const u8, step: *std.Build.Step) !void {
        try self.deps.append(RustDep{ .name = name, .step = step, .path = path });
    }

    fn deinit(self: *RustDeps) void {
        self.deps.deinit();
    }
};

const RustDep = struct {
    step: *std.Build.Step,
    name: []const u8,
    path: []const u8,
};

pub fn buildRustDependencies(b: *std.Build) !RustDeps {
    var deps = RustDeps.init(b.allocator);
    errdefer deps.deinit();

    // Build the rust library, always
    var crypto = b.addSystemCommand(&[_][]const u8{
        "cargo",
        "build",
        "--release",
        "--manifest-path",
        "ffi/rust/crypto/Cargo.toml",
    });

    try deps.register("ffi/rust/crypto/target/release", "jamzig_crypto", &crypto.step);

    return deps;
}
