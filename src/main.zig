const std = @import("std");
const database = @import("database.zig");
const navigation = @import("navigation.zig");
const assert = std.debug.assert;
const eql = std.mem.eql;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub fn main() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = database.DB.init(alloc) catch unreachable;
    defer db.deinit();

    // How come some parts of the ways get skipped?
    //     Does the database get overridden?
    //
    std.debug.print("start queries\n", .{});
    const nav_quiet = navigation.findPath(
        alloc,
        &db,
        0.0,
        1.0,
        4.51541,
        51.92629,
        4.51137,
        51.92872,
    ) catch unreachable;
    std.debug.print("Fussy Nav (optimize peace): {any}\n", .{nav_quiet});
    std.debug.print("Node amount {}\n", .{nav_quiet.len});
    for (nav_quiet) |node| {
        std.debug.print("[{},{}],", .{ node.lon, node.lat });
    }
    std.debug.print("\n", .{});
    // PERF: pre-calculate time & fuss modifiers per way, avoid fetching tags for navigation
    // also use this to remove any invalid roads
}
