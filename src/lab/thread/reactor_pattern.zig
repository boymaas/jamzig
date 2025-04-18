const std = @import("std");
const xev = @import("xev");
const Allocator = std.mem.Allocator;

const Mailbox = @import("../../datastruct/blocking_queue.zig").BlockingQueue;

pub const CommandType = enum {
    add,
    subtract,
    multiply,
    divide,
    shutdown,
};

pub const CommandCallback = *const fn (result: ?*anyopaque, context: ?*anyopaque) void;

pub const CommandMetadata = struct {
    callback: CommandCallback,
    context: ?*anyopaque = null,
    mailbox: *Mailbox(Response, 64), // Mailbox to push results back to
    mailbox_wakeup: *xev.Async, // Async handle for waking up the worker
};

pub const Command = struct {
    cmd_type: CommandType,
    params: struct {
        a: f64 = 0,
        b: f64 = 0,
    },
    metadata: CommandMetadata,
};

pub const Response = struct {
    callback: CommandCallback,
    context: ?*anyopaque,
    result: *CommandResult,
    pool: ?*ResponsePool = null,

    // Return to pool if available
    pub fn release(self: *Response) void {
        if (self.pool) |pool| {
            pool.release(self);
        }
    }
};

pub const CommandResult = struct {
    success: bool,
    value: ?f64 = null,
    error_message: ?[]const u8 = null,
};

/// Pre-allocated response pool
pub const ResponsePool = struct {
    responses: []Response,
    results: []CommandResult,
    next_available: usize,
    in_use: usize,
    mutex: std.Thread.Mutex,

    // Init pool
    pub fn init(alloc: Allocator, size: usize) !ResponsePool {
        const responses = try alloc.alloc(Response, size);
        errdefer alloc.free(responses);

        const results = try alloc.alloc(CommandResult, size);
        errdefer alloc.free(results);

        return ResponsePool{
            .responses = responses,
            .results = results,
            .next_available = 0,
            .in_use = 0,
            .mutex = .{},
        };
    }

    // Free pool
    pub fn deinit(self: *ResponsePool, alloc: Allocator) void {
        alloc.free(self.responses);
        alloc.free(self.results);
        self.* = undefined;
    }

    // Get response-result pair
    pub fn acquire(self: *ResponsePool) ?struct { response: *Response, result: *CommandResult } {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.in_use >= self.responses.len) {
            return null; // Pool is full
        }

        const idx = self.next_available;
        self.next_available = (self.next_available + 1) % self.responses.len;
        self.in_use += 1;

        return .{
            .response = &self.responses[idx],
            .result = &self.results[idx],
        };
    }

    // Return to pool
    pub fn release(self: *ResponsePool, _: *Response) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.in_use -= 1;
    }
};

