- Zig 0.13.0

# Queries

Get all nodes + connected tags
```sql
SELECT osm_nodes.id, osm_nodes.latitude, osm_nodes.longitude, osm_nodes_tags.key, osm_nodes_tags.value FROM osm_nodes
  LEFT JOIN osm_nodes_tags ON osm_nodes.id=osm_nodes_tags.node_id
  ;
```

Get nodes in area
```sql
SELECT osm_nodes.id, osm_nodes.latitude, osm_nodes.longitude, osm_nodes_tags.key, osm_nodes_tags.value FROM osm_nodes
  LEFT JOIN osm_nodes_tags ON osm_nodes.id=osm_nodes_tags.node_id
  WHERE osm_nodes.latitude > 51.922647 AND osm_nodes.latitude < 51.925558 AND osm_nodes.longitude > 4.474488 AND osm_nodes.longitude < 4.48291
  ;
```
With SQLite, this takes 11.5 seconds on "zuid-holland-latest.osm"
14 seconds with simplified tags...

Get all ways + connected tags
```sql
SELECT osm_ways.id, osm_ways_tags.key, osm_ways_tags.value FROM osm_ways
  LEFT JOIN osm_ways_tags ON osm_ways.id=osm_ways_tags.way_id
  ;
```

## Database

- Sqlite needs to keep all data in-memory

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

