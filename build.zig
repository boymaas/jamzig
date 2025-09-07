const std = @import("std");

// Define enum types that can be shared
const TracingMode = enum { disabled, compile_time, runtime };
const ConformanceParams = enum { tiny, full };

// Configuration struct to hold all build parameters
const BuildConfig = struct {
    tracing_scopes: []const []const u8,
    tracing_level: []const u8,
    tracing_mode: TracingMode,
    conformance_params: ?ConformanceParams = null,
    enable_tracy: bool = false,
};

// Helper function to apply build configuration to options
fn applyBuildConfig(options: *std.Build.Step.Options, config: BuildConfig) void {
    options.addOption([]const []const u8, "enable_tracing_scopes", config.tracing_scopes);
    options.addOption([]const u8, "enable_tracing_level", config.tracing_level);
    options.addOption(@TypeOf(config.tracing_mode), "tracing_mode", config.tracing_mode);
    options.addOption(bool, "enable_tracy", config.enable_tracy);
    if (config.conformance_params) |conformance_params| {
        options.addOption(ConformanceParams, "conformance_params", conformance_params);
    }
}

// Helper function to configure tracy for an executable, it either adds the library and the real root module or a noop module
fn configureTracy(b: *std.Build, exe: *std.Build.Step.Compile, tracy_enabled: bool, tracy_dep: anytype) void {
    const tracy_mod = if (tracy_enabled)
        tracy_dep.module("root")
    else
        b.createModule(.{
            .root_source_file = b.path("src/tracy_noop.zig"),
        });
    exe.root_module.addImport("tracy", tracy_mod);
    if (tracy_enabled) {
        exe.linkLibrary(tracy_dep.artifact("tracy"));
    }
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Parse command-line options
    const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that do not match filter") orelse &[0][]const u8{};

    // Create base configuration from command-line options
    const base_config = BuildConfig{
        .tracing_scopes = b.option([][]const u8, "tracing-scope", "Enable detailed tracing by scope") orelse &[_][]const u8{},
        .tracing_level = b.option([]const u8, "tracing-level", "Tracing log level default is info") orelse &[_]u8{},
        .tracing_mode = b.option(TracingMode, "tracing-mode", "Tracing compilation mode (disabled/compile_time/runtime)") orelse .compile_time,
        .conformance_params = b.option(ConformanceParams, "conformance-params", "JAM protocol parameters for conformance testing (tiny/full)") orelse .tiny,
        .enable_tracy = b.option(bool, "enable-tracy", "Enable Tracy profiler") orelse false,
    };

    // Create conformance configuration with runtime tracing
    const conformance_config = BuildConfig{
        .tracing_scopes = base_config.tracing_scopes,
        .tracing_level = base_config.tracing_level,
        .tracing_mode = .runtime, // Force runtime tracing for conformance tools
        .conformance_params = base_config.conformance_params,
        .enable_tracy = base_config.enable_tracy,
    };

    // Create target-specific optimized configuration with disabled tracing
    const target_config = BuildConfig{
        .tracing_scopes = &[_][]const u8{}, // Empty - no tracing scopes
        .tracing_level = "", // No default level
        .tracing_mode = .disabled, // Compile out all tracing
        .conformance_params = base_config.conformance_params,
        .enable_tracy = base_config.enable_tracy,
    };

    // Create conformance configuration with runtime tracing
    const testing_config = BuildConfig{
        .tracing_scopes = base_config.tracing_scopes,
        .tracing_level = base_config.tracing_level,
        .tracing_mode = .runtime, // Force runtime tracing for conformance tools
        .conformance_params = base_config.conformance_params,
        .enable_tracy = false, // Disable tracy for tests
    };

    // Create benchmark configuration optimized for performance - no debugging
    const bench_config = BuildConfig{
        .tracing_scopes = &[_][]const u8{}, // No tracing scopes
        .tracing_level = "", // No tracing level
        .tracing_mode = .disabled, // Compile out all tracing
        .conformance_params = base_config.conformance_params,
        .enable_tracy = base_config.enable_tracy, // Allow tracy for benchmarking
    };

    // Create build options objects
    const build_options = b.addOptions();
    applyBuildConfig(build_options, base_config);

    const conformance_build_options = b.addOptions();
    applyBuildConfig(conformance_build_options, conformance_config);

    const target_build_options = b.addOptions();
    applyBuildConfig(target_build_options, target_config);

    const testing_build_options = b.addOptions();
    applyBuildConfig(testing_build_options, testing_config);

    const bench_build_options = b.addOptions();
    applyBuildConfig(bench_build_options, bench_config);

    // Dependencies
    const dep_opts = .{ .target = target, .optimize = optimize };

    const pretty_module = b.dependency("pretty", dep_opts).module("pretty");
    const diffz_module = b.dependency("diffz", dep_opts).module("diffz");
    const clap_module = b.dependency("clap", dep_opts).module("clap");
    const tmpfile_module = b.dependency("tmpfile", .{}).module("tmpfile");

    const uuid_module = b.dependency("uuid", .{}).module("uuid");

    // Event loop
    const xev_dep = b.dependency("libxev", dep_opts);
    const xev_mod = xev_dep.module("xev");

    // Quic & Ssl
    const zig_network_dep = b.dependency("zig-network", dep_opts);
    const zig_network_mod = zig_network_dep.module("network");
    const lsquic_dep = b.dependency("lsquic", dep_opts);
    const lsquic_mod = lsquic_dep.module("lsquic");
    const ssl_dep = lsquic_dep.builder.dependency("boringssl", dep_opts);
    const ssl_mod = ssl_dep.module("ssl");
    const base32_dep = b.dependency("base32", dep_opts);
    const base32_mod = base32_dep.module("base32");

    // Tracy Profiler
    const tracy_dep = b.dependency("tracy", .{
        .target = target,
        .optimize = optimize,
        .enable_ztracy = true,
        .enable_fibers = false, // Not needed - using real threads
        .on_demand = false, // Always on when enabled
    });

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
    jamzig_exe.root_module.addOptions("build_options", build_options);
    rust_deps.staticallyLinkTo(jamzig_exe);

    jamzig_exe.root_module.addImport("uuid", uuid_module);
    jamzig_exe.root_module.addImport("xev", xev_mod);
    jamzig_exe.root_module.addImport("znet", zig_network_mod);
    jamzig_exe.root_module.addImport("lsquic", lsquic_mod);
    jamzig_exe.root_module.addImport("ssl", ssl_mod);
    jamzig_exe.root_module.addImport("base32", base32_mod);
    configureTracy(b, jamzig_exe, base_config.enable_tracy, tracy_dep);

    b.installArtifact(jamzig_exe);

    const pvm_fuzzer = b.addExecutable(.{
        .name = "jamzig-pvm-fuzzer",
        .root_source_file = b.path("src/pvm_fuzzer.zig"),
        .target = target,
        .optimize = optimize,
    });

    pvm_fuzzer.root_module.addOptions("build_options", build_options);
    pvm_fuzzer.root_module.addImport("clap", clap_module);
    configureTracy(b, pvm_fuzzer, base_config.enable_tracy, tracy_dep);
    pvm_fuzzer.linkLibCpp();
    try rust_deps.staticallyLinkDepTo("polkavm_ffi", pvm_fuzzer);
    b.installArtifact(pvm_fuzzer);

    // JAM Conformance Testing Executables
    // Create conformance-specific build options

    const jam_conformance_fuzzer = b.addExecutable(.{
        .name = "jam_conformance_fuzzer",
        .root_source_file = b.path("src/jam_conformance_fuzzer.zig"),
        .target = target,
        .optimize = optimize,
    });
    jam_conformance_fuzzer.root_module.addOptions("build_options", conformance_build_options);
    jam_conformance_fuzzer.root_module.addImport("clap", clap_module);
    configureTracy(b, jam_conformance_fuzzer, conformance_config.enable_tracy, tracy_dep);
    jam_conformance_fuzzer.linkLibCpp();
    rust_deps.staticallyLinkTo(jam_conformance_fuzzer);
    b.installArtifact(jam_conformance_fuzzer);

    const jam_conformance_target = b.addExecutable(.{
        .name = "jam_conformance_target",
        .root_source_file = b.path("src/jam_conformance_target.zig"),
        .target = target,
        .optimize = optimize,
    });
    jam_conformance_target.root_module.addOptions("build_options", target_build_options);
    jam_conformance_target.root_module.addImport("clap", clap_module);
    configureTracy(b, jam_conformance_target, target_config.enable_tracy, tracy_dep);
    jam_conformance_target.linkLibCpp();
    rust_deps.staticallyLinkTo(jam_conformance_target);
    b.installArtifact(jam_conformance_target);

    // Run Steps
    // NODE
    const run_cmd = b.addRunArtifact(jamzig_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the node");
    run_step.dependOn(&run_cmd.step);

    // PVM FUZZER
    const run_pvm_fuzzer = b.addRunArtifact(pvm_fuzzer);
    run_pvm_fuzzer.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_pvm_fuzzer.addArgs(args);
    }
    const run_pvm_fuzzer_step = b.step("pvm_fuzz", "Run the pvm fuzzer");
    run_pvm_fuzzer_step.dependOn(&run_pvm_fuzzer.step);

    // JAM CONFORMANCE FUZZER
    const run_jam_conformance_fuzzer = b.addRunArtifact(jam_conformance_fuzzer);
    run_jam_conformance_fuzzer.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_jam_conformance_fuzzer.addArgs(args);
    }
    const run_jam_conformance_fuzzer_step = b.step("jam_conformance_fuzzer", "Run the JAM conformance fuzzer");
    run_jam_conformance_fuzzer_step.dependOn(&run_jam_conformance_fuzzer.step);

    // JAM CONFORMANCE TARGET
    const run_jam_conformance_target = b.addRunArtifact(jam_conformance_target);
    run_jam_conformance_target.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_jam_conformance_target.addArgs(args);
    }
    const run_jam_conformance_target_step = b.step("jam_conformance_target", "Run the JAM conformance target server");
    run_jam_conformance_target_step.dependOn(&run_jam_conformance_target.step);

    // Add individual build steps for conformance tools
    const build_jam_conformance_fuzzer_step = b.step("conformance_fuzzer", "Build JAM conformance fuzzer");
    build_jam_conformance_fuzzer_step.dependOn(b.getInstallStep());

    const build_jam_conformance_target_step = b.step("conformance_target", "Build JAM conformance target");
    build_jam_conformance_target_step.dependOn(b.getInstallStep());

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

    unit_tests.root_module.addOptions("build_options", testing_build_options);

    unit_tests.root_module.addImport("pretty", pretty_module);
    unit_tests.root_module.addImport("diffz", diffz_module);
    unit_tests.root_module.addImport("tmpfile", tmpfile_module);

    unit_tests.root_module.addImport("uuid", uuid_module);
    unit_tests.root_module.addImport("xev", xev_mod);
    unit_tests.root_module.addImport("network", zig_network_mod);
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

    // Add test vectors step - focused testing of JAM specification compliance
    const test_vectors = b.addTest(.{
        .root_source_file = b.path("src/jamtestvectors_tests.zig"),
        .target = target,
        .optimize = optimize,
        .test_runner = .{
            .path = b.path("src/tests/runner.zig"),
            .mode = .simple,
        },
        .filters = test_filters,
    });

    test_vectors.root_module.addOptions("build_options", testing_build_options);
    test_vectors.root_module.addImport("pretty", pretty_module);
    test_vectors.root_module.addImport("diffz", diffz_module);
    test_vectors.root_module.addImport("tmpfile", tmpfile_module);

    test_vectors.root_module.addImport("uuid", uuid_module);
    test_vectors.root_module.addImport("xev", xev_mod);
    test_vectors.root_module.addImport("network", zig_network_mod);
    test_vectors.root_module.addImport("lsquic", lsquic_mod);
    test_vectors.root_module.addImport("ssl", ssl_mod);
    test_vectors.root_module.addImport("base32", base32_mod);
    test_vectors.linkLibCpp();

    // Statically link our rust_deps to the test vectors
    rust_deps.staticallyLinkTo(test_vectors);

    const run_test_vectors = b.addRunArtifact(test_vectors);
    if (b.args) |args| {
        run_test_vectors.addArgs(args);
    }

    const test_vectors_step = b.step("test-vectors", "Run JAM test vector compliance tests");
    test_vectors_step.dependOn(&run_test_vectors.step);

    // Add FFI test step
    const test_ffi_step = b.step("test-ffi", "Run FFI unit tests");

    // Add all rust crate tests
    const crypto_tests = try buildRustDepTests(b, "crypto", target, optimize);
    const reed_solomon_tests = try buildRustDepTests(b, "reed_solomon", target, optimize);
    const polkavm_tests = try buildRustDepTests(b, "polkavm_ffi", target, optimize);

    test_ffi_step.dependOn(crypto_tests);
    test_ffi_step.dependOn(reed_solomon_tests);
    test_ffi_step.dependOn(polkavm_tests);

    // Add block import benchmark step
    const bench_block_import = b.addExecutable(.{
        .name = "bench-block-import",
        .root_source_file = b.path("src/bench_block_import.zig"),
        .target = target,
        .optimize = optimize,
    });

    bench_block_import.root_module.addOptions("build_options", bench_build_options);
    bench_block_import.root_module.addImport("pretty", pretty_module);
    bench_block_import.root_module.addImport("diffz", diffz_module);
    configureTracy(b, bench_block_import, bench_config.enable_tracy, tracy_dep);
    bench_block_import.linkLibCpp();
    rust_deps.staticallyLinkTo(bench_block_import);
    b.installArtifact(bench_block_import);

    const run_bench_block_import = b.addRunArtifact(bench_block_import);
    const bench_block_import_step = b.step("bench-block-import", "Run block import benchmarks");
    bench_block_import_step.dependOn(&run_bench_block_import.step);

    // Add target trace benchmark step
    const bench_target_trace = b.addExecutable(.{
        .name = "bench-target-trace",
        .root_source_file = b.path("src/bench_target_trace.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    bench_target_trace.root_module.addOptions("build_options", bench_build_options);
    bench_target_trace.root_module.addImport("pretty", pretty_module);
    bench_target_trace.root_module.addImport("diffz", diffz_module);
    configureTracy(b, bench_target_trace, bench_config.enable_tracy, tracy_dep);
    bench_target_trace.linkLibCpp();
    rust_deps.staticallyLinkTo(bench_target_trace);
    b.installArtifact(bench_target_trace);

    const run_bench_target_trace = b.addRunArtifact(bench_target_trace);
    const bench_target_trace_step = b.step("bench-target-trace", "Benchmark target processing traces (for profiling)");
    bench_target_trace_step.dependOn(&run_bench_target_trace.step);
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
