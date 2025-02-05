const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const pg = @import("pg");

pub const OsmNode = struct {
    id: i64,
    lat: f64,
    lon: f64,
    ways: []OsmTag = &.{},
    tags: []OsmTag = &.{},
};

pub const OsmTag = struct {
    key: []const u8,
    value: []const u8,
};

// Can be marked as invisible, don't add to db if that's the case
pub const OsmWay = struct {
    id: i64,
    visible: bool,
    nodes: []OsmNode = &.{},
    tags: []OsmTag = &.{},
};

// Nd is ommited, as it should link to an actual node
// Relations connect a large amount of nodes, ways, and other relations together (through members)
pub const OsmType = enum { None, Node, Way, Tag, Relation, Member };
pub const OsmEntry = union(OsmType) {
    None: void,
    Node: OsmNode,
    Way: OsmWay,
    Tag: OsmTag,
    Relation: void,
    Member: void,
};

pub const DBError = error{GenericError};

const data_queue_size = 32_000;
const data_queue_margin = 512;

const DataQueue = struct {
    buffer: [data_queue_size]u8 = undefined,
    offset: usize = 0,

    pub fn copy_buffer(self: *DataQueue, comptime db_table: []const u8, conn: *pg.Conn) !void {
        const filename = "/tmp/" ++ db_table ++ ".txt";
        std.fs.cwd().deleteFile(filename) catch {};
        var file = try std.fs.cwd().createFile(filename, .{});
        _ = try file.writer().writeAll(self.buffer[0..self.offset]);
        defer file.close();

        self.offset = 0;
        // order postgres to load file
        const query = "COPY " ++ db_table ++ " FROM '" ++ filename ++ "';";
        _ = conn.exec(query, .{}) catch {
            if (conn.err) |pge| {
                std.log.err("PG {s}\n", .{pge.message});
                std.debug.print("file: {s}\n", .{filename});
                std.debug.print("buf: {s}\n", .{self.buffer});
            }
        };
    }

    pub fn queue_value(
        self: *DataQueue,
        comptime db_table: []const u8,
        conn: *pg.Conn,
        serial: []u8,
    ) !void {
        self.offset += serial.len;

        if (self.offset + data_queue_margin > data_queue_size) {
            try self.copy_buffer(db_table, conn);
        }
    }
};

