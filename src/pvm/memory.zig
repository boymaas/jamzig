const std = @import("std");
const Allocator = std.mem.Allocator;

const trace = @import("../tracing.zig").scoped(.pvm);

pub const Memory = struct {
    // Memory layout constants moved into Memory struct
    pub const Z_Z: u32 = 0x10000; // 2^16 = 65,536 - Major zone size
    pub const Z_P: u32 = 0x1000; // 2^12 = 4,096 - Page size
    pub const Z_I: u32 = 0x1000000; // 2^24 - Standard input data size

    // Memory section addresses
    pub const READ_ONLY_BASE_ADDRESS: u32 = Z_Z;
    pub fn HEAP_BASE_ADDRESS(code_size: u32) u32 {
        return 2 * Z_Z + code_size;
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

    // Encapsulated memory section configuration
    pub const Section = struct {
        address: u32,
        size: usize,
        state: AccessState,
        data: ?[]const u8,

        pub fn init(address: u32, size: usize, data: ?[]const u8, state: AccessState) Section {
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
            stack_size: u24,
            heap_size_in_pages: u16,
        ) !Layout {
            return .{
                .read_only = Section.init(
                    READ_ONLY_BASE_ADDRESS,
                    try std.math.divCeil(usize, read_only.len * Z_P, Z_P), // ALIGN TO PAGE
                    read_only,
                    .ReadOnly,
                ),
                .heap = Section.init(
                    HEAP_BASE_ADDRESS(@as(u32, @intCast(read_only.len))),
                    heap_size_in_pages * Z_P,
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
                    STACK_ADDRESS - (Z_P * try std.math.divCeil(u24, stack_size, Z_P)),
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
        var page_maps = std.ArrayList(PageMap).init(allocator);
        errdefer {
            for (page_maps.items) |page| {
                allocator.free(page.data);
            }
            page_maps.deinit();
        }

        // Add sections in order, but only allocate for sections with data
        inline for (.{ layout.read_only, layout.heap, layout.input, layout.stack }) |section| {
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
        for (self.page_maps) |*page| {
            if (address >= page.address and address < page.address + page.length) {
                if (page.state != .ReadWrite) return error.WriteProtected;

                // Lazy allocation on first write
                // TODO: figure out how to actually do this

                const offset = address - page.address;
                if (offset + data.len > page.length) return error.OutOfBounds;
                return;
            }
        }
        return error.PageFault;
    }

    pub fn read(self: *const Memory, address: u32, size: usize) ![]const u8 {
        for (self.page_maps) |page| {
            if (address >= page.address and address < page.address + page.length) {
                if (page.state == .Inaccessible) return error.AccessViolation;

                const offset = address - page.address;
                if (offset + size > page.length) return error.OutOfBounds;

                // For unallocated pages, return zeros
                if (page.data.len < offset + size) {
                    return error.NonAllocatedMemoryAccess; // TODO: handle this
                }

                return page.data[offset .. offset + size];
            }
        }
        return error.PageFault;
    }

    pub fn deinit(self: *Memory) void {
        for (self.page_maps) |page| {
            self.allocator.free(page.data);
        }
        self.allocator.free(self.page_maps);
        self.* = undefined;
    }

    pub fn initSection(self: *Memory, address: u32, data: []const u8) !void {
        for (self.page_maps) |*page| {
            if (page.address == address) {
                if (data.len > page.length) return error.OutOfBounds;
                if (page.data.len > 0) {
                    self.allocator.free(page.data);
                }
                page.data = try self.allocator.dupe(u8, data);
                return;
            }
        }
        return error.SectionNotFound;
    }

    pub fn initSectionByName(self: *Memory, section: enum {
        read_only,
        heap,
        input,
        stack,
    }, data: []const u8) !void {
        const address = switch (section) {
            .read_only => self.layout.read_only.address,
            .heap => @panic("heap cannot be initialized"),
            .input => self.layout.input.address,
            .stack => @panic("stack cannot be initialized"),
        };
        try self.initSection(address, data);
    }
};
