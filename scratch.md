# Queries

Get all nodes + connected tags
```sql
SELECT osm_nodes.id, osm_nodes.latitude, osm_nodes.longitude, osm_tags.key, osm_tags.value, FROM osm_nodes
  LEFT JOIN osm_nodes_tags ON osm_nodes.id=osm_nodes_tags.node_id
  LEFT JOIN osm_tags ON osm_nodes_tags.tag_id=osm_tags.rowid
  ;
```

Get all ways + connected tags
```sql
SELECT osm_ways.id, osm_tags.key, osm_tags.value FROM osm_ways
  LEFT JOIN osm_ways_tags ON osm_ways.id=osm_ways_tags.way_id
  LEFT JOIN osm_tags ON osm_ways_tags.tag_id=osm_tags.rowid
  ;
```

# Ways

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
