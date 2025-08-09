const std = @import("std");

pub fn main() !void {
    // Read version.zig file and extract the version numbers
    const allocator = std.heap.page_allocator;
    const file = try std.fs.cwd().openFile("src/version.zig", .{});
    defer file.close();
    
    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);
    
    // Parse for GRAYPAPER_VERSION
    var major: u8 = 0;
    var minor: u8 = 0;
    var patch: u8 = 0;
    
    // Look for .major = X,
    if (std.mem.indexOf(u8, content, ".major = ")) |major_pos| {
        const start = major_pos + 9;
        const end = std.mem.indexOfPos(u8, content, start, ",") orelse content.len;
        major = try std.fmt.parseInt(u8, std.mem.trim(u8, content[start..end], " \t\n"), 10);
    }
    
    // Look for .minor = X,
    if (std.mem.indexOf(u8, content, ".minor = ")) |minor_pos| {
        const start = minor_pos + 9;
        const end = std.mem.indexOfPos(u8, content, start, ",") orelse content.len;
        minor = try std.fmt.parseInt(u8, std.mem.trim(u8, content[start..end], " \t\n"), 10);
    }
    
    // Look for .patch = X,
    if (std.mem.indexOf(u8, content, ".patch = ")) |patch_pos| {
        const start = patch_pos + 9;
        const end = std.mem.indexOfPos(u8, content, start, ",") orelse content.len;
        patch = try std.fmt.parseInt(u8, std.mem.trim(u8, content[start..end], " \t\n"), 10);
    }
    
    const stdout = std.io.getStdOut().writer();
    try stdout.print("v{d}.{d}.{d}\n", .{major, minor, patch});
}