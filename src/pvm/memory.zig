const std = @import("std");
const Allocator = std.mem.Allocator;

const trace = @import("../tracing.zig").scoped(.pvm);

pub const Memory = struct {
    // Core memory pages for each section
    read_only: []u8,
    heap: []u8,
    input: []u8,
    stack: []u8,

    // Track current heap allocation position
    heap_base_address: u32,

    // Error tracking
    last_violation: ?ViolationInfo,
    allocator: Allocator,

    // Memory layout constants
    pub const Z_Z: u32 = 0x10000; // 2^16 = 65,536 - Major zone size
    pub const Z_P: u32 = 0x1000; // 2^12 = 4,096 - Page size
    pub const Z_I: u32 = 0x1000000; // 2^24 - Standard input data size

    // Fixed section base addresses
    pub const READ_ONLY_BASE_ADDRESS: u32 = Z_Z;
    pub fn HEAP_BASE_ADDRESS(read_only_size: u32) !u32 {
        return 2 * Z_Z + try std.math.divCeil(u32, read_only_size * Z_Z, Z_Z);
    }
    pub const INPUT_ADDRESS: u32 = 0xFFFFFFFF - Z_Z - Z_I;
    pub const STACK_ADDRESS: u32 = 0xFFFFFFFF - Z_Z;

    pub const MemorySection = enum {
        ReadOnly,
        Heap,
        Input,
        Stack,
    };

    pub const AccessInfo = struct {
        section: MemorySection,
        slice: []u8, // Mutable slice for write access
        offset: u32, // Offset within the section
    };

    pub const ReadAccessInfo = struct {
        section: MemorySection,
        slice: []const u8, // Immutable slice for read access
        offset: u32, // Offset within the section
    };

    pub const ViolationType = enum {
        OutOfBounds,
        WriteProtection,
        AccessViolation,
        NonAllocated,
        InvalidPage,
    };

    pub const ViolationInfo = struct {
        violation_type: ViolationType,
        address: u32,
        attempted_size: usize,
        page_bounds: ?struct {
            start: u32,
            end: u32,
        } = null,
    };

    pub const WriteAccessResult = union(enum) {
        Success: AccessInfo,
        Violation: ViolationInfo,
    };

    pub const ReadAccessResult = union(enum) {
        Success: ReadAccessInfo,
        Violation: ViolationInfo,
    };

    pub const Error = error{ PageFault, DivisionByZero, OutOfMemory, MemoryLimitExceeded };

    pub fn isMemoryError(err: anyerror) bool {
        return err == Error.PageFault;
    }

    fn checkMemoryLimits(ro_size: usize, heap_size: usize, stack_size: u32) !void {
        // Calculate sizes in terms of major zones (Z_Z)
        const ro_zones = try std.math.divCeil(usize, Z_Z * ro_size, Z_Z);
        const heap_zones = try std.math.divCeil(usize, Z_Z * heap_size, Z_Z);
        const stack_zones = try std.math.divCeil(u32, Z_Z * stack_size, Z_Z);

        // Check the memory layout equation: 5Z_Z + ⌈|o|/Z_Z⌉ + ⌈|w|/Z_Z⌉ + ⌈s/Z_Z⌉ + Z_I ≤ 2^32
        var total: u64 = 5 * Z_Z; // Fixed zones
        total += ro_zones;
        total += heap_zones;
        total += stack_zones;
        total += Z_I; // Input data section

        if (total > 0xFFFFFFFF) {
            return Error.MemoryLimitExceeded;
        }
    }

    pub fn init(
        allocator: Allocator,
        read_only: []const u8,
        read_write: []const u8,
        input: []const u8,
        stack_size_in_bytes: u24,
        heap_size_in_pages: u16,
    ) !Memory {
        const span = trace.span(.memory_init);
        defer span.deinit();

        span.debug("Initializing memory system", .{});

        // Calculate section sizes rounded to page boundaries
        const ro_size = try std.math.divCeil(usize, read_only.len * Z_P, Z_P);
        const heap_size = heap_size_in_pages * Z_P + try std.math.divCeil(usize, read_write.len * Z_P, Z_P);
        const input_size = try std.math.divCeil(usize, input.len * Z_P, Z_P);
        const stack_size = try std.math.divCeil(u32, Z_P * @as(u32, stack_size_in_bytes), Z_P);

        // Verify memory limits
        try checkMemoryLimits(ro_size, heap_size, stack_size);

        // Allocate memory pages for each section
        errdefer {
            span.debug("Cleaning up after initialization error", .{});
        }

        var memory = Memory{
            .read_only = try allocator.alloc(u8, ro_size),
            .heap = try allocator.alloc(u8, heap_size),
            .input = try allocator.alloc(u8, input_size),
            .stack = try allocator.alloc(u8, stack_size),
            .heap_base_address = try HEAP_BASE_ADDRESS(@intCast(read_only.len)),
            .last_violation = null,
            .allocator = allocator,
        };

        // Initialize sections with provided data and zero remaining space
        @memcpy(memory.read_only[0..read_only.len], read_only);
        @memset(memory.read_only[read_only.len..], 0);

        @memcpy(memory.heap[0..read_write.len], read_write);
        @memset(memory.heap[read_write.len..], 0);

        @memcpy(memory.input[0..input.len], input);
        @memset(memory.input[input.len..], 0);

        @memset(memory.stack, 0);

        return memory;
    }

    pub fn addressInReadOnlySection(self: *const Memory, address: u32) bool {
        return address >= READ_ONLY_BASE_ADDRESS and
            address < READ_ONLY_BASE_ADDRESS + self.read_only.len;
    }

    pub fn addressInHeap(self: *const Memory, address: u32) bool {
        return address >= self.heap_base_address and
            address < self.heap_base_address + self.heap.len;
    }

    pub fn addressInInput(self: *const Memory, address: u32) bool {
        return address >= INPUT_ADDRESS and
            address < INPUT_ADDRESS + self.input.len;
    }

    pub fn addressInStack(self: *const Memory, address: u32) bool {
        return address >= STACK_ADDRESS and
            address < STACK_ADDRESS + self.stack.len;
    }

    pub fn addressOutsideOfSections(self: *const Memory, address: u32) bool {
        return !self.addressInReadOnlySection(address) and
            !self.addressInHeap(address) and
            !self.addressInInput(address) and
            !self.addressInStack(address);
    }

    pub fn checkReadAccess(self: *const Memory, address: u32, size: usize) ReadAccessResult {
        // Check if address is in any valid readable section
        if (self.addressInReadOnlySection(address)) {
            const offset = address - READ_ONLY_BASE_ADDRESS;
            if (offset + size <= self.read_only.len) {
                return .{ .Success = .{
                    .section = .ReadOnly,
                    .slice = self.read_only[offset..][0..size],
                    .offset = offset,
                } };
            }
            const bound_end = READ_ONLY_BASE_ADDRESS + @as(u32, @intCast(self.read_only.len));
            return .{ .Violation = .{
                .violation_type = .OutOfBounds,
                .address = bound_end,
                .attempted_size = size,
                .page_bounds = .{
                    .start = READ_ONLY_BASE_ADDRESS,
                    .end = bound_end,
                },
            } };
        }

        if (self.addressInHeap(address)) {
            const offset = address - self.heap_base_address;
            if (offset + size <= self.heap.len) {
                return .{ .Success = .{
                    .section = .Heap,
                    .slice = self.heap[offset..][0..size],
                    .offset = offset,
                } };
            }
            const bound_end = self.heap_base_address + @as(u32, @intCast(self.heap.len));
            return .{ .Violation = .{
                .violation_type = .OutOfBounds,
                .address = bound_end,
                .attempted_size = size,
                .page_bounds = .{
                    .start = self.heap_base_address,
                    .end = bound_end,
                },
            } };
        }

        if (self.addressInInput(address)) {
            const offset = address - INPUT_ADDRESS;
            if (offset + size <= self.input.len) {
                return ReadAccessResult{ .Success = .{
                    .section = .Input,
                    .slice = self.input[offset..][0..size],
                    .offset = offset,
                } };
            }
            const bound_end = INPUT_ADDRESS + @as(u32, @intCast(self.input.len));
            return .{ .Violation = .{
                .violation_type = .OutOfBounds,
                .address = bound_end,
                .attempted_size = size,
                .page_bounds = .{
                    .start = INPUT_ADDRESS,
                    .end = bound_end,
                },
            } };
        }

        if (self.addressInStack(address)) {
            const offset = address - STACK_ADDRESS;
            if (offset + size <= self.stack.len) {
                return .{ .Success = .{
                    .section = .Stack,
                    .slice = self.stack[offset..][0..size],
                    .offset = offset,
                } };
            }
            const bound_end = STACK_ADDRESS + @as(u32, @intCast(self.stack.len));
            return .{ .Violation = .{
                .violation_type = .OutOfBounds,
                .address = bound_end,
                .attempted_size = size,
                .page_bounds = .{
                    .start = STACK_ADDRESS,
                    .end = bound_end,
                },
            } };
        }

        // Reading from outside any valid section is an access violation
        return .{ .Violation = .{
            .violation_type = .AccessViolation,
            .address = address,
            .attempted_size = size,
            .page_bounds = null,
        } };
    }

    pub fn checkWriteAccess(self: *const Memory, address: u32, size: usize) WriteAccessResult {
        // Writing to read-only section is a write protection violation
        if (self.addressInReadOnlySection(address)) {
            return .{ .Violation = .{
                .violation_type = .WriteProtection,
                .address = address,
                .attempted_size = size,
                .page_bounds = .{
                    .start = READ_ONLY_BASE_ADDRESS,
                    .end = READ_ONLY_BASE_ADDRESS + @as(u32, @intCast(self.read_only.len)),
                },
            } };
        }

        // Writing to input section is a write protection violation
        if (self.addressInInput(address)) {
            return .{ .Violation = .{
                .violation_type = .WriteProtection,
                .address = address,
                .attempted_size = size,
                .page_bounds = .{
                    .start = INPUT_ADDRESS,
                    .end = INPUT_ADDRESS + @as(u32, @intCast(self.input.len)),
                },
            } };
        }

        if (self.addressInHeap(address)) {
            const offset = address - self.heap_base_address;
            if (offset + size <= self.heap.len) {
                return .{ .Success = .{
                    .section = .Heap,
                    .slice = self.heap[offset..][0..size],
                    .offset = offset,
                } };
            }

            const bound_end = self.heap_base_address + @as(u32, @intCast(self.heap.len));
            return .{ .Violation = .{
                .violation_type = .OutOfBounds,
                .address = bound_end,
                .attempted_size = size,
                .page_bounds = .{
                    .start = self.heap_base_address,
                    .end = bound_end,
                },
            } };
        }

        if (self.addressInStack(address)) {
            const offset = address - STACK_ADDRESS;
            if (offset + size <= self.stack.len) {
                return WriteAccessResult{ .Success = .{
                    .section = .Stack,
                    .slice = self.stack[offset..][0..size],
                    .offset = offset,
                } };
            }

            const bound_end = STACK_ADDRESS + @as(u32, @intCast(self.stack.len));
            return WriteAccessResult{ .Violation = .{
                .violation_type = .OutOfBounds,
                .address = bound_end,
                .attempted_size = size,
                .page_bounds = .{
                    .start = STACK_ADDRESS,
                    .end = bound_end,
                },
            } };
        }

        // Writing outside any writable section is an access violation
        return WriteAccessResult{ .Violation = .{
            .violation_type = .AccessViolation,
            .address = address,
            .attempted_size = size,
            .page_bounds = null,
        } };
    }

    pub fn write(self: *Memory, address: u32, data: []const u8) !void {
        const span = trace.span(.memory_write);
        defer span.deinit();

        span.debug("Writing to memory", .{});
        span.trace("Address: 0x{x}, Data length: {}", .{ address, data.len });

        switch (self.checkWriteAccess(address, data.len)) {
            .Success => |info| {
                @memcpy(info.slice, data);
            },
            .Violation => |violation| {
                self.last_violation = violation;
                return Error.PageFault;
            },
        }
    }

    pub fn read(self: *Memory, address: u32, size: usize) ![]const u8 {
        const span = trace.span(.memory_read);
        defer span.deinit();

        span.debug("Reading from memory", .{});
        span.trace("Address: 0x{x}, Size: {}", .{ address, size });

        switch (self.checkReadAccess(address, size)) {
            .Success => |info| {
                return info.slice;
            },
            .Violation => |violation| {
                self.last_violation = violation;
                return Error.PageFault;
            },
        }
    }

    pub const AllocResult = struct {
        address: u32,
        success: bool,
    };

    pub fn sbrk(self: *Memory, size: u64) Error!AllocResult {
        const span = trace.span(.memory_sbrk);
        defer span.deinit();

        span.debug("Allocating memory with sbrk", .{});
        span.trace("Requested size: {}", .{size});

        // Zero size allocation returns success with address 0
        if (size == 0) {
            return AllocResult{ .address = 0, .success = true };
        }

        // Calculate allocation size rounded to page boundary
        const allocation_size = try std.math.divCeil(u32, @intCast(size), Z_P) * Z_P;

        // Check if new allocation exceeds memory limits
        const new_heap_size = self.heap.len + allocation_size;
        try checkMemoryLimits(self.read_only.len, new_heap_size, @intCast(self.stack.len));

        // Increase the heap size, could move the memory location and initialize the
        // added buffer with 0s
        const old_heap_len = self.heap.len;

        self.heap = try self.allocator.realloc(self.heap, self.heap.len + allocation_size);

        @memset(self.heap[old_heap_len..], 0);

        // Allocation successful - return current address and advance
        const result = AllocResult{
            .address = self.heap_base_address + @as(u32, @intCast(old_heap_len)), // the pointer to the newly allocated memory
            .success = true,
        };

        return result;
    }

    pub fn getLastViolation(self: *const Memory) ?ViolationInfo {
        return self.last_violation;
    }

    pub fn deinit(self: *Memory) void {
        const span = trace.span(.memory_deinit);
        defer span.deinit();

        span.debug("Deinitializing memory system", .{});

        // Free all section memory
        self.allocator.free(self.read_only);
        self.allocator.free(self.heap);
        self.allocator.free(self.input);
        self.allocator.free(self.stack);

        self.* = undefined;
    }
};