pub const Worker = struct {
    alloc: Allocator,
    loop: xev.Loop,
    wakeup: xev.Async,
    wakeup_c: xev.Completion = .{},
    stop: xev.Async,
    stop_c: xev.Completion = .{},
    mailbox: *Mailbox(Command, 64),
    response_pool: ResponsePool,
    id: []const u8,

    pub fn create(alloc: Allocator, id: []const u8) !*Worker {
        var thread = try alloc.create(Worker);
        errdefer alloc.destroy(thread);

        // Initialize event loop
        thread.loop = try xev.Loop.init(.{});
        errdefer thread.loop.deinit();

        // Initialize async handles
        thread.wakeup = try xev.Async.init();
        errdefer thread.wakeup.deinit();

        thread.stop = try xev.Async.init();
        errdefer thread.stop.deinit();

        // Initialize mailbox
        thread.mailbox = try Mailbox(Command, 64).create(alloc);
        errdefer thread.mailbox.destroy(alloc);

        // Initialize response pool (size 128 should be sufficient for most uses)
        thread.response_pool = try ResponsePool.init(alloc, 128);
        errdefer thread.response_pool.deinit(alloc);

        thread.alloc = alloc;
        thread.id = id;

        // Configure xev
        thread.wakeup.wait(&thread.loop, &thread.wakeup_c, Worker, thread, wakeupCallback);
        thread.stop.wait(&thread.loop, &thread.stop_c, Worker, thread, stopCallback);

        return thread;
    }

    pub fn destroy(self: *Worker) void {
        self.mailbox.destroy(self.alloc);
        self.response_pool.deinit(self.alloc);
        self.stop.deinit();
        self.wakeup.deinit();
        self.loop.deinit();
        self.alloc.destroy(self);
    }

    pub fn start(self: *Worker) !std.Thread {
        // Register callbacks for async events
        self.wakeup.wait(&self.loop, &self.wakeup_c, Worker, self, wakeupCallback);
        self.stop.wait(&self.loop, &self.stop_c, Worker, self, stopCallback);

        // Start the thread
        return try std.Thread.spawn(.{}, threadMain, .{self});
    }

    pub fn stopThread(self: *Worker) !void {
        try self.stop.notify();
    }

    pub fn sendCommand(self: *Worker, cmd: Command) !void {
        _ = self.mailbox.push(cmd, .{ .instant = {} });
        try self.wakeup.notify();
    }

    fn threadMain(self: *Worker) void {
        std.debug.print("[{s}] Thread started\n", .{self.id});

        // Run the event loop until stopped
        self.loop.run(.until_done) catch |err| {
            std.debug.print("[{s}] Error in event loop: {any}\n", .{ self.id, err });
        };

        std.debug.print("[{s}] Thread stopped\n", .{self.id});
    }

    fn wakeupCallback(
        self_: ?*Worker,
        _: *xev.Loop,
        _: *xev.Completion,
        r: xev.Async.WaitError!void,
    ) xev.CallbackAction {
        _ = r catch |err| {
            std.debug.print("Error in wakeup callback: {any}\n", .{err});
            return .rearm;
        };

        const self = self_.?;

        // Process all commands in the mailbox
        self.processCommands() catch |err| {
            std.debug.print("[{s}] Error processing commands: {any}\n", .{ self.id, err });
        };

        // Keep the callback active
        return .rearm;
    }

    fn processCommands(self: *Worker) !void {
        while (self.mailbox.pop()) |cmd| {
            std.debug.print("[{s}] Processing command: {any}\n", .{ self.id, cmd.cmd_type });

            // Get a response and result from the pool
            const pair = self.response_pool.acquire() orelse {
                std.debug.print("[{s}] Response pool exhausted\n", .{self.id});
                continue;
            };

            // Process the command and fill in the result
            pair.result.* = switch (cmd.cmd_type) {
                .add => CommandResult{
                    .success = true,
                    .value = cmd.params.a + cmd.params.b,
                },

                .subtract => CommandResult{
                    .success = true,
                    .value = cmd.params.a - cmd.params.b,
                },

                .multiply => CommandResult{
                    .success = true,
                    .value = cmd.params.a * cmd.params.b,
                },

                .divide => blk: {
                    if (cmd.params.b == 0) {
                        break :blk CommandResult{
                            .success = false,
                            .error_message = "Division by zero",
                        };
                    }

                    break :blk CommandResult{
                        .success = true,
                        .value = cmd.params.a / cmd.params.b,
                    };
                },

                .shutdown => blk: {
                    // Handle shutdown command
                    try self.stop.notify();

                    break :blk CommandResult{
                        .success = true,
                    };
                },
            };

            // Set up the response
            pair.response.* = Response{
                .callback = cmd.metadata.callback,
                .context = cmd.metadata.context,
                .result = pair.result,
                .pool = &self.response_pool,
            };

            // Push the response to the worker's mailbox
            _ = cmd.metadata.mailbox.push(pair.response.*, .{ .instant = {} });
            cmd.metadata.mailbox_wakeup.notify() catch {};
        }
    }

    fn stopCallback(
        self_: ?*Worker,
        _: *xev.Loop,
        _: *xev.Completion,
        r: xev.Async.WaitError!void,
    ) xev.CallbackAction {
        _ = r catch unreachable;

        std.debug.print("[{s}] stopCallback\n", .{self_.?.id});

        // Stop the event loop
        self_.?.loop.stop();

        return .disarm;
    }
};

// Example callback
fn exampleCallback(result: ?*anyopaque, context: ?*anyopaque) void {
    _ = context;

    if (result) |result_ptr| {
        const cmd_result: *const CommandResult = @ptrCast(@alignCast(result_ptr));

        if (cmd_result.success) {
            if (cmd_result.value) |value| {
                std.debug.print("Callback result: {d}\n", .{value});
            } else {
                std.debug.print("Callback successful (no value)\n", .{});
            }
        } else {
            std.debug.print("Callback failed: {s}\n", .{cmd_result.error_message orelse "Unknown error"});
        }
    } else {
        std.debug.print("Callback received null result\n", .{});
    }
}

