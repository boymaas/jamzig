//! Benchmark for profiling JAM target processing of trace directories
//!
//! This benchmark:
//! - Runs the target server in the main thread (for flamegraph profiling)
//! - Spawns a simple client thread that sends traces from directories
//! - Focuses purely on target performance when processing real traces
//!
//! Usage: bench-target-trace [iterations] [trace_name]
//! Example: bench-target-trace 10 storage
//!
//! Available traces: fallback, safrole, preimages, preimages_light, storage, storage_light
//!
//! For profiling:
//! perf record -g ./zig-out/bin/bench-target-trace 10 storage
//! perf script | flamegraph.pl > target_profile.svg

const std = @import("std");
const net = std.net;
const types = @import("types.zig");
const build_tuned_allocator = @import("build_tuned_allocator.zig");
const target = @import("fuzz_protocol/target.zig");
const messages = @import("fuzz_protocol/messages.zig");
const frame = @import("fuzz_protocol/frame.zig");
const version = @import("fuzz_protocol/version.zig");
const state_converter = @import("fuzz_protocol/state_converter.zig");
const parsers = @import("trace_runner/parsers.zig");
const jamtestvectors = @import("jamtestvectors.zig");
const io = @import("io.zig");
const jam_params = @import("jam_params.zig");
const tracy = @import("tracy");

const TraceClientContext = struct {
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    trace_name: []const u8,
    iterations: u32,
    completed: std.atomic.Value(bool),

    const Self = @This();

    fn runClient(context: *Self) void {
        context.runClientImpl() catch |err| {
            std.debug.print("Client error: {}\n", .{err});
            context.completed.store(true, .release);
        };
    }

    fn runClientImpl(context: *Self) !void {
        // Wait for server to be ready
        std.time.sleep(200 * std.time.ns_per_ms);

        std.debug.print("Client connecting to socket: {s}\n", .{context.socket_path});

        // Connect to Unix domain socket
        const socket = try std.net.connectUnixSocket(context.socket_path);
        defer socket.close();

        std.debug.print("Client connected, performing handshake...\n", .{});

        // Send handshake (v1 format)
        const peer_info = messages.PeerInfo{
            .fuzz_version = version.FUZZ_PROTOCOL_VERSION,
            .fuzz_features = version.DEFAULT_FUZZ_FEATURES,
            .jam_version = version.PROTOCOL_VERSION,
            .app_version = version.FUZZ_TARGET_VERSION,
            .app_name = "bench-target-trace",
        };
        const handshake_msg = messages.Message{ .peer_info = peer_info };

        const handshake_data = try messages.encodeMessage(context.allocator, handshake_msg);
        defer context.allocator.free(handshake_data);

        try frame.writeFrame(socket, handshake_data);
        const response_data = try frame.readFrame(context.allocator, socket);
        defer context.allocator.free(response_data);

        std.debug.print("Handshake complete, loading traces...\n", .{});

        // Load trace files
        const trace_files = try loadTraceFiles(context.allocator, context.trace_name);
        defer context.allocator.free(trace_files);

        const transitions = try loadTransitions(context, trace_files);
        defer {
            for (transitions) |*transition| {
                transition.deinit(context.allocator);
            }
            context.allocator.free(transitions);
        }

        if (transitions.len == 0) {
            std.debug.print("No transitions loaded, exiting\n", .{});
            return;
        }

        std.debug.print("Loaded {} transitions, setting initial state...\n", .{transitions.len});

        // Send blocks for specified iterations
        for (0..context.iterations) |iter| {
            std.debug.print("Iteration {}/{}\n", .{ iter + 1, context.iterations });

            // Set initial state once (from first transition)
            if (transitions.len > 0) {
                const first_transition = transitions[0];
                var dict = try first_transition.preStateAsMerklizationDict(context.allocator);
                defer dict.deinit();

                var fuzz_state = try state_converter.dictionaryToFuzzState(context.allocator, &dict);
                defer fuzz_state.deinit(context.allocator);

                const block = first_transition.block();
                const initialize_msg = messages.Message{ .initialize = .{ .header = block.header, .keyvals = fuzz_state, .ancestry = messages.Ancestry.Empty } };
                const initialize_data = try messages.encodeMessage(context.allocator, initialize_msg);
                defer context.allocator.free(initialize_data);

                try frame.writeFrame(socket, initialize_data);
                const state_response = try frame.readFrame(context.allocator, socket);
                defer context.allocator.free(state_response);

                std.debug.print("Initial state set on target, starting {} iterations...\n", .{context.iterations});
            }

            for (transitions, 0..) |transition, t_idx| {
                // Just send the block (no setState)
                const block = transition.block();
                const import_msg = messages.Message{ .import_block = block.* };
                const import_data = try messages.encodeMessage(context.allocator, import_msg);
                defer context.allocator.free(import_data);

                try frame.writeFrame(socket, import_data);
                const block_response = try frame.readFrame(context.allocator, socket);
                defer context.allocator.free(block_response);

                if (t_idx > 0 and t_idx % 10 == 0) {
                    std.debug.print("  Processed {}/{} blocks\n", .{ t_idx + 1, transitions.len });
                }
            }
        }

        std.debug.print("Client finished, sending kill signal...\n", .{});

        // Send kill message to stop server
        const kill_msg = messages.Message{ .kill = {} };
        const kill_data = try messages.encodeMessage(context.allocator, kill_msg);
        defer context.allocator.free(kill_data);
        try frame.writeFrame(socket, kill_data);

        context.completed.store(true, .release);
        std.debug.print("Client thread complete\n", .{});
    }
};

