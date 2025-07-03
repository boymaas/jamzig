const std = @import("std");
const clap = @import("clap");
const tracing = @import("tracing.zig");

const Fuzzer = @import("fuzz_protocol/fuzzer.zig").Fuzzer;
const report = @import("fuzz_protocol/report.zig");
const jam_params = @import("jam_params.zig");
const jam_params_format = @import("jam_params_format.zig");
const build_options = @import("build_options");
const messages = @import("fuzz_protocol/messages.zig");

const trace = @import("tracing.zig").scoped(.jam_conformance_fuzzer);

fn showHelp(params: anytype) !void {
    std.debug.print(
        \\JAM Conformance Fuzzer: Protocol conformance testing tool for JAM implementations
        \\
        \\This tool connects to a JAM protocol target server and performs conformance testing
        \\by generating deterministic blocks and comparing state transitions.
        \\
        \\
    , .{});
    try clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{ .spacing_between_parameters = 0 });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    tracing.runtime.init(allocator);

    // Parse command line arguments
    const params = comptime clap.parseParamsComptime(
        \\-h, --help             Display this help and exit.
        \\-v, --verbose          Enable verbose output
        \\-s, --socket <str>     Unix socket path to connect to (default: /tmp/jam_conformance.sock)
        \\-S, --seed <u64>       Random seed for deterministic execution (default: timestamp)
        \\-b, --blocks <u32>     Number of blocks to process (default: 100)
        \\-o, --output <str>     Output report file (optional, prints to stdout if not specified)
        \\--dump-params          Dump JAM protocol parameters and exit
        \\--format <str>         Output format for parameter dump: json or text (default: text)
    );

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        try showHelp(params);
        std.process.exit(1);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try showHelp(params);
        return;
    }

    // Handle parameter dumping
    if (res.args.@"dump-params" != 0) {
        const format = res.args.format orelse "text";
        const params_type = if (@hasDecl(build_options, "conformance_params") and build_options.conformance_params == .tiny) "TINY" else "FULL";

        const stdout = std.io.getStdOut().writer();

        if (std.mem.eql(u8, format, "json")) {
            jam_params_format.formatParamsJson(messages.FUZZ_PARAMS, params_type, stdout) catch |err| {
                // Handle BrokenPipe error gracefully (e.g., when piping to head)
                if (err == error.BrokenPipe) {
                    std.process.exit(0);
                }
                return err;
            };
        } else if (std.mem.eql(u8, format, "text")) {
            jam_params_format.formatParamsText(messages.FUZZ_PARAMS, params_type, stdout) catch |err| {
                // Handle BrokenPipe error gracefully (e.g., when piping to head)
                if (err == error.BrokenPipe) {
                    std.process.exit(0);
                }
                return err;
            };
        } else {
            std.debug.print("Error: Invalid format '{s}'. Use 'json' or 'text'.\n", .{format});
            std.process.exit(1);
        }
        return;
    }

    // Extract configuration
    const socket_path = res.args.socket orelse "/tmp/jam_conformance.sock";
    const seed = res.args.seed orelse @as(u64, @intCast(std.time.timestamp()));
    const num_blocks = res.args.blocks orelse 100;
    const output_file = res.args.output;

    // Print configuration
    std.debug.print("JAM Conformance Fuzzer\n", .{});
    std.debug.print("======================\n", .{});
    std.debug.print("Socket path: {s}\n", .{socket_path});
    std.debug.print("Seed: {d}\n", .{seed});
    std.debug.print("Blocks to process: {d}\n", .{num_blocks});
    if (output_file) |f| {
        std.debug.print("Output file: {s}\n", .{f});
    } else {
        std.debug.print("Output: stdout\n", .{});
    }
    std.debug.print("\n", .{});

    // Setup signal handler for graceful shutdown
    var sigaction = std.posix.Sigaction{
        .handler = .{ .handler = struct {
            fn handler(_: c_int) callconv(.C) void {
                std.debug.print("\nReceived signal, shutting down...\n", .{});
                std.process.exit(0);
            }
        }.handler },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };

    std.posix.sigaction(std.posix.SIG.INT, &sigaction, null);
    std.posix.sigaction(std.posix.SIG.TERM, &sigaction, null);

    // Create and run fuzzer
    var fuzzer = try Fuzzer.create(allocator, seed, socket_path);
    defer fuzzer.destroy();

    std.debug.print("Connecting to target at {s}...\n", .{socket_path});

    // Connect to target
    fuzzer.connectToTarget() catch |err| {
        std.debug.print("Error: Failed to connect to target: {s}\n", .{@errorName(err)});
        std.debug.print("\nMake sure the target server is running:\n", .{});
        std.debug.print("  ./zig-out/bin/jam_conformance_target --socket {s}\n", .{socket_path});
        return err;
    };

    // Perform handshake
    try fuzzer.performHandshake();
    std.debug.print("Handshake completed successfully\n\n", .{});

    // Run fuzzing cycle
    std.debug.print("Starting conformance testing with {d} blocks...\n", .{num_blocks});
    var result = try fuzzer.runFuzzCycle(num_blocks);
    defer result.deinit();

    // End session
    fuzzer.endSession();

    // Generate report
    const report_text = try report.generateReport(allocator, result);
    defer allocator.free(report_text);

    // Output report
    if (output_file) |file_path| {
        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        try file.writeAll(report_text);
        std.debug.print("\nReport written to: {s}\n", .{file_path});
    } else {
        std.debug.print("\n{s}\n", .{report_text});
    }

    // Print summary
    if (result.isSuccess()) {
        std.debug.print("\n✓ Conformance test PASSED - All {d} blocks processed successfully\n", .{num_blocks});
        std.process.exit(0);
    } else {
        std.debug.print("\n✗ Conformance test FAILED - State mismatch detected\n", .{});
        std.process.exit(1);
    }
}