pub const WorkerHandle = struct {
    id: []const u8,
    loop: *xev.Loop,
    thread: *Worker,
    wakeup: xev.Async,
    wakeup_c: xev.Completion = .{},
    mailbox: *Mailbox(Response, 64),
    response_pool: ?*ResponsePool = null,
    alloc: Allocator,

    pub fn init(alloc: Allocator, id: []const u8, loop: *xev.Loop, thread: *Worker) !*WorkerHandle {
        var worker = try alloc.create(WorkerHandle);
        errdefer alloc.destroy(worker);

        // To track the worker
        worker.id = id;
        worker.loop = loop;

        worker.thread = thread;

        // Initialize async handles
        worker.wakeup = try xev.Async.init();
        errdefer worker.wakeup.deinit();

        worker.wakeup.wait(
            worker.loop,
            &worker.wakeup_c,
            WorkerHandle,
            worker,
            wakeupCallback,
        );

        // Initialize result mailbox
        worker.mailbox = try Mailbox(Response, 64).create(alloc);
        errdefer worker.mailbox.destroy(alloc);

        worker.alloc = alloc;

        return worker;
    }

    pub fn wakeupCallback(
        self_: ?*WorkerHandle,
        _: *xev.Loop,
        _: *xev.Completion,
        r: xev.Async.WaitError!void,
    ) xev.CallbackAction {
        _ = r catch unreachable;

        // Process any pending results
        self_.?.processResults();

        return .rearm;
    }

    pub fn deinit(self: *WorkerHandle) void {

        // Free resources
        self.mailbox.destroy(self.alloc);
        self.alloc.destroy(self);
    }

    pub fn processResults(self: *WorkerHandle) void {
        while (self.mailbox.pop()) |*response| {
            std.debug.print("[{s}] Processing result\n", .{self.id});

            // Call the callback with the result
            response.callback(@ptrCast(response.result), response.context);

            // Release the response back to its pool if it came from one
            var mutable_response = @constCast(response);
            mutable_response.release();
        }
    }

    pub fn add(self: *WorkerHandle, a: f64, b: f64, callback: CommandCallback, context: ?*anyopaque) !void {
        try self.thread.sendCommand(Command{
            .cmd_type = .add,
            .params = .{ .a = a, .b = b },
            .metadata = .{
                .callback = callback,
                .context = context,
                .mailbox = self.mailbox,
                .mailbox_wakeup = &self.wakeup,
            },
        });
    }

    pub fn subtract(self: *WorkerHandle, a: f64, b: f64, callback: CommandCallback, context: ?*anyopaque) !void {
        try self.thread.sendCommand(Command{
            .cmd_type = .subtract,
            .params = .{ .a = a, .b = b },
            .metadata = .{
                .callback = callback,
                .context = context,
                .mailbox = self.mailbox,
                .mailbox_wakeup = &self.wakeup,
            },
        });
    }

    pub fn multiply(self: *WorkerHandle, a: f64, b: f64, callback: CommandCallback, context: ?*anyopaque) !void {
        try self.thread.sendCommand(Command{
            .cmd_type = .multiply,
            .params = .{ .a = a, .b = b },
            .metadata = .{
                .callback = callback,
                .context = context,
                .mailbox = self.mailbox,
                .mailbox_wakeup = &self.wakeup,
            },
        });
    }

    pub fn divide(self: *WorkerHandle, a: f64, b: f64, callback: CommandCallback, context: ?*anyopaque) !void {
        try self.thread.sendCommand(Command{
            .cmd_type = .divide,
            .params = .{ .a = a, .b = b },
            .metadata = .{
                .callback = callback,
                .context = context,
                .mailbox = self.mailbox,
                .mailbox_wakeup = &self.wakeup,
            },
        });
    }

    pub fn shutdown(self: *WorkerHandle, callback: CommandCallback, context: ?*anyopaque) !void {
        try self.thread.sendCommand(Command{
            .cmd_type = .shutdown,
            .params = .{ .a = 0, .b = 0 },
            .metadata = .{
                .callback = callback,
                .context = context,
                .mailbox = self.mailbox,
                .mailbox_wakeup = &self.wakeup,
            },
        });
    }
};

test "reactor.pattern" {
    const alloc = std.testing.allocator;

    // Initialize event loop
    var main_loop = try xev.Loop.init(.{});
    errdefer main_loop.deinit();

    // Woker thread
    const worker = try Worker.create(alloc, "worker_thread");
    defer worker.destroy();
    const worker_thread = try std.Thread.spawn(.{}, Worker.threadMain, .{worker});

    // Create a worker
    var handle = try WorkerHandle.init(alloc, "worker", &main_loop, worker);
    defer handle.deinit();

    // Now start a new thread where we will have a handle which is doing some work

    // Send some commands to the worker
    try handle.add(5, 3, exampleCallback, null);
    try handle.divide(10, 2, exampleCallback, null);
    try handle.divide(10, 0, exampleCallback, null);

    // Wait a bit and process results
    std.time.sleep(1 * std.time.ns_per_s);
    handle.processResults();

    // Send shutdown command
    try handle.shutdown(exampleCallback, null);
    //
    // Wait a bit more and process final results
    std.time.sleep(1 * std.time.ns_per_s);
    handle.processResults();

    worker_thread.join();
}
