const database = @import("database.zig");
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const HashMap = std.AutoHashMap;
const ArrayHashMap = std.AutoArrayHashMap;
const StaticStringMap = std.StaticStringMap;
const assert = std.debug.assert;

// one edge per connection or per direction?
// - One-way? Is this relevant for foot traffic? No?
// - What's easier to read? Easier to write? Less data?
// Write: slightly easier per direction
// Read: easier per direction
// Data: less per connection, is A* vectorizable anyway?

pub const NavEdge = struct {
    target: i64,
    distance_time: f64,
    distance_fuss: f64,
};

pub const NavNode = struct {
    id: i64,
    lat: f64,
    lon: f64,
    edges: []NavEdge,
};

// pub const OsmWay = struct {
//     id: i64,
//     visible: bool,
//     nodes: []OsmNode = &.{},
//     tags: []OsmTag = &.{},
// };

// what tags do I care about?
// - highway. Main travel road specifier.
//   - Good: footway, steps, pedestrian, bridleway, corridor, path
//   - Dubious: residential, living_street, track, crossing
//   - Bad: road
// - footway. Foot access in addition to another type of road.
//   - sidewalk, traffic_island, crossing
// - sidewalk.
//   - both, left, right, no
// - oneway.
// - bicycle.
//   - use_sidepath

// lower is better
const weights_time = StaticStringMap(f64).initComptime(.{
    .{ "highway - footway", 1.0 },
    .{ "highway - pedestrian", 1.0 },
    .{ "highway - bridleway", 1.0 },
    .{ "highway - corridor", 1.0 },
    .{ "highway - path", 1.0 },
    .{ "highway - residential", 1.0 },
    .{ "highway - living_street", 1.0 },
    .{ "highway - steps", 1.0 },
    .{ "highway - track", 1.0 },
    .{ "highway - crossing", 1.5 },
    .{ "highway - road", 1.2 },
    .{ "footway - sidewalk", 1.0 },
    .{ "footway - traffic_island", 1.0 },
    .{ "footway - crossing", 1.0 },
    .{ "bicycle - use_sidepath", 1.0 },
});

// lower is better
const weights_fuss = StaticStringMap(f64).initComptime(.{
    .{ "highway - footway", 0.0 },
    .{ "highway - pedestrian", 0.0 },
    .{ "highway - bridleway", 0.0 },
    .{ "highway - corridor", 0.0 },
    .{ "highway - path", 0.0 },
    .{ "highway - residential", 1.0 },
    .{ "highway - living_street", 1.0 },
    .{ "highway - steps", 0.0 },
    .{ "highway - track", 0.0 },
    .{ "highway - crossing", 3.0 },
    .{ "highway - road", 3.0 },
    .{ "footway - sidewalk", 0.5 },
    .{ "footway - traffic_island", 1.0 },
    .{ "footway - crossing", 0.5 },
    .{ "bicycle - use_sidepath", 0.5 },
});

pub fn constructNavigationGraph(
    allocator: Allocator,
    ways: []const database.OsmWay,
) !HashMap(i64, NavNode) {
    var nodes = HashMap(i64, NavNode).init(allocator);

    for (ways) |way| {
        // calculate time and fuss modifiers based on associated tags (1.0-2.0)
        var modifier_time: f64 = 2.0;
        var modifier_fuss: f64 = 1.0;
        var hash_buf: [256]u8 = undefined;
        next_tag: for (way.tags) |tag| {
            const hash_str = std.fmt.bufPrint(
                &hash_buf,
                "{s} - {s}",
                .{ tag.key, tag.value },
            ) catch {
                continue :next_tag;
            };
            if (weights_time.get(hash_str)) |weight_time| {
                if (weight_time < modifier_time) {
                    modifier_time = weight_time;
                }
            }

            if (weights_fuss.get(hash_str)) |weight_fuss| {
                if (weight_fuss > modifier_fuss) {
                    modifier_fuss = weight_fuss;
                }
            }
        }

        iter_nodes: for (way.nodes[0 .. way.nodes.len - 1], way.nodes[1..]) |node_a, node_b| {
            if (node_a.id == node_b.id) {
                continue :iter_nodes;
            }
            const dist_x = @abs(node_a.lat - node_b.lat);
            const dist_y = @abs(node_a.lon - node_b.lon);
            const distance = @sqrt(dist_x * dist_x + dist_y * dist_y);
            const distance_time = distance * modifier_time;
            const distance_fuss = distance * modifier_fuss;
            // const distance_fuss = modifier_fuss;

            const nav_a_result = try nodes.getOrPutValue(node_a.id, .{
                .id = node_a.id,
                .lat = node_a.lat,
                .lon = node_a.lon,
                .edges = &.{},
            });
            var nav_a: NavNode = nav_a_result.value_ptr.*;
            var list_a = ArrayList(NavEdge).fromOwnedSlice(allocator, nav_a.edges);
            try list_a.append(.{
                .target = node_b.id,
                .distance_time = distance_time,
                .distance_fuss = distance_fuss,
            });
            nav_a.edges = try list_a.toOwnedSlice();
            try nodes.put(node_a.id, nav_a);

            const nav_b_result = try nodes.getOrPutValue(node_b.id, .{
                .id = node_b.id,
                .lat = node_b.lat,
                .lon = node_b.lon,
                .edges = &.{},
            });
            var nav_b: NavNode = nav_b_result.value_ptr.*;
            var list_b = ArrayList(NavEdge).fromOwnedSlice(allocator, nav_b.edges);
            try list_b.append(.{
                .target = node_a.id,
                .distance_time = distance_time,
                .distance_fuss = distance_fuss,
            });
            nav_b.edges = try list_b.toOwnedSlice();
            try nodes.put(node_b.id, nav_b);
        }
    }

    return nodes;
    // === GRAPH CONSTRUCTION ===
    // for each way
    //   go through each node
    //   add edge to previous and next nodes
}

