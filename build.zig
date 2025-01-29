const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Existing options
    const tracing_scopes = b.option([][]const u8, "tracing-scope", "Enable detailed tracing by scope") orelse &[_][]const u8{};
    const tracing_level = b.option([]const u8, "tracing-level", "Tracing log level default is info") orelse &[_]u8{};
    const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that do not match filter") orelse &[0][]const u8{};

    const build_options = b.addOptions();
    build_options.addOption([]const []const u8, "enable_tracing_scopes", tracing_scopes);
    build_options.addOption([]const u8, "enable_tracing_level", tracing_level);

    // Dependencies
    const pretty_module = b.dependency("pretty", .{ .target = target, .optimize = optimize }).module("pretty");
    const diffz_module = b.dependency("diffz", .{ .target = target, .optimize = optimize }).module("diffz");
    const clap_module = b.dependency("clap", .{ .target = target, .optimize = optimize }).module("clap");
    const tmpfile_module = b.dependency("tmpfile", .{}).module("tmpfile");

    // Rest of the existing build.zig implementation...
    var rust_deps = try buildRustDependencies(b, target);
    defer rust_deps.deinit();

    const exe = b.addExecutable(.{
        .name = "jamzig",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    rust_deps.statically_link_to(exe);
    b.installArtifact(exe);

    const pvm_fuzzer = b.addExecutable(.{
        .name = "jamzig-pvm-fuzzer",
        .root_source_file = b.path("src/pvm_fuzzer.zig"),
        .target = target,
        .optimize = optimize,
    });

    pvm_fuzzer.root_module.addOptions("build_options", build_options);
    pvm_fuzzer.root_module.addImport("clap", clap_module);
    // pvm_fuzzer.linkLibCpp();
    b.installArtifact(pvm_fuzzer);

    // Run Steps
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const run_pvm_fuzzer = b.addRunArtifact(pvm_fuzzer);
    run_pvm_fuzzer.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_pvm_fuzzer.addArgs(args);
    }
    const run_pvm_fuzzer_step = b.step("pvm_fuzz", "Run the pvm fuzzer");
    run_pvm_fuzzer_step.dependOn(&run_pvm_fuzzer.step);

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

    unit_tests.linkLibCpp();

    // Statically link our rust_deps to the unit tests
    rust_deps.statically_link_to(unit_tests);

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

fn buildRustDep(b: *std.Build, deps: *RustDeps, name: []const u8, target: std.Build.ResolvedTarget) !void {
    const manifest_path = try std.fmt.allocPrint(b.allocator, "ffi/rust/{s}/Cargo.toml", .{name});
    defer b.allocator.free(manifest_path);

    // Get target triple for Rust
    const target_triple = switch (target.result.cpu.arch) {
        .x86_64 => if (target.result.os.tag == .linux)
            "x86_64-unknown-linux-gnu"
        else
            return error.UnsupportedTarget,
        .aarch64 => switch (target.result.os.tag) {
            .macos => "aarch64-apple-darwin",
            .linux => "aarch64-unknown-linux-gnu",
            else => return error.UnsupportedTarget,
        },
        else => return error.UnsupportedTarget,
    };

    var cmd = b.addSystemCommand(&[_][]const u8{
        "cargo",
        "build",
        "--release",
        "--target",
        target_triple,
        "--manifest-path",
        manifest_path,
    });

    // Update target path to include the specific architecture
    const target_path = try std.fmt.allocPrint(b.allocator, "ffi/rust/{s}/target/{s}/release", .{ name, target_triple });
    defer b.allocator.free(target_path);

    const lib_name = if (std.mem.eql(u8, name, "crypto"))
        "jamzig_crypto"
    else
        name;

    try deps.register(target_path, lib_name, &cmd.step);
}

pub fn buildRustDependencies(b: *std.Build, target: std.Build.ResolvedTarget) !RustDeps {
    var deps = RustDeps.init(b);
    errdefer deps.deinit();

    // Build the rust libraries
    try buildRustDep(b, &deps, "crypto", target);
    try buildRustDep(b, &deps, "reed_solomon", target);

    return deps;
}
