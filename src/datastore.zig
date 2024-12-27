const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const OsmNode = struct {
    id: i64,
    lat: f64,
    lon: f64,
    ways: []u64 = &.{},
};

pub const Branch = struct {
    nw: *TreeNode, // north-West
    ne: *TreeNode, // north-East
    sw: *TreeNode, // south-West
    se: *TreeNode, // south-East
    split_lat: f64,
    split_lon: f64,
};

pub const TreeNodeType = enum { BranchNode, LeafNode };
pub const TreeNode = union(TreeNodeType) {
    BranchNode: Branch,
    LeafNode: ArrayList(OsmNode),

    pub fn format(
        self: TreeNode,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        switch (self) {
            .BranchNode => |branch| {
                try writer.print("Branch(split: ({}, {}), children: [NE: {}, NW: {}, SE: {}, SW: {}])", .{ branch.split_lat, branch.split_lon, branch.ne, branch.nw, branch.se, branch.sw });
            },
            .LeafNode => |leaf| {
                try writer.print("Leaf({} items)", .{leaf.items.len});
            },
        }
    }

    //
    pub fn insertIntoTree(self: *TreeNode, allocator: Allocator, node: OsmNode) !void {
        var parent = self;

        while (true) {
            switch (parent.*) {
                //
                .LeafNode => |leaf| { // TODO: this should be when the actual nodes are read
                    if (leaf.items.len < 64) {
                        try parent.LeafNode.append(node);
                        return;
                    } else { // leaf is full, divide it into 4 areas
                        assert(leaf.items.len == 64);
                        // find average lat & lon, determines where to split
                        var lat_total: f64 = 0;
                        var lon_total: f64 = 0;
                        for (leaf.items) |item| {
                            lat_total += item.lat;
                            lon_total += item.lon;
                        }
                        const lat_avg = lat_total / 64;
                        const lon_avg = lon_total / 64;

                        // heap-allocate 4 leaf nodes
                        var leaves = try allocator.alloc(TreeNode, 4);
                        leaves[0] = .{ .LeafNode = ArrayList(OsmNode).init(allocator) };
                        leaves[1] = .{ .LeafNode = ArrayList(OsmNode).init(allocator) };
                        leaves[2] = .{ .LeafNode = ArrayList(OsmNode).init(allocator) };
                        leaves[3] = .{ .LeafNode = ArrayList(OsmNode).init(allocator) };
                        var leaf_ne = &leaves[0];
                        var leaf_nw = &leaves[1];
                        var leaf_se = &leaves[2];
                        var leaf_sw = &leaves[3];

                        // push nodes into relevant leaves
                        for (leaf.items) |item| {
                            if (item.lat > lat_avg) { // north
                                if (item.lon > lon_avg) { // east
                                    try leaf_ne.LeafNode.append(item);
                                } else { // west
                                    try leaf_nw.LeafNode.append(item);
                                }
                            } else { // south
                                if (item.lon > lon_avg) { // east
                                    try leaf_se.LeafNode.append(item);
                                } else { // west
                                    try leaf_sw.LeafNode.append(item);
                                }
                            }
                        }
                        assert(leaf_ne.LeafNode.items.len <= 64);
                        assert(leaf_nw.LeafNode.items.len <= 64);
                        assert(leaf_se.LeafNode.items.len <= 64);
                        assert(leaf_sw.LeafNode.items.len <= 64);

                        // replace self with a branch node, has previously created leaves as children
                        parent.LeafNode.deinit();
                        parent.* = .{ .BranchNode = .{
                            .ne = leaf_ne,
                            .nw = leaf_nw,
                            .se = leaf_se,
                            .sw = leaf_sw,
                            .split_lat = lat_avg,
                            .split_lon = lon_avg,
                        } };
                        return;
                    }
                },
                // find which area the node fits into, set is as parents for next search
                .BranchNode => |branch| {
                    if (node.lat > branch.split_lat) { // north
                        if (node.lon > branch.split_lon) { // east
                            parent = branch.ne;
                        } else { // west
                            parent = branch.nw;
                        }
                    } else { // south
                        if (node.lon > branch.split_lon) { // east
                            parent = branch.se;
                        } else { // west
                            parent = branch.sw;
                        }
                    }
                },
            }
        }
    }

    pub fn getInArea(self: *TreeNode, allocator: Allocator, north: f64, east: f64, south: f64, west: f64) !void {
        // Because an area can span multiple leaves, keep a stack of all branches to traverse
        var branches = ArrayList(*TreeNode).init(allocator);
        var nodes = ArrayList(OsmNode).init(allocator);
        var parent: ?(*TreeNode) = self;
        while (parent != null) {
            switch (parent.?.*) {
                .LeafNode => |leaf| {
                    // PERF: If leaf is fully enclosed in area, skip per-node if-statements
                    //     Fully enclosed when it has traversed all four directions at some point
                    //     E.g. root -> NE -> NW -> SE -> SE -> SW
                    for (leaf.items) |node| {
                        // append all nodes within given area
                        const within_north = node.lat < north;
                        const within_south = node.lat > south;
                        const within_west = node.lon > west;
                        const within_east = node.lon < east;
                        if (within_north and within_south and within_west and within_east) {
                            try nodes.append(node);
                        }
                    }
                },
                .BranchNode => |branch| {
                    // add all branches that touch the given area
                    // can append 1, 2 or 4 branches
                    if (north > branch.split_lat) { // north
                        if (east > branch.split_lon) { // east
                            try branches.append(branch.ne);
                            std.debug.print("append NE\n", .{});
                        }
                        if (west < branch.split_lon) { // west
                            try branches.append(branch.nw);
                            std.debug.print("append NW\n", .{});
                        }
                    }
                    if (south < branch.split_lat) { // south
                        if (east > branch.split_lon) { // east
                            try branches.append(branch.se);
                            std.debug.print("append SE\n", .{});
                        }
                        if (west < branch.split_lon) { // west
                            try branches.append(branch.sw);
                            std.debug.print("append SW\n", .{});
                        }
                    }
                },
            }
            parent = branches.popOrNull();
        }
        std.debug.print("Nodes: {}\n", .{nodes.items.len});
    }
};