pub const NavNodeProgress = struct {
    node: NavNode,
    prev: ?i64,
    distance: f64 = 0,
    explored: bool = false,
};

const NavigationError = error{
    NodeNotFound,
};

pub fn navigateBetween(
    allocator: Allocator,
    nodes: HashMap(i64, NavNode),
    weight_time: f64,
    weight_fuss: f64,
    lon_start: f64,
    lat_start: f64,
    lon_end: f64,
    lat_end: f64,
) ![]NavNode {
    var frontier_nodes = ArrayHashMap(i64, NavNodeProgress).init(allocator);
    var first_id: i64 = 0;
    var distance_min_first: f64 = 1e10;
    var last_id: i64 = 0;
    var distance_min_last: f64 = 1e10;

    var nodes_it = nodes.valueIterator();
    while (nodes_it.next()) |node| {
        const d_lat_first = lat_start - node.lat;
        const d_lon_first = lon_start - node.lon;

        const d_lat_last = lat_end - node.lat;
        const d_lon_last = lon_end - node.lon;

        const distance_first = @sqrt((d_lat_first * d_lat_first) + (d_lon_first * d_lon_first));
        const distance_last = @sqrt((d_lat_last * d_lat_last) + (d_lon_last * d_lon_last));

        if (distance_first < distance_min_first) {
            first_id = node.id;
            distance_min_first = distance_first;
        }
        if (distance_last < distance_min_last) {
            last_id = node.id;
            distance_min_last = distance_last;
        }
    }
    // TODO: stop seaching when next node's distance exceeds finish node's
    // var distance_max: f64 = 1e100;
    // TODO: A*
    var distance_shortest: f64 = 0;
    const first_node = nodes.get(first_id);
    var shortest_node: NavNodeProgress = .{
        .node = first_node.?,
        .prev = null,
    };
    var shortest_id: i64 = first_id;
    try frontier_nodes.put(first_id, shortest_node);

    // TODO: clean up, hard to read compared to actual complexity
    while (distance_shortest < 1e99) {
        // explore edges for shortest node
        for (shortest_node.node.edges) |edge| {
            const next_id = edge.target;
            const distance_edge =
                (edge.distance_time * weight_time) +
                (edge.distance_fuss * weight_fuss);
            const next_distance = distance_shortest + distance_edge;

            if (nodes.get(next_id)) |next_node| {
                if (frontier_nodes.get(next_id)) |next_frontier| {
                    if (next_frontier.distance > next_distance) {
                        try frontier_nodes.put(next_id, .{
                            .node = next_node,
                            .prev = shortest_id,
                            .distance = next_distance,
                        });
                    }
                } else {
                    try frontier_nodes.put(next_id, .{
                        .node = next_node,
                        .prev = shortest_id,
                        .distance = next_distance,
                    });
                }
            } else {
                return NavigationError.NodeNotFound;
            }
        }
        shortest_node.explored = true;
        try frontier_nodes.put(shortest_id, shortest_node);

        // get next shortest node
        distance_shortest = 1e100;
        var iter = frontier_nodes.iterator();
        while (iter.next()) |next_entry| {
            const next_id = next_entry.key_ptr.*;
            const next_node = next_entry.value_ptr.*;
            if (!next_node.explored and next_node.distance < distance_shortest) {
                distance_shortest = next_node.distance;
                shortest_node = next_node;
                shortest_id = next_id;
            }
        }
    }

    var prev_id: i64 = last_id;
    var node_count: usize = 0;
    count_nodes: while (frontier_nodes.get(prev_id)) |prev_node| {
        node_count += 1;
        if (prev_node.prev) |prev_node_id| {
            prev_id = prev_node_id;
        } else {
            break :count_nodes;
        }
    }

    var path = try allocator.alloc(NavNode, node_count);
    var node_i = node_count;
    prev_id = last_id;
    std.debug.print("start: {}, end: {}\n", .{ first_id, last_id });
    list_nodes: while (frontier_nodes.get(prev_id)) |prev_node| {
        path[node_i - 1] = prev_node.node;
        if (node_i > 0 and prev_node.prev != null) {
            node_i -= 1;
            prev_id = prev_node.prev.?;
        } else {
            break :list_nodes;
        }
    }

    return path;
}

