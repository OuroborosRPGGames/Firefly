# frozen_string_literal: true

require 'bundler/setup'
require 'sequel'

# Connect directly to database without loading models
DB = Sequel.connect(ENV['DATABASE_URL'] || 'postgres://prom_user:prom_password@localhost/firefly')

puts "Marking all existing battle maps as stale..."
puts "Battle maps will regenerate with new 2ft hex system on next fight."
puts

# Check if room_hexes table exists
table_exists = DB.table_exists?(:room_hexes)

# Count before
rooms_with_maps = DB[:rooms].where(has_battle_map: true).count
hex_count = table_exists ? DB[:room_hexes].count : 0

puts "Before:"
puts "  Rooms with battle maps: #{rooms_with_maps}"
puts "  Total room hexes: #{hex_count}"
puts

if rooms_with_maps == 0
  puts "No battle maps found. Nothing to do."
  exit 0
end

# Get IDs of rooms with battle maps (for hex deletion)
room_ids = DB[:rooms].where(has_battle_map: true).select(:id).map(:id)

# Mark rooms as not having battle maps
DB[:rooms].where(has_battle_map: true).update(has_battle_map: false)

# Delete all room hex data (if table exists)
deleted = 0
if table_exists && room_ids.any?
  deleted = DB[:room_hexes].where(room_id: room_ids).delete
end

puts "After:"
puts "  Rooms marked for regeneration: #{rooms_with_maps}"
puts "  Room hexes deleted: #{deleted}"
puts
puts "Done! Battle maps will regenerate with:"
puts "  - 2ft hexes (was 4ft)"
puts "  - Boolean cover system (was 0-4 scale)"
puts "  - Concealed hex type support"
puts "  - Scaled distances (×1.5)"
