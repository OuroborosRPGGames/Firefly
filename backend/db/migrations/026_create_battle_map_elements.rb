# frozen_string_literal: true

# Creates battle_map_elements, battle_map_element_assets, and fight_hexes.
# Idempotent (create_table?) because Firefly's prod DB has these tables
# out-of-band — the migration exists so fresh clones get the schema.
Sequel.migration do
  change do
    create_table?(:battle_map_elements) do
      primary_key :id
      foreign_key :fight_id, :fights, null: false, on_delete: :cascade
      String :element_type, null: false
      Integer :hex_x
      Integer :hex_y
      String :edge_side
      String :state, null: false, default: 'intact'
      String :image_url
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP

      index :fight_id
      index [:fight_id, :hex_x, :hex_y]
    end

    create_table?(:battle_map_element_assets) do
      primary_key :id
      String :element_type, null: false
      Integer :variant, null: false
      String :image_url, null: false
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP

      index :element_type
      unique [:element_type, :variant]
    end

    create_table?(:fight_hexes) do
      primary_key :id
      foreign_key :fight_id, :fights, null: false, on_delete: :cascade
      Integer :hex_x, null: false
      Integer :hex_y, null: false
      String :hex_type, null: false
      String :hazard_type
      Integer :hazard_damage_per_round
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP

      index :fight_id
      index [:fight_id, :hex_x, :hex_y]
    end
  end
end
