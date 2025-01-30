const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const StringHashMap = std.hash_map.StringHashMap;
const AutoHashMap = std.hash_map.AutoHashMap;

// TODO: generic b-tree?
// Would allow for fast tag-lookups

pub const OsmTag = struct {
    key: []u8,
    value: []u8,
};

// only used during quadtree construction
pub const OsmWay = struct {
    id: i64,
    visible: bool = true,
    tags: []OsmTag,
};

pub const OsmNode = struct {
    id: i64,
    lat: f64,
    lon: f64,
    ways: []*const OsmWay = &.{},
};

pub const Branch = struct {
    nw: *QuadTreeNode, // north-west
    ne: *QuadTreeNode, // north-east
    sw: *QuadTreeNode, // south-west
    se: *QuadTreeNode, // south-east
    split_lat: f64,
    split_lon: f64,
};

const leaf_capacity = 64;

pub const QueryError = error{
    NotFound,
};

pub const Datastore = struct {
    root: *QuadTreeNode,
    allocator: Allocator,

    pub fn init(allocator: Allocator) !Datastore {
        const root = try allocator.create(QuadTreeNode);
        root.* = .{ .LeafNode = ArrayList(OsmNode).init(allocator) };
        return .{ .root = root, .allocator = allocator };
    }

    pub fn insertNode(self: Datastore, allocator: Allocator, node: OsmNode) !void {
        var parent = self.root;

        while (true) {
            switch (parent.*) {
                // find which area the node fits into, set it as parent for next search
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
                .LeafNode => |leaf| {
                    if (leaf.items.len < leaf_capacity) {
                        try parent.LeafNode.append(node);
                        return;
                    } else { // leaf is full, divide it into 4 areas
                        assert(leaf.items.len == leaf_capacity);
                        try parent.LeafNode.append(node);
                        // find average lat & lon, determines where to split
                        var lat_total: f64 = 0;
                        var lon_total: f64 = 0;
                        for (leaf.items) |item| {
                            lat_total += item.lat;
                            lon_total += item.lon;
                        }
                        const lat_avg = lat_total / leaf_capacity;
                        const lon_avg = lon_total / leaf_capacity;

                        // heap-allocate 4 leaf nodes
                        var leaves = try allocator.alloc(QuadTreeNode, 4);
                        leaves[0] = .{ .LeafNode = ArrayList(OsmNode).init(self.allocator) };
                        leaves[1] = .{ .LeafNode = ArrayList(OsmNode).init(self.allocator) };
                        leaves[2] = .{ .LeafNode = ArrayList(OsmNode).init(self.allocator) };
                        leaves[3] = .{ .LeafNode = ArrayList(OsmNode).init(self.allocator) };
                        var leaf_ne = &leaves[0];
                        var leaf_nw = &leaves[1];
                        var leaf_se = &leaves[2];
                        var leaf_sw = &leaves[3];

                        // insert current node as well

                        // push nodes into relevant leaves
                        for (parent.LeafNode.items) |item| {
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

                        assert(leaf_ne.LeafNode.items.len <= leaf_capacity);
                        assert(leaf_nw.LeafNode.items.len <= leaf_capacity);

                        // FIX: assert fails for south-holland.osm
                        assert(leaf_se.LeafNode.items.len <= leaf_capacity);
                        assert(leaf_sw.LeafNode.items.len <= leaf_capacity);

                        // replace self with a branch node that has previously created leaves as children
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
            }
        }
    }

    // returns nodes, including connected ways
    pub fn getInArea(
        self: Datastore,
        allocator: Allocator,
        north: f64,
        east: f64,
        south: f64,
        west: f64,
    ) ![]OsmNode {
        // Because an area can span multiple leaves, keep a stack of all branches to traverse
        var nodes = ArrayList(OsmNode).init(allocator);
        var branches = ArrayList(*QuadTreeNode).init(allocator);
        var parent: ?(*QuadTreeNode) = self.root;
        while (parent != null) {
            switch (parent.?.*) {
                .BranchNode => |branch| {
                    // add all branches that touch the given area
                    // can append 1, 2 or 4 branches
                    if (north > branch.split_lat) { // north
                        if (east > branch.split_lon) { // east
                            try branches.append(branch.ne);
                        }
                        if (west < branch.split_lon) { // west
                            try branches.append(branch.nw);
                        }
                    }
                    if (south < branch.split_lat) { // south
                        if (east > branch.split_lon) { // east
                            try branches.append(branch.se);
                        }
                        if (west < branch.split_lon) { // west
                            try branches.append(branch.sw);
                        }
                    }
                },
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
            }
            parent = branches.popOrNull();
        }
        return nodes.toOwnedSlice();
    }

    pub fn insertWaysBatch(self: Datastore, allocator: Allocator, ways_map: AutoHashMap(i64, ArrayList(*const OsmWay))) !void {
        var parent: ?(*const QuadTreeNode) = self.root;
        var branches = ArrayList(*QuadTreeNode).init(allocator);

        while (parent != null) {
            switch (parent.?.*) {
                .BranchNode => |branch| {
                    try branches.append(branch.ne);
                    try branches.append(branch.nw);
                    try branches.append(branch.se);
                    try branches.append(branch.sw);
                },
                .LeafNode => |leaf| {
                    for (leaf.items) |*node| {
                        const ways = ways_map.get(node.id);
                        if (ways != null) {
                            var list = ArrayList(*const OsmWay).fromOwnedSlice(allocator, node.ways);
                            for (ways.?.items) |way_ref| {
                                try list.append(way_ref);
                            }
                            node.ways = try list.toOwnedSlice();
                        }
                    }
                },
            }
            parent = branches.popOrNull();
        }

        // TODO: store tags per way
    }

    // just searches all nodes in all leaves
    // PERF: B-tree sorted by ids would massively speed up lookup
    pub fn getById(self: Datastore, allocator: Allocator, id: i64) !*OsmNode {
        var branches = ArrayList(*QuadTreeNode).init(allocator);
        var parent: ?(*const QuadTreeNode) = self.root;
        while (parent != null) {
            switch (parent.?.*) {
                .BranchNode => |branch| {
                    try branches.append(branch.ne);
                    try branches.append(branch.nw);
                    try branches.append(branch.se);
                    try branches.append(branch.sw);
                },
                .LeafNode => |leaf| {
                    for (leaf.items) |*node| {
                        if (node.id == id) {
                            return node;
                        }
                    }
                },
            }
            parent = branches.popOrNull();
        }
        return QueryError.NotFound;
    }
};

pub const QuadTreeNodeType = enum { BranchNode, LeafNode };
pub const QuadTreeNode = union(QuadTreeNodeType) {
    BranchNode: Branch,
    LeafNode: ArrayList(OsmNode),

    pub fn format(
        self: QuadTreeNode,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        switch (self) {
            .BranchNode => |branch| {
                try writer.print(
                    "Branch(split: ({}, {}), children: [NE: {}, NW: {}, SE: {}, SW: {}])",
                    .{
                        branch.split_lat,
                        branch.split_lon,
                        branch.ne,
                        branch.nw,
                        branch.se,
                        branch.sw,
                    },
                );
            },
            .LeafNode => |leaf| {
                try writer.print("Leaf({} items)", .{leaf.items.len});
            },
        }
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
        .lon = -321.123,
    };

    const serialized = serializeOsmNode(alloc, node);

    assert(deserializeValue(i64, serialized, 0) == 66400);
    // floats are asserted to be roughly equal
    assert(deserializeValue(f64, serialized, 8) > 39);
    assert(deserializeValue(f64, serialized, 8) < 41);
    assert(deserializeValue(f64, serialized, 16) > -323);
    assert(deserializeValue(f64, serialized, 16) < -320);
}

test "construct quadtree from slice of nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = try Datastore.init(allocator);

    var prng = std.rand.DefaultPrng.init(2);
    const rand = prng.random();

    for (0..100000) |i| {
        const node = .{
            .id = @as(i64, @intCast(i)),
            .lat = rand.float(f64) * 100,
            .lon = rand.float(f64) * 100,
        };
        try tree.insertNode(allocator, node);
    }

    {
        const start = std.time.milliTimestamp();
        for (0..1000) |i| {
            // takes 5-6ms per million nodes in tree
            // half as much in ReleaseFast
            _ = tree.getById(allocator, @as(i64, @intCast(i))) catch {
                std.debug.print("Err: {}\n", .{i});
            };
        }
        const end = std.time.milliTimestamp();
        std.debug.print("Millis node: {}\n", .{@as(f32, @floatFromInt(end - start)) / 1000});
    }

    std.debug.print("Searching...\n", .{});

    _ = try tree.getInArea(allocator, 50, 50, 0, 0);
}

test "construct datastore of nodes and tagged ways" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // var ways = ArrayList(OsmWay).init(allocator);
    var ways_index = AutoHashMap(i64, ArrayList(*const OsmWay)).init(allocator);
    // node_id -> way_index

    var tree = try Datastore.init(allocator);

    var prng = std.rand.DefaultPrng.init(2);
    const rand = prng.random();

    const node_count = 10000;
    const way_count = 10000;
    const way_length = 10;
    const way_tags = 5;

    for (0..node_count) |i| {
        const node = .{
            .id = @as(i64, @intCast(i)),
            .lat = rand.float(f64) * 100,
            .lon = rand.float(f64) * 100,
        };
        try tree.insertNode(allocator, node);
    }

    for (0..way_count) |i| {
        var tags = ArrayList(OsmTag).init(allocator);
        for (0..way_tags) |_| {
            const key = try allocator.alloc(u8, 8);
            const value = try allocator.alloc(u8, 16);
            rand.bytes(key);
            rand.bytes(value);
            try tags.append(.{ .key = key, .value = value });
        }

        const way = try allocator.create(OsmWay);
        way.* = .{
            .id = @as(i64, @intCast(i)),
            .tags = try tags.toOwnedSlice(),
        };

        for (0..way_length) |_| {
            const node_id: i64 = rand.uintAtMost(u63, node_count);
            var res = ways_index.get(node_id);
            if (res == null) {
                res = ArrayList(*const OsmWay).init(allocator);
            }
            try res.?.append(way);
            try ways_index.put(node_id, res.?);
        }
    }

    {
        const start = std.time.milliTimestamp();
        try tree.insertWaysBatch(allocator, ways_index);
        const end = std.time.milliTimestamp();
        // 36s in debug, 4s in release
        std.debug.print("Inserting 10k ways & 100k connections: {}ms\n", .{
            @as(f32, @floatFromInt(end - start)),
        });
    }

    {
        const start = std.time.milliTimestamp();
        const iters = 1000;
        for (0..iters) |i| {
            // takes 5-6ms per million nodes in tree
            // 2-3ms in ReleaseFast
            _ = tree.getById(allocator, @as(i64, @intCast(i))) catch {
                std.debug.print("Err: {}\n", .{i});
            };
        }
        const end = std.time.milliTimestamp();
        std.debug.print("Get {} nodes by id: {}ms\n", .{ iters, end - start });
    }

    std.debug.print("Searching...\n", .{});

    {
        var connections: u64 = 0;
        const nodes = try tree.getInArea(allocator, 50, 50, 0, 0);
        for (nodes) |node| {
            connections += node.ways.len;
        }
        std.debug.print("Connections per node: {} * 0.1 ({} / {})\n", .{
            connections * 10 / nodes.len,
            connections,
            nodes.len,
        });
    }

    {
        std.debug.print("Inspect random node, connections and tags\n", .{});
        const node_id: i64 = rand.uintAtMost(u63, node_count);
        const node = try tree.getById(allocator, node_id);
        std.debug.print("ID: {}, lat: {}, lon: {}\n", .{ node.id, node.lat, node.lon });
        for (node.ways) |way| {
            std.debug.print("    Way(ID: {}, tags: {})\n", .{ way.id, way.tags.len });
        }
    }
}
