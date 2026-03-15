require_relative '../spec/spec_helper'

room = Room.create(
  location_id: Location.first&.id || Location.create(name: "test").id,
  name: "test arena",
  room_type: "arena",
  min_x: 0, max_x: 40, min_y: 0, max_y: 40
)
puts "Room: #{room.id}, bounds: #{room.min_x},#{room.min_y} - #{room.max_x},#{room.max_y}"
service = BattleMapGeneratorService.new(room)
puts "Config: #{service.config.inspect}"
puts "Category: #{service.category}"
puts "room_has_bounds?: #{service.send(:room_has_bounds?)}"
begin
  DB.transaction do
    service.send(:clear_existing_hexes)
    puts "After clear: OK"
    service.send(:generate_base_terrain)
    puts "After generate_base_terrain: OK, hex count: #{room.room_hexes_dataset.count}"
    service.send(:place_cover_objects)
    puts "After place_cover_objects: OK"
    service.send(:add_hazards)
    puts "After add_hazards: OK"
    service.send(:mark_battle_map_ready)
    puts "After mark_battle_map_ready: OK"
  end
  puts "All generation steps completed successfully"
rescue StandardError => e
  puts "Error: #{e.class}: #{e.message}"
  puts e.backtrace.first(10).join("\n")
end
