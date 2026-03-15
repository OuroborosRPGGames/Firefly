# frozen_string_literal: true

# Script to test monster combat resolution.
# Run with: bundle exec ruby scripts/test_monster_combat.rb

require_relative '../config/application'

# Check state
char = Character.first(name: 'Testbot Agent')
ci = CharacterInstance.first(character_id: char.id)
fight = FightService.find_active_fight(ci)

if fight.nil?
  puts 'No active fight found'
  exit
end

puts "Fight #{fight.id}: status=#{fight.status}, round=#{fight.round_number}"

# Try to run combat resolution manually
fight_service = FightService.new(fight)
puts "\nTrying to resolve round..."

# Debug: Check what event types will be recorded
puts "\nEvent types allowed: #{FightEvent::EVENT_TYPES}"

begin
  result = fight_service.resolve_round!
  puts "Resolution completed!"
  fight.refresh
  puts "New status: #{fight.status}"
  puts "New round: #{fight.round_number}"

  # Check monster HP
  LargeMonsterInstance.where(fight_id: fight.id).each do |m|
    puts "\nMonster: #{m.display_name}"
    puts "  HP: #{m.current_hp}/#{m.max_hp}"
    puts "  Status: #{m.status}"
  end

  # Check participant HP
  fight.fight_participants.each do |p|
    puts "\nParticipant: #{p.character_name}"
    puts "  HP: #{p.current_hp}/#{p.max_hp}"
  end
rescue => e
  puts "Error: #{e.message}"
  puts e.backtrace.first(20).join("\n")
end
