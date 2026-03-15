#!/usr/bin/env ruby
# frozen_string_literal: true

# Benchmark script for CombatSimulatorService
# Target: 20 simulations in < 1 second, single simulation < 50ms
#
# Usage: bundle exec ruby scripts/benchmark_combat_simulator.rb

# Load the full application to ensure all services are available
require_relative '../app'

puts "=" * 60
puts "Combat Simulator Performance Benchmark"
puts "=" * 60
puts

# Create test participants using pure Ruby structs
def create_test_pcs(count = 4)
  count.times.map do |i|
    CombatSimulatorService::SimParticipant.new(
      id: i + 1,
      name: "Hero #{i + 1}",
      is_pc: true,
      team: 'pc',
      current_hp: 6,
      max_hp: 6,
      hex_x: 1,
      hex_y: i * 2,
      damage_bonus: 0,
      defense_bonus: 0,
      speed_modifier: 0,
      damage_dice_count: 2,
      damage_dice_sides: 8,
      stat_modifier: 12,
      ai_profile: 'balanced'
    )
  end
end

def create_test_npcs(count = 4)
  profiles = %w[aggressive balanced defensive berserker]

  count.times.map do |i|
    CombatSimulatorService::SimParticipant.new(
      id: 100 + i,
      name: "Goblin #{i + 1}",
      is_pc: false,
      team: 'npc',
      current_hp: 4,
      max_hp: 4,
      hex_x: 8,
      hex_y: i * 2,
      damage_bonus: 1,
      defense_bonus: 0,
      speed_modifier: 1,
      damage_dice_count: 2,
      damage_dice_sides: 6,
      stat_modifier: 10,
      ai_profile: profiles[i % profiles.length]
    )
  end
end

# Benchmark helper
def benchmark(label, &block)
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  result = block.call
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
  [result, elapsed]
end

# Test 1: Single simulation timing
puts "Test 1: Single Simulation Performance"
puts "-" * 40

pcs = create_test_pcs(4)
npcs = create_test_npcs(4)

times = []
5.times do |i|
  # Deep copy participants for fresh state
  fresh_pcs = create_test_pcs(4)
  fresh_npcs = create_test_npcs(4)

  result, elapsed = benchmark("Simulation #{i + 1}") do
    sim = CombatSimulatorService.new(pcs: fresh_pcs, npcs: fresh_npcs, seed: 12345 + i)
    sim.simulate!
  end

  times << elapsed
  puts "  Run #{i + 1}: #{(elapsed * 1000).round(2)}ms - #{result.pc_victory ? 'PC Win' : 'NPC Win'} in #{result.rounds_taken} rounds"
end

avg_single = times.sum / times.count
puts "\n  Average: #{(avg_single * 1000).round(2)}ms per simulation"
puts "  Target:  < 50ms"
puts "  Status:  #{avg_single < 0.05 ? '✓ PASS' : '✗ FAIL'}"
puts

# Test 2: 20 simulations (the target batch size)
puts "Test 2: Batch of 20 Simulations"
puts "-" * 40

results = nil
_, batch_elapsed = benchmark("20 simulations") do
  results = 20.times.map do |i|
    fresh_pcs = create_test_pcs(4)
    fresh_npcs = create_test_npcs(4)

    sim = CombatSimulatorService.new(pcs: fresh_pcs, npcs: fresh_npcs, seed: i * 1000)
    sim.simulate!
  end
end

wins = results.count(&:pc_victory)
avg_rounds = results.sum(&:rounds_taken) / 20.0

puts "  Total time: #{(batch_elapsed * 1000).round(2)}ms"
puts "  Per sim:    #{(batch_elapsed / 20 * 1000).round(2)}ms"
puts "  Win rate:   #{wins}/20 (#{(wins / 20.0 * 100).round(1)}%)"
puts "  Avg rounds: #{avg_rounds.round(1)}"
puts "\n  Target:  < 1000ms for 20 simulations"
puts "  Status:  #{batch_elapsed < 1.0 ? '✓ PASS' : '✗ FAIL'}"
puts

# Test 3: Score calculation performance
puts "Test 3: Score Calculation Performance"
puts "-" * 40

_, score_elapsed = benchmark("Score 20 results") do
  results.each { |r| BalanceScoreCalculator.score_result(r) }
  BalanceScoreCalculator.aggregate_scores(results)
end

puts "  Score time: #{(score_elapsed * 1000).round(4)}ms"
puts

# Test 4: Scalability test
puts "Test 4: Scalability (100 simulations)"
puts "-" * 40

_, scale_elapsed = benchmark("100 simulations") do
  100.times.map do |i|
    fresh_pcs = create_test_pcs(4)
    fresh_npcs = create_test_npcs(4)

    sim = CombatSimulatorService.new(pcs: fresh_pcs, npcs: fresh_npcs, seed: i)
    sim.simulate!
  end
end

puts "  Total time: #{(scale_elapsed * 1000).round(2)}ms"
puts "  Per sim:    #{(scale_elapsed / 100 * 1000).round(2)}ms"
puts

# Test 5: Large battle (8v8)
puts "Test 5: Large Battle (8v8)"
puts "-" * 40

large_pcs = create_test_pcs(8)
large_npcs = create_test_npcs(8)

_, large_elapsed = benchmark("8v8 simulation") do
  sim = CombatSimulatorService.new(pcs: large_pcs, npcs: large_npcs, seed: 999)
  sim.simulate!
end

puts "  Time: #{(large_elapsed * 1000).round(2)}ms"
puts

# Summary
puts "=" * 60
puts "SUMMARY"
puts "=" * 60
puts "Single sim (avg): #{(avg_single * 1000).round(2)}ms (target < 50ms)"
puts "20 sims batch:    #{(batch_elapsed * 1000).round(2)}ms (target < 1000ms)"
puts "100 sims:         #{(scale_elapsed * 1000).round(2)}ms"
puts "8v8 battle:       #{(large_elapsed * 1000).round(2)}ms"
puts

all_pass = avg_single < 0.05 && batch_elapsed < 1.0
if all_pass
  puts "✓ ALL PERFORMANCE TARGETS MET"
else
  puts "✗ SOME TARGETS NOT MET - optimization needed"
end
