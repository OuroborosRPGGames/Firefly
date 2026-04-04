# frozen_string_literal: true

# Consolidates game migrations 032 (LOD views with coords) and 033 (grid_locked).
# Creates H3 level-of-detail materialized views at resolutions 3, 4, 5
# and adds grid_locked boolean to worlds table.

Sequel.migration do
  up do
    # LOD materialized views with lat/lon columns
    run <<~SQL
      CREATE MATERIALIZED VIEW world_hexes_lod3 AS
      SELECT world_id,
             h3_cell_to_parent(h3_index::h3index, 3)::bigint AS parent_h3,
             mode() WITHIN GROUP (ORDER BY terrain_type) AS terrain_type,
             avg(altitude)::integer AS avg_altitude,
             count(*) AS hex_count,
             (h3_cell_to_latlng(h3_cell_to_parent(h3_index::h3index, 3)))[1] AS latitude,
             (h3_cell_to_latlng(h3_cell_to_parent(h3_index::h3index, 3)))[0] AS longitude
      FROM world_hexes
      WHERE h3_index IS NOT NULL
      GROUP BY world_id, h3_cell_to_parent(h3_index::h3index, 3)
    SQL

    run <<~SQL
      CREATE MATERIALIZED VIEW world_hexes_lod4 AS
      SELECT world_id,
             h3_cell_to_parent(h3_index::h3index, 4)::bigint AS parent_h3,
             mode() WITHIN GROUP (ORDER BY terrain_type) AS terrain_type,
             avg(altitude)::integer AS avg_altitude,
             count(*) AS hex_count,
             (h3_cell_to_latlng(h3_cell_to_parent(h3_index::h3index, 4)))[1] AS latitude,
             (h3_cell_to_latlng(h3_cell_to_parent(h3_index::h3index, 4)))[0] AS longitude
      FROM world_hexes
      WHERE h3_index IS NOT NULL
      GROUP BY world_id, h3_cell_to_parent(h3_index::h3index, 4)
    SQL

    run <<~SQL
      CREATE MATERIALIZED VIEW world_hexes_lod5 AS
      SELECT world_id,
             h3_cell_to_parent(h3_index::h3index, 5)::bigint AS parent_h3,
             mode() WITHIN GROUP (ORDER BY terrain_type) AS terrain_type,
             avg(altitude)::integer AS avg_altitude,
             count(*) AS hex_count,
             (h3_cell_to_latlng(h3_cell_to_parent(h3_index::h3index, 5)))[1] AS latitude,
             (h3_cell_to_latlng(h3_cell_to_parent(h3_index::h3index, 5)))[0] AS longitude
      FROM world_hexes
      WHERE h3_index IS NOT NULL
      GROUP BY world_id, h3_cell_to_parent(h3_index::h3index, 5)
    SQL

    run 'CREATE INDEX idx_lod3_world ON world_hexes_lod3 (world_id)'
    run 'CREATE INDEX idx_lod4_world ON world_hexes_lod4 (world_id)'
    run 'CREATE INDEX idx_lod5_world ON world_hexes_lod5 (world_id)'
    run 'CREATE INDEX idx_lod3_coords ON world_hexes_lod3 (world_id, latitude, longitude)'
    run 'CREATE INDEX idx_lod4_coords ON world_hexes_lod4 (world_id, latitude, longitude)'
    run 'CREATE INDEX idx_lod5_coords ON world_hexes_lod5 (world_id, latitude, longitude)'

    # Grid lock flag
    add_column :worlds, :grid_locked, :boolean, default: false, null: false
  end

  down do
    drop_column :worlds, :grid_locked

    run 'DROP MATERIALIZED VIEW IF EXISTS world_hexes_lod5'
    run 'DROP MATERIALIZED VIEW IF EXISTS world_hexes_lod4'
    run 'DROP MATERIALIZED VIEW IF EXISTS world_hexes_lod3'
  end
end