// wrapper to NavigateBetween that fetches nodes from the DB
pub fn findPath(
    allocator: Allocator,
    db: *database.DB,
    weight_time: f64,
    weight_fuss: f64,
    lon_start: f64,
    lat_start: f64,
    lon_end: f64,
    lat_end: f64,
) ![]NavNode {

    // 4.51541,
    // 51.92629,
    // 4.51137,
    // 51.92872,
    // const ways = db.getOsmWaysInArea(alloc, 51.91, 4.505, 51.93, 4.52) catch unreachable;
    // const nodes_nav = navigation.constructNavigationGraph(alloc, ways) catch unreachable;
    // get left, top, right, bottom
    const left: f64 = @min(lon_start, lon_end) - 0.02;
    const right: f64 = @max(lon_start, lon_end) + 0.02;
    const top: f64 = @min(lat_start, lat_end) - 0.02;
    const bottom: f64 = @max(lat_start, lat_end) + 0.02;
    std.debug.print("{d:.2}, {d:.2}, {d:.2}, {d:.2}\n", .{ top, left, bottom, right });
    const ways = try db.getOsmWaysInArea(allocator, top, left, bottom, right);
    const nodes_nav = try constructNavigationGraph(allocator, ways);
    return navigateBetween(allocator, nodes_nav, weight_time, weight_fuss, lon_start, lat_start, lon_end, lat_end);
}

//   1
//  /
// 4-5-2
//  \|
//   3
const basic_ways: []const database.OsmWay = &.{
    .{
        .id = 0,
        .visible = true,
        .nodes = &.{
            .{ .id = 1, .lat = 1, .lon = 0 },
            .{ .id = 4, .lat = 0, .lon = 1 },
            .{ .id = 3, .lat = 1, .lon = 2 },
            .{ .id = 5, .lat = 1, .lon = 1 },
        },
        .tags = &.{.{ .key = "highway", .value = "footway" }},
    },
    .{
        .id = 0,
        .visible = true,
        .nodes = &.{
            .{ .id = 4, .lat = 0, .lon = 1 },
            .{ .id = 5, .lat = 1, .lon = 1 },
            .{ .id = 2, .lat = 2, .lon = 1 },
        },
        .tags = &.{.{ .key = "highway", .value = "footway" }},
    },
};

//   1
//  / \
// 2   3
//  \ /
//   4
// left is quick, right is quiet
const fussy_ways: []const database.OsmWay = &.{
    .{
        .id = 0,
        .visible = true,
        .nodes = &.{
            .{ .id = 1, .lat = 1, .lon = 0 },
            .{ .id = 3, .lat = 2, .lon = 1 },
            .{ .id = 5, .lat = 1, .lon = 2 },
        },
        .tags = &.{.{ .key = "highway", .value = "road" }},
    },
    .{
        .id = 0,
        .visible = true,
        .nodes = &.{
            .{ .id = 1, .lat = 1, .lon = 0 },
            .{ .id = 2, .lat = 0, .lon = 1 },
            .{ .id = 5, .lat = 1, .lon = 2 },
        },
        .tags = &.{.{ .key = "highway", .value = "crossing" }},
    },
};

test "navmap creation & navigation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // const basic_nodes = constructNavigationGraph(allocator, basic_ways) catch unreachable;
    // assert((basic_nodes.get(1)).?.edges.len == 1);
    // assert((basic_nodes.get(2)).?.edges.len == 1);
    // assert((basic_nodes.get(3)).?.edges.len == 2);
    // assert((basic_nodes.get(4)).?.edges.len == 3);
    // assert((basic_nodes.get(5)).?.edges.len == 3);

    // const nav = try navigateBetween(allocator, basic_nodes, 1.0, 1.0);
    // std.debug.print("Basic Nav: {any}\n", .{nav});

    const nodes_fussy = constructNavigationGraph(allocator, fussy_ways) catch unreachable;
    // for (nodes_fussy) |f_node| {
    //     std.debug.print("\nNav graph: {any}\n", .{nodes_fussy});
    // }
    assert((nodes_fussy.get(1)).?.edges.len == 2);
    assert((nodes_fussy.get(2)).?.edges.len == 2);
    assert((nodes_fussy.get(3)).?.edges.len == 2);
    assert((nodes_fussy.get(5)).?.edges.len == 2);

    const nav_fuss_time = try navigateBetween(allocator, nodes_fussy, 1.0, 0.0, 1, 0, 1, 2);
    std.debug.print("Fussy Nav (optimize time): {any}\n", .{nav_fuss_time});
    const nav_fuss_fuss = try navigateBetween(allocator, nodes_fussy, 0.0, 1.0, 1, 0, 1, 2);
    std.debug.print("Fussy Nav (optimize peace): {any}\n", .{nav_fuss_fuss});
}
