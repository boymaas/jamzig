const std = @import("std");
const builtin = @import("builtin");

// Project configuration - equivalent to CMake project() command
const project_name = "mcl";
const project_version = "1.74";

// Build options - equivalent to CMake options()
const BuildOptions = struct {
    // Maximum bit size for Fp, defaults to 384 in CMake
    max_bit_size: u32 = 384,
    // Build as static library (default false in CMake)
    static_lib: bool = false,
    // Use LLVM for base64.ll (default true in CMake)
    use_llvm: bool = true,
};

pub fn build(b: *std.Build) !void {
    // Get target and optimize options
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get target CPU architecture information
    const is_x86_64 = if (target.query.cpu_arch) |arch| arch == .x86_64 else false;

    // Parse build options
    const options = BuildOptions{
        .max_bit_size = b.option(u32, "max-bit-size", "Maximum bit size for Fp") orelse 384,
        .use_llvm = b.option(bool, "use-llvm", "Use LLVM for base64.ll") orelse true,
    };

    const upstream = b.dependency("mcl", .{});

    const mcl_lib = b.addStaticLibrary(.{
        .name = project_name,
        .target = target,
        .optimize = optimize,
    });

    // Common compiler flags (equivalent to target_compile_options in CMake)
    const common_flags = &.{
        "-g3",
        "-Wall",
        "-Wextra",
        "-Wformat=2",
        "-Wcast-qual",
        "-Wcast-align",
        "-Wwrite-strings",
        "-Wfloat-equal",
        "-Wpointer-arith",
        "-Wundef",
        "-fomit-frame-pointer",
        "-DNDEBUG",
        "-fno-stack-protector",
        "-O3",
        "-fpic",
        // Enable general assembly optimizations for all architectures
        "-DMCL_USE_LLVM=1",
        "-DMCL_BINT_ASM=1",
        "-DMCL_MSM=0",
    };

    // Add LLVM-specific flags if enabled
    var flags = std.ArrayList([]const u8).init(b.allocator);
    defer flags.deinit();
    try flags.appendSlice(common_flags);

    if (options.use_llvm) {
        try flags.appendSlice(&.{
            "-DMCL_USE_LLVM=1",
            "-DMCL_BINT_ASM=0",
            "-DMCL_BINT_ASM_X64=0",
        });
    }

    // Add max bit size definition if specified
    if (options.max_bit_size > 0) {
        const max_bit_def = try std.fmt.allocPrint(
            b.allocator,
            "-DMCL_MAX_BIT_SIZE={d}",
            .{options.max_bit_size},
        );
        try flags.append(max_bit_def);
    }

    // Add x64-specific flag based on architecture
    if (is_x86_64) {
        try flags.append("-DMCL_BINT_ASM_X64=1");
    } else {
        try flags.append("-DMCL_BINT_ASM_X64=0");
    }

    // Configure both main libraries
    mcl_lib.addCSourceFile(.{
        .file = upstream.path("src/fp.cpp"),
        .flags = flags.items,
    });

    // Add LLVM IR compilation step
    if (is_x86_64 and !target.result.isDarwin()) {
        // For x86_64 Linux, use the pre-written assembly
        mcl_lib.addAssemblyFile(upstream.path("src/asm/x86-64.S"));
        mcl_lib.addAssemblyFile(upstream.path("src/asm/bint-x64-amd64.S"));
    } else {
        // For other platforms, compile the LLVM IR file
        const bit_size = if (target.result.ptrBitWidth() == 64) "64" else "32";
        mcl_lib.addCSourceFile(.{
            .file = upstream.path(b.fmt("src/base{s}.ll", .{bit_size})),
            .flags = flags.items,
        });
        mcl_lib.addCSourceFile(.{
            .file = upstream.path(b.fmt("src/bint{s}.ll", .{bit_size})),
            .flags = flags.items,
        });
    }

    mcl_lib.installHeadersDirectory(upstream.path("include/mcl"), "mcl", .{});
    mcl_lib.addIncludePath(upstream.path("include"));
    mcl_lib.linkLibCpp();
    mcl_lib.linkLibC();

    b.installArtifact(mcl_lib);

    // Add specialized bn libraries
    const bn_configs = .{
        .{ .name = "mclbn256", .source = "src/bn_c256.cpp" },
        .{ .name = "mclbn384", .source = "src/bn_c384.cpp" },
        .{ .name = "mclbn384_256", .source = "src/bn_c384_256.cpp" },
    };

    // Create and configure bn libraries
    inline for (bn_configs) |config| {
        var bn_lib =
            b.addStaticLibrary(.{
            .name = config.name,
            .target = target,
            .optimize = optimize,
        });

        // Add source file and configuration
        bn_lib.addCSourceFile(.{
            .file = upstream.path(config.source),
            .flags = flags.items,
        });

        // Link against appropriate main library
        // bn_lib.linkLibrary(if (options.static_lib) mcl_static else mcl_shared);

        // Configure standard settings
        bn_lib.linkLibCpp();
        bn_lib.linkLibC();
        bn_lib.addIncludePath(upstream.path("include"));

        // Install the bn library
        b.installArtifact(bn_lib);
    }
}
