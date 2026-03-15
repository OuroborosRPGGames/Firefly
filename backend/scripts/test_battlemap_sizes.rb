# frozen_string_literal: true

# Test AI battle map generation across different room sizes
# to understand chunking needs and prompt effectiveness

require_relative '../app'

$stdout.sync = true

SIZES_TO_TEST = [
  { name: 'Huge', width: 80, height: 80 }    # 20x20 = 400 hexes
]

def test_room_size(config)
  puts "=" * 60
  puts "Testing #{config[:name]} room: #{config[:width]}x#{config[:height]} feet"

  # Find or create test room
  room = Room.first || Room.create(
    name: "Test Room",
    short_description: "A test room for battle maps",
    room_type: 'standard'
  )

  # Set bounds
  room.update(
    min_x: 0.0,
    min_y: 0.0,
    max_x: config[:width].to_f,
    max_y: config[:height].to_f
  )

  # Calculate expected hex count
  arena_w, arena_h = HexGrid.arena_dimensions_from_feet(config[:width], config[:height])
  expected_hexes = arena_w * arena_h
  puts "Arena: #{arena_w}x#{arena_h} = #{expected_hexes} hexes"

  # Clear existing data
  room.room_hexes_dataset.delete
  room.update(has_battle_map: false, battle_map_image_url: nil)

  # Time the generation
  start_time = Time.now
  service = AIBattleMapGeneratorService.new(room)
  result = service.generate
  duration = Time.now - start_time

  room.refresh

  puts "Duration: #{duration.round(2)}s"
  puts "Result: #{result[:success] ? 'SUCCESS' : 'FAILED'}"
  puts "Fallback: #{result[:fallback]}"
  puts "Hex count: #{room.room_hexes_dataset.count} (expected: #{expected_hexes})"
  puts "Error: #{result[:error]}" if result[:error]

  # Sample some hexes
  if room.room_hexes_dataset.count > 0
    samples = room.room_hexes.take(5)
    puts "Sample hexes:"
    samples.each do |h|
      puts "  (#{h.hex_x}, #{h.hex_y}): #{h.hex_type}, surface=#{h.surface_type}, cover=#{h.cover_object || 'none'}"
    end
  end

  puts ""

  {
    name: config[:name],
    dimensions: "#{config[:width]}x#{config[:height]}",
    arena: "#{arena_w}x#{arena_h}",
    expected: expected_hexes,
    actual: room.room_hexes_dataset.count,
    success: result[:success],
    fallback: result[:fallback],
    duration: duration.round(2),
    error: result[:error]
  }
end

# Run tests
results = []
SIZES_TO_TEST.each do |config|
  results << test_room_size(config)
end

# Summary
puts "=" * 60
puts "SUMMARY"
puts "=" * 60
puts format("%-10s %-12s %-10s %-8s %-8s %-10s %-8s",
            "Size", "Dimensions", "Arena", "Expected", "Actual", "Fallback", "Time")
results.each do |r|
  puts format("%-10s %-12s %-10s %-8d %-8d %-10s %-8.2fs",
              r[:name], r[:dimensions], r[:arena], r[:expected], r[:actual],
              r[:fallback] ? "YES" : "no", r[:duration])
end
