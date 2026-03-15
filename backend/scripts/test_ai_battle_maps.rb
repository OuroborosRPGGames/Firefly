#!/usr/bin/env ruby
# frozen_string_literal: true

# Test script for AI Battle Map Generation
# Creates test rooms with varying sizes and descriptions, then generates AI battle maps

require_relative '../config/application'
require 'faraday'

# Require the services we need
require_relative '../app/services/ai_provider_service'
require_relative '../app/services/llm/adapters/base_adapter'
require_relative '../app/services/llm/adapters/gemini_adapter'
require_relative '../app/services/llm/image_generation_service'
require_relative '../app/services/ai_battle_map_generator_service'
require_relative '../app/services/battle_map_generator_service'

puts "=" * 60
puts "AI Battle Map Generation Test"
puts "=" * 60

# Enable AI battle maps
puts "\n[1] Enabling AI battle maps setting..."
GameSetting.set('ai_battle_maps_enabled', 'true', type: 'boolean')
puts "    ai_battle_maps_enabled = #{GameSetting.boolean('ai_battle_maps_enabled')}"

# Check Gemini API availability
puts "\n[2] Checking Gemini API availability..."
gemini_available = AIProviderService.provider_available?('google_gemini')
puts "    Gemini available: #{gemini_available}"
unless gemini_available
  puts "    ERROR: Gemini API not available. Check GEMINI_API_KEY environment variable."
  exit 1
end

# Get or create a location for test rooms
puts "\n[3] Setting up test location..."
location = Location.first
unless location
  puts "    ERROR: No location found. Run seeds first."
  exit 1
end
puts "    Using location: #{location.name} (ID: #{location.id})"

# Test room configurations
TEST_ROOMS = [
  {
    name: "Small Tavern Back Room",
    short_description: "A small back room in the tavern",
    long_description: "A cozy back room with a single table, a few chairs pushed against the walls, and a dusty barrel in the corner. Torchlight flickers from a sconce near the door.",
    room_type: "bar",  # tavern/bar type
    min_x: 0, max_x: 4, min_y: 0, max_y: 4  # 3x3 grid (small)
  },
  {
    name: "Forest Clearing",
    short_description: "A clearing in the dark forest",
    long_description: "A natural clearing ringed by ancient oaks. Fallen logs create natural barriers, and a small stream cuts through one edge. Wildflowers dot the grass between patches of thick undergrowth.",
    room_type: "forest",  # valid forest type
    min_x: 0, max_x: 8, min_y: 0, max_y: 8  # 5x5 grid (medium)
  },
  {
    name: "Castle Great Hall",
    short_description: "The great hall of the castle",
    long_description: "A massive great hall with towering stone pillars supporting a vaulted ceiling. Long wooden tables run down the center, flanked by ornate tapestries on the walls. A raised dais at the far end holds the lord's throne. Braziers provide warmth and light.",
    room_type: "lobby",  # closest to great hall
    min_x: 0, max_x: 12, min_y: 0, max_y: 8  # 7x5 grid (wide)
  }
].freeze

# Create or update test rooms
puts "\n[4] Creating test rooms..."
created_rooms = []

TEST_ROOMS.each_with_index do |config, idx|
  room = Room.first(name: config[:name], location_id: location.id)

  if room
    puts "    Updating: #{config[:name]}"
    room.update(
      short_description: config[:short_description],
      long_description: config[:long_description],
      room_type: config[:room_type],
      min_x: config[:min_x],
      max_x: config[:max_x],
      min_y: config[:min_y],
      max_y: config[:max_y],
      has_battle_map: false,  # Reset
      battle_map_image_url: nil
    )
    # Clear existing hexes
    room.room_hexes_dataset.delete
  else
    puts "    Creating: #{config[:name]}"
    room = Room.create(
      location_id: location.id,
      name: config[:name],
      short_description: config[:short_description],
      long_description: config[:long_description],
      room_type: config[:room_type],
      min_x: config[:min_x],
      max_x: config[:max_x],
      min_y: config[:min_y],
      max_y: config[:max_y],
      safe_room: true
    )
  end

  hex_count = HexGrid.hex_coords_in_bounds(config[:min_x], config[:min_y], config[:max_x], config[:max_y]).count
  puts "       Room ID: #{room.id}, Hex grid size: #{hex_count} hexes"
  created_rooms << room
end

# Generate AI battle maps
puts "\n[5] Generating AI battle maps..."
results = []

created_rooms.each do |room|
  puts "\n    Processing: #{room.name} (ID: #{room.id})"
  puts "    Description: #{room.long_description[0..100]}..."

  start_time = Time.now

  begin
    service = AIBattleMapGeneratorService.new(room)
    result = service.generate

    elapsed = (Time.now - start_time).round(2)

    if result[:success]
      room.reload
      puts "    Result: SUCCESS"
      puts "      Hexes: #{result[:hex_count]}"
      puts "      Fallback: #{result[:fallback]}"
      puts "      Image URL: #{room.battle_map_image_url || 'none'}"
      puts "      Time: #{elapsed}s"

      # Show hex breakdown
      if room.room_hexes_dataset.any?
        hex_types = room.room_hexes_dataset.group_and_count(:hex_type).all
        puts "      Hex types: #{hex_types.map { |h| "#{h[:hex_type]}=#{h[:count]}" }.join(', ')}"

        cover_objects = room.room_hexes_dataset.exclude(cover_object: nil).select_map(:cover_object).uniq
        puts "      Cover objects: #{cover_objects.any? ? cover_objects.join(', ') : 'none'}"
      end
    else
      puts "    Result: FAILED"
      puts "      Error: #{result[:error]}"
      puts "      Time: #{elapsed}s"
    end

    results << { room: room, result: result, elapsed: elapsed }
  rescue => e
    puts "    ERROR: #{e.message}"
    puts "    #{e.backtrace.first(3).join("\n    ")}"
    results << { room: room, result: { success: false, error: e.message }, elapsed: 0 }
  end
end

# Summary
puts "\n" + "=" * 60
puts "SUMMARY"
puts "=" * 60

results.each do |r|
  status = r[:result][:success] ? (r[:result][:fallback] ? "FALLBACK" : "AI") : "FAILED"
  puts "#{r[:room].name}: #{status} (#{r[:elapsed]}s)"
end

puts "\nTest rooms created. View them at:"
created_rooms.each do |room|
  puts "  http://localhost:3000/admin/battle_maps/#{room.id}/edit"
end