fn loadTraceFiles(allocator: std.mem.Allocator, trace_name: []const u8) ![][]const u8 {
    const trace_path = try std.fmt.allocPrint(allocator, "src/jamtestvectors/data/traces/{s}", .{trace_name});
    defer allocator.free(trace_path);

    var trace_files = std.ArrayList([]const u8).init(allocator);

    var trace_dir = std.fs.cwd().openDir(trace_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("Trace directory not found: {s}\n", .{trace_path});
            return err;
        },
        else => return err,
    };
    defer trace_dir.close();

    var walker = try trace_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".bin")) continue;

        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ trace_path, entry.path });
        try trace_files.append(full_path);
    }

    return trace_files.toOwnedSlice();
}

fn loadTransitions(context: *TraceClientContext, trace_files: []const []const u8) ![]parsers.StateTransition {
    const loader = parsers.w3f.Loader(messages.FUZZ_PARAMS){};

    var transitions = std.ArrayList(parsers.StateTransition).init(context.allocator);

    for (trace_files) |file_path| {
        if (std.mem.indexOf(u8, file_path, "genesis.bin") != null) {
            continue;
        }

        const transition = loader.loader().loadTestVector(context.allocator, file_path) catch |err| {
            std.debug.print("  Warning: Failed to load {s}: {}\n", .{ file_path, err });
            continue;
        };

        transitions.append(transition) catch |err| {
            transition.deinit(context.allocator);
            return err;
        };
    }

    return transitions.toOwnedSlice();
}

pub fn main() !void {
    var alloc = build_tuned_allocator.BuildTunedAllocator.init();
    defer alloc.deinit();
    
    // TracyAllocator is a no-op when Tracy is disabled
    var tracy_alloc = tracy.TracyAllocator.init(alloc.allocator());
    const allocator = tracy_alloc.allocator();

    // Parse args: [iterations] [trace_name]
    var args = std.process.args();
    _ = args.skip();

    const iterations = if (args.next()) |arg|
        std.fmt.parseInt(u32, arg, 10) catch {
            std.debug.print("Usage: bench-target-trace [iterations] [trace_name]\n", .{});
            std.debug.print("Available traces: fallback, safrole, preimages, preimages_light, storage, storage_light\n", .{});
            return;
        }
    else
        1;

    const trace_name = args.next() orelse "fallback";

    // Validate trace name
    const valid_traces = [_][]const u8{ "fallback", "safrole", "preimages", "preimages_light", "storage", "storage_light" };
    var valid = false;
    for (valid_traces) |t| {
        if (std.mem.eql(u8, t, trace_name)) {
            valid = true;
            break;
        }
    }
    if (!valid) {
        std.debug.print("Invalid trace '{s}'. Choose from: ", .{trace_name});
        for (valid_traces, 0..) |t, i| {
            std.debug.print("{s}", .{t});
            if (i < valid_traces.len - 1) std.debug.print(", ", .{});
        }
        std.debug.print("\n", .{});
        return;
    }

    // Create ephemeral socket with timestamp
    const timestamp = std.time.timestamp();
    const socket_path = try std.fmt.allocPrint(allocator, "/tmp/jam_bench_{d}.sock", .{timestamp});
    defer allocator.free(socket_path);

    std.debug.print("JAM Target Trace Benchmark\n", .{});
    std.debug.print("===========================\n", .{});
    std.debug.print("Trace: {s}\n", .{trace_name});
    std.debug.print("Iterations: {}\n", .{iterations});
    std.debug.print("Socket: {s}\n", .{socket_path});
    std.debug.print("Target running in main thread for profiling...\n\n", .{});

    // Create client context
    var client_context = TraceClientContext{
        .allocator = allocator,
        .socket_path = socket_path,
        .trace_name = trace_name,
        .iterations = iterations,
        .completed = std.atomic.Value(bool).init(false),
    };

    // Start client in background thread
    const client_thread = try std.Thread.spawn(.{}, TraceClientContext.runClient, .{&client_context});

    // Run target server in MAIN thread (THIS GETS PROFILED)
    var executor = try io.ThreadPoolExecutor.init(allocator);
    defer executor.deinit();

    var target_server = try target.TargetServer(io.ThreadPoolExecutor).init(&executor, allocator, socket_path, .exit_on_disconnect);
    defer target_server.deinit();

    std.debug.print("Starting target server (main thread)...\n", .{});

    // This blocks and processes all requests - PROFILING HAPPENS HERE
    target_server.start() catch |err| {
        std.debug.print("Target server error: {}\n", .{err});
    };

    // Wait for client to finish
    client_thread.join();

    std.debug.print("\nBenchmark complete!\n", .{});
    std.debug.print("Target processed {} iterations of trace '{s}'\n", .{ iterations, trace_name });
}
