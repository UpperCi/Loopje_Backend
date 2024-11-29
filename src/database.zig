const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const OSMNode = struct {
    id: i64,
    lat: f64,
    lon: f64,
    ways: []i64 = &.{},
    tags: []i64 = &.{},
};

pub const OSMTag = struct {
    key: []const u8,
    value: []const u8,
};

// Can be marked as invisible, don't add to db if that's the case
pub const OSMWay = struct {
    nodes: []i64,
    value: []i64,
};

// Nd is ommited, as it should link to an actual node
// Relations connect a large amount of nodes, ways, and other relations together (trough members)
pub const OSMType = enum { None, Node, Way, Tag, Relation, Member };
pub const OSMEntry = union(OSMType) {
    None: void,
    Node: OSMNode,
    Way: void,
    Tag: OSMTag,
    Relation: void,
    Member: void,
};

pub const DBError = error{GenericError};

pub const DB = struct {
    db: *c.sqlite3,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, db_name: [*:0]const u8) DBError!DB {
        var raw_db: ?*c.sqlite3 = undefined;
        switch (c.sqlite3_open(db_name, &raw_db)) {
            c.SQLITE_OK => {
                const db = raw_db.?;
                const init_db_query =
                    \\ create table if not exists osm_nodes (
                    \\      id bigint unsigned unique,
                    \\      latitude double not null,
                    \\      longitude double not null
                    \\  );
                    \\ create table if not exists osm_tags (
                    \\      id integer primary key,
                    \\      key text not null,
                    \\      value text not null
                    \\ );
                    \\ create table if not exists osm_nodes_tags (
                    \\      node_id bigint unsigned,
                    \\      tag_id integer
                    \\ );
                ;
                var errmsg: [*c]u8 = undefined;
                if (c.SQLITE_OK != c.sqlite3_exec(db, init_db_query, null, null, &errmsg)) {
                    defer c.sqlite3_free(errmsg);
                    std.debug.print("Database initialization failed: {s}\n", .{errmsg});
                    return DBError.GenericError;
                }
                return .{ .db = db, .alloc = alloc };
            },
            else => {
                return DBError.GenericError;
            },
        }
    }

    pub fn deinit(self: DB) void {
        _ = c.sqlite3_close(self.db);
    }

    pub fn start_transaction(self: DB) void {
        _ = c.sqlite3_exec(self.db, "BEGIN TRANSACTION", null, null, null);
    }

    pub fn end_transaction(self: DB) void {
        _ = c.sqlite3_exec(self.db, "END TRANSACTION", null, null, null);
    }

    // ===== INSERTIONS =====

    pub fn insert_osm_node(self: DB, id: i64, lat: f64, lon: f64) !void {
        const query = "INSERT INTO osm_nodes (id, latitude, longitude) VALUES (?1, ?2, ?3);";
        var stmt: ?*c.sqlite3_stmt = undefined;
        if (c.SQLITE_OK != c.sqlite3_prepare_v2(self.db, query, query.len + 1, &stmt, null)) {
            std.debug.print("Couldn't insert node {}\n", .{id});
            return DBError.GenericError;
        }
        const cast_id = @as(i64, @bitCast(id));
        if (c.SQLITE_OK != c.sqlite3_bind_int64(stmt, 1, cast_id)) {
            std.debug.print("Couldn't bind value {}\n", .{cast_id});
            return DBError.GenericError;
        }
        if (c.SQLITE_OK != c.sqlite3_bind_double(stmt, 2, lat)) {
            std.debug.print("Couldn't bind value {}\n", .{lat});
            return DBError.GenericError;
        }
        if (c.SQLITE_OK != c.sqlite3_bind_double(stmt, 3, lon)) {
            std.debug.print("Couldn't bind value {}\n", .{lon});
            return DBError.GenericError;
        }
        const result = stmt.?;

        const row = c.sqlite3_step(result);
        if (c.SQLITE_DONE != row) {
            std.debug.print("Step: {}: {s}\n", .{ row, c.sqlite3_errmsg(self.db) });
            return DBError.GenericError;
        }

        if (c.SQLITE_OK != c.sqlite3_finalize(result)) {
            std.debug.print("Couldn't finalize query {}\n", .{lon});
            return DBError.GenericError;
        }
    }

    fn connect_osm_node_tag(self: DB, node_id: i64, tag_id: i64) !void {
        const query = "INSERT INTO osm_nodes_tags (node_id, tag_id) VALUES (?1, ?2);";
        var stmt: ?*c.sqlite3_stmt = undefined;
        if (c.SQLITE_OK != c.sqlite3_prepare_v2(self.db, query, query.len + 1, &stmt, null)) {
            std.debug.print("Couldn't connect node with tag {any}\n", .{tag_id});
            return DBError.GenericError;
        }
        if (c.SQLITE_OK != c.sqlite3_bind_int64(stmt, 1, @intCast(node_id))) {
            std.debug.print("Couldn't bind node_id {any}\n", .{tag_id});
            return DBError.GenericError;
        }
        if (c.SQLITE_OK != c.sqlite3_bind_int64(stmt, 2, tag_id)) {
            std.debug.print("Couldn't bind tag_id {any}\n", .{tag_id});
            return DBError.GenericError;
        }
        const result = stmt.?;

        const row = c.sqlite3_step(result);
        if (c.SQLITE_DONE != row) {
            std.debug.print("Step: {}: {any}\n", .{ row, c.sqlite3_errmsg(self.db) });
            return DBError.GenericError;
        }

        if (c.SQLITE_OK != c.sqlite3_finalize(result)) {
            std.debug.print("Couldn't finalize query {any}\n", .{tag_id});
            return DBError.GenericError;
        }
    }

    // TODO make connection to parent
    pub fn insert_osm_tag(self: DB, parent: OSMEntry, key: []const u8, value: []const u8) !void {
        const query = "INSERT INTO osm_tags (id, key, value) VALUES (NULL, ?2, ?3);";
        var stmt: ?*c.sqlite3_stmt = undefined;
        if (c.SQLITE_OK != c.sqlite3_prepare_v2(self.db, query, query.len + 1, &stmt, null)) {
            std.debug.print("Couldn't insert tag {s}\n", .{key});
            return DBError.GenericError;
        }
        if (c.SQLITE_OK != c.sqlite3_bind_text(stmt, 2, key.ptr, @intCast(key.len), c.SQLITE_STATIC)) {
            std.debug.print("Couldn't bind key {s}\n", .{key});
            return DBError.GenericError;
        }
        if (c.SQLITE_OK != c.sqlite3_bind_text(stmt, 3, value.ptr, @intCast(value.len), c.SQLITE_STATIC)) {
            std.debug.print("Couldn't bind value {s}\n", .{value});
            return DBError.GenericError;
        }
        const result = stmt.?;

        const row = c.sqlite3_step(result);
        if (c.SQLITE_DONE != row) {
            std.debug.print("Step: {}: {s}\n", .{ row, c.sqlite3_errmsg(self.db) });
            return DBError.GenericError;
        }

        if (c.SQLITE_OK != c.sqlite3_finalize(result)) {
            std.debug.print("Couldn't finalize query {s}\n", .{key});
            return DBError.GenericError;
        }

        const tag_id = c.sqlite3_last_insert_rowid(self.db);

        switch (parent) {
            .Node => |node| try self.connect_osm_node_tag(node.id, tag_id),
            else => {},
        }
    }

    // TODO get associated tags
    pub fn query_osm_nodes(self: DB, alloc: Allocator) ![]OSMNode {
        const query = "SELECT * FROM osm_nodes";
        var stmt: ?*c.sqlite3_stmt = undefined;
        if (c.SQLITE_OK != c.sqlite3_prepare_v2(self.db, query, query.len + 1, &stmt, null)) {
            std.debug.print("COULDN'T EXEC QUERY\n", .{});
            return DBError.GenericError;
        }
        const result = stmt.?;
        defer _ = c.sqlite3_finalize(result);

        var nodes = ArrayList(OSMNode).init(alloc);

        var rc = c.sqlite3_step(result);
        while (rc == c.SQLITE_ROW) {
            const id = c.sqlite3_column_int64(result, 0);
            const lat = c.sqlite3_column_double(result, 1);
            const lon = c.sqlite3_column_double(result, 2);
            try nodes.append(.{ .id = @as(i64, @bitCast(id)), .lat = lat, .lon = lon });
            rc = c.sqlite3_step(result);
        }

        const nodes_slice = try nodes.toOwnedSlice();

        return nodes_slice;
    }
};
