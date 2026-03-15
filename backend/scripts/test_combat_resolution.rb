# frozen_string_literal: true

# Load full application to get all services
require_relative '../app'

fight = Fight[64]
puts "Fight #{fight.id}: status=#{fight.status}, round=#{fight.round_number}"
puts "All input complete: #{fight.all_inputs_complete?}"

if fight.all_inputs_complete?
  puts "Resolving round..."
  service = FightService.new(fight)
  result = service.resolve_round!
  puts "Result keys: #{result.keys}" if result.is_a?(Hash)

  if result.is_a?(Hash) && result[:events]
    puts "\n=== Combat Events (#{result[:events].length} total) ==="
    result[:events].each_with_index do |e, i|
      puts "Event #{i + 1}: #{e[:type]}"
      puts "  Description: #{e[:description]}" if e[:description]
      puts "  Narrative: #{e[:narrative]}" if e[:narrative]
      puts ""
    end
  end

  if result.is_a?(Hash) && result[:roll_display]
    puts "\n=== Roll Display ==="
    puts result[:roll_display]
  end

  # Also check the fight for narrative
  fight.refresh
  puts "\n=== Fight Round Events ==="
  puts fight.round_events.inspect if fight.round_events
else
  puts "Waiting for input from:"
  fight.participants.each do |p|
    ci = CharacterInstance[p.character_instance_id]
    puts "  #{ci.character.full_name}: input_complete=#{p.input_complete}"
  end
end
