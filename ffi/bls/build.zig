const std = @import("std");

// This build script corresponds to the CMake project 'bls' version 1.10
pub fn build(b: *std.Build) void {
    // Standard target and optimize options
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const upstream = b.dependency("bls", .{});
    const upstream_mcl = b.dependency("mcl", .{});

    // For aggregation verification to work we need to enable this
    const enable_eth = b.option(
        bool,
        "enable-eth",
        "Enable Ethereum 2.0 spec support (corresponds to BLS_ETH)",
    ) orelse true;

    // Compile flags that correspond to the CMake configuration
    const lib_cflags = [_][]const u8{
        "-Wall",
        "-Wextra",
        "-Wformat=2",
        "-Wcast-qual",
        "-Wcast-align",
        "-Wwrite-strings",
        "-Wfloat-equal",
        "-Wpointer-arith",
        "-O3",
        "-fno-exceptions",
        "-fno-threadsafe-statics",
        "-fno-rtti",
        "-fno-stack-protector",
        "-DNDEBUG",
        "-DMCL_DONT_USE_OPENSSL",
        "-DMCL_MAX_BIT_SIZE=384",
        "-DCYBOZU_DONT_USE_EXCEPTION",
        "-DCYBOZU_DONT_USE_STRING",
        "-D_FORTIFY_SOURCE=0",
        "-std=c++03",
    };

    // Add BLS_ETH define if enabled
    var common_flags = std.ArrayList([]const u8).init(b.allocator);
    defer common_flags.deinit();
    common_flags.appendSlice(&lib_cflags) catch unreachable;
    if (enable_eth) {
        common_flags.append("-DBLS_ETH") catch unreachable;
    }

    // Create shared libraries for different bit versions
    const versions = [_][]const u8{ "256", "384", "384_256" };
    for (versions) |bit| {
        const lib_name = std.fmt.allocPrint(b.allocator, "bls{s}", .{bit}) catch unreachable;
        const lib = b.addStaticLibrary(.{
            .name = lib_name,
            .target = target,
            .optimize = optimize,
        });

        // Add include directories
        lib.addIncludePath(upstream.path("include"));
        lib.addIncludePath(upstream_mcl.path("include"));

        lib.linkLibCpp();

        // Add source files and flags
        lib.addCSourceFiles(.{
            .root = upstream.path("."),
            .files = &.{b.fmt("src/bls_c{s}.cpp", .{bit})},
            .flags = common_flags.items,
        });

        // Install headers (equivalent to install() in CMake)
        lib.installHeadersDirectory(upstream.path("include/bls"), "bls", .{});

        // Installation
        b.installArtifact(lib);
    }
}
