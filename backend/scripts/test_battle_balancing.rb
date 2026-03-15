#!/usr/bin/env ruby
# frozen_string_literal: true

# Standalone tests for battle balancing services
# Runs without requiring full application or database
#
# Usage: bundle exec ruby scripts/test_battle_balancing.rb

require 'bundler/setup'

# Load only the services we need (no database)
require_relative '../app/services/combat_simulator_service'
require_relative '../app/services/balance_score_calculator'

class TestRunner
  def initialize
    @passed = 0
    @failed = 0
    @errors = []
  end

  def assert(condition, message)
    if condition
      @passed += 1
      print '.'
    else
      @failed += 1
      @errors << message
      print 'F'
    end
  end

  def assert_eq(actual, expected, message)
    if actual == expected
      @passed += 1
      print '.'
    else
      @failed += 1
      @errors << "#{message}: expected #{expected.inspect}, got #{actual.inspect}"
      print 'F'
    end
  end

  def assert_between(value, min, max, message)
    if value >= min && value <= max
      @passed += 1
      print '.'
    else
      @failed += 1
      @errors << "#{message}: expected #{min}..#{max}, got #{value}"
      print 'F'
    end
  end

  def run!
    puts "=" * 60
    puts "Battle Balancing System Tests"
    puts "=" * 60
    puts

    test_sim_participant
    test_combat_simulator
    test_balance_score_calculator
    test_performance

    puts "\n\n"
    puts "=" * 60
    puts "Results: #{@passed} passed, #{@failed} failed"
    puts "=" * 60

    if @errors.any?
      puts "\nFailures:"
      @errors.each_with_index do |err, i|
        puts "  #{i + 1}. #{err}"
      end
    end

    exit(@failed == 0 ? 0 : 1)
  end

  private

  def create_pc(overrides = {})
    CombatSimulatorService::SimParticipant.new({
      id: rand(1..999),
      name: 'Hero',
      is_pc: true,
      team: 'pc',
      current_hp: 6,
      max_hp: 6,
      hex_x: 1,
      hex_y: 0,
      damage_bonus: 0,
      defense_bonus: 0,
      speed_modifier: 0,
      damage_dice_count: 2,
      damage_dice_sides: 8,
      stat_modifier: 12,
      ai_profile: 'balanced'
    }.merge(overrides))
  end

  def create_npc(overrides = {})
    CombatSimulatorService::SimParticipant.new({
      id: rand(1000..1999),
      name: 'Goblin',
      is_pc: false,
      team: 'npc',
      current_hp: 4,
      max_hp: 4,
      hex_x: 8,
      hex_y: 0,
      damage_bonus: 1,
      defense_bonus: 0,
      speed_modifier: 1,
      damage_dice_count: 2,
      damage_dice_sides: 6,
      stat_modifier: 10,
      ai_profile: 'aggressive'
    }.merge(overrides))
  end

  def test_sim_participant
    puts "Testing SimParticipant..."

    p = create_pc

    # wound_penalty
    assert_eq(p.wound_penalty, 0, "wound_penalty at full HP")
    p.current_hp = 4
    assert_eq(p.wound_penalty, 2, "wound_penalty after damage")
    p.current_hp = 6

    # damage_thresholds
    t = p.damage_thresholds
    assert_eq(t[:miss], 10, "miss threshold at full HP")
    assert_eq(t[:one_hp], 15, "one_hp threshold")
    assert_eq(t[:two_hp], 24, "two_hp threshold")

    # calculate_hp_loss
    assert_eq(p.calculate_hp_loss(10), 0, "damage 10 = 0 HP")
    assert_eq(p.calculate_hp_loss(11), 1, "damage 11 = 1 HP")
    assert_eq(p.calculate_hp_loss(15), 1, "damage 15 = 1 HP")
    assert_eq(p.calculate_hp_loss(16), 2, "damage 16 = 2 HP")
    assert_eq(p.calculate_hp_loss(24), 2, "damage 24 = 2 HP")
    assert_eq(p.calculate_hp_loss(25), 3, "damage 25 = 3 HP")

    # attacks_per_round
    assert_eq(p.attacks_per_round, 3, "base attacks per round")
    p.speed_modifier = 2
    assert_eq(p.attacks_per_round, 5, "attacks with +2 speed")
    p.speed_modifier = 0

    puts
  end

  def test_combat_simulator
    puts "Testing CombatSimulator..."

    # Basic simulation returns SimResult
    sim = CombatSimulatorService.new(pcs: [create_pc], npcs: [create_npc], seed: 12345)
    result = sim.simulate!
    assert(result.is_a?(CombatSimulatorService::SimResult), "simulate! returns SimResult")

    # Deterministic with same seed
    r1 = CombatSimulatorService.new(pcs: [create_pc], npcs: [create_npc], seed: 12345).simulate!
    r2 = CombatSimulatorService.new(pcs: [create_pc], npcs: [create_npc], seed: 12345).simulate!
    assert_eq(r1.pc_victory, r2.pc_victory, "same seed = same result")
    assert_eq(r1.rounds_taken, r2.rounds_taken, "same seed = same rounds")

    # Different seeds produce variation (use more evenly matched participants)
    results = 20.times.map do |i|
      even_pc = create_pc(stat_modifier: 10, max_hp: 5)
      even_npc = create_npc(damage_bonus: 2, max_hp: 5)
      CombatSimulatorService.new(pcs: [even_pc], npcs: [even_npc], seed: i * 1000).simulate!
    end
    unique_outcomes = results.map { |r| "#{r.pc_victory}-#{r.rounds_taken}" }.uniq.size
    assert(unique_outcomes > 1, "different seeds produce variation")

    # Strong PC beats weak NPC
    strong_pc = create_pc(stat_modifier: 20, max_hp: 10)
    weak_npc = create_npc(max_hp: 2)
    result = CombatSimulatorService.new(pcs: [strong_pc], npcs: [weak_npc], seed: 1).simulate!
    assert(result.pc_victory, "strong PC wins")

    puts
  end

  def test_balance_score_calculator
    puts "Testing BalanceScoreCalculator..."

    # Losing returns negative score
    losing = CombatSimulatorService::SimResult.new(
      pc_victory: false,
      rounds_taken: 3,
      surviving_pcs: 0,
      total_pc_hp_remaining: 0,
      total_npc_hp_remaining: 10,
      pc_ko_count: 4,
      npc_ko_count: 1,
      seed_used: 1
    )
    score = BalanceScoreCalculator.score_result(losing)
    assert_eq(score[:score], -1000, "loss = -1000 score")

    # Winning with HP/rounds calculates correctly
    winning = CombatSimulatorService::SimResult.new(
      pc_victory: true,
      rounds_taken: 5,
      surviving_pcs: 4,
      total_pc_hp_remaining: 15,
      total_npc_hp_remaining: 0,
      pc_ko_count: 0,
      npc_ko_count: 4,
      seed_used: 1
    )
    score = BalanceScoreCalculator.score_result(winning)
    assert(score[:score] > 0, "win = positive score")
    assert_eq(score[:components][:hp_score], 150, "HP score = 15 * 10")
    assert_eq(score[:components][:rounds_score], -10, "rounds penalty = 5 * -2")
    assert_eq(score[:components][:victory_bonus], 100, "flawless victory bonus")

    # Aggregate scores
    results = 5.times.map do |i|
      CombatSimulatorService::SimResult.new(
        pc_victory: true,
        rounds_taken: 5,
        surviving_pcs: 4,
        total_pc_hp_remaining: 10,
        total_npc_hp_remaining: 0,
        pc_ko_count: 0,
        npc_ko_count: 3,
        seed_used: i
      )
    end
    agg = BalanceScoreCalculator.aggregate_scores(results)
    assert_eq(agg[:win_rate], 1.0, "100% win rate")

    # Adjustment factor
    factor = BalanceScoreCalculator.calculate_adjustment_factor({ win_rate: 0.3, avg_score: -500 })
    assert_eq(factor, -0.5, "low win rate = -0.5 adjustment")

    factor = BalanceScoreCalculator.calculate_adjustment_factor({ win_rate: 1.0, avg_score: 55 })
    assert_eq(factor, 0.0, "balanced = 0 adjustment")

    puts
  end

  def test_performance
    puts "Testing Performance..."

    # Single simulation < 50ms
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    CombatSimulatorService.new(pcs: [create_pc], npcs: [create_npc], seed: 1).simulate!
    single_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    assert(single_time < 0.05, "single sim < 50ms (was #{(single_time * 1000).round(2)}ms)")

    # 20 simulations < 1000ms
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    20.times { |i| CombatSimulatorService.new(pcs: [create_pc], npcs: [create_npc], seed: i).simulate! }
    batch_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    assert(batch_time < 1.0, "20 sims < 1000ms (was #{(batch_time * 1000).round(2)}ms)")

    puts
    puts "  Single sim: #{(single_time * 1000).round(2)}ms"
    puts "  20 sims:    #{(batch_time * 1000).round(2)}ms"
  end
end

TestRunner.new.run!
