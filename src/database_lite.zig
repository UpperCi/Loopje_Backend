const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const OsmNode = struct {
    id: i64,
    lat: f64,
    lon: f64,
    ways: []i64 = &.{},
    tags: []i64 = &.{},
};

pub const OsmTag = struct {
    key: []const u8,
    value: []const u8,
};

// Can be marked as invisible, don't add to db if that's the case
pub const OsmWay = struct {
    id: i64,
    visible: bool,
    nodes: []i64 = &.{},
    value: []i64 = &.{},
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
                    \\ create table if not exists osm_nodes_tags (
                    \\      node_id bigint unsigned,
                    \\      key text not null,
                    \\      value text not null
                    \\ );
                    \\ create table if not exists osm_ways (
                    \\      id bigint unsigned unique,
                    \\      visible integer unsigned
                    \\  );
                    \\ create table if not exists osm_ways_tags (
                    \\      way_id bigint unsigned,
                    \\      key text not null,
                    \\      value text not null
                    \\ );
                    \\ create table if not exists osm_nodes_ways (
                    \\      way_id bigint unsigned,
                    \\      node_id bigint unsigned
                    \\ );
                    \\ 
                    \\ create index idx_coords on osm_nodes(latitude, longitude);
                    // 12.8 secs without index
                    // 11.5 with...
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

    pub fn startTransaction(self: DB) void {
        _ = c.sqlite3_exec(self.db, "BEGIN TRANSACTION", null, null, null);
    }

    pub fn endTransaction(self: DB) void {
        _ = c.sqlite3_exec(self.db, "END TRANSACTION", null, null, null);
    }

    // ===== HELPERS =====

    fn trySqliteResult(self: DB, result: c_int) !void {
        if (result != c.SQLITE_OK) {
            std.debug.print("ERROR: {s}\n", .{c.sqlite3_errmsg(self.db)});
            return DBError.GenericError;
        }
    }

    fn queryWithBindings(self: DB, query: []const u8, values: anytype) !void {
        const ValuesType = @TypeOf(values);
        const values_type_info = @typeInfo(ValuesType);

        if (values_type_info != .Struct) {
            @compileError("query expects tuple argument, found " ++ @typeName(ValuesType));
        }

        var stmt: ?*c.sqlite3_stmt = undefined;

        try self.trySqliteResult(c.sqlite3_prepare_v2(self.db, query.ptr, @intCast(query.len + 1), &stmt, null));

        inline for (values, 1..) |value, pos| {
            const ValueType = @TypeOf(value);
            switch (@typeInfo(ValueType)) {
                // NOTE: Assumes i64
                .Int => |int_info| {
                    switch (int_info.bits) {
                        64 => try self.trySqliteResult(c.sqlite3_bind_int64(stmt, pos, value)),
                        else => @compileError("no bind implementation for " ++ @typeName(ValueType)),
                    }
                },
                // NOTE: Assumes f64
                .Float => |float_info| {
                    switch (float_info.bits) {
                        64 => try self.trySqliteResult(c.sqlite3_bind_double(stmt, pos, value)),
                        else => @compileError("no bind implementation for " ++ @typeName(ValueType)),
                    }
                },
                .Bool => {
                    // Sqlite doesn't support booleans, store as integer instead
                    if (value) {
                        try self.trySqliteResult(c.sqlite3_bind_int(stmt, pos, 1));
                    } else {
                        try self.trySqliteResult(c.sqlite3_bind_int(stmt, pos, 0));
                    }
                },
                // NOTE: only supports binding char slices (as text)
                .Pointer => |ptr| switch (ptr.size) {
                    .Slice => {
                        try self.trySqliteResult(c.sqlite3_bind_text(stmt, pos, value.ptr, @intCast(value.len), c.SQLITE_STATIC));
                    },
                    else => {
                        @compileError("no bind implementation for single-item pointers");
                    },
                },
                else => {
                    @compileError("no bind implementation for type " ++ @typeName(ValueType));
                },
            }
        }

        const result = stmt.?;

        const row = c.sqlite3_step(result);
        if (c.SQLITE_DONE != row) {
            std.debug.print("({s}) Step: {}: {s}\n", .{ query, row, c.sqlite3_errmsg(self.db) });
            return DBError.GenericError;
        }

        if (c.SQLITE_OK != c.sqlite3_finalize(result)) {
            std.debug.print("Couldn't finalize query {s}\n", .{query});
            return DBError.GenericError;
        }
    }

    // ===== INSERTIONS =====

    pub fn insertOsmNode(self: DB, id: i64, lat: f64, lon: f64) !void {
        const query = "INSERT INTO osm_nodes (id, latitude, longitude) VALUES (?1, ?2, ?3);";

        try self.queryWithBindings(query, .{ id, lat, lon });
    }

    pub fn insertOsmTag(self: DB, parent: OsmEntry, key: []const u8, value: []const u8) !void {
        switch (parent) {
            .Node => |node| {
                const connect_query = "INSERT INTO osm_nodes_tags (node_id, key, value) VALUES (?1, ?2, ?3);";
                try self.queryWithBindings(connect_query, .{ node.id, key, value });
            },
            .Way => |way| {
                const connect_query = "INSERT INTO osm_ways_tags (way_id, key, value) VALUES (?1, ?2, ?3);";
                try self.queryWithBindings(connect_query, .{ way.id, key, value });
            },
            .None => {},
            else => {
                std.debug.print("No tag implementation for parent {any}\n", .{parent});
            },
        }
    }

    pub fn insertOsmWay(self: DB, id: i64, visible: bool) !void {
        const query = "INSERT INTO osm_ways (id, visible) VALUES (?1, ?2);";
        try self.queryWithBindings(query, .{ id, visible });
    }

    pub fn insertOsmNd(self: DB, parent: OsmEntry, node_id: i64) !void {
        switch (parent) {
            .Way => |way| {
                const query = "INSERT INTO osm_nodes_ways (way_id, node_id) VALUES (?1, ?2);";
                try self.queryWithBindings(query, .{ way.id, node_id });
            },
            else => {
                std.debug.print("No nd implementation for parent {any}\n", .{parent});
            },
        }
    }

    // TODO get associated tags
    pub fn queryOsmNodes(self: DB, alloc: Allocator) ![]OsmNode {
        const query = "SELECT * FROM osm_nodes";
        var stmt: ?*c.sqlite3_stmt = undefined;
        if (c.SQLITE_OK != c.sqlite3_prepare_v2(self.db, query, query.len + 1, &stmt, null)) {
            std.debug.print("COULDN'T EXEC QUERY\n", .{});
            return DBError.GenericError;
        }
        const result = stmt.?;
        defer _ = c.sqlite3_finalize(result);

        var nodes = ArrayList(OsmNode).init(alloc);

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

test "find duplicate dirs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const db = DB.init(alloc, "osm") catch unreachable;
    defer db.deinit();

    db.insertOsmNode(1, 0, 0) catch {};
}
