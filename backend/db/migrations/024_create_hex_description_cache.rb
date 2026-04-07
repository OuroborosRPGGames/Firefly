# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:hex_description_caches) do
      primary_key :id
      String :template_hash, null: false, unique: true
      text :template_text, null: false
      text :description, null: false
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
    end
  end
end
