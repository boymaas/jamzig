const std = @import("std");
const Allocator = std.mem.Allocator;
const trace = @import("tracing").scoped(.pvm);
const types = @import("types.zig");

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
            const span = trace.span(@src(), .allocate_pages);
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

            // Sort pages first to ensure consistent ordering for overlap checks
            std.sort.insertion(Page, self.pages.items, {}, struct {
                fn lessThan(_: void, a: Page, b: Page) bool {
                    return a.address < b.address;
                }
            }.lessThan);

            // Check for overlapping pages
            const overlap_span = span.child(@src(), .check_overlap);
            defer overlap_span.deinit();
            overlap_span.debug("Checking for page overlaps with {d} existing pages", .{self.pages.items.len});

            for (self.pages.items) |page| {
                const page_end = page.address + Memory.Z_P;
                overlap_span.trace("Checking page: 0x{X:0>8} - 0x{X:0>8}", .{ page.address, page_end });

                // Check if new range overlaps with existing page
                if ((start_address >= page.address and start_address < page_end) or
                    (new_end > page.address and new_end <= page_end) or
                    (page.address >= start_address and page.address < new_end))
                {
                    overlap_span.err("Overlap detected with page at 0x{X:0>8}", .{page.address});
                    return error.PageOverlap;
                }
            }
            overlap_span.debug("No overlapping pages found", .{});

            // Allocate new pages
            const alloc_span = span.child(@src(), .create_pages);
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

            // Re-sort pages by address (after adding new ones)
            const sort_span = span.child(@src(), .sort_pages);
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

        /// Frees a contiguous range of pages starting at the given address
        pub fn freePages(self: *PageTable, start_address: u32, num_pages: usize) !void {
            const span = trace.span(@src(), .free_pages);
            defer span.deinit();
            span.debug("Freeing {d} page(s) starting at 0x{X:0>8}", .{ num_pages, start_address });

            // Sanity check
            if (num_pages == 0) {
                span.debug("Nothing to free (0 pages requested)", .{});
                return;
            }

            // Calculate end address
            const end_address = start_address + (num_pages * Memory.Z_P);
            span.trace("Pages will span from 0x{X:0>8} to 0x{X:0>8}", .{ start_address, end_address });

            // Iterate over pages and free them
            var i: usize = 0;
            while (i < self.pages.items.len) {
                const page = &self.pages.items[i];
                const page_end = page.address + Memory.Z_P;

                // Check if the page is within the range to be freed
                if ((page.address >= start_address and page.address < end_address) or
                    (page_end > start_address and page_end <= end_address))
                {
                    span.trace("Freeing page at 0x{X:0>8}", .{page.address});
                    page.deinit(self.allocator);
                    _ = self.pages.orderedRemove(i);
                } else {
                    i += 1;
                }
            }

            span.debug("Page freeing complete", .{});
        }

        /// Returns the index of the page containing the given address using binary search
        pub fn findPageIndexOfAddress(self: *const PageTable, address: u32) ?usize {
            const span = trace.span(@src(), .find_page_index);
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

        pub fn findPageOfAddresss(self: *const PageTable, address: u32) ?PageResult {
            if (self.findPageIndexOfAddress(address)) |index| {
                return PageResult{
                    .page = &self.pages.items[index],
                    .index = index,
                    .page_table = @constCast(self),
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
    read_only_size_in_pages: u32,
    stack_size_in_pages: u32,
    heap_size_in_pages: u32,
    heap_top: u32 = 0, // Current top of the heap

    // Controls whether dynamic memory allocation is allowed beyond the initial heap size
    dynamic_allocation_enabled: bool = false,

    // Artificial limit on how many allocations we allow
    // mainly for the fuzzer, this is not in the spec
    heap_allocation_limit: ?u32 = null,

    // Memory layout constants
    pub const Z_Z: u32 = 0x10000; // 2^16 = 65,536 - Major zone size
    pub const Z_P: u32 = 0x1000; // 2^12 = 4,096 - Page size
    pub const Z_I: u32 = 0x1000000; // 2^24 - Standard input data size

    // Fixed section base addresses
    pub const READ_ONLY_BASE_ADDRESS: u32 = Z_Z;
    pub fn HEAP_BASE_ADDRESS(read_only_size_in_bytes: usize) !u32 {
        return 2 * Z_Z + @as(u32, @intCast(try alignToSectionSize(read_only_size_in_bytes)));
    }
    pub const INPUT_ADDRESS: u32 = 0xFFFFFFFF - Z_Z - Z_I + 1;
    pub const STACK_BASE_ADDRESS: u32 = 0xFFFFFFFF - (2 * Z_Z) - Z_I + 1;
    pub fn STACK_BOTTOM_ADDRESS(stack_size_in_pages: u16) !u32 {
        return STACK_BASE_ADDRESS - (@as(u32, @intCast(stack_size_in_pages)) * Z_P);
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
        OutOfMemory,
        CouldNotFindRwPage,
        MemoryLimitExceeded,
    };

    pub fn deepClone(self: *const Memory, allocator: Allocator) !Memory {
        const span = trace.span(@src(), .memory_deep_clone);
        defer span.deinit();
        span.debug("Creating deep clone of memory system", .{});

        // Initialize a new empty memory system
        var new_memory = try Memory.initEmpty(allocator, self.dynamic_allocation_enabled);
        errdefer new_memory.deinit();

        // Clone all pages
        const clone_span = span.child(@src(), .clone_pages);
        defer clone_span.deinit();
        clone_span.debug("Cloning {d} pages", .{self.page_table.pages.items.len});

        try new_memory.page_table.pages.ensureTotalCapacityPrecise(self.page_table.pages.items.len);

        for (self.page_table.pages.items) |page| {
            clone_span.trace("Cloning page at 0x{X:0>8} with flags {s}", .{ page.address, @tagName(page.flags) });

            // Allocate new page data
            const new_data = try allocator.alloc(u8, Memory.Z_P);
            errdefer allocator.free(new_data);

            // Copy page data
            @memcpy(new_data, page.data);

            // Create new page and add to page table
            const new_page = Page{
                .data = new_data,
                .address = page.address,
                .flags = page.flags,
            };
            try new_memory.page_table.pages.append(new_page);
        }

        // Copy memory properties
        new_memory.input_size_in_bytes = self.input_size_in_bytes;
        new_memory.read_only_size_in_pages = self.read_only_size_in_pages;
        new_memory.stack_size_in_pages = self.stack_size_in_pages;
        new_memory.heap_size_in_pages = self.heap_size_in_pages;
        new_memory.heap_allocation_limit = self.heap_allocation_limit;

        // Clone last violation if present
        if (self.last_violation) |violation| {
            // Create a new violation info
            var new_violation = ViolationInfo{
                .violation_type = violation.violation_type,
                .address = violation.address,
                .attempted_size = violation.attempted_size,
                .page = null,
            };

            // If the violation had a page reference, find the corresponding page in the new memory
            if (violation.page) |old_page| {
                // Find the corresponding page in the new memory by address
                for (new_memory.page_table.pages.items) |*new_page| {
                    if (new_page.address == old_page.address) {
                        new_violation.page = new_page;
                        break;
                    }
                }
            }

            new_memory.last_violation = new_violation;
        }

        span.debug("Memory deep clone complete with {d} pages", .{new_memory.page_table.pages.items.len});
        return new_memory;
    }

    /// Aligns size to the next page boundary (Z_P = 4096)
    fn alignToPageSize(size_in_bytes: usize) !u32 {
        const span = trace.span(@src(), .align_to_page);
        defer span.deinit();
        span.trace("Aligning {d} bytes to page boundary (Z_P={d})", .{ size_in_bytes, Z_P });

        const pages = try sizeInBytesToPages(size_in_bytes);
        const aligned_size = pages * Z_P;
        span.trace("Result: {d} bytes ({d} pages)", .{ aligned_size, pages });
        return aligned_size;
    }

    /// Does a bytes to pages
    fn sizeInBytesToPages(size: usize) !u16 {
        const span = trace.span(@src(), .bytes_to_pages);
        defer span.deinit();
        span.trace("Converting {d} bytes to pages (Z_P={d})", .{ size, Z_P });

        const pages: u16 = @intCast(try std.math.divCeil(@TypeOf(size), size, Z_P));
        span.trace("Result: {d} pages", .{pages});
        return pages;
    }

    /// does a pages to bytes
    fn pagesToSizeInBytes(pages: u16) usize {
        const span = trace.span(@src(), .pages_to_bytes);
        defer span.deinit();
        span.trace("Converting {d} pages to bytes (Z_P={d})", .{ pages, Z_P });

        const bytes = pages * Z_P;
        span.trace("Result: {d} bytes", .{bytes});
        return bytes;
    }

    /// Aligns size to the next section boundary (Z_Z = 65536)
    fn alignToSectionSize(size_in_bytes: usize) !u32 {
        const span = trace.span(@src(), .align_to_section);
        defer span.deinit();
        span.trace("Aligning {d} bytes to section boundary (Z_Z={d})", .{ size_in_bytes, Z_Z });

        const sections = @as(u32, @intCast(try std.math.divCeil(@TypeOf(size_in_bytes), size_in_bytes, Z_Z)));
        const aligned_size = sections * Z_Z;
        span.trace("Result: {d} bytes ({d} sections)", .{ aligned_size, sections });
        return aligned_size;
    }

    fn nextPageBoundary(address: u32) u32 {
        return ((address + Z_P - 1) / Z_P) * Z_P;
    }

    pub fn isMemoryError(err: anyerror) bool {
        return err == Error.PageFault;
    }

    fn checkMemoryLimits(ro_size_in_bytes: usize, heap_size_in_bytes: usize, stack_size_in_bytes: usize) !void {
        const span = trace.span(@src(), .check_memory_limits);
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

    pub fn initEmpty(allocator: Allocator, dynamic_allocation: bool) !Memory {
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
            .dynamic_allocation_enabled = dynamic_allocation,
        };
    }

    pub fn initWithCapacity(
        allocator: Allocator,
        read_only_size_in_bytes: usize,
        heap_size_in_pages: u32,
        input_size_in_bytes: usize,
        stack_size_in_bytes: usize,
        dynamic_allocation: bool,
    ) !Memory {
        const span = trace.span(@src(), .memory_init);
        defer span.deinit();
        span.debug("Starting memory initialization", .{});

        // Initialize page table
        var page_table = PageTable.init(allocator);
        errdefer page_table.deinit();

        // Calculate section sizes
        const read_only_aligned_size_in_bytes = try alignToPageSize(read_only_size_in_bytes);
        const heap_aligned_size_in_bytes = @as(usize, @as(u32, heap_size_in_pages) * Z_P);
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
            .heap_top = heap_base, // Initialize heap_top to the start of the heap
            .dynamic_allocation_enabled = dynamic_allocation,
        };
    }

    pub fn initWithData(
        allocator: Allocator,
        read_only: []const u8,
        read_write: []const u8,
        input: []const u8,
        stack_size_in_bytes: u24,
        heap_size_in_pages: u32,
        dynamic_allocation: bool,
    ) !Memory {
        const span = trace.span(@src(), .memory_init);
        defer span.deinit();

        span.debug("Initializing memory system with data", .{});
        span.trace("Read-only: {d} bytes, Read-write: {d} bytes, Input: {d} bytes", .{ read_only.len, read_write.len, input.len });
        span.trace("Stack size: {d} bytes, Heap size: {d} pages", .{ stack_size_in_bytes, heap_size_in_pages });

        // Calculate section sizes rounded to page boundaries
        const ro_pages: u32 = @intCast(try sizeInBytesToPages(read_only.len));
        const heap_pages: u32 = @intCast(heap_size_in_pages + try sizeInBytesToPages(read_write.len));
        span.debug("Calculated pages - Read-only: {d}, Heap: {d}", .{ ro_pages, heap_pages });

        // Initialize the memory system with the calculated capacities
        const memory_init_span = span.child(@src(), .memory_init_capacity);
        defer memory_init_span.deinit();
        memory_init_span.debug("Initializing memory with capacity", .{});

        var memory = try Memory.initWithCapacity(
            allocator,
            read_only.len,
            heap_pages,
            input.len,
            stack_size_in_bytes,
            dynamic_allocation,
        );
        memory_init_span.debug("Base memory system initialized", .{});
        errdefer {
            memory_init_span.err("Error during initialization, cleaning up", .{});
            memory.deinit();
        }

        // Initialize read-only section
        if (read_only.len > 0) {
            const ro_span = span.child(@src(), .init_readonly);
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
            const rw_span = span.child(@src(), .init_readwrite);
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
            const input_span = span.child(@src(), .init_input);
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

        // Initialize heap_top to the end of the allocated heap section (section-aligned)
        // This matches PolkaVM's behavior where the heap starts at the section boundary,
        // not immediately after the RW data. This ensures compatibility with PolkaVM.
        const heap_base = try HEAP_BASE_ADDRESS(@intCast(ro_pages * Z_P));
        memory.heap_top = heap_base + (@as(u32, heap_pages) * Z_P);

        span.debug("Memory initialization complete with heap_top set to 0x{X:0>8} (section-aligned)", .{memory.heap_top});
        return memory;
    }

    /// Allocate a single page at a specific address
    pub fn allocatePageAt(self: *Memory, address: u32, writable: bool) !void {
        const span = trace.span(@src(), .memory_allocate_page_at);
        defer span.deinit();
        const flags = if (writable) .ReadWrite else .ReadOnly;
        span.debug("Allocating single page at address 0x{X:0>8} with flags {s}", .{ address, @tagName(flags) });
        return self.allocatePagesAt(address, 1, flags);
    }

    /// Allocate multiple contiguous pages starting at a specific address
    /// Address must be page aligned
    pub fn allocatePagesAt(self: *Memory, address: u32, num_pages: usize, writeable: bool) !void {
        const span = trace.span(@src(), .memory_allocate_pages_at);
        defer span.deinit();

        const flags = if (writeable) .ReadWrite else .ReadOnly;

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
        const alloc_span = span.child(@src(), .allocate_pages);
        defer alloc_span.deinit();
        alloc_span.debug("Allocating {d} pages in page table", .{num_pages});
        try self.page_table.allocatePages(address, num_pages, flags);
        span.debug("Page allocation successful", .{});
    }

    /// Get the heap start address according to graypaper specification
    /// h = 2*ZZ + Z(|o|) where Z(x) = ZZ * ceil(x / ZZ)
    pub fn getHeapStart(self: *const Memory) u32 {
        const span = trace.span(@src(), .get_heap_start);
        defer span.deinit();

        // Calculate read-only section size in bytes
        const readonly_size_bytes = @as(u32, self.read_only_size_in_pages) * Z_P;

        // Use HEAP_BASE_ADDRESS which performs the same calculation
        const heap_start = HEAP_BASE_ADDRESS(readonly_size_bytes) catch unreachable;

        span.debug("Heap start calculation: readonly_size={d}, heap_start=0x{X:0>8}", .{ readonly_size_bytes, heap_start });

        return heap_start;
    }

    /// Check if a specific page address is currently valid (allocated)
    pub fn isPageValid(self: *const Memory, page_addr: u32) bool {
        const span = trace.span(@src(), .is_page_valid);
        defer span.deinit();
        span.trace("Checking if page at 0x{X:0>8} is valid", .{page_addr});

        const page_exists = self.page_table.findPageOfAddresss(page_addr) != null;
        span.trace("Page valid: {}", .{page_exists});
        return page_exists;
    }

    /// Check if a memory range [addr, addr+size) is currently valid (allocated)
    /// Returns true if ANY part of the range is currently allocated
    pub fn isRangeValid(self: *const Memory, addr: u32, size: u32) bool {
        const span = trace.span(@src(), .is_range_valid);
        defer span.deinit();
        span.debug("Checking if range [0x{X:0>8}, 0x{X:0>8}) is valid", .{ addr, addr + size });

        if (size == 0) {
            span.debug("Zero-size range, returning false", .{});
            return false;
        }

        // Calculate the range of pages this spans
        const start_page = (addr / Z_P) * Z_P;
        const end_addr = addr + size - 1; // Last byte address
        const end_page = (end_addr / Z_P) * Z_P;

        span.trace("Range spans pages from 0x{X:0>8} to 0x{X:0>8}", .{ start_page, end_page });

        // Check each page in the range
        var current_page = start_page;
        while (current_page <= end_page) : (current_page += Z_P) {
            if (self.isPageValid(current_page)) {
                span.debug("Found valid page at 0x{X:0>8}, range is valid", .{current_page});
                return true;
            }
        }

        span.debug("No valid pages found in range", .{});
        return false;
    }

    /// Graypaper-compliant sbrk implementation
    /// Returns the previous heap pointer and extends heap linearly
    pub fn sbrk(self: *Memory, size: u32) !u32 {
        const span = trace.span(@src(), .sbrk);
        defer span.deinit();
        span.debug("sbrk called with size={d} bytes", .{size});

        // Initialize heap_top if not set
        if (self.heap_top == 0) {
            self.heap_top = self.getHeapStart();
            span.debug("Initialized heap_top to 0x{X:0>8}", .{self.heap_top});
        }

        // Special case: size 0 should return current heap pointer without allocation
        if (size == 0) {
            span.debug("Zero-size sbrk, returning current heap pointer: 0x{X:0>8}", .{self.heap_top});
            return self.heap_top;
        }

        // Record current heap pointer to return
        const result = self.heap_top;

        // Calculate next page boundary from current heap pointer
        const next_page_boundary = nextPageBoundary(self.heap_top);
        const new_heap_pointer = self.heap_top + size;

        span.debug("Current heap: 0x{X:0>8}, next boundary: 0x{X:0>8}, new heap: 0x{X:0>8}", .{ self.heap_top, next_page_boundary, new_heap_pointer });

        // Check if we need to allocate new pages
        if (new_heap_pointer > next_page_boundary) {
            const final_boundary = nextPageBoundary(new_heap_pointer);
            const idx_start = next_page_boundary / Z_P;
            const idx_end = final_boundary / Z_P;
            const page_count = idx_end - idx_start;

            span.debug("Allocating {d} pages from index {d} to {d}", .{ page_count, idx_start, idx_end });

            // Convert page indices to addresses and allocate
            const start_address = idx_start * Z_P;
            try self.page_table.allocatePages(start_address, page_count, .ReadWrite);

            // Update heap size tracking
            self.heap_size_in_pages += @intCast(page_count);
            span.debug("Heap size increased to {d} pages", .{self.heap_size_in_pages});
        }

        // Advance the heap pointer
        self.heap_top = new_heap_pointer;

        span.debug("sbrk successful, returning previous heap pointer: 0x{X:0>8}", .{result});
        return result;
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
        const span = trace.span(@src(), .memory_read);
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

    pub const MemorySlice = struct {
        buffer: []const u8,
        allocator: ?std.mem.Allocator = null,

        // Take ownership of the buffer, this object is not responsible for freeing it anymore
        // but it will point to the buffer, which could be internal memory. If it was pointing
        // to internal memory, we will dupe so the caller can safely use it
        pub fn takeBufferOwnership(self: *MemorySlice, allocator: std.mem.Allocator) ![]const u8 {
            if (self.allocator) |_| {
                self.allocator = null; // Clear allocator reference
                return self.buffer;
            } else {
                const result = try allocator.dupe(u8, self.buffer);
                return result;
            }
        }

        pub fn deinit(self: *@This()) void {
            // if we have an allocator we own the slice and should free it
            if (self.allocator) |alloc| {
                alloc.free(self.buffer);
            }
            self.* = undefined;
        }
    };

    /// Reads a hash from memory
    pub fn readHash(self: *Memory, address: u32) ![32]u8 {
        var hash_slice = try self.readSlice(address, 32);
        defer hash_slice.deinit();

        return hash_slice.buffer[0..32].*;
    }

    /// Read a slice from memory
    pub fn readSlice(self: *Memory, address: u32, size: usize) !MemorySlice {
        const span = trace.span(@src(), .memory_read_slice);
        defer span.deinit();
        span.debug("Reading slice of {d} bytes from address 0x{X:0>8}", .{ size, address });

        // Special case for zero-size reads
        if (size == 0) {
            span.debug("Zero-size read requested, returning empty slice", .{});
            return .{ .buffer = &[_]u8{} };
        }

        // Find the page containing the starting address
        const first_page = self.page_table.findPageOfAddresss(address) orelse {
            const aligned_addr = @divTrunc(address, Z_P) * Z_P;
            span.err("Page fault - non-allocated memory at 0x{X:0>8} (aligned: 0x{X:0>8})", .{ address, aligned_addr });
            self.last_violation = ViolationInfo{
                .violation_type = .NonAllocated,
                .address = aligned_addr,
                .attempted_size = size,
                .page = null,
            };
            return Error.PageFault;
        };

        span.trace("Found first page at 0x{X:0>8} with flags {s}", .{ first_page.page.address, @tagName(first_page.page.flags) });

        // Calculate offset and available bytes in the first page
        const offset = address - first_page.page.address;
        const bytes_in_first_page = Z_P - offset;
        span.trace("Offset in first page: 0x{X}, bytes available: {d}", .{ offset, bytes_in_first_page });

        // If the entire read fits in the first page, return a slice directly
        if (size <= bytes_in_first_page) {
            const result = first_page.page.data[offset..][0..size];
            if (size <= 64) {
                span.trace("Read data (single page): {any}", .{std.fmt.fmtSliceHexLower(result)});
            } else {
                span.trace("First 64 bytes (single page): {any}", .{std.fmt.fmtSliceHexLower(result[0..@min(64, size)])});
            }
            span.debug("Successfully read {d} bytes from a single page", .{size});
            return .{ .buffer = result };
        }

        // For cross-page reads, we need to allocate a buffer and copy the data
        span.debug("Cross-page read detected, allocating buffer for {d} bytes", .{size});
        var buffer = try self.allocator.alloc(u8, size);
        errdefer self.allocator.free(buffer);

        // Copy data from the first page
        @memcpy(buffer[0..bytes_in_first_page], first_page.page.data[offset..Z_P]);
        span.trace("Copied {d} bytes from first page", .{bytes_in_first_page});

        // Copy data from subsequent pages
        var bytes_read = bytes_in_first_page;
        var remaining = size - bytes_read;
        var current_page = first_page;

        while (remaining > 0) {
            // Get the next contiguous page
            current_page = current_page.nextContiguous() orelse {
                const next_addr = current_page.page.address + Z_P;
                span.err("Page fault - missing contiguous page at 0x{X:0>8}", .{next_addr});
                self.allocator.free(buffer);
                self.last_violation = ViolationInfo{
                    .violation_type = .NonAllocated,
                    .address = next_addr,
                    .attempted_size = size,
                    .page = current_page.page,
                };
                return Error.PageFault;
            };
            span.trace("Reading from next page at 0x{X:0>8}", .{current_page.page.address});

            // Determine how many bytes to copy from this page
            const bytes_to_copy = @min(remaining, Z_P);
            @memcpy(buffer[bytes_read..][0..bytes_to_copy], current_page.page.data[0..bytes_to_copy]);

            bytes_read += bytes_to_copy;
            remaining -= bytes_to_copy;
            span.trace("Copied {d} bytes from page, {d} bytes remaining", .{ bytes_to_copy, remaining });
        }

        if (size <= 64) {
            span.trace("Read data (cross-page): {any}", .{std.fmt.fmtSliceHexLower(buffer)});
        } else {
            span.trace("First 64 bytes (cross-page): {any}", .{std.fmt.fmtSliceHexLower(buffer[0..@min(64, size)])});
        }
        span.debug("Successfully read {d} bytes across multiple pages", .{size});

        return .{ .buffer = buffer, .allocator = self.allocator };
    }

    pub fn readSliceOwned(self: *Memory, address: u32, size: usize) ![]const u8 {
        const slice = try self.readSlice(address, size);
        // either was already owned, and otherwise we dupe
        if (slice.allocator) |_| {
            return slice.buffer;
        } else {
            return self.allocator.dupe(u8, slice.buffer);
        }
    }

    /// Write a slice to memory, supporting cross-page writes
    pub fn writeSlice(self: *Memory, address: u32, slice: []const u8) !void {
        const span = trace.span(@src(), .memory_write_slice);
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

        // Support cross-page writes
        if (end_offset > Z_P) {
            span.trace("Cross-page write detected - splitting write across pages", .{});

            // Write to first page (remaining bytes in current page)
            const first_page_bytes = Z_P - offset;
            @memcpy(page.page.data[offset..Z_P], slice[0..first_page_bytes]);
            span.trace("Wrote {d} bytes to first page at offset 0x{X}", .{ first_page_bytes, offset });

            // Write remaining bytes to subsequent pages
            var remaining_slice = slice[first_page_bytes..];
            var current_address = page.page.address + Z_P;

            while (remaining_slice.len > 0) {
                // Find or create the next page
                const next_page = self.page_table.findPageOfAddresss(current_address) orelse {
                    span.err("Page fault during cross-page write at address 0x{X:0>8}", .{current_address});
                    self.last_violation = ViolationInfo{
                        .violation_type = .NonAllocated,
                        .address = current_address,
                        .attempted_size = remaining_slice.len,
                        .page = null,
                    };
                    return Error.PageFault;
                };

                // Check write permissions on subsequent page
                if (next_page.page.flags == .ReadOnly) {
                    span.err("Write protection violation during cross-page write at 0x{X:0>8}", .{current_address});
                    self.last_violation = ViolationInfo{
                        .violation_type = .WriteProtection,
                        .address = current_address,
                        .attempted_size = remaining_slice.len,
                        .page = next_page.page,
                    };
                    return Error.PageFault;
                }

                // Write to this page
                const bytes_to_write = @min(remaining_slice.len, Z_P);
                @memcpy(next_page.page.data[0..bytes_to_write], remaining_slice[0..bytes_to_write]);
                span.trace("Wrote {d} bytes to page at 0x{X:0>8}", .{ bytes_to_write, current_address });

                // Update for next iteration
                remaining_slice = remaining_slice[bytes_to_write..];
                current_address += Z_P;
            }

            span.debug("Successfully completed cross-page write of {d} bytes", .{slice.len});
        } else {
            // Single page write
            @memcpy(page.page.data[offset..][0..slice.len], slice);
            span.debug("Successfully wrote {d} bytes within single page", .{slice.len});
        }

        if (slice.len <= 64) {
            span.trace("Written data: {any}", .{std.fmt.fmtSliceHexLower(slice)});
        } else {
            span.trace("First 64 bytes: {any}", .{std.fmt.fmtSliceHexLower(slice[0..@min(64, slice.len)])});
        }
    }

    /// Initilialize a slice to memory not cross-page, will err on cross page
    /// access. Does not check ReadWrite permissions can also write to ReadOnly
    /// segments.
    pub fn initMemory(self: *Memory, address: u32, slice: []const u8) !void {
        const span = trace.span(@src(), .memory_init_data);
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
        const span = trace.span(@src(), .memory_write);
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
        return self.readInt(u8, address);
    }

    pub fn readU16(self: *Memory, address: u32) !u16 {
        return self.readInt(u16, address);
    }

    pub fn readU32(self: *Memory, address: u32) !u32 {
        return self.readInt(u32, address);
    }

    pub fn readU64(self: *Memory, address: u32) !u64 {
        return self.readInt(u64, address);
    }

    pub fn writeU8(self: *Memory, address: u32, value: u8) !void {
        return self.writeInt(u8, address, value);
    }

    pub fn writeU16(self: *Memory, address: u32, value: u16) !void {
        return self.writeInt(u16, address, value);
    }

    pub fn writeU32(self: *Memory, address: u32, value: u32) !void {
        return self.writeInt(u32, address, value);
    }

    pub fn writeU64(self: *Memory, address: u32, value: u64) !void {
        return self.writeInt(u64, address, value);
    }

    /// Returns a snapshot of memory organized as individual pages.
    /// Each returned region represents exactly one page (Z_P = 4KB) of memory.
    /// The caller owns the returned memory and must free it.
    pub fn getMemorySnapshot(self: *Memory, allocator: Allocator) !types.MemorySnapShot {
        const span = trace.span(@src(), .memory_snapshot);
        defer span.deinit();
        span.debug("Creating memory snapshot with {d} pages", .{self.page_table.pages.items.len});

        var regions = std.ArrayList(types.MemoryRegion).init(allocator);
        errdefer {
            for (regions.items) |region| {
                allocator.free(region.data);
            }
            regions.deinit();
        }

        // Iterate through all pages in the page table
        for (self.page_table.pages.items) |page| {
            span.trace("Snapshotting page at address 0x{X:0>8}", .{page.address});

            // Duplicate the page data for the snapshot
            const page_data = try allocator.dupe(u8, page.data);
            errdefer allocator.free(page_data);

            // Create memory region for this page
            try regions.append(.{
                .address = page.address,
                .data = page_data,
                .writable = page.flags == .ReadWrite,
            });
        }

        span.debug("Created memory snapshot with {d} regions", .{regions.items.len});
        return .{ .regions = try regions.toOwnedSlice() };
    }

    pub fn deinit(self: *Memory) void {
        const span = trace.span(@src(), .memory_deinit);
        defer span.deinit();

        self.page_table.deinit();
        self.* = undefined;
    }

    pub fn getLastViolation(self: *const Memory) ?ViolationInfo {
        return self.last_violation;
    }
};
