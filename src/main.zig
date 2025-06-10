const std = @import("std");
const httpz = @import("httpz");
const database = @import("database.zig");
const navigation = @import("navigation.zig");
const assert = std.debug.assert;
const eql = std.mem.eql;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const HashMap = std.AutoHashMap;

const NavigationQueryArgs = struct {
    lat_start: f64,
    lon_start: f64,
    lat_end: f64,
    lon_end: f64,
};

const AppState = struct {};

// longitude is E-W (~5 for NL)
// latitude is N-S (~52 for NL)

// DECLARE GLOBAL STATE
var db: database.DB = undefined;
var nodes_nav_cache: HashMap(i64, navigation.NavNode) = undefined;
const left_cache: f64 = 4.234;
const right_cache: f64 = 4.539;
const top_cache: f64 = 51.898;
const bottom_cache: f64 = 51.946;

fn queryNavigation(_: *AppState, req: *httpz.Request, res: *httpz.Response) !void {
    const allocator: Allocator = res.arena;
    if (try req.json(NavigationQueryArgs)) |args| {
        res.status = 200;
        std.debug.print("Args: {any}\n", .{args});
        const nodes = try navigation.findPath(
            allocator,
            &db,
            0.0,
            1.0,
            args.lon_start,
            args.lat_start,
            args.lon_end,
            args.lat_end,
        );
        try res.json(.{ .status = "succes", .nodes = nodes }, .{});
    } else {
        res.status = 400;
        try res.json("Invalid arguments", .{});
    }
}

// uses global cache of nodes
fn queryNavigationCached(_: *AppState, req: *httpz.Request, res: *httpz.Response) !void {
    const allocator: Allocator = res.arena;
    if (try req.json(NavigationQueryArgs)) |args| {
        res.status = 200;
        std.debug.print("Args: {any}\n", .{args});
        const nodes = try navigation.navigateBetween(
            allocator,
            nodes_nav_cache,
            0.0,
            1.0,
            args.lon_start,
            args.lat_start,
            args.lon_end,
            args.lat_end,
        );
        try res.json(.{ .status = "succes", .nodes = nodes }, .{});
    } else {
        res.status = 400;
        try res.json("Invalid arguments", .{});
    }
}

const ObjectEmpty = struct {};
const object_empty: ObjectEmpty = .{};

// "coordinates" : [[lon, lat], [lon, lat]]
fn queryNavigationJson(_: *AppState, req: *httpz.Request, res: *httpz.Response) !void {
    const allocator: Allocator = res.arena;
    if (try req.json(NavigationQueryArgs)) |args| {
        res.status = 200;
        std.debug.print("Args: {any}\n", .{args});

        const nodes = try navigation.findPath(
            allocator,
            &db,
            0.0,
            1.0,
            args.lon_start,
            args.lat_start,
            args.lon_end,
            args.lat_end,
        );

        const coordinates = try allocator.alloc([]f64, nodes.len);
        for (coordinates, nodes) |*coord, node| {
            coord.* = try allocator.alloc(f64, 2);
            coord.*[0] = node.lon;
            coord.*[1] = node.lat;
        }
        try res.json(.{
            .type = "FeatureCollection", .features = .{.{
                .type = "Feature",
                .properties = object_empty,
                .geometry = .{ .coordinates = coordinates, .type = "LineString" },
            }}
        }, .{});
    } else {
        res.status = 400;
        try res.json("Invalid arguments", .{});
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator_arena = arena.allocator();

    // DEFINE GLOBAL STATE
    db = database.DB.init(allocator_arena) catch unreachable;
    defer db.deinit();

    // const ways_cache = try db.getOsmWaysInArea(
    //     allocator_arena,
    //     top_cache,
    //     left_cache,
    //     bottom_cache,
    //     right_cache,
    // );
    // nodes_nav_cache = try navigation.constructNavigationGraph(allocator_arena, ways_cache);
    var state_app: AppState = .{};

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator_gpa = gpa.allocator();

    var server = try httpz.Server(*AppState).init(allocator_gpa, .{ .port = 8090 }, &state_app);
    defer {
        // clean shutdown, finishes serving any live request
        server.stop();
        server.deinit();
    }

    var router = try server.router(.{});

    router.post("/navigate", queryNavigation, .{});
    router.post("/navigate-cached", queryNavigationCached, .{});
    router.post("/navigate-json", queryNavigationJson, .{});

    // blocks
    std.debug.print("Starting server...\n", .{});
    try server.listen();

    // How come some parts of the ways get skipped?
    //     Does the database get overridden?
    //

    // std.debug.print("start queries\n", .{});
    // const nav_quiet = navigation.findPath(
    //     allocator_arena,
    //     &db,
    //     0.0,
    //     1.0,
    //     4.51541,
    //     51.92629,
    //     4.51137,
    //     51.92872,
    // ) catch unreachable;

    // blocks
    std.debug.print("Starting server...\n", .{});
    try server.listen();

    // How come some parts of the ways get skipped?
    //     Does the database get overridden?
    //

    // std.debug.print("start queries\n", .{});
    // const nav_quiet = navigation.findPath(
    //     allocator_arena,
    //     &db,
    //     0.0,
    //     1.0,
    //     4.51541,
    //     51.92629,
    //     4.51137,
    //     51.92872,
    // ) catch unreachable;
    // std.debug.print("Fussy Nav (optimize peace): {any}\n", .{nav_quiet});
    // std.debug.print("Node amount {}\n", .{nav_quiet.len});
    // for (nav_quiet) |node| {
    //     std.debug.print("[{},{}],", .{ node.lon, node.lat });
    // }
    // std.debug.print("\n", .{});

    // PERF: pre-calculate time & fuss modifiers per way, avoid fetching tags for navigation
    // also use this to remove any invalid roads
}
