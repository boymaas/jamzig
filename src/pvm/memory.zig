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

            // Sanity check
            if (num_pages == 0) {
                span.debug("Nothing to allocate (0 pages requested)", .{});
                return;
            }

            // Calculate end address
            const new_end = start_address + (num_pages * Memory.Z_P);
            span.trace("Pages will span from 0x{X:0>8} to 0x{X:0>8}", .{ start_address, new_end });

            // Check for overlapping pages
            const overlap_span = span.child(.check_overlap);
            defer overlap_span.deinit();
            overlap_span.debug("Checking for page overlaps with {d} existing pages", .{self.pages.items.len});

            for (self.pages.items, 0..) |page, i| {
                const page_end = page.address + Memory.Z_P;
                overlap_span.trace("Checking page {d}: 0x{X:0>8} - 0x{X:0>8}", .{ i, page.address, page_end });

                if ((start_address >= page.address and start_address < page_end) or
                    (new_end > page.address and new_end <= page_end))
                {
                    overlap_span.err("Overlap detected with page at 0x{X:0>8}", .{page.address});
                    return error.PageOverlap;
                }
            }
            overlap_span.debug("No overlapping pages found", .{});

            // Allocate new pages
            const alloc_span = span.child(.create_pages);
            defer alloc_span.deinit();
            alloc_span.debug("Creating {d} new page(s)", .{num_pages});

            var i: usize = 0;
            while (i < num_pages) : (i += 1) {
                const page_addr: u32 = start_address + (@as(u32, @intCast(i)) * Memory.Z_P);
                alloc_span.trace("Creating page {d}/{d} at 0x{X:0>8}", .{ i + 1, num_pages, page_addr });

                const page = try Page.init(self.allocator, page_addr, flags);
                try self.pages.append(page);
                alloc_span.debug("Created page at 0x{X:0>8} with flags {s}", .{ page.address, @tagName(page.flags) });
            }

            // Sort pages by address
            const sort_span = span.child(.sort_pages);
            defer sort_span.deinit();
            sort_span.debug("Sorting {d} pages by address", .{self.pages.items.len});

            std.sort.insertion(Page, self.pages.items, {}, struct {
                fn lessThan(_: void, a: Page, b: Page) bool {
                    return a.address < b.address;
                }
            }.lessThan);

            sort_span.debug("Pages sorted successfully", .{});
            span.debug("Page allocation complete", .{});
        }

        /// Returns the index of the page containing the given address using binary search
        pub fn findPageIndexOfAddress(self: *const PageTable, address: u32) ?usize {
            const span = trace.span(.find_page_index);
            defer span.deinit();
            span.debug("Searching for page containing address 0x{X:0>8}", .{address});

            if (self.pages.items.len == 0) {
                span.debug("Page table is empty", .{});
                return null;
            }

            var left: usize = 0;
            var right: usize = self.pages.items.len;

            span.trace("Binary search in {d} pages", .{self.pages.items.len});

            while (left < right) {
                const mid = left + (right - left) / 2;
                const page = self.pages.items[mid];

                span.trace("Checking page at index {d}: address=0x{X:0>8}, end=0x{X:0>8}", .{ mid, page.address, page.address + Page.Size });

                if (page.address <= address and address < page.address + Page.Size) {
                    span.debug("Found page at index {d} (0x{X:0>8})", .{ mid, page.address });
                    return mid;
                } else if (page.address < address) {
                    span.trace("Address is higher, moving left bound to {d}", .{mid + 1});
                    left = mid + 1;
                } else {
                    span.trace("Address is lower, moving right bound to {d}", .{mid});
                    right = mid;
                }
            }

            span.debug("No matching page found for address 0x{X:0>8}", .{address});
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

        pub fn findPageOfAddresss(self: *PageTable, address: u32) ?PageResult {
            if (self.findPageIndexOfAddress(address)) |index| {
                return PageResult{
                    .page = &self.pages.items[index],
                    .index = index,
                    .page_table = self,
                };
            }
            return null;
        }

        const OrdPages = struct {
            fn order(ctx: *const Page, item: *const Page) std.math.Order {
                return std.math.order(ctx.address, item.address);
            }
        }.order;
    };

    page_table: PageTable,
    last_violation: ?ViolationInfo,
    allocator: Allocator,
    input_size_in_bytes: u32,
    read_only_size_in_pages: u16,
    stack_size_in_pages: u16,
    heap_size_in_pages: u16,

    // Artificial limit on how many allocations we allow
    // mainly for the fuzzer, this is not in the spec
    heap_allocation_limit: ?u16 = null,

    // Memory layout constants
    pub const Z_Z: u32 = 0x10000; // 2^16 = 65,536 - Major zone size
    pub const Z_P: u32 = 0x1000; // 2^12 = 4,096 - Page size
    pub const Z_I: u32 = 0x1000000; // 2^24 - Standard input data size

    // Fixed section base addresses
    pub const READ_ONLY_BASE_ADDRESS: u32 = Z_Z;
    pub fn HEAP_BASE_ADDRESS(read_only_size_in_bytes: usize) !u32 {
        return 2 * Z_Z + @as(u32, @intCast(try alignToSectionSize(read_only_size_in_bytes)));
    }
    pub const INPUT_ADDRESS: u32 = 0xFFFFFFFF - Z_Z - Z_I;
    pub const STACK_BASE_ADDRESS: u32 = 0xFFFFFFFF - (2 * Z_Z) - Z_I;
    pub fn STACK_BOTTOM_ADDRESS(stack_size_in_pages: u16) !u32 {
        return STACK_BASE_ADDRESS - @as(u32, @intCast(try alignToPageSize(stack_size_in_pages)));
    }

    pub const ViolationType = enum {
        WriteProtection,
        AccessViolation,
        NonAllocated,
    };

    pub const ViolationInfo = struct {
        violation_type: ViolationType,
        address: u32, // aligned to page
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
    fn alignToPageSize(size_in_bytes: usize) !u32 {
        const span = trace.span(.align_to_page);
        defer span.deinit();
        span.trace("Aligning {d} bytes to page boundary (Z_P={d})", .{ size_in_bytes, Z_P });

        const pages = try sizeInBytesToPages(size_in_bytes);
        const aligned_size = pages * Z_P;
        span.trace("Result: {d} bytes ({d} pages)", .{ aligned_size, pages });
        return aligned_size;
    }

    /// Does a bytes to pages
    fn sizeInBytesToPages(size: usize) !u16 {
        const span = trace.span(.bytes_to_pages);
        defer span.deinit();
        span.trace("Converting {d} bytes to pages (Z_P={d})", .{ size, Z_P });

        const pages: u16 = @intCast(try std.math.divCeil(@TypeOf(size), size, Z_P));
        span.trace("Result: {d} pages", .{pages});
        return pages;
    }

    /// does a pages to bytes
    fn pagesToSizeInBytes(pages: u16) usize {
        const span = trace.span(.pages_to_bytes);
        defer span.deinit();
        span.trace("Converting {d} pages to bytes (Z_P={d})", .{ pages, Z_P });

        const bytes = pages * Z_P;
        span.trace("Result: {d} bytes", .{bytes});
        return bytes;
    }

    /// Aligns size to the next section boundary (Z_Z = 65536)
    fn alignToSectionSize(size_in_bytes: usize) !u32 {
        const span = trace.span(.align_to_section);
        defer span.deinit();
        span.trace("Aligning {d} bytes to section boundary (Z_Z={d})", .{ size_in_bytes, Z_Z });

        const sections = @as(u32, @intCast(try std.math.divCeil(@TypeOf(size_in_bytes), size_in_bytes, Z_Z)));
        const aligned_size = sections * Z_Z;
        span.trace("Result: {d} bytes ({d} sections)", .{ aligned_size, sections });
        return aligned_size;
    }

    pub fn isMemoryError(err: anyerror) bool {
        return err == Error.PageFault;
    }

    fn checkMemoryLimits(ro_size_in_bytes: usize, heap_size_in_bytes: usize, stack_size_in_bytes: usize) !void {
        const span = trace.span(.check_memory_limits);
        defer span.deinit();
        span.debug("Checking memory layout limits", .{});
        span.trace("Input sizes - RO: {d} bytes, Heap: {d} bytes, Stack: {d} bytes", .{ ro_size_in_bytes, heap_size_in_bytes, stack_size_in_bytes });

        // Calculate sizes in terms of major zones (Z_Z)
        const ro_zones = try alignToSectionSize(ro_size_in_bytes);
        const heap_zones = try alignToSectionSize(heap_size_in_bytes);
        const stack_zones = try alignToSectionSize(stack_size_in_bytes);

        span.trace("Section-aligned sizes - RO: 0x{X}, Heap: 0x{X}, Stack: 0x{X}", .{ ro_zones, heap_zones, stack_zones });

        // Check the memory layout equation: 5Z_Z + ⌈|o|/Z_Z⌉ + ⌈|w|/Z_Z⌉ + ⌈s/Z_Z⌉ + Z_I ≤ 2^32
        var total: u64 = 5 * Z_Z; // Fixed zones
        total += ro_zones;
        total += heap_zones;
        total += stack_zones;
        total += Z_I; // Input data section

        span.debug("Memory layout calculation: 5*Z_Z + RO + Heap + Stack + Z_I = {d} bytes (0x{X})", .{ total, total });
        span.trace("Fixed zones: {d}, Input (Z_I): {d}", .{ 5 * Z_Z, Z_I });

        if (total > 0xFFFFFFFF) {
            span.err("Memory layout exceeds 32-bit address space: {d} > {d}", .{ total, 0xFFFFFFFF });
            return Error.MemoryLimitExceeded;
        }

        span.debug("Memory layout within limits", .{});
    }

    pub fn initEmpty(allocator: Allocator) !Memory {
        // Initialize page table
        var page_table = PageTable.init(allocator);
        errdefer page_table.deinit();

        return Memory{
            .page_table = page_table,
            .last_violation = null,
            .allocator = allocator,
            .input_size_in_bytes = 0,
            .read_only_size_in_pages = 0,
            .stack_size_in_pages = 0,
            .heap_size_in_pages = 0,
        };
    }

    pub fn initWithCapacity(
        allocator: Allocator,
        read_only_size_in_bytes: usize,
        heap_size_in_pages: u16,
        input_size_in_bytes: usize,
        stack_size_in_bytes: usize,
    ) !Memory {
        const span = trace.span(.memory_init);
        defer span.deinit();
        span.debug("Starting memory initialization", .{});

        // Initialize page table
        var page_table = PageTable.init(allocator);
        errdefer page_table.deinit();

        // Calculate section sizes
        const read_only_aligned_size_in_bytes = try alignToPageSize(read_only_size_in_bytes);
        const heap_aligned_size_in_bytes = @as(usize, heap_size_in_pages * Z_P);
        const stack_aligned_size_in_bytes = try alignToPageSize(stack_size_in_bytes);

        // Verify memory limits
        try checkMemoryLimits(
            read_only_aligned_size_in_bytes,
            heap_aligned_size_in_bytes,
            stack_aligned_size_in_bytes,
        );

        // Allocate the ReadOnly section
        try page_table.allocatePages(
            READ_ONLY_BASE_ADDRESS,
            try sizeInBytesToPages(read_only_size_in_bytes),
            .ReadOnly,
        );

        // Allocate the Heap section
        const heap_base = try HEAP_BASE_ADDRESS(read_only_aligned_size_in_bytes);
        try page_table.allocatePages(heap_base, heap_size_in_pages, .ReadWrite);

        // Allocate the Input section
        try page_table.allocatePages(INPUT_ADDRESS, try sizeInBytesToPages(input_size_in_bytes), .ReadOnly);

        // Allocate the Stack section
        const stack_size_in_pages = try sizeInBytesToPages(stack_aligned_size_in_bytes);
        try page_table.allocatePages(try STACK_BOTTOM_ADDRESS(stack_size_in_pages), stack_size_in_pages, .ReadWrite);

        return Memory{
            .page_table = page_table,
            .last_violation = null,
            .allocator = allocator,
            .input_size_in_bytes = @as(u32, @intCast(input_size_in_bytes)),
            .read_only_size_in_pages = try sizeInBytesToPages(read_only_size_in_bytes),
            .stack_size_in_pages = stack_size_in_pages,
            .heap_size_in_pages = heap_size_in_pages,
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

        span.debug("Initializing memory system with data", .{});
        span.trace("Read-only: {d} bytes, Read-write: {d} bytes, Input: {d} bytes", .{ read_only.len, read_write.len, input.len });
        span.trace("Stack size: {d} bytes, Heap size: {d} pages", .{ stack_size_in_bytes, heap_size_in_pages });

        // Calculate section sizes rounded to page boundaries
        const ro_pages: u16 = @intCast(try sizeInBytesToPages(read_only.len));
        const heap_pages: u16 = @intCast(heap_size_in_pages + try sizeInBytesToPages(read_write.len));
        span.debug("Calculated pages - Read-only: {d}, Heap: {d}", .{ ro_pages, heap_pages });

        // Initialize the memory system with the calculated capacities
        const memory_init_span = span.child(.memory_init_capacity);
        defer memory_init_span.deinit();
        memory_init_span.debug("Initializing memory with capacity", .{});

        var memory = try Memory.initWithCapacity(
            allocator,
            ro_pages,
            heap_pages,
            input.len,
            stack_size_in_bytes,
        );
        memory_init_span.debug("Base memory system initialized", .{});
        errdefer {
            memory_init_span.err("Error during initialization, cleaning up", .{});
            memory.deinit();
        }

        // Initialize read-only section
        if (read_only.len > 0) {
            const ro_span = span.child(.init_readonly);
            defer ro_span.deinit();
            ro_span.debug("Initializing read-only section at 0x{X:0>8} with {d} bytes", .{ READ_ONLY_BASE_ADDRESS, read_only.len });
            if (read_only.len > 64) {
                ro_span.trace("First 64 bytes: {any}", .{std.fmt.fmtSliceHexLower(read_only[0..@min(64, read_only.len)])});
            } else {
                ro_span.trace("Data: {any}", .{std.fmt.fmtSliceHexLower(read_only)});
            }
            try memory.initMemory(READ_ONLY_BASE_ADDRESS, read_only);
            ro_span.debug("Read-only section initialized", .{});
        }

        // Initialize heap section with read-write data
        if (read_write.len > 0) {
            const rw_span = span.child(.init_readwrite);
            defer rw_span.deinit();
            const heap_base = try HEAP_BASE_ADDRESS(@intCast(ro_pages * Z_P));
            rw_span.debug("Initializing read-write section at 0x{X:0>8} with {d} bytes", .{ heap_base, read_write.len });
            if (read_write.len > 64) {
                rw_span.trace("First 64 bytes: {any}", .{std.fmt.fmtSliceHexLower(read_write[0..@min(64, read_write.len)])});
            } else {
                rw_span.trace("Data: {any}", .{std.fmt.fmtSliceHexLower(read_write)});
            }
            try memory.initMemory(heap_base, read_write);
            rw_span.debug("Read-write section initialized", .{});
        }

        // Initialize input section
        if (input.len > 0) {
            const input_span = span.child(.init_input);
            defer input_span.deinit();
            input_span.debug("Initializing input section at 0x{X:0>8} with {d} bytes", .{ INPUT_ADDRESS, input.len });
            if (input.len > 64) {
                input_span.trace("First 64 bytes: {any}", .{std.fmt.fmtSliceHexLower(input[0..@min(64, input.len)])});
            } else {
                input_span.trace("Data: {any}", .{std.fmt.fmtSliceHexLower(input)});
            }
            try memory.initMemory(INPUT_ADDRESS, input);
            input_span.debug("Input section initialized", .{});
        }

        // Stack is already zero-initialized by initWithCapacity
        span.debug("Stack is zero-initialized, size: {d} bytes", .{stack_size_in_bytes});

        span.debug("Memory initialization complete", .{});
        return memory;
    }

    /// Allocate a single page at a specific address
    pub fn allocatePageAt(self: *Memory, address: u32, flags: Page.Flags) !void {
        const span = trace.span(.memory_allocate_page_at);
        defer span.deinit();
        span.debug("Allocating single page at address 0x{X:0>8} with flags {s}", .{ address, @tagName(flags) });
        return self.allocatePagesAt(address, 1, flags);
    }

    /// Allocate multiple contiguous pages starting at a specific address
    /// Address must be page aligned
    pub fn allocatePagesAt(self: *Memory, address: u32, num_pages: usize, flags: Page.Flags) !void {
        const span = trace.span(.memory_allocate_pages_at);
        defer span.deinit();
        span.debug("Allocating {d} contiguous pages at address 0x{X:0>8} with flags {s}", .{ num_pages, address, @tagName(flags) });

        // Ensure address is page aligned
        if (address % Z_P != 0) {
            span.err("Unaligned address 0x{X:0>8} - must be aligned to page size (0x{X})", .{ address, Z_P });
            return error.UnalignedAddress;
        }
        span.trace("Address is properly aligned to page boundary", .{});

        // Calculate total memory size
        const total_size = num_pages * Z_P;
        span.trace("Total allocation size: {d} bytes (0x{X})", .{ total_size, total_size });

        // Allocate the new pages
        const alloc_span = span.child(.allocate_pages);
        defer alloc_span.deinit();
        alloc_span.debug("Allocating {d} pages in page table", .{num_pages});
        try self.page_table.allocatePages(address, num_pages, flags);
        span.debug("Page allocation successful", .{});
    }

    pub fn allocate(self: *Memory, memory_requested: u32) !u32 {
        const span = trace.span(.memory_allocate);
        defer span.deinit();
        span.debug("Allocating {d} bytes of memory", .{memory_requested});

        // Check allocation limit
        if (self.heap_allocation_limit) |limit| {
            const pages_required = try sizeInBytesToPages(memory_requested);
            if (self.heap_size_in_pages + pages_required > limit) {
                span.err("Memory allocation exceeds limit - requested: {d} pages, limit: {d} pages", .{ pages_required, limit });
                return error.MemoryLimitExceeded;
            }
            span.trace("Memory allocation within limits (pages: {d}/{d})", .{ self.heap_size_in_pages + pages_required, limit });
        }

        // Calculate required pages, rounding up to nearest page size
        const aligned_size = try alignToPageSize(memory_requested);
        const pages_needed = aligned_size / Z_P;
        span.debug("Allocation requires {d} pages ({d} bytes aligned)", .{ pages_needed, aligned_size });

        // Check if the size is within bounds
        const check_span = span.child(.check_limits);
        defer check_span.deinit();
        check_span.debug("Checking memory limits", .{});
        check_span.trace("Current sizes - RO: {d} pages, Heap: {d} pages, Stack: {d} pages", .{ self.read_only_size_in_pages, self.heap_size_in_pages, self.stack_size_in_pages });

        try checkMemoryLimits(
            pagesToSizeInBytes(self.read_only_size_in_pages),
            pagesToSizeInBytes(self.heap_size_in_pages),
            pagesToSizeInBytes(self.stack_size_in_pages),
        );
        check_span.debug("Memory limits verification passed", .{});

        // Find the last ReadWrite page (heap section)
        const find_span = span.child(.find_last_rw);
        defer find_span.deinit();
        find_span.debug("Finding last ReadWrite page", .{});

        var last_rw_page: ?PageTable.PageResult = null;
        for (self.page_table.pages.items, 0..) |*page, i| {
            if (page.flags == .ReadWrite) {
                find_span.trace("Found ReadWrite page at index {d}: 0x{X:0>8}", .{ i, page.address });
                last_rw_page = PageTable.PageResult{
                    .page = page,
                    .index = i,
                    .page_table = &self.page_table,
                };
            }
        }

        const last_page = last_rw_page orelse {
            find_span.err("Could not find any ReadWrite pages", .{});
            return Error.CouldNotFindRwPage;
        };
        find_span.debug("Last ReadWrite page found at 0x{X:0>8}", .{last_page.page.address});

        // Calculate new allocation address (immediately after last ReadWrite page)
        const new_address = last_page.page.address + Z_P;
        span.debug("New allocation will start at address 0x{X:0>8}", .{new_address});

        // Special case when size is 0, we are not going to allocate
        // anything, we will return the address of the next page
        if (memory_requested == 0) {
            span.debug("Zero-sized allocation, returning address 0x{X:0>8} without allocating pages", .{new_address});
            return new_address;
        }

        // Allocate the new pages
        span.debug("Allocating {d} pages starting at 0x{X:0>8}", .{ pages_needed, new_address });
        try self.page_table.allocatePages(new_address, pages_needed, .ReadWrite);

        // Do some bookkeeping
        self.heap_size_in_pages += 1;
        span.debug("Heap size increased to {d} pages", .{self.heap_size_in_pages});
        span.debug("Memory allocation successful, returning address 0x{X:0>8}", .{new_address});

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
        span.debug("Reading {d}-bit integer from address 0x{X:0>8}", .{ @bitSizeOf(T), address });

        const size = @sizeOf(T);
        comptime std.debug.assert(size <= 8); // Only handle up to u64

        // Get first page and offset
        const first_page = self.page_table.findPageOfAddresss(address) orelse {
            const aligned_addr = @divTrunc(address, Z_P) * Z_P;
            span.err("Page fault - non-allocated memory at 0x{X:0>8} (aligned: 0x{X:0>8})", .{ address, aligned_addr });
            self.last_violation = ViolationInfo{
                .violation_type = .NonAllocated,
                .address = aligned_addr,
                .attempted_size = @sizeOf(T),
                .page = null,
            };
            return Error.PageFault;
        };

        const offset = address - first_page.page.address;
        const bytes_in_first = Memory.Z_P - offset;
        span.trace("Found page at 0x{X:0>8}, offset: 0x{X}, bytes available: {d}", .{ first_page.page.address, offset, bytes_in_first });

        // If it fits in first page, read directly
        if (size <= bytes_in_first) {
            const result = @as(T, @bitCast(first_page.page.data[offset..][0..size].*));
            span.debug("Read value: 0x{X} (fits in single page)", .{result});
            return result;
        }

        span.debug("Cross-page read detected ({d} bytes span two pages)", .{size});

        // Cross-page read - use stack buffer
        var buf: [@sizeOf(T)]u8 = undefined;

        // Copy from first page
        @memcpy(buf[0..bytes_in_first], first_page.page.data[offset..][0..bytes_in_first]);
        span.trace("Read {d} bytes from first page: {any}", .{ bytes_in_first, std.fmt.fmtSliceHexLower(buf[0..bytes_in_first]) });

        // Get and copy from second page, this should aways have enough
        const next_page = first_page.nextContiguous() orelse {
            const next_addr = first_page.page.address + Memory.Z_P;
            span.err("Page fault - missing contiguous page at 0x{X:0>8}", .{next_addr});
            self.last_violation = ViolationInfo{
                .violation_type = .NonAllocated,
                .address = next_addr, // Address where next page should be
                .attempted_size = size,
                .page = first_page.page,
            };
            return error.PageFault;
        };

        const bytes_in_second = size - bytes_in_first;
        @memcpy(buf[bytes_in_first..size], next_page.page.data[0..bytes_in_second]);
        span.trace("Read {d} bytes from second page: {any}", .{ bytes_in_second, std.fmt.fmtSliceHexLower(buf[bytes_in_first..size]) });

        const result = std.mem.readInt(T, &buf, .little);
        span.debug("Read value: 0x{X} (from cross-page read)", .{result});
        return result;
    }

    /// Read a slice from memory, not allowing cross-page reads
    /// FIXME: this should be able to cross pages
    pub fn readSlice(self: *Memory, address: u32, size: usize) ![]const u8 {
        const span = trace.span(.memory_read_slice);
        defer span.deinit();
        span.debug("Reading slice of {d} bytes from address 0x{X:0>8}", .{ size, address });

        // Find the page containing the address
        const page = self.page_table.findPageOfAddresss(address) orelse {
            span.err("Page fault - non-allocated memory at 0x{X:0>8}", .{address});
            self.last_violation = ViolationInfo{
                .violation_type = .NonAllocated,
                .address = address,
                .attempted_size = size,
                .page = null,
            };
            return Error.PageFault;
        };
        span.trace("Found page at 0x{X:0>8} with flags {s}", .{ page.page.address, @tagName(page.page.flags) });

        // Check if read would cross page boundary
        const offset = address - page.page.address;
        const end_offset = offset + size;
        span.trace("Read range: offset 0x{X} to 0x{X} (page size: 0x{X})", .{ offset, end_offset, Z_P });

        if (end_offset > Z_P) {
            span.err("Cross-page read detected - read would span page boundary", .{});
            return Error.CrossPageRead;
        }

        // Return slice of page data
        const result = page.page.data[offset..][0..size];
        if (size <= 64) {
            span.trace("Read data: {any}", .{std.fmt.fmtSliceHexLower(result)});
        } else {
            span.trace("First 64 bytes: {any}", .{std.fmt.fmtSliceHexLower(result[0..@min(64, size)])});
        }
        span.debug("Successfully read {d} bytes", .{size});

        return result;
    }

    pub fn readSliceOwned(self: *Memory, address: u32, size: usize) ![]const u8 {
        const slice = try self.readSlice(address, size);
        return self.allocator.dupe(u8, slice);
    }

    /// Write a slice to memory, not allowing cross-page writes
    /// FIXME: this should be able to cross pages
    pub fn writeSlice(self: *Memory, address: u32, slice: []const u8) !void {
        const span = trace.span(.memory_write_slice);
        defer span.deinit();
        span.debug("Writing slice of {d} bytes to address 0x{X:0>8}", .{ slice.len, address });

        // Find the page containing the address
        const page = self.page_table.findPageOfAddresss(address) orelse {
            const aligned_addr = @divTrunc(address, Z_P) * Z_P;
            span.err("Page fault - non-allocated memory at 0x{X:0>8} (aligned: 0x{X:0>8})", .{ address, aligned_addr });
            self.last_violation = ViolationInfo{
                .violation_type = .NonAllocated,
                .address = aligned_addr,
                .attempted_size = slice.len,
                .page = null,
            };
            return Error.PageFault;
        };
        span.trace("Found page at 0x{X:0>8} with flags {s}", .{ page.page.address, @tagName(page.page.flags) });

        // Check write permissions
        if (page.page.flags == .ReadOnly) {
            span.err("Write protection violation at 0x{X:0>8} - page is ReadOnly", .{address});
            self.last_violation = ViolationInfo{
                .violation_type = .WriteProtection,
                .address = page.page.address,
                .attempted_size = slice.len,
                .page = page.page,
            };
            return Error.PageFault;
        }

        // Check if write would cross page boundary
        const offset = address - page.page.address;
        const end_offset = offset + slice.len;
        span.trace("Write range: offset 0x{X} to 0x{X} (page size: 0x{X})", .{ offset, end_offset, Z_P });

        if (end_offset > Z_P) {
            span.err("Cross-page write detected - write would span page boundary", .{});
            return Error.CrossPageWrite;
        }

        // Write slice to page data
        @memcpy(page.page.data[offset..][0..slice.len], slice);

        if (slice.len <= 64) {
            span.trace("Written data: {any}", .{std.fmt.fmtSliceHexLower(slice)});
        } else {
            span.trace("First 64 bytes: {any}", .{std.fmt.fmtSliceHexLower(slice[0..@min(64, slice.len)])});
        }
        span.debug("Successfully wrote {d} bytes", .{slice.len});
    }

    /// Initilialize a slice to memory not cross-page, will err on cross page
    /// access. Does not check ReadWrite permissions can also write to ReadOnly
    /// segments.
    pub fn initMemory(self: *Memory, address: u32, slice: []const u8) !void {
        const span = trace.span(.memory_init_data);
        defer span.deinit();
        span.debug("Initializing memory at 0x{X:0>8} with {d} bytes", .{ address, slice.len });

        if (slice.len == 0) {
            span.debug("Empty slice, nothing to initialize", .{});
            return;
        }

        var remaining = slice;
        var current_addr = address;
        var page_count: usize = 0;

        while (remaining.len > 0) {
            // Find the page containing the current address
            const page_result = self.page_table.findPageOfAddresss(current_addr) orelse {
                span.err("Page fault at address 0x{X:0>8} - page not found", .{current_addr});
                return Error.PageFault;
            };

            // Calculate offset and available space in current page
            const offset = current_addr - page_result.page.address;
            const available_in_page = Z_P - offset;
            const bytes_to_write = @min(remaining.len, available_in_page);

            span.trace("Writing to page {d} at address 0x{X:0>8}, offset 0x{X}, {d} bytes", .{ page_count, page_result.page.address, offset, bytes_to_write });

            // Show a sample of the data being written
            if (bytes_to_write > 0) {
                const sample_size = @min(bytes_to_write, 32);
                span.trace("Data sample: {any}", .{std.fmt.fmtSliceHexLower(remaining[0..sample_size])});
            }

            // Write data to current page
            @memcpy(page_result.page.data[offset..][0..bytes_to_write], remaining[0..bytes_to_write]);

            // If we need to continue to next page, verify it exists and is contiguous
            if (remaining.len > bytes_to_write) {
                const next_page = page_result.nextContiguous() orelse {
                    const expected_addr = page_result.page.address + Z_P;
                    span.err("Page fault - missing contiguous page at 0x{X:0>8}", .{expected_addr});
                    return Error.PageFault;
                };
                span.debug("Moving to next contiguous page at 0x{X:0>8}", .{next_page.page.address});
            }

            // Update pointers for next iteration
            remaining = remaining[bytes_to_write..];
            current_addr += bytes_to_write;
            page_count += 1;
        }

        span.debug("Successfully initialized memory across {d} page(s)", .{page_count});
    }

    /// Write an integer type to memory (u8, u16, u32, u64)
    pub fn writeInt(self: *Memory, T: type, address: u32, value: T) !void {
        const span = trace.span(.memory_write);
        defer span.deinit();
        span.debug("Writing {d}-bit integer 0x{X} to address 0x{X:0>8}", .{ @bitSizeOf(T), value, address });

        const size = @sizeOf(T);
        comptime std.debug.assert(size <= 8); // Only handle up to u64
        comptime std.debug.assert(@typeInfo(T) == .int);

        // First verify all required pages exist
        const page = self.page_table.findPageOfAddresss(address) orelse {
            const aligned_addr = @divTrunc(address, Z_P) * Z_P;
            span.err("Page fault - non-allocated memory at 0x{X:0>8} (aligned: 0x{X:0>8})", .{ address, aligned_addr });
            self.last_violation = ViolationInfo{
                .violation_type = .NonAllocated,
                .address = aligned_addr, // since this falls outside any page, we just round it
                .attempted_size = size,
                .page = null,
            };
            return Error.PageFault;
        };

        const offset = address - page.page.address;
        const bytes_in_first = Z_P - offset;
        span.trace("Found page at 0x{X:0>8}, offset: 0x{X}, bytes available: {d}", .{ page.page.address, offset, bytes_in_first });

        // Check if we need a second page
        const need_second_page = size > bytes_in_first;
        if (need_second_page) {
            span.debug("Cross-page write detected ({d} bytes span two pages)", .{size});
        }

        const next_contiguous = if (need_second_page)
            page.nextContiguous() orelse {
                const next_addr = page.page.address + Z_P;
                span.err("Page fault - missing contiguous page at 0x{X:0>8}", .{next_addr});
                self.last_violation = ViolationInfo{
                    .violation_type = .NonAllocated,
                    .address = next_addr,
                    .attempted_size = size,
                    .page = null,
                };
                return Error.PageFault;
            }
        else
            null;

        // Check page permissions
        if (page.page.flags == .ReadOnly) {
            span.err("Write protection violation at 0x{X:0>8} - page is ReadOnly", .{address});
            self.last_violation = ViolationInfo{
                .violation_type = .WriteProtection,
                .address = page.page.address,
                .attempted_size = size,
                .page = page.page,
            };
            return Error.PageFault;
        }

        if (next_contiguous != null and next_contiguous.?.page.flags == .ReadOnly) {
            span.err("Write protection violation at 0x{X:0>8} - second page is ReadOnly", .{next_contiguous.?.page.address});
            self.last_violation = ViolationInfo{
                .violation_type = .WriteProtection,
                .address = next_contiguous.?.page.address,
                .attempted_size = size,
                .page = next_contiguous.?.page,
            };
            return Error.PageFault;
        }

        // Now perform the actual write, knowing all pages exist and are writable
        var bytes: [size]u8 = undefined;
        std.mem.writeInt(T, &bytes, value, .little);
        span.trace("Value as bytes: {any}", .{std.fmt.fmtSliceHexLower(&bytes)});

        // Write to first page
        const first_write_size = @min(size, bytes_in_first);
        @memcpy(page.page.data[offset..][0..first_write_size], bytes[0..first_write_size]);
        span.trace("Wrote {d} bytes to first page at offset 0x{X}", .{ first_write_size, offset });

        // Write to second page if needed
        if (next_contiguous) |next| {
            const bytes_in_second = size - bytes_in_first;
            @memcpy(next.page.data[0..bytes_in_second], bytes[bytes_in_first..size]);
            span.trace("Wrote {d} bytes to second page at offset 0", .{bytes_in_second});
        }

        span.debug("Successfully wrote value 0x{X}", .{value});
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
