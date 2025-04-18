//! Exploring the reactor pattern with Zig since I want
//! to use this as a pattern to handle threads in JamZig

const std = @import("std");
const xev = @import("xev");
const Allocator = std.mem.Allocator;

const Mailbox = @import("../../datastruct/blocking_queue.zig").BlockingQueue;

pub const CommandCallback = *const fn (result: ?*anyopaque, context: ?*anyopaque) void;

pub const RequestMetadata = struct {
    callback: CommandCallback,
    context: ?*anyopaque = null,
    mailbox: *Mailbox(Response, 64), // Mailbox to push results back to
    mailbox_wakeup: *xev.Async, // Async handle for waking up the worker
};

pub const Request = struct {
    command: Command,
    metadata: RequestMetadata,

    pub fn getMetadata(self: Request) RequestMetadata {
        return self.metadata;
    }
};

pub const Response = struct {
    callback: CommandCallback,
    context: ?*anyopaque,
    result: CommandResult,
    allocator: ?Allocator = null,

    // Free the response and result
    pub fn release(self: *Response) void {
        if (self.allocator) |alloc| {
            alloc.destroy(self.result);
            alloc.destroy(self);
        }
    }
};

pub const Command = union(enum) {
    add: struct { a: f64, b: f64 },
    subtract: struct { a: f64, b: f64 },
    multiply: struct { a: f64, b: f64 },
    divide: struct { a: f64, b: f64 },
    shutdown: void,
};

pub const CommandResult = anyerror!f64;

pub const Worker = struct {
    alloc: Allocator,
    loop: xev.Loop,
    wakeup: xev.Async,
    wakeup_c: xev.Completion = .{},
    stop: xev.Async,
    stop_c: xev.Completion = .{},
    mailbox: *Mailbox(Request, 64),
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
        thread.mailbox = try Mailbox(Request, 64).create(alloc);
        errdefer thread.mailbox.destroy(alloc);

        thread.alloc = alloc;
        thread.id = id;

        // Configure xev
        thread.wakeup.wait(&thread.loop, &thread.wakeup_c, Worker, thread, wakeupCallback);
        thread.stop.wait(&thread.loop, &thread.stop_c, Worker, thread, stopCallback);

        return thread;
    }

    pub fn destroy(self: *Worker) void {
        self.mailbox.destroy(self.alloc);
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

    pub fn sendRequest(self: *Worker, cmd: Request) !void {
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
            std.debug.print("[{s}] Processing command: {s}\n", .{ self.id, @tagName(@as(std.meta.Tag(Command), cmd.command)) });

            // Process the command and fill in the result
            const result = switch (cmd.command) {
                .add => |params| params.a + params.b,
                .subtract => |params| params.a - params.b,
                .multiply => |params| params.a * params.b,
                .divide => |params| blk: {
                    if (params.b == 0) {
                        break :blk error.DivideByZero;
                    }
                    break :blk params.a / params.b;
                },
                .shutdown => blk: {
                    // Handle shutdown command
                    try self.stop.notify();
                    break :blk 0; // Return a default value for shutdown
                },
            };

            // Allocate a new response
            const response = Response{
                .callback = cmd.metadata.callback,
                .context = cmd.metadata.context,
                .result = result,
                .allocator = self.alloc,
            };

            // Push the response to the worker's mailbox
            _ = cmd.metadata.mailbox.push(response, .{ .instant = {} });
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

    std.debug.print("Callback invoked\n", .{});

    if (result) |result_ptr| {
        const cmd_result: *const CommandResult = @ptrCast(@alignCast(result_ptr));

        if (cmd_result.*) |value| {
            std.debug.print("Callback received result: {d:.3}\n", .{value});
        } else |err| {
            std.debug.print("Callback received err: {}\n", .{err});
            return;
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
        self_.?.processResponses();

        return .rearm;
    }

    pub fn deinit(self: *WorkerHandle) void {

        // Free resources
        self.mailbox.destroy(self.alloc);
        self.alloc.destroy(self);
    }

    pub fn processResponses(self: *WorkerHandle) void {
        while (self.mailbox.pop()) |response| {
            std.debug.print("[{s}] Processing result\n", .{self.id});

            response.callback(@ptrCast(@constCast(&response.result)), response.context);
        }
    }

    pub fn add(self: *WorkerHandle, a: f64, b: f64, callback: CommandCallback, context: ?*anyopaque) !void {
        try self.thread.sendRequest(Request{
            .command = .{ .add = .{ .a = a, .b = b } },
            .metadata = .{
                .callback = callback,
                .context = context,
                .mailbox = self.mailbox,
                .mailbox_wakeup = &self.wakeup,
            },
        });
    }

    pub fn subtract(self: *WorkerHandle, a: f64, b: f64, callback: CommandCallback, context: ?*anyopaque) !void {
        try self.thread.sendRequest(Request{
            .command = .{ .subtract = .{ .a = a, .b = b } },
            .metadata = .{
                .callback = callback,
                .context = context,
                .mailbox = self.mailbox,
                .mailbox_wakeup = &self.wakeup,
            },
        });
    }

    pub fn multiply(self: *WorkerHandle, a: f64, b: f64, callback: CommandCallback, context: ?*anyopaque) !void {
        try self.thread.sendRequest(Request{
            .command = .{ .multiply = .{ .a = a, .b = b } },
            .metadata = .{
                .callback = callback,
                .context = context,
                .mailbox = self.mailbox,
                .mailbox_wakeup = &self.wakeup,
            },
        });
    }

    pub fn divide(self: *WorkerHandle, a: f64, b: f64, callback: CommandCallback, context: ?*anyopaque) !void {
        try self.thread.sendRequest(Request{
            .command = .{ .divide = .{ .a = a, .b = b } },
            .metadata = .{
                .callback = callback,
                .context = context,
                .mailbox = self.mailbox,
                .mailbox_wakeup = &self.wakeup,
            },
        });
    }

    pub fn shutdown(self: *WorkerHandle, callback: CommandCallback, context: ?*anyopaque) !void {
        try self.thread.sendRequest(Request{
            .command = .{ .shutdown = {} },
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

    // Worker thread
    const worker = try Worker.create(alloc, "worker_thread");
    defer worker.destroy();
    const worker_thread = try std.Thread.spawn(.{}, Worker.threadMain, .{worker});

    // Create a worker handle
    var handle = try WorkerHandle.init(alloc, "worker", &main_loop, worker);
    defer handle.deinit();

    // Now start a new thread where we will have a handle which is doing some work

    // Send some commands to the worker
    try handle.add(5, 3, exampleCallback, null);
    try handle.divide(10, 2, exampleCallback, null);
    try handle.divide(10, 0, exampleCallback, null);

    // Wait a bit and process results
    std.time.sleep(500 * std.time.ns_per_ms);
    handle.processResponses();

    // Send shutdown command
    try handle.shutdown(exampleCallback, null);
    //
    // Wait a bit more and process final results
    std.time.sleep(500 * std.time.ns_per_ms);
    handle.processResponses();

    worker_thread.join();
}
