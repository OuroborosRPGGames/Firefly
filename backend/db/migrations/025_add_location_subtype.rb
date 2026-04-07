# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:locations) do
      add_column :subtype, String, size: 50, default: 'misc'
    end
  end
end
