# frozen_string_literal: true

# Consolidates game migrations 026 (h3_index) and 029 (voronoi boundary columns).
# Adds H3 geospatial index, precomputed neighbor IDs, and Voronoi boundary vertices.

Sequel.migration do
  no_transaction

  up do
    # Try to enable h3 extension (non-fatal if unavailable)
    begin
      run 'CREATE EXTENSION IF NOT EXISTS h3'
    rescue Sequel::DatabaseError => e
      $stderr.puts "[Migration 021] h3 extension not available: #{e.message}"
    end

    alter_table(:world_hexes) do
      add_column :h3_index, :bigint
      add_column :neighbor_globe_hex_ids, 'integer[]'
      add_column :boundary_vertices, :jsonb
    end

    add_index :world_hexes, :h3_index, name: :idx_world_hexes_h3_index,
              where: Sequel.lit('h3_index IS NOT NULL')

    add_index :world_hexes, :world_id,
              name: :idx_world_hexes_no_neighbors,
              where: Sequel.lit('neighbor_globe_hex_ids IS NULL AND latitude IS NOT NULL')
  end

  down do
    drop_index :world_hexes, nil, name: :idx_world_hexes_no_neighbors
    drop_index :world_hexes, nil, name: :idx_world_hexes_h3_index
    alter_table(:world_hexes) do
      drop_column :boundary_vertices
      drop_column :neighbor_globe_hex_ids
      drop_column :h3_index
    end
  end
end
