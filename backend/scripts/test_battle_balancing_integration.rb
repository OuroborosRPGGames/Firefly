#!/usr/bin/env ruby
# frozen_string_literal: true

# Integration test for battle balancing with real database
# Usage: bundle exec ruby scripts/test_battle_balancing_integration.rb

require_relative '../app'

puts "=" * 60
puts "Battle Balancing Integration Test"
puts "=" * 60
puts

# Find or create test data
puts "1. Setting up test data..."

# Find NPC archetypes (no universe_id - archetypes are global)
archetypes = NpcArchetype.limit(5).all
if archetypes.empty?
  puts "   No NPC archetypes found, creating test ones..."

  # Create test archetypes with individual combat columns
  boss = NpcArchetype.create(
    name: 'Test Boss',
    behavior_pattern: 'aggressive',
    combat_max_hp: 8,
    combat_damage_bonus: 3,
    combat_defense_bonus: 2,
    combat_speed_modifier: 1,
    combat_ai_profile: 'aggressive',
    damage_dice_count: 2,
    damage_dice_sides: 8
  )

  minion = NpcArchetype.create(
    name: 'Test Minion',
    behavior_pattern: 'neutral',
    combat_max_hp: 4,
    combat_damage_bonus: 1,
    combat_defense_bonus: 0,
    combat_speed_modifier: 0,
    combat_ai_profile: 'balanced',
    damage_dice_count: 2,
    damage_dice_sides: 6
  )

  archetypes = [boss, minion]
end

puts "   Found #{archetypes.count} archetypes:"
archetypes.each do |a|
  stats = a.combat_stats
  puts "     - #{a.name} (HP: #{stats[:max_hp]}, DMG+#{stats[:damage_bonus]}, DEF+#{stats[:defense_bonus]})"
end

# Find characters to use as PCs (not NPCs)
characters = Character.exclude(is_npc: true).limit(4).all
if characters.empty?
  puts "   No PC characters found, creating test ones..."

  # Need a universe first for characters
  universe = Universe.first
  unless universe
    puts "   ERROR: No universe found. Run seeds first."
    exit 1
  end

  4.times do |i|
    Character.create(
      universe_id: universe.id,
      forename: "Test Hero #{i + 1}",
      is_npc: false
    )
  end
  characters = Character.exclude(is_npc: true).limit(4).all
end

puts "   Found #{characters.count} PC characters:"
characters.each { |c| puts "     - #{c.full_name}" }
puts

# Test power calculations
puts "2. Testing power calculations..."

pc_power = PowerCalculatorService.calculate_pc_group_power(characters.map(&:id))
puts "   Combined PC power: #{pc_power.round(1)}"

archetypes.each do |a|
  power = PowerCalculatorService.calculate_archetype_power(a)
  puts "   #{a.name} power: #{power.round(1)}"
end
puts

# Test initial composition estimate
puts "3. Testing initial composition estimate..."

mandatory = [archetypes.first]
optional = archetypes[1..] || []

composition = PowerCalculatorService.estimate_balanced_composition(
  pc_power: pc_power,
  mandatory_archetypes: mandatory,
  optional_archetypes: optional
)

puts "   Initial estimate:"
composition.each do |id, config|
  archetype = NpcArchetype[id]
  puts "     - #{config[:count]}x #{archetype&.name || 'Unknown'}"
end
puts

# Test simulation
puts "4. Testing combat simulation..."

pcs = PowerCalculatorService.pcs_to_participants(characters.map(&:id))
npcs = PowerCalculatorService.composition_to_participants(composition)

puts "   PCs: #{pcs.map(&:name).join(', ')}"
puts "   NPCs: #{npcs.map(&:name).join(', ')}"

results = 10.times.map do |i|
  fresh_pcs = pcs.map do |p|
    CombatSimulatorService::SimParticipant.new(
      id: p.id, name: p.name, is_pc: p.is_pc, team: p.team,
      current_hp: p.max_hp, max_hp: p.max_hp,
      hex_x: p.hex_x, hex_y: p.hex_y,
      damage_bonus: p.damage_bonus, defense_bonus: p.defense_bonus,
      speed_modifier: p.speed_modifier,
      damage_dice_count: p.damage_dice_count, damage_dice_sides: p.damage_dice_sides,
      stat_modifier: p.stat_modifier, ai_profile: p.ai_profile
    )
  end

  fresh_npcs = npcs.map do |p|
    CombatSimulatorService::SimParticipant.new(
      id: p.id, name: p.name, is_pc: p.is_pc, team: p.team,
      current_hp: p.max_hp, max_hp: p.max_hp,
      hex_x: p.hex_x, hex_y: p.hex_y,
      damage_bonus: p.damage_bonus, defense_bonus: p.defense_bonus,
      speed_modifier: p.speed_modifier,
      damage_dice_count: p.damage_dice_count, damage_dice_sides: p.damage_dice_sides,
      stat_modifier: p.stat_modifier, ai_profile: p.ai_profile
    )
  end

  sim = CombatSimulatorService.new(pcs: fresh_pcs, npcs: fresh_npcs, seed: i * 1000)
  sim.simulate!
end

wins = results.count(&:pc_victory)
avg_rounds = results.sum(&:rounds_taken) / 10.0

puts "   Results: #{wins}/10 PC wins, avg #{avg_rounds.round(1)} rounds"

aggregate = BalanceScoreCalculator.aggregate_scores(results)
puts "   Score: #{aggregate[:avg_score].round(1)} (target: 30-80)"
puts "   Status: #{aggregate[:is_balanced] ? 'BALANCED' : aggregate[:adjustment_hint].to_s.upcase}"
puts

# Test full balancing service
puts "5. Testing full balancing service..."

begin
  balancer = BattleBalancingService.new(
    pc_ids: characters.map(&:id),
    mandatory_archetype_ids: [archetypes.first.id],
    optional_archetype_ids: archetypes[1..]&.map(&:id) || []
  )

  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  result = balancer.balance!
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

  puts "   Iterations: #{result[:iterations_used]}"
  puts "   Simulations: #{result[:simulation_count]}"
  puts "   Time: #{(elapsed * 1000).round(0)}ms"
  puts "   Status: #{result[:status]}"
  puts "   Final score: #{result[:aggregate][:avg_score].round(1)}"
  puts "   Win rate: #{(result[:aggregate][:win_rate] * 100).round(1)}%"

  puts "\n   Final composition:"
  result[:composition].each do |id, config|
    archetype = NpcArchetype[id]
    modifier = result[:stat_modifiers][id]
    mod_str = modifier && modifier != 0 ? " (#{modifier > 0 ? '+' : ''}#{(modifier * 100).round}% stats)" : ""
    puts "     - #{config[:count]}x #{archetype&.name || 'Unknown'}#{mod_str}"
  end

  puts "\n   Difficulty variants generated: #{result[:difficulty_variants].keys.join(', ')}"
rescue => e
  puts "   ERROR: #{e.message}"
  puts e.backtrace.first(5).join("\n")
end

puts
puts "=" * 60
puts "Integration Test Complete"
puts "=" * 60
