const std = @import("std");
const database = @import("database.zig");
const assert = std.debug.assert;

const ReadValueError = error.KeyNotFound;

const InsertItemError = error{
    Overflow,
    InvalidCharacter,
    GenericError,
};

fn valueFromTag(key: []const u8, data: []const u8) ![]const u8 {
    var in_string = false;
    var escape_next = false;
    var match_progress: u64 = 0;
    var string_start: u64 = 0;
    var matched = false;

    for (data, 0..data.len) |c, i| {
        if (escape_next) {
            escape_next = false;
        } else {
            if (c == '"') {
                in_string = !in_string;
                if (in_string) {
                    string_start = i + 1;
                } else if (matched) {
                    return data[string_start..i];
                }
            }
        }

        if (in_string) {} else if (!matched) {
            if (c == key[match_progress]) {
                match_progress += 1;
                if (match_progress == key.len) {
                    matched = true;
                }
            } else {
                match_progress = 0;
            }
        }
    }

    return error.KeyNotFound;
}

// FIXME actual errors when node can't be parsed
fn getOsmNodeFromTag(data: []u8) !database.OsmNode {
    const id_str = try valueFromTag("id", data);
    const lat_str = try valueFromTag("lat", data);
    const lon_str = try valueFromTag("lon", data);

    const id = try std.fmt.parseInt(i64, id_str, 10);
    const lat = try std.fmt.parseFloat(f64, lat_str);
    const lon = try std.fmt.parseFloat(f64, lon_str);

    return .{ .id = id, .lat = lat, .lon = lon };
}

fn getOsmTagFromTag(data: []u8) !database.OsmTag {
    const key = try valueFromTag("k", data);
    const value = try valueFromTag("v", data);

    return .{ .key = key, .value = value };
}

fn getOsmWayFromTag(data: []u8) !database.OsmWay {
    const visibility = valueFromTag("visible", data) catch "false";
    const id_str = try valueFromTag("id", data);
    const id = try std.fmt.parseInt(i64, id_str, 10);
    if (visibility[0] == 't') {
        return .{ .id = id, .visible = true };
    } else {
        assert(visibility[0] == 'f');
        return .{ .id = id, .visible = false };
    }
}

fn getOsmNdIdFromTag(data: []u8) !i64 {
    const id_str = try valueFromTag("ref", data);
    return try std.fmt.parseInt(i64, id_str, 10);
}

fn parseOsm(db: *database.DB, path: []const u8) void {
    db.reset() catch unreachable;
    const file = std.fs.cwd().openFile(path, .{}) catch unreachable;
    defer file.close();
    const meta = file.metadata() catch unreachable;
    const size = meta.size();

    var buf_reader = std.io.bufferedReader(file.reader());
    var in_stream = buf_reader.reader();

    var byte: u8 = undefined;
    // longest line is 341 chars
    var item_buf: [512]u8 = undefined;
    var item_size: u16 = 0;

    // current parser state
    var in_item = false;
    var parent: database.OsmEntry = .None;
    var insertions: u64 = 0;
    const stdout = std.io.getStdOut().writer();

    db.startTransaction() catch unreachable;
    // 11363070619
    // in_stream.skipBytes(11375795500, .{}) catch {};

    for (0..size) |i| {
        byte = in_stream.readByte() catch {
            break;
        };

        if (insertions >= 200_000) {
            assert(!in_item);
            db.endTransaction() catch unreachable;
            db.startTransaction() catch unreachable;
            const percentage: f64 = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(size));
            stdout.print("{any}/{any} ({d:.2}%)\n", .{ i, size, percentage * 100 }) catch {};
            insertions = 0;
        }

        if (in_item) {
            if (byte == '>') {
                // Register new item
                switch (item_buf[0]) {
                    '/' => { // end parent
                        parent = .None;
                    },
                    'w' => { // Way
                        const way = getOsmWayFromTag(item_buf[0..]) catch continue;
                        db.queueOsmWay(way.id, way.visible) catch {};
                        insertions += 1;
                        parent = .{ .Way = way };
                    },
                    't' => { // Tag
                        const tag = getOsmTagFromTag(item_buf[0..]) catch unreachable;
                        db.queueOsmTag(parent, tag.key, tag.value) catch {};
                        insertions += 1;
                    },
                    'r' => { // Relation
                    },
                    'm' => { // Member
                    },
                    'n' => { // Node or Nd
                        if (item_buf[1] == 'o') { // Node
                            // Error return trace
                            const node = getOsmNodeFromTag(item_buf[0..]) catch unreachable;
                            db.queueOsmNode(node.id, node.lat, node.lon) catch unreachable;
                            insertions += 1;
                            parent = .{ .Node = node };
                        } else { // Nd, connects node to way
                            assert(parent == .Way);
                            const nd_id = getOsmNdIdFromTag(item_buf[0..]) catch unreachable;
                            db.queueOsmNd(parent, nd_id) catch {};
                            insertions += 1;
                        }
                    },
                    else => { // Headers & metadata
                        // should only happen at the start of the file
                        assert(i < 1_000);
                    },
                }
                in_item = false;
                @memset(&item_buf, 0);
                item_size = 0;
            } else {
                item_buf[item_size] = byte;
                item_size += 1;
            }
        } else {
            if (byte == '<') {
                in_item = true;
            }
        }
    }
    assert(!in_item);

    db.insert_queue() catch unreachable;
    db.endTransaction() catch unreachable;
}

pub fn main() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = database.DB.init(alloc) catch unreachable;
    defer db.deinit();

    // std.debug.print("{}\n", .{db});

    parseOsm(&db, "zuid-holland-latest.osm");
    // parseOsm(&db, "beurs.osm");
    // parseOsm(&db, "roffa.osm");
}
