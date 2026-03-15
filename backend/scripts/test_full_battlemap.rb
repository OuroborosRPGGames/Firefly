# frozen_string_literal: true

require_relative '../app'

# Find a room with bounds
room = Room.where(Sequel.lit('min_x IS NOT NULL AND max_x IS NOT NULL')).first

if room.nil?
  puts "No room with bounds found"
  exit
end

puts "=== Testing Full Battle Map Generation ==="
puts "Room: #{room.name} (ID: #{room.id})"
puts "Bounds: (#{room.min_x}, #{room.min_y}) to (#{room.max_x}, #{room.max_y})"

room_width = room.max_x - room.min_x
room_height = room.max_y - room.min_y
arena_w, arena_h = HexGrid.arena_dimensions_from_feet(room_width, room_height)
total_hexes = arena_w * arena_h
puts "Expected hexes: #{arena_w} x #{arena_h} = #{total_hexes}"

puts ""
puts "=== Checking AI Settings ==="
ai_enabled = defined?(GameSetting) && GameSetting.boolean('ai_battle_maps_enabled')
puts "AI battle maps enabled: #{ai_enabled}"

gemini_available = AIProviderService.provider_available?('google_gemini')
puts "Gemini provider available: #{gemini_available}"

puts ""
puts "=== Generating Battle Map ==="
service = AIBattleMapGeneratorService.new(room)
result = service.generate

puts ""
puts "=== Result ==="
puts "Success: #{result[:success]}"
puts "Hex count: #{result[:hex_count]}"
puts "Fallback used: #{result[:fallback]}"
puts "Error: #{result[:error]}" if result[:error]

if result[:success]
  room.refresh
  puts ""
  puts "=== Room After Generation ==="
  puts "has_battle_map: #{room.has_battle_map}"
  puts "battle_map_image_url: #{room.battle_map_image_url}"

  hex_count = room.room_hexes_dataset.count
  puts "RoomHex records: #{hex_count}"

  if hex_count > 0
    puts ""
    puts "=== Sample Hexes ==="
    room.room_hexes_dataset.limit(10).each do |hex|
      puts "  Hex (#{hex.hex_x}, #{hex.hex_y}): #{hex.hex_type}, cover=#{hex.cover_object || 'none'}, hazard=#{hex.hazard_type || 'none'}, elevation=#{hex.elevation_level}"
    end

    # Stats
    puts ""
    puts "=== Hex Statistics ==="
    types = room.room_hexes_dataset.group_and_count(:hex_type).all
    puts "By type: #{types.map { |t| "#{t[:hex_type]}=#{t[:count]}" }.join(', ')}"

    with_cover = room.room_hexes_dataset.exclude(cover_object: nil).count
    puts "With cover objects: #{with_cover}"

    with_hazards = room.room_hexes_dataset.exclude(hazard_type: nil).count
    puts "With hazards: #{with_hazards}"

    elevated = room.room_hexes_dataset.exclude(elevation_level: 0).count
    puts "With elevation changes: #{elevated}"
  end
end
