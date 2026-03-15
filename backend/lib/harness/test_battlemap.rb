#!/usr/bin/env ruby
# frozen_string_literal: true

# Standalone battle map generation/reanalysis script for iterative tuning.
# Usage:
#   bundle exec ruby tmp/test_battlemap.rb [room_id] [mode]
#
# Modes:
#   reanalyze  - Re-run hex classification on existing image (fast, ~60s)
#   generate   - Generate new image + classify hexes (slow, ~120s)
#   clean      - Just clean up room data without regenerating
#
# Examples:
#   bundle exec ruby tmp/test_battlemap.rb 155 reanalyze
#   bundle exec ruby tmp/test_battlemap.rb 155 generate
#   bundle exec ruby tmp/test_battlemap.rb 155 clean

require_relative '../config/room_type_config'
Dir[File.join(__dir__, '../app/lib/*.rb')].each { |f| require f }
require_relative '../config/application'

ROOM_ID = (ARGV[0] || 155).to_i
MODE = ARGV[1] || 'reanalyze'

room = Room[ROOM_ID]
abort "Room #{ROOM_ID} not found" unless room

puts "=== Battle Map Test Tool ==="
puts "Room: #{room.id} - #{room.name}"
puts "Mode: #{MODE}"
puts "Bounds: #{room.min_x},#{room.min_y} → #{room.max_x},#{room.max_y}" if room.min_x
puts

# Clear debug log
log_path = File.join(__dir__, 'ai_battlemap_debug.log')
File.write(log_path, '')

case MODE
when 'clean'
  puts "Cleaning room #{ROOM_ID}..."
  RoomHex.where(room_id: ROOM_ID).delete
  room.update(has_battle_map: false, battle_map_image_url: nil, battle_map_config: Sequel.pg_jsonb_wrap({}))
  puts "Done. Room cleaned."

when 'reanalyze'
  image_url = room.battle_map_image_url
  abort "No existing battle map image for room #{ROOM_ID}. Use 'generate' mode." unless image_url

  image_path = File.join('public', image_url.sub(%r{^/}, ''))
  abort "Image file not found: #{image_path}" unless File.exist?(image_path)

  puts "Image: #{image_path}"
  puts "Clearing existing hex data..."
  RoomHex.where(room_id: ROOM_ID).delete

  puts "Re-analyzing hexes..."
  start = Time.now
  service = AIBattleMapGeneratorService.new(room, debug: false)
  result = service.reanalyze(image_path)
  elapsed = (Time.now - start).round(1)

  puts
  puts "=== Result (#{elapsed}s) ==="
  puts "Success: #{result[:success]}"
  puts "Hex count: #{result[:hex_count]}" if result[:hex_count]
  puts "Error: #{result[:error]}" if result[:error]

when 'generate'
  puts "Cleaning room #{ROOM_ID}..."
  RoomHex.where(room_id: ROOM_ID).delete
  room.update(has_battle_map: false, battle_map_image_url: nil, battle_map_config: Sequel.pg_jsonb_wrap({}))

  puts "Generating new battle map..."
  start = Time.now
  service = AIBattleMapGeneratorService.new(room, debug: false)
  result = service.generate
  elapsed = (Time.now - start).round(1)

  puts
  puts "=== Result (#{elapsed}s) ==="
  puts "Success: #{result[:success]}"
  puts "Hex count: #{result[:hex_count]}" if result[:hex_count]
  puts "Fallback: #{result[:fallback]}" unless result[:fallback].nil?
  puts "Error: #{result[:error]}" if result[:error]

else
  abort "Unknown mode: #{MODE}. Use 'reanalyze', 'generate', or 'clean'."
end

# Print debug log
puts
puts "=== Debug Log ==="
if File.exist?(log_path) && File.size(log_path) > 0
  puts File.read(log_path)
else
  puts "(empty)"
end

# Print hex type summary from DB
hex_counts = RoomHex.where(room_id: ROOM_ID)
                    .exclude(hex_type: 'normal')
                    .group_and_count(:hex_type)
                    .order(Sequel.desc(:count))
                    .all
if hex_counts.any?
  puts
  puts "=== DB Hex Types ==="
  hex_counts.each { |r| puts "  #{r[:hex_type]}: #{r[:count]}" }
  puts "  Total typed: #{hex_counts.sum { |r| r[:count] }}"
  total = RoomHex.where(room_id: ROOM_ID).count
  puts "  Total hexes: #{total}"
end
