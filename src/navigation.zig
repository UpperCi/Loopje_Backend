const database = @import("database.zig");
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

// one edge per connection or per direction?
// - One-way? Is this relevant for foot traffic?
// - What's easier to read? Easier to write? Less data?
// Write: slightly easier per direction
//  Read: easier per direction
//  Data: less per connection, though A* is not vectorizable anyway?

pub const NavEdge = struct {
    cost_time: f64,
    node_target: i64,
};

pub fn construct_navigation_graph(allocator: Allocator, ways: []const database.OsmWay) void {}
