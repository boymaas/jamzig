const std = @import("std");
const Allocator = std.mem.Allocator;
const trace = @import("../tracing.zig").scoped(.pvm);

pub const Memory = struct {
    pub const Page = struct {
        data: []u8,
        address: u32,
        flags: Flags,

        const Size = Memory.Z_P;

        pub const Flags = enum {
            ReadOnly,
            ReadWrite,
        };

        pub fn init(allocator: Allocator, address: u32, flags: Flags) !Page {
            const data = try allocator.alloc(u8, Memory.Z_P);
            @memset(data, 0);
            return Page{
                .data = data,
                .address = address,
                .flags = flags,
            };
        }

        pub fn deinit(self: *Page, allocator: Allocator) void {
            allocator.free(self.data);
            self.* = undefined;
        }
    };

    pub const PageTable = struct {
        pages: std.ArrayList(Page),
        allocator: Allocator,

        pub fn init(allocator: Allocator) PageTable {
            return .{
                .pages = std.ArrayList(Page).init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *PageTable) void {
            for (self.pages.items) |*page| {
                page.deinit(self.allocator);
            }
            self.pages.deinit();
            self.* = undefined;
        }

        /// Allocates a contiguous range of pages starting at the given address
        pub fn allocatePages(self: *PageTable, start_address: u32, num_pages: usize, flags: Page.Flags) !void {
            const span = trace.span(.allocate_pages);
            defer span.deinit();
            span.debug("Allocating {d} {s} page(s) starting at 0x{X:0>8}", .{ num_pages, @tagName(flags), start_address });

            // Ensure address is page aligned
            if (start_address % Memory.Z_P != 0) {
                return error.UnalignedAddress;
            }

            // Check for overlapping pages
            for (self.pages.items) |page| {
                const new_end = start_address + (num_pages * Memory.Z_P);
                const page_end = page.address + Memory.Z_P;

                if ((start_address >= page.address and start_address < page_end) or
                    (new_end > page.address and new_end <= page_end))
                {
                    span.err("Page allocation would overlap existing pages", .{});
                    return error.PageOverlap;
                }
            }

            // Allocate new pages
            var i: usize = 0;
            while (i < num_pages) : (i += 1) {
                const page_addr: u32 = start_address + (@as(u32, @intCast(i)) * Memory.Z_P);
                const page = try Page.init(self.allocator, page_addr, flags);
                span.debug("Created page at 0x{X:0>8} with flags {s}", .{ page.address, @tagName(page.flags) });
                try self.pages.append(page);
            }

            // Sort pages by address
            std.sort.insertion(Page, self.pages.items, {}, struct {
                fn lessThan(_: void, a: Page, b: Page) bool {
                    return a.address < b.address;
                }
            }.lessThan);
        }

        /// Returns the index of the page containing the given address using binary search
        pub fn findPageIndex(self: *const PageTable, address: u32) ?usize {
            const page_addr = address & ~(@as(u32, Memory.Z_P) - 1);

            var left: usize = 0;
            var right: usize = self.pages.items.len;

            while (left < right) {
                const mid = left + (right - left) / 2;
                const page = self.pages.items[mid];

                if (page.address <= page_addr and page_addr < page.address + Page.Size) {
                    return mid;
                } else if (page.address < page_addr) {
                    left = mid + 1;
                } else {
                    right = mid;
                }
            }
            return null;
        }

        pub const PageResult = struct {
            page: *Page,
            index: usize,
            page_table: *PageTable,

            pub fn next(self: PageResult) ?PageResult {
                if (self.index + 1 >= self.page_table.pages.items.len) return null;
                return PageResult{
                    .page = &self.page_table.pages.items[self.index + 1],
                    .index = self.index + 1,
                    .page_table = self.page_table,
                };
            }

            pub fn nextContiguous(self: PageResult) ?PageResult {
                if (self.next()) |next_result| {
                    const expected_address = self.page.address + Page.Size;
                    if (next_result.page.address == expected_address) {
                        return next_result;
                    }
                }
                return null;
            }
        };

        pub fn findPage(self: *PageTable, address: u32) ?PageResult {
            if (self.findPageIndex(address)) |index| {
                return PageResult{
                    .page = &self.pages.items[index],
                    .index = index,
                    .page_table = self,
                };
            }
            return null;
        }
    };

    page_table: PageTable,
    last_violation: ?ViolationInfo,
    allocator: Allocator,

    // Memory layout constants
    pub const Z_Z: u32 = 0x10000; // 2^16 = 65,536 - Major zone size
    pub const Z_P: u32 = 0x1000; // 2^12 = 4,096 - Page size
    pub const Z_I: u32 = 0x1000000; // 2^24 - Standard input data size

    // Fixed section base addresses
    pub const READ_ONLY_BASE_ADDRESS: u32 = Z_Z;
    pub fn HEAP_BASE_ADDRESS(read_only_size: u32) !u32 {
        return 2 * Z_Z + try alignToSectionSize(read_only_size);
    }
    pub const INPUT_ADDRESS: u32 = 0xFFFFFFFF - Z_Z - Z_I;
    pub const STACK_BASE_ADDRESS: u32 = 0xFFFFFFFF - (2 * Z_Z) - Z_I;
    pub fn STACK_BOTTOM_ADDRESS(stack_size: anytype) u32 {
        return STACK_BASE_ADDRESS - @as(u32, @intCast(alignToPageSize(stack_size) catch 0));
    }

    pub const ViolationType = enum {
        WriteProtection,
        AccessViolation,
        NonAllocated,
    };

    pub const ViolationInfo = struct {
        violation_type: ViolationType,
        address: u32,
        attempted_size: usize,
        page: ?*Page = null,
    };

    pub const Error = error{
        PageFault,
        CrossPageWrite,
        CrossPageRead,
        OutOfMemory,
        CouldNotFindRwPage,
        MemoryLimitExceeded,
    };

    /// Aligns size to the next page boundary (Z_P = 4096)
    fn alignToPageSize(size: anytype) !@TypeOf(size) {
        return try std.math.divCeil(@TypeOf(size), size, Z_P) * Z_P;
    }

    /// Aligns size to the next section boundary (Z_Z = 65536)
    fn alignToSectionSize(size: anytype) !@TypeOf(size) {
        return try std.math.divCeil(@TypeOf(size), size, Z_Z) * Z_Z;
    }

    pub fn isMemoryError(err: anyerror) bool {
        return err == Error.PageFault;
    }

    fn checkMemoryLimits(ro_size: usize, heap_size: usize, stack_size: u32) !void {
        // Calculate sizes in terms of major zones (Z_Z)
        const ro_zones = try alignToSectionSize(ro_size);
        const heap_zones = try alignToSectionSize(heap_size);
        const stack_zones = try alignToSectionSize(stack_size);

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

    pub fn initEmpty(allocator: Allocator) !Memory {
        // Initialize page table
        var page_table = PageTable.init(allocator);
        errdefer page_table.deinit();

        return Memory{
            .page_table = page_table,
            .last_violation = null,
            .allocator = allocator,
        };
    }

    pub fn initWithCapacity(
        allocator: Allocator,
        read_only_size_in_pages: u32,
        heap_size_in_pages: u32,
        input_size_in_pages: u32,
        stack_size_in_bytes: u24,
    ) !Memory {
        const span = trace.span(.memory_init);
        defer span.deinit();
        span.debug("Starting memory initialization", .{});

        // Initialize page table
        var page_table = PageTable.init(allocator);
        errdefer page_table.deinit();

        // Calculate section sizes
        const ro_size = read_only_size_in_pages * Z_P;
        const heap_size = heap_size_in_pages * Z_P;
        // const input_size = input_size_in_pages * Z_P;
        const stack_size = try alignToPageSize(@as(u32, stack_size_in_bytes));

        // Verify memory limits
        try checkMemoryLimits(ro_size, heap_size, stack_size);

        // Allocate pages for each section
        try page_table.allocatePages(READ_ONLY_BASE_ADDRESS, read_only_size_in_pages, .ReadOnly);

        const heap_base = try HEAP_BASE_ADDRESS(@intCast(ro_size));
        try page_table.allocatePages(heap_base, heap_size_in_pages, .ReadWrite);

        try page_table.allocatePages(INPUT_ADDRESS, input_size_in_pages, .ReadOnly);

        const stack_pages = try std.math.divCeil(u32, stack_size, Z_P);
        try page_table.allocatePages(STACK_BOTTOM_ADDRESS(stack_size), stack_pages, .ReadWrite);

        return Memory{
            .page_table = page_table,
            .last_violation = null,
            .allocator = allocator,
        };
    }

    pub fn initWithData(
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
        const ro_pages = try alignToPageSize(read_only.len) / Z_P;
        const heap_pages = (heap_size_in_pages * Z_P + try alignToPageSize(read_write.len)) / Z_P;
        const input_pages = try alignToPageSize(input.len) / Z_P;

        var memory = Memory.initWithCapacity(
            allocator,
            ro_pages,
            heap_pages,
            input_pages,
            stack_size_in_bytes,
        );

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

    /// Allocate a single page at a specific address
    pub fn allocatePageAt(self: *Memory, address: u32, flags: Page.Flags) !void {
        return self.allocatePagesAt(address, 1, flags);
    }

    /// Allocate multiple contiguous pages starting at a specific address
    /// Address must be page aligned
    pub fn allocatePagesAt(self: *Memory, address: u32, num_pages: usize, flags: Page.Flags) !void {
        const span = trace.span(.memory_allocate_pages_at);
        defer span.deinit();

        // Ensure address is page aligned
        if (address % Z_P != 0) {
            return error.UnalignedAddress;
        }

        // Allocate the new pages
        try self.page_table.allocatePages(address, num_pages, flags);
    }

    pub fn allocate(self: *Memory, size: u32) !u32 {
        const span = trace.span(.memory_allocate);
        defer span.deinit();

        // TODO: > HEAP_BASE_ADDRESS

        // Calculate required pages, rounding up to nearest page size
        const aligned_size = try alignToPageSize(size);
        const pages_needed = aligned_size / Z_P;

        // Find the last ReadWrite page (heap section)
        var last_rw_page: ?PageTable.PageResult = null;
        for (self.page_table.pages.items, 0..) |*page, i| {
            if (page.flags == .ReadWrite) {
                last_rw_page = PageTable.PageResult{
                    .page = page,
                    .index = i,
                    .page_table = &self.page_table,
                };
            }
        }

        const last_page = last_rw_page orelse {
            return Error.CouldNotFindRwPage;
        };

        // Calculate new allocation address (immediately after last ReadWrite page)
        const new_address = last_page.page.address + Z_P;

        // Allocate the new pages
        try self.page_table.allocatePages(new_address, pages_needed, .ReadWrite);
        return new_address;
    }

    /// Read an integer type from memory (u8, u16, u32, u64)
    /// Read any integer type and convert it to u64, handling sign extension for signed types
    pub fn readIntAndSignExtend(self: *Memory, comptime T: type, address: u32) !u64 {
        const value = try self.readInt(T, address);
        return switch (@typeInfo(T)) {
            .int => |info| switch (info.signedness) {
                .signed => @bitCast(@as(i64, @intCast(value))),
                .unsigned => value,
            },
            else => @compileError("Only integer types are supported"),
        };
    }

    /// Read an integer type from memory (u8, u16, u32, u64)
    pub fn readInt(self: *Memory, comptime T: type, address: u32) !T {
        const span = trace.span(.memory_read);
        defer span.deinit();

        const size = @sizeOf(T);
        comptime std.debug.assert(size <= 8); // Only handle up to u64

        // Get first page and offset
        const first_page = self.page_table.findPage(address) orelse {
            self.last_violation = ViolationInfo{
                .violation_type = .NonAllocated,
                .address = address,
                .attempted_size = @sizeOf(T),
                .page = null,
            };
            return Error.PageFault;
        };
        const offset = address - first_page.page.address;
        const bytes_in_first = Memory.Z_P - offset;

        // If it fits in first page, read directly
        if (size <= bytes_in_first) {
            return @as(T, @bitCast(first_page.page.data[offset..][0..size].*));
        }

        // Cross-page read - use stack buffer
        var buf: [@sizeOf(T)]u8 = undefined;

        // Copy from first page
        @memcpy(buf[0..bytes_in_first], first_page.page.data[offset..][0..bytes_in_first]);

        // Get and copy from second page, this should aways have enough
        const next_page = first_page.nextContiguous() orelse {
            self.last_violation = ViolationInfo{
                .violation_type = .NonAllocated,
                .address = first_page.page.address + Memory.Z_P, // Address where next page should be
                .attempted_size = size,
                .page = first_page.page,
            };
            return error.PageFault;
        };
        const bytes_in_second = size - bytes_in_first;
        @memcpy(buf[bytes_in_first..size], next_page.page.data[0..bytes_in_second]);

        return std.mem.readInt(T, &buf, .little);
    }

    /// Read a slice from memory, not allowing cross-page reads
    pub fn readSlice(self: *Memory, address: u32, size: usize) ![]const u8 {
        const span = trace.span(.memory_read);
        defer span.deinit();

        // Find the page containing the address
        const page = self.page_table.findPage(address) orelse {
            self.last_violation = ViolationInfo{
                .violation_type = .NonAllocated,
                .address = address,
                .attempted_size = size,
                .page = null,
            };
            return Error.PageFault;
        };

        // Check if read would cross page boundary
        const offset = address - page.page.address;
        if (offset + size > Z_P) {
            return Error.CrossPageRead;
        }

        // Return slice of page data
        return page.page.data[offset..][0..size];
    }

    /// Initilialize a slice to memory not cross-page, will err on cross page
    /// access. Does not check ReadWrite permissions can also write to ReadOnly
    /// segments.
    pub fn initMemory(self: *Memory, address: u32, slice: []const u8) !void {
        const span = trace.span(.memory_write);
        defer span.deinit();

        // Find the page containing the address
        const page = self.page_table.findPage(address) orelse {
            self.last_violation = ViolationInfo{
                .violation_type = .NonAllocated,
                .address = address,
                .attempted_size = slice.len,
                .page = null,
            };
            return Error.PageFault;
        };

        // Check if write would cross page boundary
        const offset = address - page.page.address;
        if (offset + slice.len > Z_P) {
            return Error.CrossPageWrite;
        }

        // Perform the write
        @memcpy(page.page.data[offset..][0..slice.len], slice);
    }

    /// Write an integer type to memory (u8, u16, u32, u64)
    pub fn writeInt(self: *Memory, T: type, address: u32, value: T) !void {
        const span = trace.span(.memory_write);
        defer span.deinit();

        const size = @sizeOf(T);
        comptime std.debug.assert(size <= 8); // Only handle up to u64
        comptime std.debug.assert(@typeInfo(T) == .int);

        // First verify all required pages exist
        const page = self.page_table.findPage(address) orelse {
            self.last_violation = ViolationInfo{
                .violation_type = .NonAllocated,
                .address = address,
                .attempted_size = size,
                .page = null,
            };
            return Error.PageFault;
        };

        const next_contiguous = if (size > (page.page.address + Z_P) - address)
            page.nextContiguous() orelse {
                self.last_violation = ViolationInfo{
                    .violation_type = .NonAllocated,
                    .address = page.page.address + Z_P,
                    .attempted_size = size,
                    .page = null,
                };
                return Error.PageFault;
            }
        else
            null;

        // TODO: Check if both pages are ReadWrite

        // Now perform the actual write, knowing all pages exist
        var bytes: [size]u8 = undefined;
        std.mem.writeInt(T, &bytes, value, .little);

        // Write to first page
        const offset = address - page.page.address;
        const bytes_in_first = Z_P - offset;
        const first_write_size = @min(size, bytes_in_first);
        @memcpy(page.page.data[offset..][0..first_write_size], bytes[0..first_write_size]);

        // Write to second page if needed
        if (next_contiguous) |_| {
            const bytes_in_second = size - bytes_in_first;
            @memcpy(next_contiguous.?.page.data[0..bytes_in_second], bytes[bytes_in_first..size]);
        }
    }

    // Helper methods for common types
    pub fn readU8(self: *Memory, address: u32) !u8 {
        return self.readInt(address, u8);
    }

    pub fn readU16(self: *Memory, address: u32) !u16 {
        return self.readInt(address, u16);
    }

    pub fn readU32(self: *Memory, address: u32) !u32 {
        return self.readInt(address, u32);
    }

    pub fn readU64(self: *Memory, address: u32) !u64 {
        return self.readInt(address, u64);
    }

    pub fn writeU8(self: *Memory, address: u32, value: u8) !void {
        return self.writeInt(address, value);
    }

    pub fn writeU16(self: *Memory, address: u32, value: u16) !void {
        return self.writeInt(address, value);
    }

    pub fn writeU32(self: *Memory, address: u32, value: u32) !void {
        return self.writeInt(address, value);
    }

    pub fn writeU64(self: *Memory, address: u32, value: u64) !void {
        return self.writeInt(address, value);
    }

    pub fn deinit(self: *Memory) void {
        const span = trace.span(.memory_deinit);
        defer span.deinit();

        self.page_table.deinit();
        self.* = undefined;
    }

    pub fn getLastViolation(self: *const Memory) ?ViolationInfo {
        return self.last_violation;
    }
};
