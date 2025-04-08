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
    const dep_opts = .{ .target = target, .optimize = optimize };

    const pretty_module = b.dependency("pretty", dep_opts).module("pretty");
    const diffz_module = b.dependency("diffz", dep_opts).module("diffz");
    const clap_module = b.dependency("clap", dep_opts).module("clap");
    const tmpfile_module = b.dependency("tmpfile", .{}).module("tmpfile");

    // Event loop
    const xev_dep = b.dependency("libxev", dep_opts);
    const xev_mod = xev_dep.module("xev");

    // Quic & Ssl
    const lsquic_dep = b.dependency("lsquic", dep_opts);
    const lsquic_mod = lsquic_dep.module("lsquic");
    const ssl_dep = lsquic_dep.builder.dependency("boringssl", dep_opts);
    const ssl_mod = ssl_dep.module("ssl");
    const base32_dep = b.dependency("base32", dep_opts);
    const base32_mod = base32_dep.module("base32");

    // Rest of the existing build.zig implementation...
    var rust_deps = try buildRustDependencies(b, target, optimize);
    defer rust_deps.deinit();

    const jamzig_exe = b.addExecutable(.{
        .name = "jamzig",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    jamzig_exe.linkLibCpp();
    // jamzig_exe.linkLibC();
    jamzig_exe.root_module.addOptions("build-options", build_options);
    rust_deps.staticallyLinkTo(jamzig_exe);
    jamzig_exe.root_module.addImport("xev", xev_mod);
    jamzig_exe.root_module.addImport("lsquic", lsquic_mod);
    jamzig_exe.root_module.addImport("ssl", ssl_mod);
    jamzig_exe.root_module.addImport("base32", base32_mod);

    b.installArtifact(jamzig_exe);

    const jamtestnet_export = b.addExecutable(.{
        .name = "jamzig-jamtestnet-export",
        .root_source_file = b.path("src/jamtestnet_export.zig"),
        .target = target,
        .optimize = optimize,
    });
    jamtestnet_export.root_module.addOptions("build_options", build_options);
    jamtestnet_export.root_module.addImport("clap", clap_module);
    jamtestnet_export.linkLibCpp();
    rust_deps.staticallyLinkTo(jamtestnet_export);
    b.installArtifact(jamtestnet_export);

    const pvm_fuzzer = b.addExecutable(.{
        .name = "jamzig-pvm-fuzzer",
        .root_source_file = b.path("src/pvm_fuzzer.zig"),
        .target = target,
        .optimize = optimize,
    });

    pvm_fuzzer.root_module.addOptions("build_options", build_options);
    pvm_fuzzer.root_module.addImport("clap", clap_module);
    pvm_fuzzer.linkLibCpp();
    try rust_deps.staticallyLinkDepTo("polkavm_ffi", pvm_fuzzer);
    b.installArtifact(pvm_fuzzer);

    // Run Steps
    // NODE
    const run_cmd = b.addRunArtifact(jamzig_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the node");
    run_step.dependOn(&run_cmd.step);

    // JAMTESTNET EXPORT
    const run_jamtestnet_export = b.addRunArtifact(jamtestnet_export);
    run_jamtestnet_export.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_jamtestnet_export.addArgs(args);
    }
    const run_jamtestnet_export_step = b.step("jamtestnet_export", "Run the jamtestnet export");
    run_jamtestnet_export_step.dependOn(&run_jamtestnet_export.step);

    // PVM FUZZER
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
        .test_runner = .{
            .path = b.path("src/tests/runner.zig"),
            .mode = .simple,
        },
        .filters = test_filters,
    });

    unit_tests.root_module.addOptions("build_options", build_options);

    unit_tests.root_module.addImport("pretty", pretty_module);
    unit_tests.root_module.addImport("diffz", diffz_module);
    unit_tests.root_module.addImport("tmpfile", tmpfile_module);

    unit_tests.root_module.addImport("xev", xev_mod);
    unit_tests.root_module.addImport("lsquic", lsquic_mod);
    unit_tests.root_module.addImport("ssl", ssl_mod);
    unit_tests.root_module.addImport("base32", base32_mod);

    unit_tests.linkLibCpp();

    // Statically link our rust_deps to the unit tests
    rust_deps.staticallyLinkTo(unit_tests);

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

    // Add FFI test step
    const test_ffi_step = b.step("test-ffi", "Run FFI unit tests");

    // Add all rust crate tests
    const crypto_tests = try buildRustDepTests(b, "crypto", target, optimize);
    const reed_solomon_tests = try buildRustDepTests(b, "reed_solomon", target, optimize);
    const polkavm_tests = try buildRustDepTests(b, "polkavm_ffi", target, optimize);

    test_ffi_step.dependOn(crypto_tests);
    test_ffi_step.dependOn(reed_solomon_tests);
    test_ffi_step.dependOn(polkavm_tests);
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

    pub fn staticallyLinkTo(self: *RustDeps, comp_step: *std.Build.Step.Compile) void {
        for (self.deps.items) |dep| {
            comp_step.step.dependOn(dep.step);
            comp_step.addObjectFile(self.b.path(dep.fullpath));
        }
    }

    pub fn staticallyLinkDepTo(self: *RustDeps, name: []const u8, comp_step: *std.Build.Step.Compile) !void {
        for (self.deps.items) |dep| {
            if (std.mem.eql(u8, dep.name, name)) {
                comp_step.step.dependOn(dep.step);
                comp_step.addObjectFile(self.b.path(dep.fullpath));
                return;
            }
        }
        return error.DependencyNotFound;
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

fn getRustTargetTriple(target: std.Build.ResolvedTarget) ![]const u8 {
    return switch (target.result.cpu.arch) {
        .x86_64 => switch (target.result.os.tag) {
            .macos => "x86_64-apple-darwin",
            .linux => switch (target.result.abi) {
                .gnu => "x86_64-unknown-linux-gnu",
                .musl => "x86_64-unknown-linux-musl",
                else => return error.UnsupportedTarget,
            },
            else => return error.UnsupportedTarget,
        },
        .aarch64 => switch (target.result.os.tag) {
            .macos => "aarch64-apple-darwin",
            .linux => switch (target.result.abi) {
                .gnu => "aarch64-unknown-linux-gnu",
                .musl => "aarch64-unknown-linux-musl",
                else => return error.UnsupportedTarget,
            },
            else => return error.UnsupportedTarget,
        },
        .powerpc64 => switch (target.result.os.tag) {
            .linux => switch (target.result.abi) {
                .gnu => "powerpc64-unknown-linux-gnu",
                else => return error.UnsupportedTarget,
            },
            else => return error.UnsupportedTarget,
        },
        else => return error.UnsupportedTarget,
    };
}

fn buildRustDep(b: *std.Build, deps: *RustDeps, name: []const u8, target: std.Build.ResolvedTarget, optimize_mode: std.builtin.OptimizeMode) !void {
    const manifest_path = try std.fmt.allocPrint(b.allocator, "ffi/rust/{s}/Cargo.toml", .{name});
    defer b.allocator.free(manifest_path);

    const target_triple = try getRustTargetTriple(target);

    var cmd = switch (optimize_mode) {
        .Debug => b.addSystemCommand(&[_][]const u8{
            "cargo",
            "build",
            "--target",
            target_triple,
            "--manifest-path",
            manifest_path,
        }),
        .ReleaseSafe, .ReleaseSmall, .ReleaseFast => b.addSystemCommand(&[_][]const u8{
            "cargo",
            "build",
            "--release",
            "--target",
            target_triple,
            "--manifest-path",
            manifest_path,
        }),
    };

    // Update target path to include the specific architecture
    const target_path = try std.fmt.allocPrint(b.allocator, "ffi/rust/{s}/target/{s}/{s}", .{ name, target_triple, if (optimize_mode == .Debug) "debug" else "release" });
    defer b.allocator.free(target_path);

    const lib_name = if (std.mem.eql(u8, name, "crypto"))
        "jamzig_crypto"
    else
        name;

    try deps.register(target_path, lib_name, &cmd.step);
}

fn buildRustDepTests(b: *std.Build, name: []const u8, target: std.Build.ResolvedTarget, optimize_mode: std.builtin.OptimizeMode) !*std.Build.Step {
    const manifest_path = try std.fmt.allocPrint(b.allocator, "ffi/rust/{s}/Cargo.toml", .{name});
    defer b.allocator.free(manifest_path);
    const target_triple = try getRustTargetTriple(target);

    // Base cargo command
    var cargo_args = std.ArrayList([]const u8).init(b.allocator);
    defer cargo_args.deinit();
    try cargo_args.appendSlice(&[_][]const u8{
        "cargo",
        "test",
        "--target",
        target_triple,
        "--manifest-path",
        manifest_path,
    });

    if (optimize_mode != .Debug) {
        try cargo_args.append("--release");
    }

    // Create the cargo command
    var cmd = b.addSystemCommand(cargo_args.items);

    return &cmd.step;
}

pub fn buildRustDependencies(b: *std.Build, target: std.Build.ResolvedTarget, optimize_mode: std.builtin.OptimizeMode) !RustDeps {
    var deps = RustDeps.init(b);
    errdefer deps.deinit();

    // Build the rust libraries
    try buildRustDep(b, &deps, "crypto", target, optimize_mode);
    try buildRustDep(b, &deps, "reed_solomon", target, optimize_mode);
    try buildRustDep(b, &deps, "polkavm_ffi", target, optimize_mode);

    return deps;
}

fn toUpperStringWithUnderscore(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const upper_string = try std.ascii.allocUpperString(allocator, input);
    for (upper_string) |*c| {
        if (c.* == '-') {
            c.* = '_';
        }
    }
    return upper_string;
}
