const std = @import("std");
const Allocator = std.mem.Allocator;

const shared = @import("shared.zig");
const types = @import("types.zig");

const trace = @import("tracing").scoped(.pvm);

pub const alignToSectionSize = shared.alignToSectionSize;
pub const ViolationInfo = types.ViolationInfo;
pub const ViolationType = types.ViolationType;
pub const PageFlags = types.PageFlags;
pub const MemoryAccessResult = types.MemoryAccessResult;

pub const FlatMemory = struct {
    allocator: Allocator,

    read_only_base: u32,
    read_only_size: u32,
    read_only_data: []u8,

    stack_base: u32,
    stack_bottom: u32,
    stack_size: u32,
    stack_data: []u8,

    input_base: u32,
    input_size_in_bytes: u32,
    input_data: []u8,

    heap_base: u32,
    heap_top: u32,
    heap_data: []u8,

    read_only_size_in_pages: u32,
    stack_size_in_pages: u32,
    heap_size_in_pages: u32,
    dynamic_allocation_enabled: bool,
    heap_allocation_limit: ?u32 = null,

    last_violation: ?ViolationInfo,

    pub const Z_P = shared.Z_P;
    pub const Z_Z = shared.Z_Z;
    pub const Z_I = shared.Z_I;
    pub const READ_ONLY_BASE_ADDRESS = shared.READ_ONLY_BASE_ADDRESS;
    pub const INPUT_ADDRESS = shared.INPUT_ADDRESS;
    pub const STACK_BASE_ADDRESS = shared.STACK_BASE_ADDRESS;
    pub const HEAP_BASE_ADDRESS = shared.HEAP_BASE_ADDRESS;
    pub const STACK_BOTTOM_ADDRESS = shared.STACK_BOTTOM_ADDRESS;

    pub const MemorySlice = types.MemorySlice;

    pub const Error = error{
        PageFault,
        OutOfMemory,
        CouldNotFindRwPage,
        MemoryLimitExceeded,
    };

    pub fn initWithData(
        allocator: Allocator,
        read_only: []const u8,
        read_write: []const u8,
        input: []const u8,
        stack_size_in_bytes: u24,
        heap_size_in_pages: u32,
        dynamic_allocation: bool,
    ) !FlatMemory {
        const span = trace.span(@src(), .memory_init);
        defer span.deinit();

        const stack_size_in_pages = try shared.sizeInBytesToPages(stack_size_in_bytes);

        var memory = try init(
            allocator,
            read_only.len,
            read_write.len,
            @intCast(heap_size_in_pages),
            stack_size_in_pages,
            input,
            dynamic_allocation,
        );

        if (read_only.len > 0) {
            @memcpy(memory.read_only_data[0..read_only.len], read_only);
        }

        if (read_write.len > 0) {
            @memcpy(memory.heap_data[0..read_write.len], read_write);
        }

        return memory;
    }

    pub fn init(
        allocator: Allocator,
        read_only_size_in_bytes: usize,
        read_write_size_in_bytes: usize,
        heap_size_in_pages: u32,
        stack_size_in_pages: u32,
        input_data_bytes: []const u8,
        dynamic_allocation_enabled: bool,
    ) !FlatMemory {
        const span = trace.span(@src(), .init);
        defer span.deinit();

        const heap_initial_size = try shared.alignToPageSize(read_write_size_in_bytes) + (heap_size_in_pages * Z_P);
        const stack_size = stack_size_in_pages * Z_P;

        const read_only_data: []u8 = if (read_only_size_in_bytes > 0) blk: {
            const data = try allocator.alloc(u8, read_only_size_in_bytes);
            @memset(data, 0);
            break :blk data;
        } else &[_]u8{};

        const stack_data: []u8 = if (stack_size > 0) blk: {
            const data = try allocator.alloc(u8, stack_size);
            @memset(data, 0);
            break :blk data;
        } else &[_]u8{};

        // 4x capacity growth factor balances memory usage vs reallocation frequency
        const heap_base = try HEAP_BASE_ADDRESS(read_only_size_in_bytes);
        const stack_bottom = try STACK_BOTTOM_ADDRESS(stack_size_in_pages);

        const max_heap_space = stack_bottom - heap_base;
        _ = max_heap_space;

        const heap_data = try allocator.alloc(u8, heap_initial_size);
        @memset(heap_data, 0);

        const input_data = try allocator.dupe(u8, input_data_bytes);

        const read_only_base = READ_ONLY_BASE_ADDRESS;
        const input_base = INPUT_ADDRESS;
        const stack_base = STACK_BASE_ADDRESS;

        span.debug("Memory layout initialized:", .{});
        span.debug("  Read-only: 0x{X:0>8} - 0x{X:0>8} ({d} bytes)", .{ read_only_base, read_only_base + @as(u32, @intCast(read_only_size_in_bytes)), read_only_size_in_bytes });
        span.debug("  Heap: 0x{X:0>8} - 0x{X:0>8}", .{ heap_base, heap_base + heap_initial_size });
        span.debug("  Stack: 0x{X:0>8} - 0x{X:0>8} ({d} bytes)", .{ stack_bottom, stack_base, stack_size });
        span.debug("  Input: 0x{X:0>8} - 0x{X:0>8} ({d} bytes)", .{ input_base, input_base + @as(u32, @intCast(input_data_bytes.len)), input_data_bytes.len });

        return FlatMemory{
            .allocator = allocator,
            .read_only_base = read_only_base,
            .read_only_size = @intCast(read_only_size_in_bytes),
            .read_only_data = read_only_data,
            .stack_base = stack_base,
            .stack_bottom = stack_bottom,
            .stack_size = stack_size,
            .stack_data = stack_data,
            .input_base = input_base,
            .input_size_in_bytes = @intCast(input_data_bytes.len),
            .input_data = input_data,
            .heap_base = heap_base,
            .heap_top = heap_base + heap_initial_size,
            .heap_data = heap_data,
            .read_only_size_in_pages = try shared.sizeInBytesToPages(read_only_size_in_bytes),
            .stack_size_in_pages = stack_size_in_pages,
            .heap_size_in_pages = heap_size_in_pages,
            .dynamic_allocation_enabled = dynamic_allocation_enabled,
            .last_violation = null,
        };
    }

    pub fn deinit(self: *FlatMemory) void {
        self.allocator.free(self.read_only_data);
        self.allocator.free(self.stack_data);
        self.allocator.free(self.heap_data);
        self.allocator.free(self.input_data);
        self.* = undefined;
    }

    inline fn getMemoryPtr(self: *FlatMemory, address: u32, size: usize, check_write: bool) MemoryAccessResult {
        if (address >= self.stack_bottom and address < self.stack_base) {
            if (address +| size <= self.stack_base) {
                const offset = address - self.stack_bottom;
                return .{ .success = self.stack_data.ptr + offset };
            }
        }

        // CRITICAL: Use heap_data.len, NOT heap_top for bounds checking
        //
        // Graypaper defines ram_access as sequence[2^32/4096] - PAGE-INDEXED permissions (overview.tex:176)
        // This makes byte-granular permissions impossible; only full pages can be marked W/R/⊥
        //
        // When sbrk(n) marks range [x, x+n) writable per spec (pvm.tex:441):
        // → Must set ram_access[page] = W for all pages overlapping [x, x+n)
        // → ENTIRE pages become writable, including bytes beyond n
        //
        // Example: sbrk(500) allocates page [0x33000, 0x34000)
        //   heap_top = 0x33000 + 500 = 0x331f4 (cursor for next sbrk)
        //   heap_data.len = 4096 (entire page allocated)
        //   Bytes [0x331f4, 0x34000) are WRITABLE per graypaper (same page)
        //   Programs can legally read/write this "gap" - it's not a bug!
        //
        // Therefore heap_data.len represents all pages with ram_access=W (graypaper-compliant)
        // while heap_top is just an optimization cursor (not a permission boundary).
        const heap_limit = self.heap_base + @as(u32, @intCast(self.heap_data.len));
        if (address >= self.heap_base and address < heap_limit) {
            const end_addr = address +| size;
            if (end_addr <= heap_limit and end_addr >= address) {
                const offset = address - self.heap_base;
                return .{ .success = self.heap_data.ptr + offset };
            }
        }

        const ro_end = self.read_only_base + self.read_only_size;
        if (address >= self.read_only_base and address < ro_end) {
            if (address +| size <= ro_end) {
                if (check_write) {
                    const violation = ViolationInfo{
                        .violation_type = .WriteProtection,
                        .address = address & ~(Z_P - 1),
                        .attempted_size = size,
                    };
                    self.last_violation = violation;
                    return .{ .violation = violation };
                }

                const offset = address - self.read_only_base;
                return .{ .success = self.read_only_data.ptr + offset };
            }
        }

        const input_end = self.input_base + self.input_size_in_bytes;
        if (address >= self.input_base and address < input_end) {
            if (address +| size <= input_end) {
                if (check_write) {
                    const violation = ViolationInfo{
                        .violation_type = .WriteProtection,
                        .address = address & ~(Z_P - 1),
                        .attempted_size = size,
                    };
                    self.last_violation = violation;
                    return .{ .violation = violation };
                }

                const offset = address - self.input_base;
                return .{ .success = self.input_data.ptr + offset };
            }
        }

        const violation = ViolationInfo{
            .violation_type = .NonAllocated,
            .address = (address +| @as(u32, @intCast(size))) & ~(Z_P - 1),
            .attempted_size = size,
        };

        self.last_violation = violation;

        return .{ .violation = violation };
    }

    /// Read integer - optimized with direct pointer access
    pub fn readInt(self: *FlatMemory, comptime T: type, address: u32) !T {
        const span = trace.span(@src(), .memory_read);
        defer span.deinit();

        const size = @sizeOf(T);
        comptime std.debug.assert(size <= 8);

        switch (self.getMemoryPtr(address, size, false)) {
            .success => |ptr| {
                const bytes = @as(*const [size]u8, @ptrCast(ptr));
                const result = std.mem.readInt(T, bytes, .little);
                span.debug("Read {d}-bit value 0x{X} from address 0x{X:0>8}", .{ @bitSizeOf(T), result, address });
                return result;
            },
            .violation => |_| {
                span.err("Memory violation reading from 0x{X:0>8}", .{address});
                return Error.PageFault;
            },
        }
    }

    /// Write integer - optimized with direct pointer access
    pub fn writeInt(self: *FlatMemory, comptime T: type, address: u32, value: T) !void {
        const span = trace.span(@src(), .memory_write);
        defer span.deinit();
        span.debug("Writing {d}-bit value 0x{X} to address 0x{X:0>8}", .{ @bitSizeOf(T), value, address });

        const size = @sizeOf(T);
        comptime std.debug.assert(size <= 8);
        comptime std.debug.assert(@typeInfo(T) == .int);

        switch (self.getMemoryPtr(address, size, true)) {
            .success => |ptr| {
                const bytes = @as(*[size]u8, @ptrCast(ptr));
                std.mem.writeInt(T, bytes, value, .little);
            },
            .violation => |_| {
                span.err("Memory violation writing to 0x{X:0>8}", .{address});
                return Error.PageFault;
            },
        }
    }

    /// Sign extension helper
    pub fn readIntAndSignExtend(self: *FlatMemory, comptime T: type, address: u32) !u64 {
        const value = try self.readInt(T, address);
        return switch (@typeInfo(T)) {
            .int => |info| switch (info.signedness) {
                .signed => @bitCast(@as(i64, @intCast(value))),
                .unsigned => value,
            },
            else => @compileError("Only integer types are supported"),
        };
    }

    /// Read byte
    pub fn readByte(self: *FlatMemory, address: u32) !u8 {
        return self.readInt(u8, address);
    }

    /// Write byte
    pub fn writeByte(self: *FlatMemory, address: u32, value: u8) !void {
        return self.writeInt(u8, address, value);
    }

    /// Read slice
    pub fn readSlice(self: *FlatMemory, address: u32, size: usize) !MemorySlice {
        const span = trace.span(@src(), .memory_read_slice);
        defer span.deinit();
        span.debug("Reading slice of {d} bytes from address 0x{X:0>8}", .{ size, address });

        if (size == 0) {
            return .{ .buffer = &[_]u8{}, .allocator = null };
        }

        switch (self.getMemoryPtr(address, size, false)) {
            .success => |ptr| {
                return .{ .buffer = ptr[0..size], .allocator = null };
            },
            .violation => |_| {
                span.err("Memory violation reading slice from 0x{X:0>8}", .{address});
                return Error.PageFault;
            },
        }
    }

    pub fn readSliceOwned(self: *FlatMemory, address: u32, size: usize) ![]const u8 {
        const slice = try self.readSlice(address, size);
        if (slice.allocator) |_| {
            return slice.buffer;
        } else {
            return self.allocator.dupe(u8, slice.buffer);
        }
    }

    /// Reads a hash from memory
    pub fn readHash(self: *FlatMemory, address: u32) ![32]u8 {
        var hash_slice = try self.readSlice(address, 32);
        defer hash_slice.deinit();
        return hash_slice.buffer[0..32].*;
    }

    /// Write slice
    pub fn writeSlice(self: *FlatMemory, address: u32, data: []const u8) !void {
        const span = trace.span(@src(), .memory_write_slice);
        defer span.deinit();
        span.debug("Writing slice of {d} bytes to address 0x{X:0>8}", .{ data.len, address });

        if (data.len == 0) return;

        switch (self.getMemoryPtr(address, data.len, true)) {
            .success => |ptr| {
                @memcpy(ptr[0..data.len], data);
            },
            .violation => |_| {
                span.err("Memory violation writing slice to 0x{X:0>8}", .{address});
                return Error.PageFault;
            },
        }
    }

    // Bypasses write permission checks - used only during initialization
    pub fn initMemory(self: *FlatMemory, address: u32, data: []const u8) !void {
        const span = trace.span(@src(), .memory_init);
        defer span.deinit();
        span.debug("Initializing memory at 0x{X:0>8} with {d} bytes", .{ address, data.len });

        switch (self.getMemoryPtr(address, data.len, false)) {
            .success => |ptr| {
                @memcpy(ptr[0..data.len], data);
            },
            .violation => |_| {
                span.err("Failed to initialize memory at 0x{X:0>8}", .{address});
                return Error.PageFault;
            },
        }
    }

    /// Optimized sbrk - O(1) with boundary checks and page-aligned allocation
    pub fn sbrk(self: *FlatMemory, size: u32) !u32 {
        const span = trace.span(@src(), .sbrk);
        defer span.deinit();
        span.debug("sbrk called with size={d} bytes", .{size});

        const old_top = self.heap_top;

        if (size == 0) {
            span.debug("Zero-size sbrk, returning current heap pointer: 0x{X:0>8}", .{old_top});
            return old_top;
        }

        const new_top = brk: {
            const r = @addWithOverflow(old_top, size);

            if (r[1] == 1) {
                span.err("Arithmetic overflow detected: 0x{X:0>8} + {d} overflows", .{ old_top, size });
                return 0;
            }
            break :brk r[0];
        };

        if (new_top >= self.stack_bottom) {
            span.err("Stack collision: new heap top 0x{X:0>8} >= stack bottom 0x{X:0>8}", .{ new_top, self.stack_bottom });
            return 0;
        }

        const current_heap_size = self.heap_top - self.heap_base;
        const new_heap_size = new_top - self.heap_base;

        const current_capacity_pages = try shared.sizeInBytesToPages(current_heap_size);
        const required_capacity_pages = try shared.sizeInBytesToPages(new_heap_size);

        if (required_capacity_pages > current_capacity_pages) {
            const new_capacity_bytes = required_capacity_pages * Z_P;
            span.debug("Growing heap from {d} pages to {d} pages ({d} to {d} bytes)", .{ current_capacity_pages, required_capacity_pages, self.heap_data.len, new_capacity_bytes });

            self.heap_data = self.allocator.realloc(self.heap_data, new_capacity_bytes) catch |err| {
                span.err("Failed to reallocate heap: {}", .{err});
                return 0;
            };

            @memset(self.heap_data[current_heap_size..new_capacity_bytes], 0);
        }

        self.heap_top = new_top;
        span.debug("sbrk successful, returning previous heap pointer: 0x{X:0>8}, new heap top: 0x{X:0>8}", .{ old_top, new_top });
        return old_top;
    }

    /// Check if memory range is valid
    pub fn isRangeValid(self: *const FlatMemory, addr: u32, size: u32) bool {
        if (size == 0) return false;

        return switch (self.getMemoryPtr(addr, size, false)) {
            .success => true,
            .violation => false,
        };
    }

    /// Get heap start
    pub fn getHeapStart(self: *const FlatMemory) u32 {
        return self.heap_base;
    }

    /// Get last memory violation info (for PVM error handling)
    pub fn getLastViolation(self: *const FlatMemory) ?ViolationInfo {
        return self.last_violation;
    }

    /// Deep clone (for forking)
    pub fn deepClone(self: *const FlatMemory, allocator: Allocator) !FlatMemory {
        const span = trace.span(@src(), .memory_deep_clone);
        defer span.deinit();

        const read_only_data = if (self.read_only_data.len > 0)
            try allocator.dupe(u8, self.read_only_data)
        else
            try allocator.alloc(u8, 0);

        const stack_data = if (self.stack_data.len > 0)
            try allocator.dupe(u8, self.stack_data)
        else
            try allocator.alloc(u8, 0);

        const heap_data = try allocator.dupe(u8, self.heap_data);
        const input_data = try allocator.dupe(u8, self.input_data);

        return FlatMemory{
            .allocator = allocator,
            .read_only_base = self.read_only_base,
            .read_only_size = self.read_only_size,
            .read_only_data = read_only_data,
            .stack_base = self.stack_base,
            .stack_bottom = self.stack_bottom,
            .stack_size = self.stack_size,
            .stack_data = stack_data,
            .input_base = self.input_base,
            .input_size_in_bytes = self.input_size_in_bytes,
            .input_data = input_data,
            .heap_base = self.heap_base,
            .heap_top = self.heap_top,
            .heap_data = heap_data,
            .last_violation = self.last_violation,
            .read_only_size_in_pages = self.read_only_size_in_pages,
            .stack_size_in_pages = self.stack_size_in_pages,
            .heap_size_in_pages = self.heap_size_in_pages,
            .heap_allocation_limit = self.heap_allocation_limit,
            .dynamic_allocation_enabled = self.dynamic_allocation_enabled,
        };
    }

    // Test API functions - cleaner interface for test setup and validation

    pub fn initEmpty(allocator: Allocator, dynamic: bool) !FlatMemory {
        return init(allocator, 0, 0, 0, 0, &[_]u8{}, dynamic);
    }

    pub fn allocatePageAt(self: *FlatMemory, address: u32, writable: bool) !void {
        return self.allocatePagesAt(address, Z_P, writable);
    }

    pub fn allocatePagesAt(self: *FlatMemory, address: u32, size: u32, writable: bool) !void {
        const span = trace.span(@src(), .allocate_test_region);
        defer span.deinit();
        _ = writable;

        const aligned_size = try shared.alignToPageSize(size);
        span.trace("Allocating test region at 0x{X:0>8} of size {d} bytes (aligned to {d} bytes)\n", .{ address, size, aligned_size });

        if (address == self.read_only_base) {
            span.trace("Allocating {d} read only pages", .{aligned_size / Z_P});
            const new_data = try self.allocator.realloc(self.read_only_data, aligned_size);
            @memset(new_data, 0);
            self.read_only_data = new_data;
            self.read_only_size = @intCast(new_data.len);
        } else if (address >= self.heap_base) {
            const pages = ((address +| aligned_size) - self.heap_base) / Z_P;
            span.trace("Allocating {d} heap pages", .{pages});
            if (pages > 32) {
                std.debug.panic("allocateTestRegion: too many pages requested to reach address 0x{X:0>8} (max 32 pages)\n", .{address});
            }
            const new_heap_data = try self.allocator.realloc(self.heap_data, pages * Z_P);
            @memset(new_heap_data, 0);
            self.heap_data = new_heap_data;
            self.heap_top = self.heap_base + @as(u32, @intCast(new_heap_data.len));
        } else {
            std.debug.panic("allocateTestRegion: address 0x{X:0>8} not supported (expected heap at 0x{X:0>8})\n", .{ address, self.heap_base });
        }
    }

    /// Set heap allocation limit for fuzzing
    pub fn setHeapAllocationLimit(self: *FlatMemory, limit: u32) void {
        self.heap_allocation_limit = limit;
    }

    /// Returns a snapshot of memory organized as individual pages.
    ///
    /// Invariants:
    /// - Each returned region represents exactly one page (Z_P = 4KB) of memory
    /// - Regions are non-overlapping and ordered by address
    /// - Empty/unallocated pages are not included
    /// - The caller owns the returned memory and must free both the slice and each region's data
    /// - Compatible with both PageTableMemory and FlatMemory implementations
    /// - Maintains the same semantics as PageTableMemory.getMemorySnapshot for cross-checking
    pub fn getMemorySnapshot(self: *FlatMemory) !MemorySnapShot {
        var regions = std.ArrayList(MemoryRegion).init(self.allocator);
        errdefer {
            for (regions.items) |region| {
                self.allocator.free(region.data);
            }
            regions.deinit();
        }

        const addPagesForSection = struct {
            fn add(
                region_list: *std.ArrayList(MemoryRegion),
                alloc: Allocator,
                section_data: []const u8,
                section_base: u32,
                writable: bool,
            ) !void {
                if (section_data.len == 0) return;

                const num_pages = (section_data.len + Z_P - 1) / Z_P;
                var page_idx: u32 = 0;

                while (page_idx < num_pages) : (page_idx += 1) {
                    const page_offset = page_idx * Z_P;
                    const page_address = section_base + page_offset;
                    const remaining_bytes = section_data.len - page_offset;
                    const page_size = @min(Z_P, remaining_bytes);

                    const page_data = try alloc.dupe(u8, section_data[page_offset .. page_offset + page_size]);

                    try region_list.append(.{
                        .address = page_address,
                        .data = page_data,
                        .writable = writable,
                    });
                }
            }
        }.add;

        // Add pages for read-only region
        try addPagesForSection(&regions, self.allocator, self.read_only_data, self.read_only_base, false);

        // Add pages for heap region
        try addPagesForSection(&regions, self.allocator, self.heap_data, self.heap_base, true);

        // Add pages for stack region
        try addPagesForSection(&regions, self.allocator, self.stack_data, self.stack_bottom, true);

        // Add pages for input region
        try addPagesForSection(&regions, self.allocator, self.input_data, self.input_base, false);

        return .{ .regions = try regions.toOwnedSlice() };
    }

    /// Memory region for testing and comparison
    pub const MemoryRegion = types.MemoryRegion;
    pub const MemorySnapShot = types.MemorySnapShot;
};
