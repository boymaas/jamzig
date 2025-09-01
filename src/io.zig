const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ThreadPoolTaskGroup = struct {
    pool: *std.Thread.Pool,
    wg: std.Thread.WaitGroup,
    error_list: std.ArrayList(anyerror),
    error_mutex: std.Thread.Mutex,
    allocator: Allocator,

    pub fn deinit(self: *ThreadPoolTaskGroup) void {
        self.error_list.deinit();
        self.* = undefined;
    }

    pub fn spawn(self: *ThreadPoolTaskGroup, comptime func: anytype, args: anytype) !void {
        self.wg.start();
        const Wrapper = struct {
            fn run(group: *ThreadPoolTaskGroup, f: @TypeOf(func), a: @TypeOf(args)) void {
                defer group.wg.finish();

                const ResultType = @typeInfo(@TypeOf(f)).@"fn".return_type orelse @TypeOf(void);
                const is_error_union = @typeInfo(ResultType) == .error_union;
                if (is_error_union) {
                    @call(.auto, f, a) catch |err| {
                        {
                            group.error_mutex.lock();
                            defer group.error_mutex.unlock();
                            group.error_list.append(err) catch {}; // best effort
                        }
                        std.log.err("Task failed with error: {}", .{err});
                    };
                } else {
                    @call(.auto, f, a);
                }
            }
        };

        try self.pool.spawn(Wrapper.run, .{ self, func, args });
    }

    pub fn wait(self: *ThreadPoolTaskGroup) void {
        self.wg.wait();
    }

    pub fn waitAndCheckErrors(self: *ThreadPoolTaskGroup) !void {
        self.wg.wait();

        self.error_mutex.lock();
        defer self.error_mutex.unlock();

        if (self.error_list.items.len > 0) {
            const first_error = self.error_list.items[0];
            std.log.err("Found {} errors during parallel execution", .{self.error_list.items.len});
            return first_error;
        }
    }
};

pub const ThreadPoolExecutor = struct {
    pool: *std.Thread.Pool,
    allocator: Allocator,

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

    pub fn deinit(self: *ThreadPoolExecutor) void {
        self.pool.deinit();
        self.allocator.destroy(self.pool);
    }

    pub fn createGroup(self: *ThreadPoolExecutor) ThreadPoolTaskGroup {
        return .{
            .pool = self.pool,
            .wg = std.Thread.WaitGroup{},
            .error_list = std.ArrayList(anyerror).init(self.allocator),
            .error_mutex = std.Thread.Mutex{},
            .allocator = self.allocator,
        };
    }
};

pub const SequentialTaskGroup = struct {
    error_list: std.ArrayList(anyerror),
    allocator: Allocator,

    pub fn deinit(self: *SequentialTaskGroup) void {
        self.error_list.deinit();
        self.* = undefined;
    }

    pub fn spawn(self: *SequentialTaskGroup, comptime func: anytype, args: anytype) !void {
        const ResultType = @TypeOf(@call(.auto, func, args));
        const is_error_union = @typeInfo(ResultType) == .error_union;
        if (is_error_union) {
            @call(.auto, func, args) catch |err| {
                self.error_list.append(err) catch {};
                std.log.err("Task failed with error: {}", .{err});
            };
        } else {
            @call(.auto, func, args);
        }
    }

    pub fn wait(self: *SequentialTaskGroup) void {
        _ = self;
    }

    pub fn waitAndCheckErrors(self: *SequentialTaskGroup) !void {
        if (self.error_list.items.len > 0) {
            const first_error = self.error_list.items[0];
            std.log.err("Found {} errors during sequential execution", .{self.error_list.items.len});
            return first_error;
        }
    }
};

pub const SequentialExecutor = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) SequentialExecutor {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SequentialExecutor) void {
        self.* = undefined;
    }

    pub fn createGroup(self: *SequentialExecutor) SequentialTaskGroup {
        return .{
            .error_list = std.ArrayList(anyerror).init(self.allocator),
            .allocator = self.allocator,
        };
    }
};

test "thread_pool_executor" {
    const allocator = std.testing.allocator;

    var executor = try ThreadPoolExecutor.init(allocator, 2);
    defer executor.deinit();

    var counter = std.atomic.Value(i32).init(0);

    var group = executor.createGroup();
    defer group.deinit();

    const incrementTask = struct {
        fn increment(c: *std.atomic.Value(i32)) void {
            _ = c.fetchAdd(1, .monotonic);
        }
    }.increment;

    try group.spawn(incrementTask, .{&counter});
    try group.spawn(incrementTask, .{&counter});
    try group.spawn(incrementTask, .{&counter});

    group.wait();

    try std.testing.expectEqual(@as(i32, 3), counter.load(.monotonic));
}

test "sequential_executor" {
    const allocator = std.testing.allocator;

    var executor = SequentialExecutor.init(allocator);
    defer executor.deinit();

    var counter: i32 = 0;

    var group = executor.createGroup();
    defer group.deinit();

    const incrementTask = struct {
        fn increment(c: *i32) void {
            c.* += 1;
        }
    }.increment;

    try group.spawn(incrementTask, .{&counter});
    try group.spawn(incrementTask, .{&counter});
    try group.spawn(incrementTask, .{&counter});

    group.wait();

    try std.testing.expectEqual(@as(i32, 3), counter);
}

test "multiple_task_groups" {
    const allocator = std.testing.allocator;

    var executor = try ThreadPoolExecutor.init(allocator, 4);
    defer executor.deinit();

    var counter1 = std.atomic.Value(i32).init(0);
    var counter2 = std.atomic.Value(i32).init(0);

    var group1 = executor.createGroup();
    defer group1.deinit();
    var group2 = executor.createGroup();
    defer group2.deinit();

    const incrementTask = struct {
        fn increment(c: *std.atomic.Value(i32)) void {
            _ = c.fetchAdd(1, .monotonic);
        }
    }.increment;

    try group1.spawn(incrementTask, .{&counter1});
    try group1.spawn(incrementTask, .{&counter1});

    try group2.spawn(incrementTask, .{&counter2});
    try group2.spawn(incrementTask, .{&counter2});
    try group2.spawn(incrementTask, .{&counter2});
    group1.wait();
    try std.testing.expectEqual(@as(i32, 2), counter1.load(.monotonic));

    group2.wait();
    try std.testing.expectEqual(@as(i32, 3), counter2.load(.monotonic));
}

test "error_handling" {
    const allocator = std.testing.allocator;

    const TestError = error{TaskFailed};

    const failingTask = struct {
        fn fail() TestError!void {
            return TestError.TaskFailed;
        }
    }.fail;

    const succeedingTask = struct {
        fn succeed() void {}
    }.succeed;

    // Test ThreadPoolExecutor error collection
    {
        var executor = try ThreadPoolExecutor.init(allocator, 2);
        defer executor.deinit();

        var group = executor.createGroup();
        defer group.deinit();

        try group.spawn(failingTask, .{});
        try group.spawn(succeedingTask, .{});
        try group.spawn(failingTask, .{});

        try std.testing.expectError(TestError.TaskFailed, group.waitAndCheckErrors());
    }

    // Test SequentialExecutor error collection
    {
        var executor = SequentialExecutor.init(allocator);
        defer executor.deinit();

        var group = executor.createGroup();
        defer group.deinit();

        try group.spawn(failingTask, .{});
        try group.spawn(succeedingTask, .{});
        try group.spawn(failingTask, .{});

        try std.testing.expectError(TestError.TaskFailed, group.waitAndCheckErrors());
    }
}
