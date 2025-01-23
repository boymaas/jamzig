const std = @import("std");
const Allocator = std.mem.Allocator;

const trace = @import("../tracing.zig").scoped(.pvm);

pub const Memory = struct {
    // Memory layout constants moved into Memory struct
    pub const Z_Z: u32 = 0x10000; // 2^16 = 65,536 - Major zone size
    pub const Z_P: u32 = 0x1000; // 2^12 = 4,096 - Page size
    pub const Z_I: u32 = 0x1000000; // 2^24 - Standard input data size

    pub const Error = error{
        OutOfBounds,
        PageFault,
        AccessViolation,
        WriteProtected,
    };

    pub fn isMemoryError(err: anyerror) bool {
        const memory_errors = comptime std.meta.fields(Error);
        inline for (memory_errors) |e| {
            if (err == @field(Memory.Error, e.name)) {
                return true;
            }
        }
        return false;
    }

    // Memory section addresses
    pub const READ_ONLY_BASE_ADDRESS: u32 = Z_Z;
    pub fn HEAP_BASE_ADDRESS(read_only_size: u32) !u32 {
        return 2 * Z_Z + try std.math.divCeil(u32, read_only_size * Z_Z, Z_Z);
    }
    pub const INPUT_ADDRESS: u32 = 0xFFFFFFFF - Z_Z - Z_I;
    pub const STACK_ADDRESS: u32 = 0xFFFFFFFF - Z_Z;

    pub const PageMap = struct {
        address: u32,
        length: u32,
        state: AccessState,
        data: []u8,
    };

    // AccessSate
    pub const AccessState = enum {
        /// Memory region is readable only
        ReadOnly,
        /// Memory region is readable and writable
        ReadWrite,
        /// Memory region cannot be accessed
        Inaccessible,
    };

    pub const Section = struct {
        address: u32,
        size: usize,
        state: AccessState,
        data: ?[]const u8,

        pub fn init(address: u32, size: usize, data: ?[]const u8, state: AccessState) Section {
            const span = trace.span(.section_init);
            defer span.deinit();

            span.debug("Initializing memory section", .{});
            span.trace("address: 0x{x}, size: {}, state: {s}", .{ address, size, @tagName(state) });

            return .{
                .address = address,
                .size = size,
                .state = state,
                .data = data,
            };
        }
    };

    // Standard memory layout configuration
    pub const Layout = struct {
        read_only: Section,
        heap: Section,
        input: Section,
        stack: Section,

        pub fn standard(
            read_only: []const u8,
            read_write: []const u8,
            input: []const u8,
            stack_size_in_bytes: u24,
            heap_size_in_pages: u16,
        ) !Layout {
            const span = trace.span(.layout_standard);
            defer span.deinit();

            span.debug("Creating standard memory layout", .{});
            span.trace("RO size: {}, RW size: {}, Input size: {}, Stack size: {}, Heap pages: {}", .{ read_only.len, read_write.len, input.len, stack_size_in_bytes, heap_size_in_pages });

            return .{
                .read_only = Section.init(
                    READ_ONLY_BASE_ADDRESS,
                    try std.math.divCeil(usize, read_only.len * Z_P, Z_P),
                    read_only,
                    .ReadOnly,
                ),
                .heap = Section.init(
                    try HEAP_BASE_ADDRESS(@as(u32, @intCast(read_only.len))),
                    heap_size_in_pages * Z_P + try std.math.divCeil(usize, read_write.len * Z_P, Z_P),
                    read_write,
                    .ReadWrite,
                ),
                .input = Section.init(
                    INPUT_ADDRESS,
                    try std.math.divCeil(usize, input.len * Z_P, Z_P),
                    input,
                    .ReadOnly,
                ),
                .stack = Section.init(
                    STACK_ADDRESS - try std.math.divCeil(u32, Z_P * @as(u32, stack_size_in_bytes), Z_P),
                    Z_Z,
                    null,
                    .ReadWrite,
                ),
            };
        }
    };

    layout: Layout,
    page_maps: []PageMap,
    allocator: Allocator,

    pub fn init(allocator: Allocator, layout: Layout) !Memory {
        const span = trace.span(.memory_init);
        defer span.deinit();

        span.debug("Initializing memory system", .{});

        var page_maps = std.ArrayList(PageMap).init(allocator);
        errdefer {
            span.debug("Cleaning up after initialization error", .{});
            for (page_maps.items) |page| {
                allocator.free(page.data);
            }
            page_maps.deinit();
        }

        // Add sections in order
        inline for (.{ layout.read_only, layout.heap, layout.input, layout.stack }) |section| {
            const section_span = span.child(.section_alloc);
            defer section_span.deinit();

            section_span.debug("Allocating section at 0x{x}", .{section.address});
            section_span.trace("Size: {}, State: {s}", .{ section.size, @tagName(section.state) });

            try page_maps.append(.{
                .address = section.address,
                .length = @intCast(section.size),
                .state = section.state,
                .data = try allocator.alloc(u8, section.size),
            });
        }

        return Memory{
            .page_maps = try page_maps.toOwnedSlice(),
            .layout = layout,
            .allocator = allocator,
        };
    }

    pub fn write(self: *Memory, address: u32, data: []const u8) !void {
        const span = trace.span(.memory_write);
        defer span.deinit();

        span.debug("Writing to memory", .{});
        span.trace("Address: 0x{x}, Data length: {}", .{ address, data.len });
        span.trace("Data: {any}", .{std.fmt.fmtSliceHexLower(data)});

        for (self.page_maps) |*page| {
            if (address >= page.address and address < page.address + page.length) {
                if (page.state != .ReadWrite) {
                    span.err("Write protection violation at 0x{x}", .{address});
                    return Error.WriteProtected;
                }

                const offset = address - page.address;
                if (offset + data.len > page.length) {
                    span.err("Write operation exceeds bounds at 0x{x} - bounds: [0x{x}..0x{x}], overflow: {d} bytes", .{
                        address,
                        page.address,
                        page.address + page.length,
                        (offset + data.len) - page.length,
                    });
                    return Error.PageFault;
                }

                span.debug("Write operation completed successfully", .{});
                return;
            }
        }

        span.err("Page fault on write to 0x{x}", .{address});
        return error.PageFault;
    }

    pub fn read(self: *const Memory, address: u32, size: usize) ![]const u8 {
        const span = trace.span(.memory_read);
        defer span.deinit();

        span.debug("Reading from memory", .{});
        span.trace("Address: 0x{x}, Size: {}", .{ address, size });

        for (self.page_maps) |page| {
            if (address >= page.address and address < page.address + page.length) {
                if (page.state == .Inaccessible) {
                    span.err("Access violation at 0x{x}", .{address});
                    return Error.AccessViolation;
                }

                const offset = address - page.address;
                if (offset + size > page.length) {
                    span.err("Read operation exceeds bounds at 0x{x} - bounds: [0x{x}..0x{x}], overflow: {d} bytes", .{
                        address,
                        page.address,
                        page.address + page.length,
                        (offset + size) - page.length,
                    });
                    return Error.PageFault;
                }

                if (page.data.len < offset + size) {
                    span.err("Attempt to read non-allocated memory at 0x{x}", .{address});
                    return error.NonAllocatedMemoryAccess;
                }

                const data = page.data[offset .. offset + size];
                span.trace("Read data: {any}", .{std.fmt.fmtSliceHexLower(data)});
                span.debug("Read operation completed successfully", .{});
                return data;
            }
        }

        span.err("Page fault on read from 0x{x}", .{address});
        return Error.PageFault;
    }

    pub fn deinit(self: *Memory) void {
        const span = trace.span(.memory_deinit);
        defer span.deinit();

        span.debug("Deinitializing memory system", .{});

        for (self.page_maps) |page| {
            span.trace("Freeing page at 0x{x}, size: {}", .{ page.address, page.data.len });
            self.allocator.free(page.data);
        }
        self.allocator.free(self.page_maps);
        self.* = undefined;
    }

    pub fn initSection(self: *Memory, address: u32, data: []const u8) Error!void {
        const span = trace.span(.init_section);
        defer span.deinit();

        span.debug("Initializing section data", .{});
        span.trace("Address: 0x{x}, Data length: {}", .{ address, data.len });
        span.trace("Data: {any}", .{std.fmt.fmtSliceHexLower(data)});

        for (self.page_maps) |*page| {
            if (page.address == address) {
                if (data.len > page.length) {
                    span.err("Section data exceeds bounds", .{});
                    return error.OutOfBounds;
                }
                if (page.data.len > 0) {
                    span.debug("Freeing existing section data", .{});
                    self.allocator.free(page.data);
                }
                page.data = try self.allocator.dupe(u8, data);
                span.debug("Section initialized successfully", .{});
                return;
            }
        }

        span.err("Section not found at address 0x{x}", .{address});
        return error.SectionNotFound;
    }

    pub fn initSectionByName(self: *Memory, section: enum {
        read_only,
        heap,
        input,
        stack,
    }, data: []const u8) !void {
        const span = trace.span(.init_section_by_name);
        defer span.deinit();

        span.debug("Initializing named section: {s}", .{@tagName(section)});
        span.trace("Data length: {}", .{data.len});

        const address = switch (section) {
            .read_only => self.layout.read_only.address,
            .heap => {
                span.err("Cannot initialize heap section", .{});
                @panic("heap cannot be initialized");
            },
            .input => self.layout.input.address,
            .stack => {
                span.err("Cannot initialize stack section", .{});
                @panic("stack cannot be initialized");
            },
        };
        try self.initSection(address, data);
    }
};
