# frozen_string_literal: true

# Adds named world features (rivers, roads, railroads, etc.) so that
# feature lines drawn on the world map can carry a human-readable name
# like "Mississippi River" or "Pacific Railroad".
#
# A new `world_features` table stores the name + type once.
# Six nullable FK columns on `world_hexes` link each directional edge
# to its named feature, mirroring the existing `feature_<dir>` pattern.

Sequel.migration do
  up do
    create_table(:world_features) do
      primary_key :id
      foreign_key :world_id, :worlds, null: false, on_delete: :cascade
      String :name, null: false
      String :feature_type, null: false
      DateTime :created_at
      DateTime :updated_at

      index [:world_id]
      index [:world_id, :name], unique: true
    end

    %w[n ne se s sw nw].each do |dir|
      alter_table(:world_hexes) do
        add_foreign_key :"feature_id_#{dir}", :world_features, on_delete: :set_null
      end
    end
  end

  down do
    %w[n ne se s sw nw].each do |dir|
      alter_table(:world_hexes) do
        drop_foreign_key :"feature_id_#{dir}"
      end
    end

    drop_table(:world_features)
  end
end
