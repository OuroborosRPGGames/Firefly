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

# Show current state
fight.fight_participants.each do |p|
  ci = p.character_instance
  char = ci.character
  is_npc = char.npc?
  puts "#{char.full_name} (CI##{ci.id}) #{is_npc ? '[NPC]' : '[PC]'}:"
  puts "  Hex: (#{p.hex_x}, #{p.hex_y})"
  puts "  Char x/y: (#{ci.x}, #{ci.y})"
  puts "  input_complete: #{p.input_complete}"
  puts ""
end

# Apply AI decisions for NPCs who haven't completed input
puts "=== Applying AI Decisions ==="
fight.fight_participants.each do |p|
  next if p.input_complete
  next if p.is_knocked_out

  ci = p.character_instance
  char = ci.character

  # Apply AI decisions (works for both NPCs and players who haven't decided)
  puts "Applying AI for #{char.full_name}..."
  CombatAIService.new(p).apply_decisions!
  p.refresh
  puts "  -> input_complete: #{p.input_complete}"
end

puts ""
service = FightService.new(fight)
puts "ready_to_resolve?: #{service.ready_to_resolve?}"

if service.ready_to_resolve?
  puts "\n=== Resolving round #{fight.round_number}... ==="
  begin
    result = service.resolve_round!
    puts "Success! Events: #{result[:events].length}"
    result[:events].each_with_index do |e, i|
      puts "  Event #{i + 1}: #{e[:type]} - #{e[:description]}"
    end

    # Check position sync
    puts "\n=== After Resolution ==="
    fight.refresh
    fight.fight_participants.each do |p|
      p.refresh
      ci = p.character_instance
      ci.refresh
      char = ci.character
      puts "#{char.full_name}: Hex (#{p.hex_x}, #{p.hex_y}) -> World (#{ci.x}, #{ci.y})"
    end

    # Advance to next round if fight is still ongoing
    if fight.ongoing?
      puts "\n=== Advancing to next round... ==="
      service.next_round!
      fight.refresh
      puts "Now on round #{fight.round_number}, status: #{fight.status}"
    else
      puts "\n=== Fight completed ==="
    end
  rescue StandardError => e
    puts "Error: #{e.class} - #{e.message}"
    puts e.backtrace.first(10).join("\n")
  end
else
  puts "Still not ready to resolve - missing inputs"
end
