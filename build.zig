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

    const tracing_scopes = b.option([][]const u8, "tracing-scope", "Enable detailed tracing by scope") orelse &[_][]const u8{};
    const tracing_source_location = b.option([][]const u8, "tracing-source", "Enable detailed tracing by source location") orelse &[_][]const u8{};

    const tracy = b.option([]const u8, "tracy", "Enable Tracy integration. Supply path to Tracy source");
    const tracy_callstack = b.option(bool, "tracy-callstack", "Include callstack information with Tracy data. Does nothing if -Dtracy is not provided") orelse (tracy != null);
    const tracy_allocation = b.option(bool, "tracy-allocation", "Include allocation information with Tracy data. Does nothing if -Dtracy is not provided") orelse (tracy != null);

    const build_options = b.addOptions();
    build_options.addOption([]const []const u8, "enable_tracing_scopes", tracing_scopes);
    build_options.addOption([]const []const u8, "enable_tracing_source_location", tracing_source_location);

    build_options.addOption(bool, "enable_tracy", tracy != null);
    build_options.addOption(bool, "enable_tracy_callstack", tracy_callstack);
    build_options.addOption(bool, "enable_tracy_allocation", tracy_allocation);

    // This is a list of filters that can be passed to the test step to run only
    // can be specified by:
    //
    //      -Dtest-filter=[list]         Skip tests that do not match filter
    //
    const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that do not match filter") orelse &[0][]const u8{};

    // Dependencies
    // Add the pretty module as a dependency to the executable
    // https://github.com/timfayz/pretty
    const pretty_module = b.dependency("pretty", .{ .target = target, .optimize = optimize }).module("pretty");
    // Add the diffz module:
    // https://github.com/ziglibs/diffz/tree/420fcb22306ffd4c9c3c761863dfbb6bdbb18a73
    const diffz_module = b.dependency("diffz", .{ .target = target, .optimize = optimize }).module("diffz");
    // Add tmpfile module
    // https://github.com/liyu1981/tmpfile.zig/archive/7ca14fb3a8a59e5ab83d3fca7aa0b85e087bd6ff.zip
    const tmpfile_module = b.dependency("tmpfile", .{}).module("tmpfile");

    // Build any rust dependencies
    var rust_deps = try buildRustDependencies(b);
    defer rust_deps.deinit();

    const exe = b.addExecutable(.{
        .name = "jamzig",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addOptions("build_options", build_options);

    if (tracy) |tracy_path| {
        const client_cpp = b.pathJoin(
            &[_][]const u8{ tracy_path, "public", "TracyClient.cpp" },
        );

        // On mingw, we need to opt into windows 7+ to get some features required by tracy.
        const tracy_c_flags: []const []const u8 = &[_][]const u8{ "-DTRACY_ENABLE=1", "-fno-sanitize=undefined" };

        exe.addIncludePath(.{ .cwd_relative = tracy_path });
        exe.addCSourceFile(.{ .file = .{ .cwd_relative = client_cpp }, .flags = tracy_c_flags });

        // exe.root_module.linkSystemLibrary("c++", .{ .use_pkg_config = .no });
        exe.linkLibCpp();
        exe.linkLibC();
    }

    // Resister the dependencies
    // exe.root_module.addImport("diffz", diffz_dependency.module("diffz"));
    // exe.root_module.addImport("pretty", pretty_module);

    // Statically link our rust_deps to the executable
    rust_deps.statically_link_to(exe);

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
        .test_runner = b.path("src/tests/runner.zig"),
        .filters = test_filters,
    });

    unit_tests.root_module.addOptions("build_options", build_options);

    unit_tests.root_module.addImport("pretty", pretty_module);
    unit_tests.root_module.addImport("diffz", diffz_module);
    unit_tests.root_module.addImport("tmpfile", tmpfile_module);

    // Statically link our rust_deps to the unit tests
    rust_deps.statically_link_to(unit_tests);

    // Since our rust static lib depend on libc and libccp we need to link
    // against them as well.
    unit_tests.linkLibC();
    unit_tests.linkLibCpp();

    const run_unit_tests = b.addRunArtifact(unit_tests);

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build test -- arg1 arg2 etc`
    if (b.args) |args| {
        run_unit_tests.addArgs(args);
    }

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

const RustDeps = struct {
    deps: std.ArrayList(RustDep),
    b: *std.Build,

    pub fn init(b: *std.Build) RustDeps {
        return RustDeps{ .deps = std.ArrayList(RustDep).init(b.allocator), .b = b };
    }

    pub fn register(self: *RustDeps, path: []const u8, name: []const u8, step: *std.Build.Step) !void {
        const lib_name = try std.fmt.allocPrint(self.b.allocator, "lib{s}.a", .{name});
        defer self.b.allocator.free(lib_name);
        const fullpath = try std.fs.path.join(self.b.allocator, &[_][]const u8{ path, lib_name });
        try self.deps.append(RustDep{ .name = name, .step = step, .path = path, .fullpath = fullpath });
    }

    pub fn statically_link_to(self: *RustDeps, comp_step: *std.Build.Step.Compile) void {
        for (self.deps.items) |dep| {
            comp_step.step.dependOn(dep.step);
            comp_step.addObjectFile(self.b.path(dep.fullpath));
        }
    }

    fn deinit(self: *RustDeps) void {
        for (self.deps.items) |dep| {
            self.b.allocator.free(dep.fullpath);
        }
        self.deps.deinit();
    }
};

const RustDep = struct {
    step: *std.Build.Step,
    name: []const u8,
    path: []const u8,
    fullpath: []const u8,
};

fn buildRustDep(b: *std.Build, deps: *RustDeps, name: []const u8) !void {
    const manifest_path = try std.fmt.allocPrint(b.allocator, "ffi/rust/{s}/Cargo.toml", .{name});
    defer b.allocator.free(manifest_path);

    var cmd = b.addSystemCommand(&[_][]const u8{
        "cargo",
        "build",
        "--release",
        "--manifest-path",
        manifest_path,
    });

    const target_path = try std.fmt.allocPrint(b.allocator, "ffi/rust/{s}/target/release", .{name});
    defer b.allocator.free(target_path);

    const lib_name = if (std.mem.eql(u8, name, "crypto"))
        "jamzig_crypto"
    else
        name;

    try deps.register(target_path, lib_name, &cmd.step);
}

pub fn buildRustDependencies(b: *std.Build) !RustDeps {
    var deps = RustDeps.init(b);
    errdefer deps.deinit();

    // Build the rust libraries
    try buildRustDep(b, &deps, "crypto");
    try buildRustDep(b, &deps, "reed_solomon");

    return deps;
}
