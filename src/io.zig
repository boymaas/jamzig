//! IO Executor abstraction for parallel and sequential task execution
//! Provides a unified interface for running groups of tasks with proper synchronization

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Thread pool task group for parallel execution
pub const ThreadPoolTaskGroup = struct {
    pool: *std.Thread.Pool,
    wg: std.Thread.WaitGroup,

    /// Spawn a task in this group
    pub fn spawn(self: *ThreadPoolTaskGroup, comptime func: anytype, args: anytype) !void {
        // Increment wait group BEFORE spawning
        self.wg.start();

        // Spawn with wrapper that ensures finish() is called
        const Wrapper = struct {
            fn run(wg: *std.Thread.WaitGroup, f: @TypeOf(func), a: @TypeOf(args)) void {
                defer wg.finish();
                @call(.auto, f, a) catch |err| {
                    // Log the error but don't propagate it since this is a fire-and-forget task
                    std.log.err("Task failed with error: {}", .{err});
                };
            }
        };

        try self.pool.spawn(Wrapper.run, .{ &self.wg, func, args });
    }

    /// Wait for all tasks in this group to complete
    pub fn wait(self: *ThreadPoolTaskGroup) void {
        self.wg.wait();
    }
};

/// Thread pool executor for parallel task execution
pub const ThreadPoolExecutor = struct {
    pool: *std.Thread.Pool,
    allocator: Allocator,

    /// Initialize with specified thread count (null = CPU core count)
    pub fn init(allocator: Allocator, thread_count: ?usize) !ThreadPoolExecutor {
        const pool = try allocator.create(std.Thread.Pool);
        errdefer allocator.destroy(pool);

        try pool.init(.{
            .allocator = allocator,
            .n_jobs = thread_count orelse try std.Thread.getCpuCount(),
        });

        return .{
            .pool = pool,
            .allocator = allocator,
        };
    }

    /// Clean up the thread pool
    pub fn deinit(self: *ThreadPoolExecutor) void {
        self.pool.deinit();
        self.allocator.destroy(self.pool);
    }

    /// Create a new task group
    pub fn createGroup(self: *ThreadPoolExecutor) ThreadPoolTaskGroup {
        return .{
            .pool = self.pool,
            .wg = std.Thread.WaitGroup{},
        };
    }
};

/// Sequential task group for testing - executes tasks immediately
pub const SequentialTaskGroup = struct {
    /// Spawn (execute immediately) a task
    pub fn spawn(self: *SequentialTaskGroup, comptime func: anytype, args: anytype) !void {
        _ = self;
        try @call(.auto, func, args);
    }

    /// No-op for sequential execution (tasks already completed)
    pub fn wait(self: *SequentialTaskGroup) void {
        _ = self;
    }
};

/// Sequential executor for testing
pub const SequentialExecutor = struct {
    /// Initialize a sequential executor
    pub fn init() SequentialExecutor {
        return .{};
    }

    /// Create a new task group
    pub fn createGroup(self: *SequentialExecutor) SequentialTaskGroup {
        _ = self;
        return .{};
    }
};

// Tests
test "ThreadPoolExecutor basic functionality" {
    const allocator = std.testing.allocator;

    var executor = try ThreadPoolExecutor.init(allocator, 2);
    defer executor.deinit();

    var counter = std.atomic.Value(i32).init(0);

    var group = executor.createGroup();

    const incrementTask = struct {
        fn increment(c: *std.atomic.Value(i32)) void {
            _ = c.fetchAdd(1, .monotonic);
        }
    }.increment;

    // Spawn multiple tasks
    try group.spawn(incrementTask, .{&counter});
    try group.spawn(incrementTask, .{&counter});
    try group.spawn(incrementTask, .{&counter});

    // Wait for all to complete
    group.wait();

    try std.testing.expectEqual(@as(i32, 3), counter.load(.monotonic));
}

test "SequentialExecutor basic functionality" {
    var executor = SequentialExecutor.init();

    var counter: i32 = 0;

    var group = executor.createGroup();

    const incrementTask = struct {
        fn increment(c: *i32) void {
            c.* += 1;
        }
    }.increment;

    // Spawn (execute) multiple tasks
    try group.spawn(incrementTask, .{&counter});
    try group.spawn(incrementTask, .{&counter});
    try group.spawn(incrementTask, .{&counter});

    // Wait is a no-op for sequential
    group.wait();

    try std.testing.expectEqual(@as(i32, 3), counter);
}

test "Multiple task groups can run independently" {
    const allocator = std.testing.allocator;

    var executor = try ThreadPoolExecutor.init(allocator, 4);
    defer executor.deinit();

    var counter1 = std.atomic.Value(i32).init(0);
    var counter2 = std.atomic.Value(i32).init(0);

    // Create two independent task groups
    var group1 = executor.createGroup();
    var group2 = executor.createGroup();

    const incrementTask = struct {
        fn increment(c: *std.atomic.Value(i32)) void {
            _ = c.fetchAdd(1, .monotonic);
        }
    }.increment;

    // Spawn tasks in both groups
    try group1.spawn(incrementTask, .{&counter1});
    try group1.spawn(incrementTask, .{&counter1});

    try group2.spawn(incrementTask, .{&counter2});
    try group2.spawn(incrementTask, .{&counter2});
    try group2.spawn(incrementTask, .{&counter2});

    // Wait for each group independently
    group1.wait();
    try std.testing.expectEqual(@as(i32, 2), counter1.load(.monotonic));

    group2.wait();
    try std.testing.expectEqual(@as(i32, 3), counter2.load(.monotonic));
}
