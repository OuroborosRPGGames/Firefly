# frozen_string_literal: true

require_relative '../app'

# Find active fight
fight = Fight.where(status: %w[input resolving narrative]).first
if fight.nil?
  puts "No active fight found"
  exit
end

puts "Fight ##{fight.id}: status=#{fight.status}, round=#{fight.round_number}"
puts "Arena: #{fight.arena_width}x#{fight.arena_height} hexes"
puts ""

fight.fight_participants.each do |p|
  ci = p.character_instance
  char = ci.character
  puts "#{char.full_name} (CI##{ci.id}):"
  puts "  Hex: (#{p.hex_x}, #{p.hex_y})"
  puts "  Char x/y: (#{ci.x}, #{ci.y})"
  puts "  input_complete: #{p.input_complete}"
  puts "  is_knocked_out: #{p.is_knocked_out}"
  puts ""
end

puts "all_inputs_complete?: #{fight.all_inputs_complete?}"
puts "input_timed_out?: #{fight.input_timed_out?}"

service = FightService.new(fight)
puts "ready_to_resolve?: #{service.ready_to_resolve?}"

if service.ready_to_resolve?
  puts "\n=== Resolving round... ==="
  begin
    result = service.resolve_round!
    puts "Success! Events: #{result[:events].length}"
    result[:events].each_with_index do |e, i|
      puts "  Event #{i + 1}: #{e[:type]} - #{e[:description]}"
    end

    # Check if movement synced
    puts "\n=== After Resolution ==="
    fight.refresh
    fight.fight_participants.each do |p|
      p.refresh
      ci = p.character_instance
      ci.refresh
      char = ci.character
      puts "#{char.full_name}: Hex (#{p.hex_x}, #{p.hex_y}) -> World (#{ci.x}, #{ci.y})"
    end

    # Now advance to next round
    puts "\n=== Advancing to next round... ==="
    service.next_round!
    puts "Now on round #{fight.round_number}"
  rescue StandardError => e
    puts "Error: #{e.class} - #{e.message}"
    puts e.backtrace.first(10).join("\n")
  end
else
  puts "Waiting for all participants to complete input"
end
