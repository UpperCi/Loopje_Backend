const std = @import("std");
const database = @import("database.zig");
const expect = std.testing.expect;
const assert = std.testing.assert;
const eql = std.mem.eql;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

// longest line is 341 chars

const ReadValueError = error.ValueNotFound;

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
    return error.ValueNotFound;
}

// FIXME actual errors when node can't be parsed
fn getOSMNodeFromTag(data: []u8) !database.OSMNode {
    const id_str = try valueFromTag("id", data);
    const lat_str = try valueFromTag("lat", data);
    const lon_str = try valueFromTag("lon", data);

    const id = try std.fmt.parseInt(i64, id_str, 10);
    const lat = try std.fmt.parseFloat(f64, lat_str);
    const lon = try std.fmt.parseFloat(f64, lon_str);

    return .{ .id = id, .lat = lat, .lon = lon };
}

fn insertOSMNode(db: database.DB, node: database.OSMNode) InsertItemError!void {
    try db.insert_osm_node(node.id, node.lat, node.lon);
}

fn getOSMTagFromTag(data: []u8) !database.OSMTag {
    const key = try valueFromTag("k", data);
    const value = try valueFromTag("v", data);

    return .{ .key = key, .value = value };
}
// FIXME actual errors when node can't be parsed
fn insertOSMTag(db: database.DB, tag: database.OSMTag) InsertItemError!void {
    try db.insert_osm_tag(tag.key, tag.value);
}

fn parseOSM(db: database.DB, path: []const u8) void {
    const file = std.fs.cwd().openFile(path, .{}) catch unreachable;
    defer file.close();
    const meta = file.metadata() catch unreachable;
    const size = meta.size();

    var buf_reader = std.io.bufferedReader(file.reader());
    var in_stream = buf_reader.reader();

    var byte: u8 = undefined;
    var item_buf: [512]u8 = undefined;
    var item_size: u16 = 0;

    // current parser state
    var in_item = false;
    var escaped = false;
    var parent: database.OSMEntry = .None;

    db.start_transaction();

    for (0..size) |_| {
        byte = in_stream.readByte() catch {
            break;
        };

        if (in_item) {
            if (byte == '"' and item_buf[item_size - 1] != '\\') {
                escaped = !escaped;
            }

            if (!escaped and byte == '>') {
                // Register new item
                // Ignore, Node, Way, Tag, Nd, Relation
                // TODO: seperate parsing and insertion; save parent
                // E.g. getEntry(&item_buf, "ref") -> '123456' getEntry(&item_buf, "vis") -> 'true'
                switch (item_buf[0]) {
                    '/' => { // end parent
                        parent = .None;
                    },
                    'w' => { // Way
                    },
                    't' => { // Tag
                        const tag = getOSMTagFromTag(item_buf[0..]) catch unreachable;
                        db.insert_osm_tag(parent, tag.key, tag.value) catch unreachable;
                        parent = .{ .Tag = tag };
                    },
                    'r' => { // Relation
                    },
                    'm' => { // Member
                    },
                    'n' => { // Node or Nd
                        if (item_buf[1] == 'o') { // Node
                            // Error return trace
                            const node = getOSMNodeFromTag(item_buf[0..]) catch unreachable;
                            insertOSMNode(db, node) catch unreachable;
                            parent = .{ .Node = node };
                        } else { // Nd, connects node and parent
                        }
                    },
                    else => {},
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

    db.end_transaction();
}

pub fn main() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const db = database.DB.init(alloc, "osm") catch unreachable;
    defer db.deinit();

    std.debug.print("{}\n", .{db});
    std.debug.print("{s} -> {!?s}\n", .{ "member=\"abc\" key=\"value\"", valueFromTag("key", "member=\"abc\" key=\"value\" ") });

    // No allocations during data insertion (besides internal SQLite allocations)
    parseOSM(db, "beurs.osm");
    // parseOSM(db, "netherlands-latest.osm");

    // const nodes = db.query_osm_nodes(alloc) catch unreachable;
    // for (nodes) |n| {
    //     std.debug.print("{}\n", .{n});
    // }
}

test "find duplicate dirs" {
    parseOSM("beurs.osm");
}
