# frozen_string_literal: true

require_relative '../app'

begin
  puts "Script starting..."

  # Use the small closet room (3x3 hexes)
  room = Room[182]

  if room.nil?
    puts "Room 182 not found"
    exit
  end

  room_width = room.max_x - room.min_x
  room_height = room.max_y - room.min_y
  arena_w, arena_h = HexGrid.arena_dimensions_from_feet(room_width, room_height)
  puts "=== Using room: #{room.name} (ID: #{room.id}) ==="
  puts "Size: #{room_width}ft x #{room_height}ft = #{arena_w}x#{arena_h} hexes (#{arena_w * arena_h} total)"
  puts "Description: #{room.long_description || room.short_description}"

  puts ''
  puts '=== Generating Battle Map ==='
  service = AIBattleMapGeneratorService.new(room)

  # Check the prompt first
  prompt = service.send(:build_image_prompt)
  puts "Image prompt: #{prompt}"
  puts ''

  result = service.generate
  puts "Result: #{result.inspect}"

  if result[:success] && !result[:fallback]
    room.refresh
    puts ''
    puts "SUCCESS! AI generation worked."
    puts "Image URL: #{room.battle_map_image_url}"
    puts "Hex count: #{room.room_hexes_dataset.count}"

    puts ''
    puts '=== All Hexes ==='
    room.room_hexes.each do |hex|
      details = []
      details << "cover=#{hex.cover_object}" if hex.cover_object
      details << "hazard=#{hex.hazard_type}" if hex.hazard_type
      details << "elev=#{hex.elevation_level}" if hex.elevation_level != 0
      details << "water=#{hex.water_type}" if hex.water_type
      details << "surface=#{hex.surface_type}" if hex.surface_type && hex.surface_type != 'stone'
      extra = details.any? ? " (#{details.join(', ')})" : ''
      puts "  (#{hex.hex_x}, #{hex.hex_y}): #{hex.hex_type}#{extra}"
    end
  elsif result[:fallback]
    puts ''
    puts "Fell back to procedural generation: #{result[:error]}"
  else
    puts ''
    puts "Generation failed: #{result[:error]}"
  end
rescue StandardError => e
  puts "ERROR: #{e.class} - #{e.message}"
  puts e.backtrace.first(15).join("\n")
end
