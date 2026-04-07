# frozen_string_literal: true

Sequel.migration do
  change do
    add_column :zones, :zone_subtype, :text
  end
end
