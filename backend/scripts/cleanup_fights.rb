#!/usr/bin/env ruby
# One-time script to end all fights and delete all battle maps
require_relative "../config/application"

# 1. Find all fights
all_fights = Fight.all
ongoing = Fight.where(Sequel.~(status: "complete")).all
puts "Total fights: #{all_fights.count}"
puts "Ongoing fights: #{ongoing.count}"

# 2. Complete all ongoing fights
ongoing.each do |fight|
  begin
    fight.complete!
    puts "  Completed fight ##{fight.id}"
  rescue => e
    puts "  Error completing fight ##{fight.id}: #{e.message}"
  end
end

# 3. Delete ALL fights (cascade deletes participants, events, entry_delays)
deleted = Fight.dataset.delete
puts "\nDeleted #{deleted} fights (with cascaded participants/events/delays)"

# 4. Delete all room_hexes (battle map hex data)
hex_count = RoomHex.dataset.delete
puts "Deleted #{hex_count} room_hexes"

# 5. Clear battle map flags on rooms
rooms_cleared = Room.where(has_battle_map: true).update(
  has_battle_map: false,
  battle_map_image_url: nil,
  battle_map_config: nil
)
puts "Cleared battle map data from #{rooms_cleared} rooms"

puts "\nDone! All fights ended, deleted, and battle maps cleared."
