- Zig 0.13.0

# Build

- seperate steps for populating DB and starting webserver

# Queries

Get all nodes + connected tags
```sql
SELECT osm_nodes.id, osm_nodes.latitude, osm_nodes.longitude, osm_nodes_tags.key, osm_nodes_tags.value FROM osm_nodes
  LEFT JOIN osm_nodes_tags ON osm_nodes.id=osm_nodes_tags.node_id
  ;
```

Get nodes in area
```sql
  SELECT COUNT(*) FROM osm_nodes WHERE ST_Contains(ST_MakeEnvelope(51.8,4.4,51.85,4.45),position);
```
```sql

SELECT COUNT(*) FROM osm_nodes 
 LEFT JOIN osm_nodes_tags ON osm_nodes.id = osm_nodes_tags.node_id
 WHERE ST_Contains(ST_MakeEnvelope(51.8,4.4,51.85,4.45),position);
```
```sql
SELECT
osm_ways.id, ST_X(osm_nodes.position), ST_Y(osm_nodes.position)
FROM osm_ways
LEFT JOIN osm_ways_nodes ON osm_ways.id = osm_ways_nodes.way_id
LEFT JOIN osm_nodes ON osm_ways_nodes.node_id = osm_nodes.id;
```

With Postgres + PostGIS, this takes ~2.5 seconds on "zuid-holland-latest.osm"

Get all ways + connected tags
```sql
SELECT osm_ways.id, osm_nodes.id, ST_X(osm_nodes.position), ST_Y(osm_nodes.position), osm_ways_tags.key, osm_ways_tags.value
FROM osm_ways
LEFT JOIN osm_ways_nodes ON osm_ways.id = osm_ways_nodes.way_id
LEFT JOIN osm_nodes ON osm_ways_nodes.node_id = osm_nodes.id
LEFT JOIN osm_ways_tags ON osm_ways_tags.way_id = osm_ways.id
WHERE ST_Contains(ST_MakeEnvelope(51.90224,4.43693,51.9486,4.57169),osm_nodes.position) AND
osm_ways_tags.key IN ('highway','footway','sidewalk','bicycle');

SELECT osm_ways.id, osm_nodes.id, ST_X(osm_nodes.position), ST_Y(osm_nodes.position), osm_ways_tags.key, osm_ways_tags.value
FROM osm_ways
LEFT JOIN osm_ways_nodes ON osm_ways.id = osm_ways_nodes.way_id
LEFT JOIN osm_nodes ON osm_ways_nodes.node_id = osm_nodes.id
WHERE ST_Contains(ST_MakeEnvelope(51.90224,4.43693,51.9486,4.57169),osm_nodes.position);
```
```sql
SELECT osm_ways.id, osm_nodes.id, ST_X(osm_nodes.position), ST_Y(osm_nodes.position), osm_ways_tags.key, osm_ways_tags.value FROM osm_ways LEFT JOIN osm_ways_nodes ON osm_ways.id = osm_ways_nodes.way_id LEFT JOIN osm_nodes ON osm_ways_nodes.node_id = osm_nodes.id LEFT JOIN osm_ways_tags ON osm_ways_tags.way_id = osm_ways.id WHERE ST_Contains(ST_MakeEnvelope(0,0,100,100),osm_nodes.position) AND osm_ways_tags.key IN ('highway','footway','sidewalk','bicycle');

SELECT COUNT(*) FROM osm_ways LEFT JOIN osm_ways_nodes ON osm_ways.id = osm_ways_nodes.way_id LEFT JOIN osm_nodes ON osm_ways_nodes.node_id = osm_nodes.id LEFT JOIN osm_ways_tags ON osm_ways_tags.way_id = osm_ways.id WHERE ST_Contains(ST_MakeEnvelope(0,0,100,100),osm_nodes.position) AND osm_ways_tags.key IN ('highway','footway','sidewalk','bicycle');

SELECT COUNT(*) FROM osm_ways LEFT JOIN osm_ways_nodes ON osm_ways.id = osm_ways_nodes.way_id LEFT JOIN osm_nodes ON osm_ways_nodes.node_id = osm_nodes.id LEFT JOIN osm_ways_tags ON osm_ways_tags.way_id = osm_ways.id WHERE ST_Contains(ST_MakeEnvelope(0,0,100,100),osm_nodes.position);

sELECT COUNT(*) FROM osm_ways LEFT JOIN osm_ways_nodes ON osm_ways.id = osm_ways_nodes.way_id LEFT JOIN osm_nodes ON osm_ways_nodes.node_id = osm_nodes.id WHERE ST_Contains(ST_MakeEnvelope(51.90224,4.43693,51.9486,4.57169),osm_nodes.position);

sELECT COUNT(*) FROM osm_ways LEFT JOIN osm_ways_nodes ON osm_ways.id = osm_ways_nodes.way_id LEFT JOIN osm_nodes ON osm_ways_nodes.node_id = osm_nodes.id WHERE ST_Contains(ST_MakeEnvelope(0,0,100,100),osm_nodes.position);
```

## Database

- Sqlite needs to keep all data in-memory

## Quadtree

Stored in two files
- Structure file describes all branches
- Datafile actually stores the nodes

When a query is made, only load in structure file. Datafile can be read when the nodes are actually needed.

To allow for tight packing of nodes and tags, without reordering the whole file at every write, some algorithm needs to manage memory and such.

Static node size? Could store tags & ways somewhere else.

### Insertions

- All data is connected to nodes (to optimize spatial queries)
- Nodes appear before ways

1. Initialize node
2. Connect tags
3. Insert node w tags

Per way
1. Register way into hashmap w connected nodes

Iterate through all nodes to connect after all ways

Tags should be filtered on relevancy during insertion, not query.

### Queries

Should be optimized for pathfinding.

After receiving nodes in area, create hashmap with node ids as keys. Each node maps to list of ways.

### Structurestore

Bytes:

Branch 0 (1-4)   Leaf 1    Leaf 2    
ABBBBBBBBCCCCCCCCADEEEEEEEEADEEEEEEEE
Branch 3 (5-8)   Leaf 5    Leaf 6    Leaf 7    Leaf 8    
ABBBBBBBBCCCCCCCCADEEEEEEEEADEEEEEEEEADEEEEEEEEADEEEEEEEE
Leaf 4 (from branch 0 still)
ADEEEEEEEE

A - Node type
B - latitude split
C - longitude split
D - OsmNode count within leaf
E - index of OSM Nodes within datafile

If node is of type branch, it's children are pushed to a filo stack.

This structure is compact, but is hard to load partially.

## Ways

- Connected nodes chart path

Navigation-relevant tags:

- highway. Main travel road specifier.
  - Good: footway, steps, pedestrian, bridleway, corridor, path 
  - Dubious: residential, living_street, track, crossing
  - Bad: road
- footway. Foot access in addition to another type of road.
  - sidewalk, traffic_island, crossing
- sidewalk.
  - both, left, right, no
- oneway.
- bicycle. 
  - use_sidepath

NOTE: should these be indexed upon insertion?

# Pathfinding Procedure

1. Load all nodes into memory.
  - Query all nodes
2. Graph all edges.
  1. Query all ways w their nodes
  2. Filter out non-traversable ways
  3. Determine 'friction' of ways (based on road type)
  4. Set weights based on node distance and way friction
    - Add 'loudness' later
  5. Remove non-intersections from map
3. Find shortest path between start and end node.
  - Maybe easier to do while evaluating instead of at graph creation

