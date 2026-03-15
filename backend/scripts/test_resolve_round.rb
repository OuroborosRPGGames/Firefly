# frozen_string_literal: true

# Test script for monster combat resolution
# Run with: DEBUG=1 bundle exec ruby scripts/test_resolve_round.rb

require_relative '../config/application'

# Get the fight
fight = Fight.where(status: 'input').order(Sequel.desc(:id)).first
puts "Fight #{fight.id}: status=#{fight.status}, round=#{fight.round_number}"

# Resolve the round
puts 'Resolving round...'

# The fight service should handle round resolution
if fight.all_inputs_complete?
  puts 'All inputs complete - triggering resolution'

  # Update fight to resolving status
  fight.update(status: 'resolving')

  # Use CombatResolutionService directly
  resolution_service = CombatResolutionService.new(fight)
  result = resolution_service.resolve!

  fight.refresh
  puts "Resolution completed!"
  puts "Fight status: #{fight.status}"
  puts "Fight round: #{fight.round_number}"

  # Check monster HP
  LargeMonsterInstance.where(fight_id: fight.id).each do |m|
    puts "\nMonster: #{m.display_name}"
    puts "  HP: #{m.current_hp}/#{m.max_hp}"
    puts "  Status: #{m.status}"
    m.monster_segment_instances.each do |s|
      puts "  Segment #{s.name}: #{s.current_hp}/#{s.max_hp} (#{s.status})"
    end
  end

  # Check participant HP
  fight.fight_participants.each do |p|
    puts "\nParticipant: #{p.character_name}"
    puts "  HP: #{p.current_hp}/#{p.max_hp}"
  end

  # Check events
  events = FightEvent.where(fight_id: fight.id).all
  puts "\nFight events: #{events.count}"
  events.each do |e|
    puts "  Round #{e.round_number}, Segment #{e.segment}: #{e.event_type}"
  end
else
  puts 'Inputs not complete'
  fight.fight_participants.each do |p|
    puts "  #{p.character_name}: input_complete=#{p.input_complete}"
  end
end