// TODO: make postgres-based
pub const DB = struct {
    pool: *pg.Pool,
    conn: *pg.Conn,
    node_queue: DataQueue = .{},
    way_queue: DataQueue = .{},
    way_nd_queue: DataQueue = .{},
    node_tag_queue: DataQueue = .{},
    way_tag_queue: DataQueue = .{},

    pub fn reset(self: DB) !void {
        const init_db_query =
            \\ DROP TABLE IF EXISTS osm_nodes;
            \\ CREATE UNLOGGED TABLE IF NOT EXISTS osm_nodes (
            \\      id BIGINT unique,
            \\      position GEOMETRY
            \\  ) with (autovacuum_enabled=false);
            \\ DROP TABLE IF EXISTS osm_ways;
            \\ CREATE UNLOGGED TABLE IF NOT EXISTS osm_ways (
            \\      id BIGINT,
            \\      visible BOOLEAN
            \\  ) with (autovacuum_enabled=false);
            \\ DROP TABLE IF EXISTS osm_ways_nodes;
            \\ CREATE UNLOGGED TABLE IF NOT EXISTS osm_ways_nodes (
            \\      way_id BIGINT,
            \\      node_id BIGINT
            \\  ) with (autovacuum_enabled=false);
            \\ CREATE UNLOGGED TABLE IF NOT EXISTS osm_nodes_tags (
            \\      node_id BIGINT,
            \\      key TEXT,
            \\      value TEXT
            \\ ) with (autovacuum_enabled=false);
            \\ CREATE UNLOGGED TABLE IF NOT EXISTS osm_ways_tags (
            \\      way_id BIGINT,
            \\      key TEXT,
            \\      value TEXT
            \\ ) with (autovacuum_enabled=false);
        ;
        // TODO: index join ids? e.g. osm_nodes_tags.node_id
        _ = self.conn.exec(init_db_query, .{}) catch |err| {
            std.debug.print("EPIC FAIL: {}\n", .{err});
            if (self.conn.err) |pgerr| {
                std.debug.print("Message: {s}\n", .{pgerr.message});
            }
            return err;
        };
    }

    pub fn init(allocator: std.mem.Allocator) !DB {
        var pool = try pg.Pool.init(allocator, .{
            .size = 5,
            .connect = .{
                .port = 5432,
                .host = "127.0.0.1",
            },
            .auth = .{
                .username = "postgres",
                .password = "postgres",
                .database = "loopje",
                .timeout = 10_000,
            },
        });
        // \\ Index has little effect when using POSTGIS, but +100-200% insertion time
        // \\ create index idx_coords on osm_nodes(position);

        // 12.8 secs without index
        // 11.5 with...
        const conn = try pool.acquire();
        return .{ .pool = pool, .conn = conn };
    }

    pub fn insert_queue(self: *DB) !void {
        try self.node_queue.copy_buffer("osm_nodes", self.conn);
        try self.way_queue.copy_buffer("osm_ways", self.conn);
        try self.way_nd_queue.copy_buffer("osm_ways_nodes", self.conn);
        try self.node_tag_queue.copy_buffer("osm_nodes_tags", self.conn);
        try self.way_tag_queue.copy_buffer("osm_ways_tags", self.conn);
    }

    pub fn deinit(self: *DB) void {
        // TODO fix this
        self.pool.deinit();
    }

    pub fn startTransaction(self: DB) !void {
        _ = try self.conn.begin();
    }

    pub fn endTransaction(self: DB) !void {
        _ = try self.conn.commit();
    }

    // ===== HELPERS =====

    // ===== INSERTIONS =====

    pub fn queueOsmNode(self: *DB, id: i64, lat: f64, lon: f64) !void {
        const lat_as_bytes = @byteSwap(@as(u64, @bitCast(lat)));
        const lon_as_bytes = @byteSwap(@as(u64, @bitCast(lon)));
        const string = try std.fmt.bufPrint(
            self.node_queue.buffer[self.node_queue.offset..],
            // point consists of:
            // 0101000000 -> geometry type specifier (which is always point here)
            // {X:0>16} lat/lon floats as raw bytes, swapped endian
            "{d}\t0101000000{X:0>16}{X:0>16}\n",
            .{ id, lat_as_bytes, lon_as_bytes },
        );
        try self.node_queue.queue_value("osm_nodes", self.conn, string);
    }

    pub fn queueOsmWay(self: *DB, id: i64, visible: bool) !void {
        const visible_char: u8 = if (visible) 't' else 'f';
        const string = try std.fmt.bufPrint(
            self.way_queue.buffer[self.way_queue.offset..],
            "{d}\t{c}\n",
            .{ id, visible_char },
        );
        try self.way_queue.queue_value("osm_ways", self.conn, string);
    }

    pub fn queueOsmNd(self: *DB, parent: OsmEntry, node_id: i64) !void {
        switch (parent) {
            .Way => |way| {
                const string = try std.fmt.bufPrint(
                    self.way_nd_queue.buffer[self.way_nd_queue.offset..],
                    "{d}\t{d}\n",
                    .{ way.id, node_id },
                );
                try self.way_nd_queue.queue_value("osm_ways_nodes", self.conn, string);
            },
            else => {
                std.debug.print("No nd implementation for parent {any}\n", .{parent});
            },
        }
    }

    pub fn queueOsmTag(self: *DB, parent: OsmEntry, key: []const u8, value: []const u8) !void {
        switch (parent) {
            .Node => |node| {
                // node_id key value
                const string = try std.fmt.bufPrint(
                    self.node_tag_queue.buffer[self.node_tag_queue.offset..],
                    "{d}\t{s}\t{s}\n",
                    .{ node.id, key, value },
                );
                try self.node_tag_queue.queue_value("osm_nodes_tags", self.conn, string);
            },
            .Way => |way| {
                const string = try std.fmt.bufPrint(
                    self.way_tag_queue.buffer[self.way_tag_queue.offset..],
                    "{d}\t{s}\t{s}\n",
                    .{ way.id, key, value },
                );
                try self.way_tag_queue.queue_value("osm_ways_tags", self.conn, string);
            },
            .None => {},
            else => {
                std.debug.print("No tag implementation for parent {any}\n", .{parent});
            },
        }
    }

    // ===== QUERIES =====

    pub fn getOsmNodesInArea(
        self: DB,
        allocator: Allocator,
        top: f64,
        left: f64,
        bottom: f64,
        right: f64,
    ) ![]OsmNode {
        var nodes = ArrayList(OsmNode).init(allocator);
        var node_tags = ArrayList(OsmTag).init(allocator);
        const query =
            \\ SELECT
            \\ osm_nodes.id, ST_X(osm_nodes.position), ST_Y(osm_nodes.position),
            \\ osm_nodes_tags.key, osm_nodes_tags.value
            \\ FROM osm_nodes
            \\ LEFT JOIN osm_nodes_tags ON osm_nodes.id = osm_nodes_tags.node_id
            \\ WHERE ST_Contains(ST_MakeEnvelope($1,$2,$3,$4),position)
            \\ ;
        ;
        var result = self.conn.query(query, .{ top, left, bottom, right }) catch |err| {
            if (self.conn.err) |pgerr| {
                std.debug.print("Message: {s}\n", .{pgerr.message});
            }
            return err;
        };
        defer result.deinit();

        var node: OsmNode = .{ .id = 0, .lat = 0, .lon = 0 };
        while (try result.next()) |row| {
            const id = row.get(i64, 0);
            if (id != node.id) {
                // 1 xa ya ka va
                // 1 xa ya kb vb
                // 2 xb yb kc vc
                if (node.id != 0) {
                    try nodes.append(node);
                }
                node.tags = try node_tags.toOwnedSlice();

                node = .{
                    .id = row.get(i64, 0),
                    .lat = row.get(f64, 1),
                    .lon = row.get(f64, 2),
                    .tags = try node_tags.toOwnedSlice(),
                };
            }

            // slice are only valid until next row
            if (row.get(?[]const u8, 3)) |key_temp| {
                if (row.get(?[]const u8, 4)) |value_temp| {
                    const key = try allocator.dupe(key_temp);
                    const value = try allocator.dupe(value_temp);
                    std.debug.print("Key: {s}", .{key});
                    try node_tags.append(.{ .key = key, .value = value });
                }
            }
        }

        return try nodes.toOwnedSlice();
    }

    pub fn getOsmWaysInArea(
        self: DB,
        allocator: Allocator,
        left: f64,
        top: f64,
        right: f64,
        bottom: f64,
    ) ![]OsmWay {
        var ways = ArrayList(OsmWay).init(allocator);
        var way_nodes = ArrayList(OsmNode).init(allocator);
        var way_tags = ArrayList(OsmTag).init(allocator);
        // irrelevant ways are filtered out in query
        const query =
            \\SELECT
            \\osm_ways.id, osm_nodes.id, ST_X(osm_nodes.position), ST_Y(osm_nodes.position),
            \\osm_ways_tags.key, osm_ways_tags.value
            \\FROM osm_ways
            \\LEFT JOIN osm_ways_nodes ON osm_ways.id = osm_ways_nodes.way_id
            \\LEFT JOIN osm_nodes ON osm_ways_nodes.node_id = osm_nodes.id
            \\LEFT JOIN osm_ways_tags ON osm_ways_tags.way_id = osm_ways.id
            \\WHERE ST_Contains(ST_MakeEnvelope($1,$2,$3,$4),osm_nodes.position) AND
            \\osm_ways_tags.key IN ('highway','footway','sidewalk','bicycle')
            \\;
        ;
        std.debug.print("query:\n{s}\n", .{query});
        var result = self.conn.query(query, .{ left, top, right, bottom }) catch |err| {
            std.debug.print("Errtype: {any}\n", .{err});
            if (self.conn.err) |pgerr| {
                std.debug.print("Message: {s}\n", .{pgerr.message});
            }
            return err;
        };
        defer result.deinit();

        var way: OsmWay = .{ .id = 0, .visible = true };
        std.debug.print("Going through results\n", .{});
        while (try result.next()) |row| {
            // wayid, nodex, nodey, tagk, tagv
            // 1 nxa nxa tka tka
            // 1 nxb nxb tkb tkb
            // 1 nxc nxc tkb tkb
            // 2 nxd nxd tkc tkc
            const id = row.get(i64, 0);
            if (id != way.id) {
                if (way.id != 0) {
                    way.nodes = try way_nodes.toOwnedSlice();
                    way.tags = try way_tags.toOwnedSlice();
                    try ways.append(way);
                }
                way.id = id;
            }

            // extra tags and ways get connected
            if (row.get(?i64, 1)) |node_id| {
                if (row.get(?f64, 2)) |lat| {
                    if (row.get(?f64, 3)) |lon| {
                        try way_nodes.append(.{
                            .id = node_id,
                            .lat = lat,
                            .lon = lon,
                        });
                    }
                }
            }

            if (row.get(?[]const u8, 4)) |key_temp| {
                var skip_tag = false;
                for (way_tags.items) |tag| {
                    if (std.mem.eql(u8, key_temp, tag.key)) {
                        skip_tag = true;
                    }
                }
                if (!skip_tag) {
                    if (row.get(?[]const u8, 5)) |value_temp| {
                        const key = try allocator.dupe(u8, key_temp);
                        const value = try allocator.dupe(u8, value_temp);
                        try way_tags.append(.{ .key = key, .value = value });
                    }
                }
            }
        }

        return try ways.toOwnedSlice();
    }

    // TODO get associated tags
    // pub fn queryOsmNodes(self: DB, alloc: Allocator) ![]OsmNode {
    //     const query = "SELECT * FROM osm_nodes";
    //     var stmt: ?*c.sqlite3_stmt = undefined;
    //     if (c.SQLITE_OK != c.sqlite3_prepare_v2(self.db, query, query.len + 1, &stmt, null)) {
    //         std.debug.print("COULDN'T EXEC QUERY\n", .{});
    //         return DBError.GenericError;
    //     }
    //     const const result = stmt.?;
    //     defer _ = c.sqlite3_finalize(result);

    //     var nodes = ArrayList(OsmNode).init(alloc);

    //     var rc = c.sqlite3_step(result);
    //     while (rc == c.SQLITE_ROW) {
    //         const id = c.sqlite3_column_int64(result, 0);
    //         const lat = c.sqlite3_column_double(result, 1);
    //         const lon = c.sqlite3_column_double(result, 2);
    //         try nodes.append(.{ .id = @as(i64, @bitCast(id)), .lat = lat, .lon = lon });
    //         rc = c.sqlite3_step(result);
    //     }

    //     const nodes_slice = try nodes.toOwnedSlice();

    //     return nodes_slice;
    // }
};

test "insert content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const db = try DB.init(alloc);
    defer db.deinit();

    std.debug.print("Inserting node!\n", .{});
    try db.insertOsmNode(1, 2, 3);
    try db.insertOsmNode(4, 3, 2);

    try db.insertOsmWay(1, true);
    try db.insertOsmWay(2, false);
    try db.insertOsmWay(3, true);

    const parent: OsmEntry = .{ .Way = .{
        .id = 1,
        .visible = true,
    } };
    try db.insertOsmNd(parent, 4);
    const parent2: OsmEntry = .{ .Way = .{
        .id = 2,
        .visible = true,
    } };
    try db.insertOsmNd(parent2, 1);
}

test "geojson point formatting" {
    const lat: f64 = 123.0;
    const lon: f64 = 456.0;
    std.debug.print(
        "0101000000{X:0>16}{X:0>16}\n",
        .{
            @byteSwap(@as(u64, @bitCast(lat))),
            @byteSwap(@as(u64, @bitCast(lon))),
        },
    );
    std.debug.print("0101000000000000000000F03F000000000000F03F\n", .{});
}