fn serializeValue(buffer: []u8, value: anytype, offset: u64) void {
    const ValueType = @TypeOf(value);
    var buffer_typed = std.mem.bytesAsSlice(ValueType, buffer[offset..]);
    buffer_typed[0] = value;
}

fn deserializeValue(T: type, buffer: []const u8, offset: u64) T {
    return std.mem.bytesAsSlice(T, buffer[offset..])[0];
}

pub fn serializeOsmNode(allocator: Allocator, node: OsmNode) []const u8 {
    const buffer = allocator.alloc(u8, 24) catch unreachable;
    serializeValue(buffer, node.id, 0);
    serializeValue(buffer, node.lat, 8);
    serializeValue(buffer, node.lon, 16);
    return buffer;
}

pub fn deserializeOsmNode(buffer: []const u8) OsmNode {
    return .{
        .id = deserializeValue(i64, buffer, 0),
        .lat = deserializeValue(f64, buffer, 8),
        .lon = deserializeValue(f64, buffer, 16),
    };
}

test "serialize node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const node: OsmNode = .{
        .id = 66400,
        .lat = 40.0,
        .lon = -320.023,
    };

    const serialized = serializeOsmNode(alloc, node);

    assert(deserializeValue(i64, serialized, 0) == 66400);
}

test "construct quadtree from slice of nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var root: TreeNode = .{ .LeafNode = ArrayList(OsmNode).init(allocator) };

    var prng = std.rand.DefaultPrng.init(2);
    const rand = prng.random();

    for (0..4096) |i| {
        const node = .{
            .id = @as(i64, @intCast(i)),
            .lat = rand.float(f64) * 100,
            .lon = rand.float(f64) * 100,
        };
        try root.insertIntoTree(allocator, node);
    }

    std.debug.print("RESULT: {}\n", .{root});

    try root.getInArea(allocator, 50, 50, 0, 0);
}
