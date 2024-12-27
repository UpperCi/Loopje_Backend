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
    nw: *TreeNode, // North-West
    ne: *TreeNode, // North-East
    sw: *TreeNode, // South-West
    se: *TreeNode, // South-East
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

pub fn insertIntoTreeNode(allocator: Allocator, node: OsmNode, root: *TreeNode) void {
    // stack of nodes
    // index of current child?
    //     or could u push all children to the stack at once?
    //     would u need a stack? U will end up at one node anyway
    var parent = root;
    // breaks when NW child is split (second split)
    // std.debug.print("Node: {}\n\n", .{root});
    while (true) {
        switch (parent.*) {
            //
            .LeafNode => |leaf| { // TODO: this should be when the actual nodes are read
                if (leaf.items.len < 64) {
                    parent.LeafNode.append(node) catch unreachable;
                    return;
                } else { // subdivide
                    // Get average lat & lon
                    var lat_total: f64 = 0;
                    var lon_total: f64 = 0;
                    for (leaf.items) |item| {
                        lat_total += item.lat;
                        lon_total += item.lon;
                    }
                    const lat_avg = lat_total / 64;
                    const lon_avg = lon_total / 64;

                    // Alloc 4 Leaf Nodes
                    var leaves = allocator.alloc(TreeNode, 4) catch unreachable;
                    leaves[0] = .{ .LeafNode = ArrayList(OsmNode).init(allocator) }; // ne
                    leaves[1] = .{ .LeafNode = ArrayList(OsmNode).init(allocator) }; // nw
                    leaves[2] = .{ .LeafNode = ArrayList(OsmNode).init(allocator) }; // se
                    leaves[3] = .{ .LeafNode = ArrayList(OsmNode).init(allocator) }; // sw
                    var leaf_ne = &leaves[0];
                    var leaf_nw = &leaves[1];
                    var leaf_se = &leaves[2];
                    var leaf_sw = &leaves[3];

                    // Push children into relevant leaves
                    for (leaf.items) |item| {
                        if (item.lat > lat_avg) { // north
                            if (item.lon > lon_avg) { // east
                                std.debug.print("Append North-East\n", .{});
                                leaf_ne.LeafNode.append(item) catch unreachable;
                            } else { // west
                                leaf_nw.LeafNode.append(item) catch unreachable;
                            }
                        } else { // south
                            if (item.lon > lon_avg) { // east
                                leaf_se.LeafNode.append(item) catch unreachable;
                            } else { // west
                                std.debug.print("Append South-West\n", .{});
                                leaf_sw.LeafNode.append(item) catch unreachable;
                            }
                        }
                    }

                    // Set self to branch node
                    parent.LeafNode.deinit();
                    parent.* = .{ .BranchNode = .{
                        .ne = leaf_ne,
                        .nw = leaf_nw,
                        .se = leaf_se,
                        .sw = leaf_sw,
                        .split_lat = lat_avg,
                        .split_lon = lon_avg,
                    } };
                    std.debug.print("New branch: {}\n", .{parent});
                    return;
                }
            },
            // check for closest leaf, then recurse with it
            // split_lat: f64,
            // split_lon: f64,
            .BranchNode => |branch| {
                // crashes here because one of the branches segfaults
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

    for (0..100) |i| {
        const node_a = .{
            .id = @as(i64, @intCast(i)),
            .lat = @as(f64, @floatFromInt(i)),
            .lon = 100 - @as(f64, @floatFromInt(i)),
        };
        insertIntoTreeNode(allocator, node_a, &root);

        const node_b = .{
            .id = @as(i64, @intCast(i)),
            .lat = 100 - @as(f64, @floatFromInt(i)),
            .lon = @as(f64, @floatFromInt(i)),
        };
        insertIntoTreeNode(allocator, node_b, &root);
    }

    std.debug.print("RESULT: {}\n", .{root});
}

// test "find duplicate dirs" {

//     const db = DB.init(alloc, "osm") catch unreachable;
//     defer db.deinit();

//     db.insertOsmNode(1, 0, 0) catch {};
// }
